//! Tranche-based escrow for grant disbursement (mirrors
//! `contracts/src/MilestoneEscrow.sol`). Funds are released in tranches once
//! approved via multisig, DAO vote, or oracle attestation. A timeout fallback
//! lets the sender recover unreleased funds after `release_deadline`.

use soroban_sdk::{
    contract, contractimpl, token::TokenClient, Address, Env, Map, MuxedAddress, Symbol, Vec,
};

use crate::types::ApprovalMode;

const ROUTER: Symbol = soroban_sdk::symbol_short!("router");
const SENDER: Symbol = soroban_sdk::symbol_short!("sender");
const RECIPIENT: Symbol = soroban_sdk::symbol_short!("recipient");
const TOKEN: Symbol = soroban_sdk::symbol_short!("token");
const AMOUNT: Symbol = soroban_sdk::symbol_short!("amount");
const MODE: Symbol = soroban_sdk::symbol_short!("mode");
const ORACLE: Symbol = soroban_sdk::symbol_short!("oracle");
const DEADLINE: Symbol = soroban_sdk::symbol_short!("deadline");
const THRESHOLD: Symbol = soroban_sdk::symbol_short!("threshold");
const TRANCHES: Symbol = soroban_sdk::symbol_short!("tranches");
const APPROVERS: Symbol = soroban_sdk::symbol_short!("approvers");
const RELEASED: Symbol = soroban_sdk::symbol_short!("released");
const APPROVALS: Symbol = soroban_sdk::symbol_short!("approvals");
const APPROVED_BY: Symbol = soroban_sdk::symbol_short!("appr_by");
const ATTESTED: Symbol = soroban_sdk::symbol_short!("attested");
const FUNDED: Symbol = soroban_sdk::symbol_short!("funded");
const CANCELLED: Symbol = soroban_sdk::symbol_short!("cancelled");
const RELEASED_AMT: Symbol = soroban_sdk::symbol_short!("rel_amt");

#[contract]
pub struct MilestoneEscrow;

#[contractimpl]
impl MilestoneEscrow {
    #[allow(clippy::too_many_arguments)]
    pub fn milestone_init(
        env: Env,
        router: Address,
        sender: Address,
        recipient: Address,
        token: Address,
        amount: i128,
        tranche_amounts: Vec<i128>,
        mode: ApprovalMode,
        approvers: Vec<Address>,
        threshold: u32,
        oracle: Address,
        release_deadline: u64,
    ) {
        router.require_auth();

        let existing: Option<Address> = env.storage().instance().get(&ROUTER);
        assert!(existing.is_none(), "already initialized");

        assert!(amount > 0, "zero amount");
        assert!(tranche_amounts.len() > 0, "no tranches");
        assert!(release_deadline > env.ledger().timestamp(), "deadline in past");

        let mut sum: i128 = 0;
        for t in tranche_amounts.iter() {
            assert!(t > 0, "zero tranche");
            sum += t;
        }
        assert!(sum == amount, "tranches != amount");

        env.storage().instance().set(&ROUTER, &router);
        env.storage().instance().set(&SENDER, &sender);
        env.storage().instance().set(&RECIPIENT, &recipient);
        env.storage().instance().set(&TOKEN, &token);
        env.storage().instance().set(&AMOUNT, &amount);
        env.storage().instance().set(&MODE, &mode);
        env.storage().instance().set(&ORACLE, &oracle);
        env.storage().instance().set(&DEADLINE, &release_deadline);
        env.storage().instance().set(&TRANCHES, &tranche_amounts);
        env.storage().instance().set(&FUNDED, &false);
        env.storage().instance().set(&CANCELLED, &false);
        env.storage().instance().set(&RELEASED_AMT, &0i128);

        match &mode {
            ApprovalMode::Oracle => {}
            _ => {
                assert!(approvers.len() > 0, "no approvers");
                env.storage().instance().set(&APPROVERS, &approvers);
                if mode == ApprovalMode::Multisig {
                    assert!(threshold > 0 && threshold <= approvers.len(), "bad threshold");
                    env.storage().instance().set(&THRESHOLD, &threshold);
                } else {
                    // Vote: simple majority of the voter set.
                    let majority = (approvers.len() as u32) / 2 + 1;
                    env.storage().instance().set(&THRESHOLD, &majority);
                }
            }
        }
    }

