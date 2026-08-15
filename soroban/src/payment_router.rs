//! Entry point for all cross-chain payments (mirrors
//! `contracts/src/PaymentRouter.sol`).
//!
//! Source-chain flow: validate → deploy the correct escrow → pull funds → send
//! the canonical message to the bridge. Destination-chain flow: `recv_bytes`
//! (bridge-only, bytes) decodes, replay-checks, and records the announcement.
//! The router depends only on the `Bridge` interface (`crate::bridge`), never
//! on a concrete bridge.

use soroban_sdk::{
    contract, contractimpl, contracttype, token::TokenClient, Address, Bytes, BytesN, Env, Map,
    Symbol, Vec,
};

use crate::bridge::BridgeClient;
use crate::codec;
use crate::milestone_escrow::MilestoneEscrowClient;
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
const ALLOWED_TOKENS: Symbol = soroban_sdk::symbol_short!("tokens");

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
        admin: Address,
        source_chain_id: u32,
        stream_escrow_wasm: BytesN<32>,
        milestone_escrow_wasm: BytesN<32>,
    ) {
        admin.require_auth();

        let existing: Option<u32> = env.storage().instance().get(&CHAIN_ID);
        assert!(existing.is_none(), "already initialized");

        env.storage().instance().set(&CHAIN_ID, &source_chain_id);
        env.storage().instance().set(&OWNER, &admin);
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

    /// Allow/disallow a token on this chain. Checked when funding a payment and
    /// when announcing an inbound message, preventing spoofed token claims.
    pub fn set_allowed_token(env: Env, token: Address, allowed: bool) {
        let owner: Address = env.storage().instance().get(&OWNER).unwrap();
        owner.require_auth();

        let mut allowed_tokens: Map<Address, bool> =
            env.storage().instance().get(&ALLOWED_TOKENS).unwrap_or(Map::new(&env));
        allowed_tokens.set(token, allowed);
        env.storage().instance().set(&ALLOWED_TOKENS, &allowed_tokens);
    }

    pub fn is_token_allowed(env: Env, token: Address) -> bool {
        let allowed_tokens: Map<Address, bool> =
            env.storage().instance().get(&ALLOWED_TOKENS).unwrap_or(Map::new(&env));
        allowed_tokens.get(token).unwrap_or(false)
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
    ) -> BytesN<32> {
        sender.require_auth();
        assert!(amount > 0, "zero amount");
        assert!(timeout > env.ledger().timestamp(), "timeout in past");
        assert!(Self::is_token_allowed(env.clone(), token.clone()), "token not allowed");

        let nonce = Self::next_nonce(&env, &sender);
        let message = CrossChainMessage {
            nonce,
            source_chain_id: Self::chain_id(env.clone()),
            dest_chain_id,
            sender: sender.clone(),
            token: token.clone(),
            amount,
            recipient: recipient.clone(),
            mode: PaymentMode::OneTime,
            metadata: Bytes::new(&env),
        };

        let message_id = Self::dispatch(&env, &sender, dest_chain_id, &message);

        let token_client = TokenClient::new(&env, &token);
        token_client.transfer_from(
            &env.current_contract_address(),
            &sender,
            &env.current_contract_address(),
            &amount,
        );

        let lock = OneTimeLock {
            sender,
            token,
            amount,
            timeout,
            settled: false,
            refunded: false,
        };
        let mut locks: Map<BytesN<32>, OneTimeLock> =
            env.storage().instance().get(&LOCKS).unwrap_or(Map::new(&env));
        locks.set(message_id.clone(), lock);
        env.storage().instance().set(&LOCKS, &locks);

        message_id
    }

    pub fn refund_one_time(env: Env, sender: Address, delivery_id: BytesN<32>) {
        sender.require_auth();

        let mut locks: Map<BytesN<32>, OneTimeLock> =
            env.storage().instance().get(&LOCKS).unwrap_or(Map::new(&env));
        let mut lock = locks.get(delivery_id.clone()).expect("unknown lock");
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
    pub fn settle_one_time(env: Env, delivery_id: BytesN<32>) {
        let bridge = Self::bridge(env.clone());
        bridge.require_auth();

        let mut locks: Map<BytesN<32>, OneTimeLock> =
            env.storage().instance().get(&LOCKS).unwrap_or(Map::new(&env));
        let mut lock = locks.get(delivery_id.clone()).expect("unknown lock");
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
    ) -> (BytesN<32>, Address) {
        sender.require_auth();
        assert!(amount > 0, "zero amount");
        assert!(duration > 0, "zero duration");
        assert!(timeout > env.ledger().timestamp(), "timeout in past");
        assert!(Self::is_token_allowed(env.clone(), token.clone()), "token not allowed");

        let nonce = Self::next_nonce(&env, &sender);
        let message = CrossChainMessage {
            nonce,
            source_chain_id: Self::chain_id(env.clone()),
            dest_chain_id,
            sender: sender.clone(),
            token: token.clone(),
            amount,
            recipient: recipient.clone(),
            mode: PaymentMode::Stream,
            metadata: Bytes::new(&env),
        };

        let message_id = Self::dispatch(&env, &sender, dest_chain_id, &message);

        let escrow = Self::deploy_stream_escrow(&env, &sender, &recipient, &token, amount, duration, nonce);

        let token_client = TokenClient::new(&env, &token);
        token_client.transfer_from(&env.current_contract_address(), &sender, &escrow, &amount);
        StreamEscrowClient::new(&env, &escrow).fund();

        (message_id, escrow)
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
    ) -> (BytesN<32>, Address) {
        sender.require_auth();
        assert!(amount > 0, "zero amount");
        assert!(timeout > env.ledger().timestamp(), "timeout in past");
        assert!(Self::is_token_allowed(env.clone(), token.clone()), "token not allowed");

        let nonce = Self::next_nonce(&env, &sender);
        let message = CrossChainMessage {
            nonce,
            source_chain_id: Self::chain_id(env.clone()),
            dest_chain_id,
            sender: sender.clone(),
            token: token.clone(),
            amount,
            recipient: recipient.clone(),
            mode: PaymentMode::Milestone,
            metadata: Bytes::new(&env),
        };

        let message_id = Self::dispatch(&env, &sender, dest_chain_id, &message);

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

        (message_id, escrow)
    }

    // ---- destination chain: receive bridge messages ----

    /// Typed receive entry point (used by direct/typed callers such as tests).
    /// Bridge-only: requires the configured bridge to authorize the call.
    pub fn receive_message(env: Env, message: CrossChainMessage) {
        Self::process_inbound(&env, message);
    }

    /// Bytes-based receive entry point called by bridge adapters (e.g. the
    /// Axelar GMP adapter). Decodes the canonical payload and applies the same
    /// replay/allowlist checks as `receive_message`.
    pub fn recv_bytes(env: Env, payload: Bytes) {
        let message = codec::decode_message(&payload);
        Self::process_inbound(&env, message);
    }

    // ---- view helpers ----

    pub fn chain_id(env: Env) -> u32 {
        env.storage().instance().get(&CHAIN_ID).unwrap()
    }

    pub fn bridge(env: Env) -> Address {
        env.storage().instance().get(&BRIDGE).unwrap()
    }

    pub fn owner(env: Env) -> Address {
        env.storage().instance().get(&OWNER).unwrap()
    }

    pub fn nonce(env: Env, sender: Address) -> u64 {
        let nonces: Map<Address, u64> =
            env.storage().instance().get(&NONCES).unwrap_or(Map::new(&env));
        nonces.get(sender).unwrap_or(0)
    }

    pub fn is_delivered(env: Env, source_chain_id: u32, sender: Address, nonce: u64) -> bool {
        let delivered: Map<(u32, Address, u64), bool> =
            env.storage().instance().get(&DELIVERED).unwrap_or(Map::new(&env));
        delivered.get((source_chain_id, sender, nonce)).unwrap_or(false)
    }

    pub fn announced(env: Env, source_chain_id: u32, sender: Address, nonce: u64) -> CrossChainMessage {
        let announced: Map<(u32, Address, u64), CrossChainMessage> =
            env.storage().instance().get(&ANNOUNCED).unwrap_or(Map::new(&env));
        announced.get((source_chain_id, sender, nonce)).expect("not announced")
    }

    pub fn one_time_lock(env: Env, delivery_id: BytesN<32>) -> OneTimeLock {
        let locks: Map<BytesN<32>, OneTimeLock> =
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

    /// Encode the message, hand it to the configured bridge, and return the
    /// bridge-agnostic message id (`sha256(payload)`), mirroring the EVM
    /// router's `keccak256(payload)`.
    fn dispatch(
        env: &Env,
        caller: &Address,
        dest_chain_id: u32,
        message: &CrossChainMessage,
    ) -> BytesN<32> {
        let payload = codec::encode_message(env, message);
        let bridge: Address = env.storage().instance().get(&BRIDGE).unwrap();
        BridgeClient::new(env, &bridge).send(caller, &dest_chain_id, &payload);
        env.crypto().sha256(&payload)
    }

    /// Shared inbound processing: auth, dest-chain check, token allowlist,
    /// replay check, announcement.
    fn process_inbound(env: &Env, message: CrossChainMessage) {
        let bridge: Address = env.storage().instance().get(&BRIDGE).unwrap();
        bridge.require_auth();

        let chain_id: u32 = env.storage().instance().get(&CHAIN_ID).unwrap();
        assert!(message.dest_chain_id == chain_id, "wrong dest chain");

        let allowed_tokens: Map<Address, bool> =
            env.storage().instance().get(&ALLOWED_TOKENS).unwrap_or(Map::new(env));
        assert!(allowed_tokens.get(message.token.clone()).unwrap_or(false), "token not allowed");

        let mut delivered: Map<(u32, Address, u64), bool> =
            env.storage().instance().get(&DELIVERED).unwrap_or(Map::new(env));
        let key = (message.source_chain_id, message.sender.clone(), message.nonce);
        assert!(!delivered.get(key.clone()).unwrap_or(false), "replay");
        delivered.set(key, true);
        env.storage().instance().set(&DELIVERED, &delivered);

        let mut announced: Map<(u32, Address, u64), CrossChainMessage> =
            env.storage().instance().get(&ANNOUNCED).unwrap_or(Map::new(env));
        announced.set(
            (message.source_chain_id, message.sender.clone(), message.nonce),
            message,
        );
        env.storage().instance().set(&ANNOUNCED, &announced);
    }

    /// Deploy salt unique per (sender, nonce) so escrows from different
    /// senders never collide on the deterministic deploy address.
    fn salt_for_deploy(env: &Env, sender: &Address, nonce: u64) -> BytesN<32> {
        let mut data = Bytes::new(env);
        data.append(&Bytes::from(sender.to_string()));
        data.extend_from_slice(&nonce.to_be_bytes());
        env.crypto().sha256(&data)
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
        let salt = Self::salt_for_deploy(env, sender, nonce);
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
        let salt = Self::salt_for_deploy(env, sender, nonce);
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
