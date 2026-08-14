//! Entry point for all cross-chain payments (mirrors
//! `contracts/src/PaymentRouter.sol`).
//!
//! Source-chain flow: validate → deploy the correct escrow → pull funds → send
//! the canonical message to the bridge. Destination-chain flow: `receive_message`
//! decodes, replay-checks, and records the announcement.

use soroban_sdk::{
    contract, contractimpl, contracttype, token::TokenClient, Address, Bytes, BytesN, Env, Map,
    Symbol, Vec,
};

use crate::milestone_escrow::MilestoneEscrowClient;
use crate::mock_bridge::MockBridgeAdapterClient;
use crate::stream_escrow::StreamEscrowClient;
use crate::types::{ApprovalMode, CrossChainMessage, PaymentMode};

const CHAIN_ID: Symbol = soroban_sdk::symbol_short!("chain_id");
const OWNER: Symbol = soroban_sdk::symbol_short!("owner");
const BRIDGE: Symbol = soroban_sdk::symbol_short!("bridge");
const STREAM_WASM: Symbol = soroban_sdk::symbol_short!("strm_wasm");
const MILESTONE_WASM: Symbol = soroban_sdk::symbol_short!("mile_wsm");
const NONCES: Symbol = soroban_sdk::symbol_short!("nonces");
const DELIVERED: Symbol = soroban_sdk::symbol_short!("delivered");
const LOCKS: Symbol = soroban_sdk::symbol_short!("locks");
const ANNOUNCED: Symbol = soroban_sdk::symbol_short!("announced");

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OneTimeLock {
    pub sender: Address,
    pub token: Address,
    pub amount: i128,
    pub timeout: u64,
    pub settled: bool,
    pub refunded: bool,
}

#[contract]
pub struct PaymentRouter;

#[contractimpl]
impl PaymentRouter {
    pub fn router_init(
        env: Env,
        source_chain_id: u32,
        stream_escrow_wasm: BytesN<32>,
        milestone_escrow_wasm: BytesN<32>,
    ) {
        env.storage().instance().set(&CHAIN_ID, &source_chain_id);
        env.storage().instance().set(&OWNER, &env.current_contract_address());
        env.storage().instance().set(&STREAM_WASM, &stream_escrow_wasm);
        env.storage().instance().set(&MILESTONE_WASM, &milestone_escrow_wasm);
    }

    // ---- administration ----

    pub fn set_bridge(env: Env, bridge: Address) {
        let owner: Address = env.storage().instance().get(&OWNER).unwrap();
        owner.require_auth();
        env.storage().instance().set(&BRIDGE, &bridge);
    }

    pub fn transfer_ownership(env: Env, new_owner: Address) {
        let owner: Address = env.storage().instance().get(&OWNER).unwrap();
        owner.require_auth();
        env.storage().instance().set(&OWNER, &new_owner);
    }

    // ---- one-time payments ----

    pub fn send_payment(
        env: Env,
        sender: Address,
        token: Address,
        amount: i128,
        recipient: Address,
        dest_chain_id: u32,
        timeout: u64,
    ) -> u64 {
        sender.require_auth();
        assert!(amount > 0, "zero amount");
        assert!(timeout > env.ledger().timestamp(), "timeout in past");

        let nonce = Self::next_nonce(&env, &sender);
        let message = CrossChainMessage {
            nonce,
            source_chain_id: Self::chain_id(env.clone()),
            dest_chain_id,
            token: token.clone(),
            amount,
            recipient: recipient.clone(),
            mode: PaymentMode::OneTime,
            metadata: Bytes::new(&env),
        };

        let bridge = Self::bridge(env.clone());
        let delivery_id = MockBridgeAdapterClient::new(&env, &bridge).send_message(&message);

        let token_client = TokenClient::new(&env, &token);
        token_client.transfer_from(&env.current_contract_address(), &sender, &env.current_contract_address(), &amount);

        let lock = OneTimeLock {
            sender,
            token,
            amount,
            timeout,
            settled: false,
            refunded: false,
        };
        let mut locks: Map<u64, OneTimeLock> =
            env.storage().instance().get(&LOCKS).unwrap_or(Map::new(&env));
        locks.set(delivery_id, lock);
        env.storage().instance().set(&LOCKS, &locks);

        delivery_id
    }

