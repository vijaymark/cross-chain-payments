//! Canonical `CrossChainMessage` <-> `Bytes` codec.
//!
//! This is the Soroban-native wire format used by the router's bridge
//! transport (`recv_bytes` / generic `send`). Layout (all integers big-endian;
//! variable-length fields are `u32` length-prefixed):
//!
//! ```text
//! nonce            u64    8 bytes
//! source_chain_id  u32    4 bytes
//! dest_chain_id    u32    4 bytes
//! sender           bytes  length-prefixed strkey (Address)
//! token            bytes  length-prefixed strkey (Address)
//! amount           i128   16 bytes
//! recipient        bytes  length-prefixed strkey (Address)
//! mode             u8     0 / 1 / 2
//! metadata         bytes  length-prefixed
//! ```
//!
//! NOTE: This is the native format for the Soroban bridge path. Decoding the
//! EVM ABI-encoded payloads produced by the Ethereum router is a separate
//! follow-up (see `docs/AXELAR_BRIDGE.md`).

use soroban_sdk::{Address, Bytes, Env};

use crate::types::{CrossChainMessage, PaymentMode};

/// Encode a `CrossChainMessage` into its canonical byte representation.
pub fn encode_message(env: &Env, m: &CrossChainMessage) -> Bytes {
    let mut buf = Bytes::new(env);
    push_u64(&mut buf, m.nonce);
    push_u32(&mut buf, m.source_chain_id);
    push_u32(&mut buf, m.dest_chain_id);
    push_bytes(&mut buf, &Bytes::from(m.sender.to_string()));
    push_bytes(&mut buf, &Bytes::from(m.token.to_string()));
    push_i128(&mut buf, m.amount);
    push_bytes(&mut buf, &Bytes::from(m.recipient.to_string()));
    buf.push_back(mode_to_u8(m.mode.clone()));
    push_bytes(&mut buf, &m.metadata);
    buf
}

/// Decode a `CrossChainMessage` from its canonical byte representation.
///
/// Panics if the payload is malformed or carries trailing bytes.
pub fn decode_message(payload: &Bytes) -> CrossChainMessage {
    let mut r = Reader { bytes: payload, pos: 0 };
    let message = CrossChainMessage {
        nonce: r.read_u64(),
        source_chain_id: r.read_u32(),
        dest_chain_id: r.read_u32(),
        sender: r.read_address(),
        token: r.read_address(),
        amount: r.read_i128(),
        recipient: r.read_address(),
        mode: u8_to_mode(r.read_u8()),
        metadata: r.read_bytes(),
    };
    assert!(r.pos == payload.len(), "trailing bytes");
    message
}

fn push_u32(buf: &mut Bytes, v: u32) {
    buf.extend_from_slice(&v.to_be_bytes());
}

fn push_u64(buf: &mut Bytes, v: u64) {
    buf.extend_from_slice(&v.to_be_bytes());
}

fn push_i128(buf: &mut Bytes, v: i128) {
    buf.extend_from_slice(&v.to_be_bytes());
}

fn push_bytes(buf: &mut Bytes, b: &Bytes) {
    push_u32(buf, b.len());
    buf.append(b);
}

fn mode_to_u8(mode: PaymentMode) -> u8 {
    match mode {
        PaymentMode::OneTime => 0,
        PaymentMode::Stream => 1,
        PaymentMode::Milestone => 2,
    }
}

fn u8_to_mode(v: u8) -> PaymentMode {
    match v {
        0 => PaymentMode::OneTime,
        1 => PaymentMode::Stream,
        2 => PaymentMode::Milestone,
        _ => panic!("invalid payment mode"),
    }
}

struct Reader<'a> {
    bytes: &'a Bytes,
    pos: u32,
}

impl<'a> Reader<'a> {
    fn read_u8(&mut self) -> u8 {
        let v = self.bytes.get_unchecked(self.pos);
        self.pos += 1;
        v
    }

    fn read_u32(&mut self) -> u32 {
        let mut arr = [0u8; 4];
        for (i, b) in arr.iter_mut().enumerate() {
            *b = self.bytes.get_unchecked(self.pos + i as u32);
        }
        self.pos += 4;
        u32::from_be_bytes(arr)
    }

    fn read_u64(&mut self) -> u64 {
        let mut arr = [0u8; 8];
        for (i, b) in arr.iter_mut().enumerate() {
            *b = self.bytes.get_unchecked(self.pos + i as u32);
        }
        self.pos += 8;
        u64::from_be_bytes(arr)
    }

    fn read_i128(&mut self) -> i128 {
        let mut arr = [0u8; 16];
        for (i, b) in arr.iter_mut().enumerate() {
            *b = self.bytes.get_unchecked(self.pos + i as u32);
        }
        self.pos += 16;
        i128::from_be_bytes(arr)
    }

    fn read_bytes(&mut self) -> Bytes {
        let len = self.read_u32();
        let b = self.bytes.slice(self.pos..self.pos + len);
        self.pos += len;
        b
    }

    fn read_address(&mut self) -> Address {
        Address::from_string_bytes(&self.read_bytes())
    }
}
