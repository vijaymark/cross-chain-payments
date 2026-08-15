use ipay::{
    milestone_escrow::{MilestoneEscrow, MilestoneEscrowClient},
    mock_token::{MockToken, MockTokenClient},
    types::ApprovalMode,
};
use soroban_sdk::token::TokenClient;
use soroban_sdk::testutils::{Address as _, Ledger as _};
use soroban_sdk::{vec, Address, Env, String, Vec};

const AMOUNT: i128 = 100;

fn setup() -> (Env, Address, Address, Address, Address) {
    let env = Env::default();
    env.mock_all_auths();

    let admin = Address::generate(&env);
    let router = Address::generate(&env);
    let sender = Address::generate(&env);
    let recipient = Address::generate(&env);

    let token = env.register(MockToken, ());
    MockTokenClient::new(&env, &token).token_init(
        &admin,
        &String::from_str(&env, "Mock"),
        &String::from_str(&env, "MCK"),
        &7u32,
    );
    MockTokenClient::new(&env, &token).mint(&sender, &(AMOUNT * 10));
    (env, router, sender, recipient, token)
}

fn tranches(env: &Env) -> Vec<i128> {
    vec![env, 40i128, 30i128, 30i128]
}

fn approvers(env: &Env) -> Vec<Address> {
    vec![
        env,
        Address::generate(env),
        Address::generate(env),
        Address::generate(env),
    ]
}

fn deploy_multisig(
    env: &Env,
    router: &Address,
    sender: &Address,
    recipient: &Address,
    token: &Address,
    approvers: Vec<Address>,
    deadline: u64,
) -> Address {
    let escrow = env.register(MilestoneEscrow, ());
    MilestoneEscrowClient::new(env, &escrow).milestone_init(
        router,
        sender,
        recipient,
        token,
        &AMOUNT,
        &tranches(env),
        &ApprovalMode::Multisig,
        &approvers,
        &2u32,
        &Address::generate(env),
        &deadline,
    );
    escrow
}

#[test]
fn test_release_after_threshold() {
    let (env, router, sender, recipient, token) = setup();
    let approvers = approvers(&env);
    let escrow =
        deploy_multisig(&env, &router, &sender, &recipient, &token, approvers.clone(), env.ledger().timestamp() + 1000);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.fund_milestone();

    client.approve_milestone(&approvers.get(0).unwrap(), &0);
    client.approve_milestone(&approvers.get(1).unwrap(), &0);
    client.release_milestone(&0);

    assert_eq!(TokenClient::new(&env, &token).balance(&recipient), 40);
    assert_eq!(client.released_amount(), 40);
}

#[test]
#[should_panic(expected = "insufficient approvals")]
fn test_release_before_threshold_panics() {
    let (env, router, sender, recipient, token) = setup();
    let approvers = approvers(&env);
    let escrow =
        deploy_multisig(&env, &router, &sender, &recipient, &token, approvers.clone(), env.ledger().timestamp() + 1000);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.fund_milestone();

    client.approve_milestone(&approvers.get(0).unwrap(), &0);
    client.release_milestone(&0);
}

#[test]
fn test_vote_majority() {
    let (env, router, sender, recipient, token) = setup();
    let voters = approvers(&env);
    let escrow = env.register(MilestoneEscrow, ());
    MilestoneEscrowClient::new(&env, &escrow).milestone_init(
        &router,
        &sender,
        &recipient,
        &token,
        &AMOUNT,
        &tranches(&env),
        &ApprovalMode::Vote,
        &voters,
        &0u32,
        &Address::generate(&env),
        &(env.ledger().timestamp() + 1000),
    );
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.fund_milestone();

    // majority of 3 = 2
    client.approve_milestone(&voters.get(0).unwrap(), &1);
    client.approve_milestone(&voters.get(1).unwrap(), &1);
    client.release_milestone(&1);

    assert_eq!(TokenClient::new(&env, &token).balance(&recipient), 30);
}