    pub fn refund_one_time(env: Env, sender: Address, delivery_id: u64) {
        sender.require_auth();

        let mut locks: Map<u64, OneTimeLock> =
            env.storage().instance().get(&LOCKS).unwrap_or(Map::new(&env));
        let mut lock = locks.get(delivery_id).expect("unknown lock");
        assert!(lock.sender == sender, "not sender");
        assert!(!lock.settled, "already settled");
        assert!(!lock.refunded, "already refunded");
        assert!(env.ledger().timestamp() > lock.timeout, "before timeout");

        lock.refunded = true;
        let amount = lock.amount;
        let lock_token = lock.token.clone();
        locks.set(delivery_id, lock);
        env.storage().instance().set(&LOCKS, &locks);

        let token_client = TokenClient::new(&env, &lock_token);
        let to_muxed = soroban_sdk::MuxedAddress::from(sender);
        token_client.transfer(&env.current_contract_address(), &to_muxed, &amount);
    }

    /// Mark a one-time payment as delivered (bridge-only confirmation).
    pub fn settle_one_time(env: Env, delivery_id: u64) {
        let bridge = Self::bridge(env.clone());
        bridge.require_auth();

        let mut locks: Map<u64, OneTimeLock> =
            env.storage().instance().get(&LOCKS).unwrap_or(Map::new(&env));
        let mut lock = locks.get(delivery_id).expect("unknown lock");
        lock.settled = true;
        locks.set(delivery_id, lock);
        env.storage().instance().set(&LOCKS, &locks);
    }

    // ---- streamed payments ----

    #[allow(clippy::too_many_arguments)]
    pub fn stream_payment(
        env: Env,
        sender: Address,
        token: Address,
        amount: i128,
        recipient: Address,
        dest_chain_id: u32,
        duration: u64,
        timeout: u64,
    ) -> (u64, Address) {
        sender.require_auth();
        assert!(amount > 0, "zero amount");
        assert!(duration > 0, "zero duration");
        assert!(timeout > env.ledger().timestamp(), "timeout in past");

        let nonce = Self::next_nonce(&env, &sender);
        let message = CrossChainMessage {
            nonce,
            source_chain_id: Self::chain_id(env.clone()),
            dest_chain_id,
            token: token.clone(),
            amount,
            recipient: recipient.clone(),
            mode: PaymentMode::Stream,
            metadata: Bytes::new(&env),
        };

        let bridge = Self::bridge(env.clone());
        let delivery_id = MockBridgeAdapterClient::new(&env, &bridge).send_message(&message);

        let escrow = Self::deploy_stream_escrow(&env, &sender, &recipient, &token, amount, duration, nonce);

        let token_client = TokenClient::new(&env, &token);
        token_client.transfer_from(&env.current_contract_address(), &sender, &escrow, &amount);
        StreamEscrowClient::new(&env, &escrow).fund();

        (delivery_id, escrow)
    }

    // ---- milestone payments ----

    #[allow(clippy::too_many_arguments)]
    pub fn create_milestone_payment(
        env: Env,
        sender: Address,
        token: Address,
        amount: i128,
        recipient: Address,
        dest_chain_id: u32,
        tranche_amounts: Vec<i128>,
        mode: ApprovalMode,
        approvers: Vec<Address>,
        threshold: u32,
        oracle: Address,
        release_deadline: u64,
        timeout: u64,
    ) -> (u64, Address) {
        sender.require_auth();
        assert!(amount > 0, "zero amount");
        assert!(timeout > env.ledger().timestamp(), "timeout in past");

        let nonce = Self::next_nonce(&env, &sender);
        let message = CrossChainMessage {
            nonce,
            source_chain_id: Self::chain_id(env.clone()),
            dest_chain_id,
            token: token.clone(),
            amount,
            recipient: recipient.clone(),
            mode: PaymentMode::Milestone,
            metadata: Bytes::new(&env),
        };

        let bridge = Self::bridge(env.clone());
        let delivery_id = MockBridgeAdapterClient::new(&env, &bridge).send_message(&message);

        let escrow = Self::deploy_milestone_escrow(
            &env,
            &sender,
            &recipient,
            &token,
            amount,
            &tranche_amounts,
            &mode,
            &approvers,
            threshold,
            &oracle,
            release_deadline,
            nonce,
        );

        let token_client = TokenClient::new(&env, &token);
        token_client.transfer_from(&env.current_contract_address(), &sender, &escrow, &amount);
        MilestoneEscrowClient::new(&env, &escrow).fund_milestone();

        (delivery_id, escrow)
    }

    // ---- destination chain: receive bridge messages ----

