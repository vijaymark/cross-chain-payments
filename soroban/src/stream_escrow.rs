//! Linear, per-second streamed payment (mirrors `contracts/src/StreamEscrow.sol`).
//!
//! Funds are released to `recipient` at `rate_per_second` from `start_time`
//! until `end_time`. The recipient may withdraw accrued funds at any time; the
//! sender may cancel with pro-rata settlement.

use soroban_sdk::{contract, contractimpl, token::TokenClient, Address, Env, MuxedAddress, Symbol};

const ROUTER: Symbol = soroban_sdk::symbol_short!("router");
const SENDER: Symbol = soroban_sdk::symbol_short!("sender");
const RECIPIENT: Symbol = soroban_sdk::symbol_short!("recipient");
const TOKEN: Symbol = soroban_sdk::symbol_short!("token");
const REQUESTED: Symbol = soroban_sdk::symbol_short!("req_amt");
const AMOUNT: Symbol = soroban_sdk::symbol_short!("amount");
const RATE: Symbol = soroban_sdk::symbol_short!("rate");
const START: Symbol = soroban_sdk::symbol_short!("start");
const END: Symbol = soroban_sdk::symbol_short!("end");
const FUNDED: Symbol = soroban_sdk::symbol_short!("funded");
const CANCELLED: Symbol = soroban_sdk::symbol_short!("cancelled");
const WITHDRAWN: Symbol = soroban_sdk::symbol_short!("withdrawn");

#[contract]
pub struct StreamEscrow;

#[contractimpl]
impl StreamEscrow {
    /// Initialize the escrow. The router transfers `amount` into this contract
    /// and then calls `fund()`.
    pub fn stream_init(
        env: Env,
        router: Address,
        sender: Address,
        recipient: Address,
        token: Address,
        amount: i128,
        duration: u64,
    ) {
        router.require_auth();

        let existing: Option<Address> = env.storage().instance().get(&ROUTER);
        assert!(existing.is_none(), "already initialized");

        assert!(amount > 0, "zero amount");
        assert!(duration > 0, "zero duration");
        assert!(amount >= duration as i128, "amount < duration");

        let rate = amount / duration as i128;
        let locked = rate * duration as i128;
        let start = env.ledger().timestamp();

        env.storage().instance().set(&ROUTER, &router);
        env.storage().instance().set(&SENDER, &sender);
        env.storage().instance().set(&RECIPIENT, &recipient);
        env.storage().instance().set(&TOKEN, &token);
        env.storage().instance().set(&REQUESTED, &amount);
        env.storage().instance().set(&AMOUNT, &locked);
        env.storage().instance().set(&RATE, &rate);
        env.storage().instance().set(&START, &start);
        env.storage().instance().set(&END, &(start + duration));
        env.storage().instance().set(&FUNDED, &false);
        env.storage().instance().set(&CANCELLED, &false);
        env.storage().instance().set(&WITHDRAWN, &0i128);
    }

    /// Mark funded once the router has transferred `requested`. Refunds the
    /// division remainder to the sender so accounting is exact.
    pub fn fund(env: Env) {
        let router: Address = env.storage().instance().get(&ROUTER).unwrap();
        router.require_auth();
        assert!(!Self::is_funded(env.clone()), "already funded");

        let token: Address = env.storage().instance().get(&TOKEN).unwrap();
        let sender: Address = env.storage().instance().get(&SENDER).unwrap();
        let requested: i128 = env.storage().instance().get(&REQUESTED).unwrap();
        let locked: i128 = env.storage().instance().get(&AMOUNT).unwrap();

        let token_client = TokenClient::new(&env, &token);
        let balance = token_client.balance(&env.current_contract_address());
        assert!(balance >= requested, "underfunded");

        env.storage().instance().set(&FUNDED, &true);

        let remainder = requested - locked;
        if remainder > 0 {
            let to_muxed = MuxedAddress::from(sender.clone());
            token_client.transfer(&env.current_contract_address(), &to_muxed, &remainder);
        }
    }

