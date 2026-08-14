use cross_chain_payments::{
    mock_token::{MockToken, MockTokenClient},
    stream_escrow::{StreamEscrow, StreamEscrowClient},
};
use soroban_sdk::token::TokenClient;
use soroban_sdk::testutils::{Address as _, Ledger as _};
use soroban_sdk::{Address, Env, String};

const AMOUNT: i128 = 1000;
const DURATION: u64 = 1000;

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

fn deploy(
    env: &Env,
    router: &Address,
    sender: &Address,
    recipient: &Address,
    token: &Address,
    amount: i128,
    duration: u64,
) -> Address {
    let escrow = env.register(StreamEscrow, ());
    StreamEscrowClient::new(env, &escrow).stream_init(router, sender, recipient, token, &amount, &duration);
    escrow
}

#[test]
fn test_full_withdraw_at_end() {
    let (env, router, sender, recipient, token) = setup();
    let escrow = deploy(&env, &router, &sender, &recipient, &token, AMOUNT, DURATION);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = StreamEscrowClient::new(&env, &escrow);
    client.fund();
    assert_eq!(client.amount(), AMOUNT);

    let start = client.start_time();
    env.ledger().set_timestamp(start + DURATION);
    client.withdraw();

    assert_eq!(TokenClient::new(&env, &token).balance(&recipient), AMOUNT);
    assert_eq!(TokenClient::new(&env, &token).balance(&escrow), 0);
}

#[test]
fn test_partial_withdraw_mid_stream() {
    let (env, router, sender, recipient, token) = setup();
    let escrow = deploy(&env, &router, &sender, &recipient, &token, AMOUNT, DURATION);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = StreamEscrowClient::new(&env, &escrow);
    client.fund();

    let start = client.start_time();
    env.ledger().set_timestamp(start + 250);
    client.withdraw();
    assert_eq!(TokenClient::new(&env, &token).balance(&recipient), 250);

    env.ledger().set_timestamp(start + 500);
    client.withdraw();
    assert_eq!(TokenClient::new(&env, &token).balance(&recipient), 500);
}

#[test]
fn test_cancel_pro_rata() {
    let (env, router, sender, recipient, token) = setup();
    let escrow = deploy(&env, &router, &sender, &recipient, &token, AMOUNT, DURATION);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = StreamEscrowClient::new(&env, &escrow);
    client.fund();

    let sender_before = TokenClient::new(&env, &token).balance(&sender);
    let start = client.start_time();
    env.ledger().set_timestamp(start + 250);
    client.cancel();

    assert!(client.is_cancelled());
    assert_eq!(TokenClient::new(&env, &token).balance(&recipient), 250);
    assert_eq!(TokenClient::new(&env, &token).balance(&sender), sender_before + (AMOUNT - 250));
    assert_eq!(TokenClient::new(&env, &token).balance(&escrow), 0);
}

#[test]
fn test_fund_refunds_dust() {
    let (env, router, sender, recipient, token) = setup();
    // 1000 over 3 seconds -> rate 333, locked 999, dust 1.
    let amount: i128 = 1000;
    let duration: u64 = 3;
    let escrow = deploy(&env, &router, &sender, &recipient, &token, amount, duration);
    MockTokenClient::new(&env, &token).mint(&escrow, &amount);

    let sender_before = TokenClient::new(&env, &token).balance(&sender);
    let client = StreamEscrowClient::new(&env, &escrow);
    client.fund();

    assert_eq!(client.amount(), (amount / duration as i128) * duration as i128);
    assert_eq!(
        TokenClient::new(&env, &token).balance(&sender),
        sender_before + (amount - client.amount())
    );
}

#[test]
#[should_panic(expected = "nothing to withdraw")]
fn test_withdraw_nothing_at_start_panics() {
    let (env, router, sender, recipient, token) = setup();
    let escrow = deploy(&env, &router, &sender, &recipient, &token, AMOUNT, DURATION);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = StreamEscrowClient::new(&env, &escrow);
    client.fund();
    client.withdraw(); // nothing accrued yet
}

#[test]
#[should_panic(expected = "cancelled")]
fn test_withdraw_after_cancel_panics() {
    let (env, router, sender, recipient, token) = setup();
    let escrow = deploy(&env, &router, &sender, &recipient, &token, AMOUNT, DURATION);
    MockTokenClient::new(&env, &token).mint(&escrow, &AMOUNT);

    let client = StreamEscrowClient::new(&env, &escrow);
    client.fund();

    let start = client.start_time();
    env.ledger().set_timestamp(start + 100);
    client.cancel();
    client.withdraw();
}
