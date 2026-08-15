//! Tests for the canonical `CrossChainMessage` <-> `Bytes` codec used by the
//! router's bridge transport (`recv_bytes` / generic `send`).

use ipay::codec::{decode_message, encode_message};
use ipay::types::{CrossChainMessage, PaymentMode};
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{Address, Bytes, Env};

#[test]
fn test_message_codec_round_trip() {
    let env = Env::default();

    for mode in [
        PaymentMode::OneTime,
        PaymentMode::Stream,
        PaymentMode::Milestone,
    ] {
        let msg = CrossChainMessage {
            nonce: 7,
            source_chain_id: 1,
            dest_chain_id: 1500,
            sender: Address::generate(&env),
            token: Address::generate(&env),
            amount: 123_456_789,
            recipient: Address::generate(&env),
            mode,
            metadata: Bytes::from_slice(&env, &[1, 2, 3, 4]),
        };

        let payload = encode_message(&env, &msg);
        let decoded = decode_message(&payload);
        assert_eq!(decoded, msg);
    }
}

#[test]
#[should_panic(expected = "trailing bytes")]
fn test_decode_rejects_trailing_bytes() {
    let env = Env::default();
    let msg = CrossChainMessage {
        nonce: 0,
        source_chain_id: 1,
        dest_chain_id: 1500,
        sender: Address::generate(&env),
        token: Address::generate(&env),
        amount: 1,
        recipient: Address::generate(&env),
        mode: PaymentMode::OneTime,
        metadata: Bytes::new(&env),
    };
    let mut payload = encode_message(&env, &msg);
    payload.push_back(0u8); // corrupt with a trailing byte
    decode_message(&payload);
}