    /// Total streamed as of `timestamp`, capped at `amount`.
    pub fn streamed_at(env: Env, timestamp: u64) -> i128 {
        let start: u64 = env.storage().instance().get(&START).unwrap();
        let locked: i128 = env.storage().instance().get(&AMOUNT).unwrap();
        let rate: i128 = env.storage().instance().get(&RATE).unwrap();

        if !Self::is_funded(env.clone()) || timestamp <= start {
            return 0;
        }
        let elapsed = (timestamp - start) as i128;
        let accrued = rate * elapsed;
        if accrued > locked {
            locked
        } else {
            accrued
        }
    }

    pub fn releasable_amount(env: Env) -> i128 {
        let now = env.ledger().timestamp();
        let withdrawn: i128 = env.storage().instance().get(&WITHDRAWN).unwrap_or(0);
        Self::streamed_at(env, now) - withdrawn
    }

    pub fn refundable_amount(env: Env) -> i128 {
        let locked: i128 = env.storage().instance().get(&AMOUNT).unwrap();
        locked - Self::streamed_at(env.clone(), env.ledger().timestamp())
    }

    /// Recipient withdraws everything accrued so far.
    pub fn withdraw(env: Env) {
        let recipient: Address = env.storage().instance().get(&RECIPIENT).unwrap();
        recipient.require_auth();
        assert!(Self::is_funded(env.clone()), "not funded");
        assert!(!Self::is_cancelled(env.clone()), "cancelled");

        let share = Self::releasable_amount(env.clone());
        assert!(share > 0, "nothing to withdraw");

        let withdrawn: i128 = env.storage().instance().get(&WITHDRAWN).unwrap_or(0);
        env.storage().instance().set(&WITHDRAWN, &(withdrawn + share));

        let token: Address = env.storage().instance().get(&TOKEN).unwrap();
        let to_muxed = MuxedAddress::from(recipient);
        TokenClient::new(&env, &token).transfer(&env.current_contract_address(), &to_muxed, &share);
    }

    /// Sender cancels: recipient keeps accrued, sender recovers the remainder.
    pub fn cancel(env: Env) {
        let sender: Address = env.storage().instance().get(&SENDER).unwrap();
        sender.require_auth();
        assert!(Self::is_funded(env.clone()), "not funded");
        assert!(!Self::is_cancelled(env.clone()), "cancelled");

        let token: Address = env.storage().instance().get(&TOKEN).unwrap();
        let recipient: Address = env.storage().instance().get(&RECIPIENT).unwrap();
        let now = env.ledger().timestamp();

        env.storage().instance().set(&CANCELLED, &true);

        let withdrawn: i128 = env.storage().instance().get(&WITHDRAWN).unwrap_or(0);
        let recipient_share = Self::streamed_at(env.clone(), now) - withdrawn;
        let sender_refund = Self::refundable_amount(env.clone());

        let token_client = TokenClient::new(&env, &token);
        let contract_addr = env.current_contract_address();
        if recipient_share > 0 {
            env.storage().instance().set(&WITHDRAWN, &(withdrawn + recipient_share));
            let to_muxed = MuxedAddress::from(recipient);
            token_client.transfer(&contract_addr, &to_muxed, &recipient_share);
        }
        if sender_refund > 0 {
            let to_muxed = MuxedAddress::from(sender);
            token_client.transfer(&contract_addr, &to_muxed, &sender_refund);
        }
    }

    // ---- view getters ----

    pub fn is_funded(env: Env) -> bool {
        env.storage().instance().get(&FUNDED).unwrap_or(false)
    }

    pub fn is_cancelled(env: Env) -> bool {
        env.storage().instance().get(&CANCELLED).unwrap_or(false)
    }

    pub fn withdrawn(env: Env) -> i128 {
        env.storage().instance().get(&WITHDRAWN).unwrap_or(0)
    }

    pub fn amount(env: Env) -> i128 {
        env.storage().instance().get(&AMOUNT).unwrap()
    }

    pub fn start_time(env: Env) -> u64 {
        env.storage().instance().get(&START).unwrap()
    }

    pub fn end_time(env: Env) -> u64 {
        env.storage().instance().get(&END).unwrap()
    }
}