    /// Mark funded once the router has transferred the full `amount`.
    pub fn fund_milestone(env: Env) {
        let router: Address = env.storage().instance().get(&ROUTER).unwrap();
        router.require_auth();
        assert!(!Self::milestone_funded(env.clone()), "already funded");

        let token: Address = env.storage().instance().get(&TOKEN).unwrap();
        let amount: i128 = env.storage().instance().get(&AMOUNT).unwrap();
        let token_client = TokenClient::new(&env, &token);
        let balance = token_client.balance(&env.current_contract_address());
        assert!(balance >= amount, "underfunded");

        env.storage().instance().set(&FUNDED, &true);
    }

    /// Record an approval for tranche `index` (multisig / vote modes).
    /// `approver` identifies the caller and must authorize the call.
    pub fn approve_milestone(env: Env, approver: Address, index: u32) {
        let mode: ApprovalMode = env.storage().instance().get(&MODE).unwrap();
        assert!(mode != ApprovalMode::Oracle, "not approver mode");

        approver.require_auth();
        let approvers: Vec<Address> = env.storage().instance().get(&APPROVERS).unwrap();
        assert!(approvers.contains(&approver), "not approver");

        assert!(index < Self::tranche_count(env.clone()), "invalid tranche");
        assert!(!Self::milestone_cancelled(env.clone()), "cancelled");

        let released: Map<u32, bool> =
            env.storage().instance().get(&RELEASED).unwrap_or(Map::new(&env));
        assert!(!released.get(index).unwrap_or(false), "already released");

        let mut approved_by: Map<(u32, Address), bool> =
            env.storage().instance().get(&APPROVED_BY).unwrap_or(Map::new(&env));
        let key = (index, approver.clone());
        if approved_by.get(key.clone()).unwrap_or(false) {
            return; // idempotent
        }
        approved_by.set(key, true);
        env.storage().instance().set(&APPROVED_BY, &approved_by);

        let mut approvals: Map<u32, u32> =
            env.storage().instance().get(&APPROVALS).unwrap_or(Map::new(&env));
        let count = approvals.get(index).unwrap_or(0) + 1;
        approvals.set(index, count);
        env.storage().instance().set(&APPROVALS, &approvals);
    }

    /// Oracle attestation that a tranche is complete (oracle mode only).
    pub fn attest_milestone(env: Env, index: u32) {
        let mode: ApprovalMode = env.storage().instance().get(&MODE).unwrap();
        assert!(mode == ApprovalMode::Oracle, "not oracle mode");

        let oracle: Address = env.storage().instance().get(&ORACLE).unwrap();
        oracle.require_auth();

        assert!(index < Self::tranche_count(env.clone()), "invalid tranche");
        assert!(!Self::milestone_cancelled(env.clone()), "cancelled");

        let mut attested: Map<u32, bool> =
            env.storage().instance().get(&ATTESTED).unwrap_or(Map::new(&env));
        assert!(!attested.get(index).unwrap_or(false), "already released");
        attested.set(index, true);
        env.storage().instance().set(&ATTESTED, &attested);
    }

