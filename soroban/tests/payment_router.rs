use cross_chain_payments::{
    milestone_escrow::MilestoneEscrowClient,
    mock_bridge::{MockBridgeAdapter, MockBridgeAdapterClient},
    mock_token::{MockToken, MockTokenClient},
    payment_router::{PaymentRouter, PaymentRouterClient},
    stream_escrow::StreamEscrowClient,
    types::{ApprovalMode, CrossChainMessage, PaymentMode},
};
use soroban_sdk::token::TokenClient;
use soroban_sdk::testutils::{Address as _, Ledger as _};
use soroban_sdk::{vec, Address, Bytes, Env, String};

const SOURCE_CHAIN: u32 = 1;
const DEST_CHAIN: u32 = 1500;

const WASM: &[u8] = include_bytes!("../target/wasm32v1-none/release/cross_chain_payments.wasm");

struct TestEnv {
    env: Env,
    sender: Address,
    recipient: Address,
    token: Address,
    source_router: Address,
    dest_router: Address,
    bridge: Address,
}

fn setup() -> TestEnv {
    let env = Env::default();
    env.mock_all_auths();

    let admin = Address::generate(&env);
    let sender = Address::generate(&env);
    let recipient = Address::generate(&env);

    let token = env.register(MockToken, ());
    MockTokenClient::new(&env, &token).token_init(
        &admin,
        &String::from_str(&env, "Mock"),
        &String::from_str(&env, "MCK"),
        &7u32,
    );
    MockTokenClient::new(&env, &token).mint(&sender, &1000i128);

    let wasm_hash = env.deployer().upload_contract_wasm(Bytes::from_slice(&env, WASM));

    let source_router = env.register(PaymentRouter, ());
    PaymentRouterClient::new(&env, &source_router).router_init(&SOURCE_CHAIN, &wasm_hash, &wasm_hash);
    let dest_router = env.register(PaymentRouter, ());
    PaymentRouterClient::new(&env, &dest_router).router_init(&DEST_CHAIN, &wasm_hash, &wasm_hash);

    let bridge = env.register(MockBridgeAdapter, ());
    MockBridgeAdapterClient::new(&env, &bridge).bridge_init(&admin);
    let bridge_client = MockBridgeAdapterClient::new(&env, &bridge);
    bridge_client.set_router(&SOURCE_CHAIN, &source_router);
    bridge_client.set_router(&DEST_CHAIN, &dest_router);

    PaymentRouterClient::new(&env, &source_router).set_bridge(&bridge);
    PaymentRouterClient::new(&env, &dest_router).set_bridge(&bridge);

    TestEnv {
        env,
        sender,
        recipient,
        token,
        source_router,
        dest_router,
        bridge,
    }
}

#[test]
fn test_stream_payment_full_flow() {
    let t = setup();
    let env = &t.env;
    TokenClient::new(env, &t.token).approve(&t.sender, &t.source_router, &100i128, &1000u32);

    let source = PaymentRouterClient::new(env, &t.source_router);
    let (delivery_id, escrow) =
        source.stream_payment(&t.sender, &t.token, &100i128, &t.recipient, &DEST_CHAIN, &100u64, &2000u64);

    assert_eq!(TokenClient::new(env, &t.token).balance(&escrow), 100);
    assert_eq!(source.nonce(&t.sender), 1);

    // deliver to destination
    MockBridgeAdapterClient::new(env, &t.bridge).deliver(&delivery_id);
    assert!(PaymentRouterClient::new(env, &t.dest_router).is_delivered(&SOURCE_CHAIN, &0u64));

    // recipient withdraws half after 50 seconds
    let start = StreamEscrowClient::new(env, &escrow).start_time();
    env.ledger().set_timestamp(start + 50);
    StreamEscrowClient::new(env, &escrow).withdraw();
    assert_eq!(TokenClient::new(env, &t.token).balance(&t.recipient), 50);
}

#[test]
fn test_milestone_payment_full_flow() {
    let t = setup();
    let env = &t.env;
    TokenClient::new(env, &t.token).approve(&t.sender, &t.source_router, &100i128, &1000u32);

    let approvers = vec![env, Address::generate(env), Address::generate(env)];
    let tranches = vec![env, 60i128, 40i128];

    let source = PaymentRouterClient::new(env, &t.source_router);
    let (delivery_id, escrow) = source.create_milestone_payment(
        &t.sender,
        &t.token,
        &100i128,
        &t.recipient,
        &DEST_CHAIN,
        &tranches,
        &ApprovalMode::Multisig,
        &approvers,
        &2u32,
        &Address::generate(env),
        &(env.ledger().timestamp() + 1000),
        &2000u64,
    );

    assert_eq!(TokenClient::new(env, &t.token).balance(&escrow), 100);

    let escrow_client = MilestoneEscrowClient::new(env, &escrow);
    escrow_client.approve_milestone(&approvers.get(0).unwrap(), &0);
    escrow_client.approve_milestone(&approvers.get(1).unwrap(), &0);
    escrow_client.release_milestone(&0);

    assert_eq!(TokenClient::new(env, &t.token).balance(&t.recipient), 60);

    MockBridgeAdapterClient::new(env, &t.bridge).deliver(&delivery_id);
    assert!(PaymentRouterClient::new(env, &t.dest_router).is_delivered(&SOURCE_CHAIN, &0u64));
}

#[test]
fn test_one_time_refund_after_timeout() {
    let t = setup();
    let env = &t.env;
    TokenClient::new(env, &t.token).approve(&t.sender, &t.source_router, &100i128, &1000u32);

    let source = PaymentRouterClient::new(env, &t.source_router);
    let delivery_id = source.send_payment(&t.sender, &t.token, &100i128, &t.recipient, &DEST_CHAIN, &2000u64);

    assert_eq!(TokenClient::new(env, &t.token).balance(&t.source_router), 100);

    env.ledger().set_timestamp(env.ledger().timestamp() + 2001);
    source.refund_one_time(&t.sender, &delivery_id);

    assert_eq!(TokenClient::new(env, &t.token).balance(&t.sender), 1000);
}

#[test]
#[should_panic(expected = "replay")]
fn test_receive_message_replay_rejected() {
    let t = setup();
    let env = &t.env;
    let message = CrossChainMessage {
        nonce: 0,
        source_chain_id: SOURCE_CHAIN,
        dest_chain_id: DEST_CHAIN,
        token: t.token.clone(),
        amount: 100,
        recipient: t.recipient.clone(),
        mode: PaymentMode::OneTime,
        metadata: Bytes::new(env),
    };
    let dest = PaymentRouterClient::new(env, &t.dest_router);
    dest.receive_message(&message); // ok
    dest.receive_message(&message); // replay -> panic
}

#[test]
#[should_panic(expected = "wrong dest chain")]
fn test_dest_router_rejects_wrong_chain() {
    let t = setup();
    let env = &t.env;
    let message = CrossChainMessage {
        nonce: 0,
        source_chain_id: SOURCE_CHAIN,
        dest_chain_id: 999,
        token: t.token.clone(),
        amount: 100,
        recipient: t.recipient.clone(),
        mode: PaymentMode::OneTime,
        metadata: Bytes::new(env),
    };
    PaymentRouterClient::new(env, &t.dest_router).receive_message(&message);
}