    pub fn receive_message(env: Env, message: CrossChainMessage) {
        let bridge = Self::bridge(env.clone());
        bridge.require_auth();

        assert!(message.dest_chain_id == Self::chain_id(env.clone()), "wrong dest chain");

        let mut delivered: Map<(u32, u64), bool> =
            env.storage().instance().get(&DELIVERED).unwrap_or(Map::new(&env));
        let key = (message.source_chain_id, message.nonce);
        assert!(!delivered.get(key).unwrap_or(false), "replay");
        delivered.set(key, true);
        env.storage().instance().set(&DELIVERED, &delivered);

        let mut announced: Map<(u32, u64), CrossChainMessage> =
            env.storage().instance().get(&ANNOUNCED).unwrap_or(Map::new(&env));
        announced.set((message.source_chain_id, message.nonce), message);
        env.storage().instance().set(&ANNOUNCED, &announced);
    }

    // ---- view helpers ----

    pub fn chain_id(env: Env) -> u32 {
        env.storage().instance().get(&CHAIN_ID).unwrap()
    }

    pub fn bridge(env: Env) -> Address {
        env.storage().instance().get(&BRIDGE).unwrap()
    }

    pub fn nonce(env: Env, sender: Address) -> u64 {
        let nonces: Map<Address, u64> =
            env.storage().instance().get(&NONCES).unwrap_or(Map::new(&env));
        nonces.get(sender).unwrap_or(0)
    }

    pub fn is_delivered(env: Env, source_chain_id: u32, nonce: u64) -> bool {
        let delivered: Map<(u32, u64), bool> =
            env.storage().instance().get(&DELIVERED).unwrap_or(Map::new(&env));
        delivered.get((source_chain_id, nonce)).unwrap_or(false)
    }

    pub fn announced(env: Env, source_chain_id: u32, nonce: u64) -> CrossChainMessage {
        let announced: Map<(u32, u64), CrossChainMessage> =
            env.storage().instance().get(&ANNOUNCED).unwrap_or(Map::new(&env));
        announced.get((source_chain_id, nonce)).expect("not announced")
    }

    pub fn one_time_lock(env: Env, delivery_id: u64) -> OneTimeLock {
        let locks: Map<u64, OneTimeLock> =
            env.storage().instance().get(&LOCKS).unwrap_or(Map::new(&env));
        locks.get(delivery_id).expect("unknown lock")
    }
}

impl PaymentRouter {
    fn next_nonce(env: &Env, sender: &Address) -> u64 {
        let mut nonces: Map<Address, u64> =
            env.storage().instance().get(&NONCES).unwrap_or(Map::new(env));
        let nonce = nonces.get(sender.clone()).unwrap_or(0);
        nonces.set(sender.clone(), nonce + 1);
        env.storage().instance().set(&NONCES, &nonces);
        nonce
    }

    fn salt_from_nonce(env: &Env, nonce: u64) -> BytesN<32> {
        let mut arr = [0u8; 32];
        arr[24..32].copy_from_slice(&nonce.to_be_bytes());
        BytesN::from_array(env, &arr)
    }

    #[allow(clippy::too_many_arguments)]
    fn deploy_stream_escrow(
        env: &Env,
        sender: &Address,
        recipient: &Address,
        token: &Address,
        amount: i128,
        duration: u64,
        nonce: u64,
    ) -> Address {
        let wasm: BytesN<32> = env.storage().instance().get(&STREAM_WASM).unwrap();
        let salt = Self::salt_from_nonce(env, nonce);
        let addr = env.deployer().with_current_contract(salt).deploy_v2(wasm, ());

        let router = env.current_contract_address();
        StreamEscrowClient::new(env, &addr).stream_init(
            &router,
            sender,
            recipient,
            token,
            &amount,
            &duration,
        );
        addr
    }

    #[allow(clippy::too_many_arguments)]
    fn deploy_milestone_escrow(
        env: &Env,
        sender: &Address,
        recipient: &Address,
        token: &Address,
        amount: i128,
        tranche_amounts: &Vec<i128>,
        mode: &ApprovalMode,
        approvers: &Vec<Address>,
        threshold: u32,
        oracle: &Address,
        release_deadline: u64,
        nonce: u64,
    ) -> Address {
        let wasm: BytesN<32> = env.storage().instance().get(&MILESTONE_WASM).unwrap();
        let salt = Self::salt_from_nonce(env, nonce);
        let addr = env.deployer().with_current_contract(salt).deploy_v2(wasm, ());

        let router = env.current_contract_address();
        MilestoneEscrowClient::new(env, &addr).milestone_init(
            &router,
            sender,
            recipient,
            token,
            &amount,
            tranche_amounts,
            mode,
            approvers,
            &threshold,
            oracle,
            &release_deadline,
        );
        addr
    }
}