    /// Release tranche `index` to the recipient once approved/attested.
    pub fn release_milestone(env: Env, index: u32) {
        assert!(index < Self::tranche_count(env.clone()), "invalid tranche");
        assert!(!Self::milestone_cancelled(env.clone()), "cancelled");
        assert!(Self::milestone_funded(env.clone()), "not funded");

        let mode: ApprovalMode = env.storage().instance().get(&MODE).unwrap();
        let mut released: Map<u32, bool> =
            env.storage().instance().get(&RELEASED).unwrap_or(Map::new(&env));
        assert!(!released.get(index).unwrap_or(false), "already released");

        if mode == ApprovalMode::Oracle {
            let attested: Map<u32, bool> =
                env.storage().instance().get(&ATTESTED).unwrap_or(Map::new(&env));
            assert!(attested.get(index).unwrap_or(false), "not attested");
        } else {
            let threshold: u32 = env.storage().instance().get(&THRESHOLD).unwrap();
            let approvals: Map<u32, u32> =
                env.storage().instance().get(&APPROVALS).unwrap_or(Map::new(&env));
            assert!(approvals.get(index).unwrap_or(0) >= threshold, "insufficient approvals");
        }

        let tranches: Vec<i128> = env.storage().instance().get(&TRANCHES).unwrap();
        let tranche_amount = tranches.get(index).unwrap();

        released.set(index, true);
        env.storage().instance().set(&RELEASED, &released);

        let released_amt: i128 = env.storage().instance().get(&RELEASED_AMT).unwrap_or(0);
        env.storage().instance().set(&RELEASED_AMT, &(released_amt + tranche_amount));

        let token: Address = env.storage().instance().get(&TOKEN).unwrap();
        let recipient: Address = env.storage().instance().get(&RECIPIENT).unwrap();
        let to_muxed = MuxedAddress::from(recipient);
        TokenClient::new(&env, &token)
            .transfer(&env.current_contract_address(), &to_muxed, &tranche_amount);
    }

    /// Timeout fallback: sender recovers unreleased funds after the deadline.
    pub fn claim_timeout_refund(env: Env) {
        let sender: Address = env.storage().instance().get(&SENDER).unwrap();
        sender.require_auth();

        let deadline: u64 = env.storage().instance().get(&DEADLINE).unwrap();
        assert!(env.ledger().timestamp() >= deadline, "before deadline");
        assert!(!Self::milestone_cancelled(env.clone()), "cancelled");
        assert!(Self::milestone_funded(env.clone()), "not funded");

        env.storage().instance().set(&CANCELLED, &true);

        let amount: i128 = env.storage().instance().get(&AMOUNT).unwrap();
        let released_amt: i128 = env.storage().instance().get(&RELEASED_AMT).unwrap_or(0);
        let refund = amount - released_amt;

        if refund > 0 {
            let token: Address = env.storage().instance().get(&TOKEN).unwrap();
            let to_muxed = MuxedAddress::from(sender);
            TokenClient::new(&env, &token)
                .transfer(&env.current_contract_address(), &to_muxed, &refund);
        }
    }

    // ---- view getters ----

    pub fn milestone_funded(env: Env) -> bool {
        env.storage().instance().get(&FUNDED).unwrap_or(false)
    }

    pub fn milestone_cancelled(env: Env) -> bool {
        env.storage().instance().get(&CANCELLED).unwrap_or(false)
    }

    pub fn tranche_count(env: Env) -> u32 {
        let tranches: Vec<i128> = env.storage().instance().get(&TRANCHES).unwrap();
        tranches.len()
    }

    pub fn released_amount(env: Env) -> i128 {
        env.storage().instance().get(&RELEASED_AMT).unwrap_or(0)
    }

    pub fn unreleased_amount(env: Env) -> i128 {
        let amount: i128 = env.storage().instance().get(&AMOUNT).unwrap();
        amount - Self::released_amount(env)
    }

    pub fn approval_count(env: Env, index: u32) -> u32 {
        let approvals: Map<u32, u32> =
            env.storage().instance().get(&APPROVALS).unwrap_or(Map::new(&env));
        approvals.get(index).unwrap_or(0)
    }

    /// 0 Created, 2 PendingMilestone, 3 PartiallyReleased, 4 Completed, 5 Cancelled.
    pub fn status(env: Env) -> u32 {
        if !Self::milestone_funded(env.clone()) {
            return 0;
        }
        if Self::milestone_cancelled(env.clone()) {
            return 5;
        }
        let amount: i128 = env.storage().instance().get(&AMOUNT).unwrap();
        let released_amt = Self::released_amount(env);
        if released_amt == amount {
            return 4;
        }
        if released_amt > 0 {
            return 3;
        }
        2
    }
}