#[test]
fn test_oracle_attest_and_release() {
    let (env, router, sender, recipient, token) = setup();
    let oracle = Address::generate(&env);
    let escrow = env.register(MilestoneEscrow, ());
    MilestoneEscrowClient::new(&env, &escrow).milestone_init(
        &router,
        &sender,
        &recipient,
        &token,
        &AMOUNT,
        &tranches(&env),
        &ApprovalMode::Oracle,
        &Vec::<Address>::new(&env),
        &0u32,
        &oracle,
        &(env.ledger().timestamp() + 1000),
    );
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.fund_milestone();

    client.attest_milestone(&2);
    client.release_milestone(&2);

    assert_eq!(TokenClient::new(&env, &token).balance(&recipient), 30);
}

#[test]
fn test_timeout_refund() {
    let (env, router, sender, recipient, token) = setup();
    let approvers = approvers(&env);
    let escrow =
        deploy_multisig(&env, &router, &sender, &recipient, &token, approvers.clone(), env.ledger().timestamp() + 1000);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.fund_milestone();

    let sender_before = TokenClient::new(&env, &token).balance(&sender);
    client.approve_milestone(&approvers.get(0).unwrap(), &0);
    client.approve_milestone(&approvers.get(1).unwrap(), &0);
    client.release_milestone(&0); // release 40

    env.ledger().set_timestamp(env.ledger().timestamp() + 1001);
    client.claim_timeout_refund();

    assert!(client.milestone_cancelled());
    assert_eq!(
        TokenClient::new(&env, &token).balance(&sender),
        sender_before + (AMOUNT - 40)
    );
}

#[test]
#[should_panic(expected = "before deadline")]
fn test_timeout_refund_before_deadline_panics() {
    let (env, router, sender, recipient, token) = setup();
    let approvers = approvers(&env);
    let escrow =
        deploy_multisig(&env, &router, &sender, &recipient, &token, approvers.clone(), env.ledger().timestamp() + 1000);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.fund_milestone();
    client.claim_timeout_refund();
}

#[test]
fn test_status_transitions() {
    let (env, router, sender, recipient, token) = setup();
    let approvers = approvers(&env);
    let escrow =
        deploy_multisig(&env, &router, &sender, &recipient, &token, approvers.clone(), env.ledger().timestamp() + 1000);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    assert_eq!(client.status(), 0); // Created

    client.fund_milestone();
    assert_eq!(client.status(), 2); // PendingMilestone

    client.approve_milestone(&approvers.get(0).unwrap(), &0);
    client.approve_milestone(&approvers.get(1).unwrap(), &0);
    client.release_milestone(&0);
    assert_eq!(client.status(), 3); // PartiallyReleased
}

#[test]
#[should_panic(expected = "already initialized")]
fn test_milestone_init_cannot_reinitialize() {
    let (env, router, sender, recipient, token) = setup();
    let approvers = approvers(&env);
    let escrow = env.register(MilestoneEscrow, ());
    let deadline = env.ledger().timestamp() + 1000;
    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.milestone_init(
        &router,
        &sender,
        &recipient,
        &token,
        &AMOUNT,
        &tranches(&env),
        &ApprovalMode::Multisig,
        &approvers,
        &2u32,
        &Address::generate(&env),
        &deadline,
    );
    client.milestone_init(
        &router,
        &sender,
        &recipient,
        &token,
        &AMOUNT,
        &tranches(&env),
        &ApprovalMode::Multisig,
        &approvers,
        &2u32,
        &Address::generate(&env),
        &deadline,
    );
}

#[test]
#[should_panic(expected = "insufficient approvals")]
fn test_approve_milestone_double_count_blocked() {
    let (env, router, sender, recipient, token) = setup();
    let approvers = approvers(&env);
    let escrow = deploy_multisig(
        &env,
        &router,
        &sender,
        &recipient,
        &token,
        approvers.clone(),
        env.ledger().timestamp() + 1000,
    );
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = MilestoneEscrowClient::new(&env, &escrow);
    client.fund_milestone();

    // The same approver approving twice must count once.
    client.approve_milestone(&approvers.get(0).unwrap(), &0);
    client.approve_milestone(&approvers.get(0).unwrap(), &0);
    assert_eq!(client.approval_count(&0), 1);

    // Threshold is 2, so a single approver still cannot release.
    client.release_milestone(&0);
}
