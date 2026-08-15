//! Shared protocol types for IPay.
//!
//! These mirror `contracts/src/Types.sol` and `docs/PROTOCOL_SPEC.md`. On
//! Soroban, `token` and `recipient` use the native 32-byte `Address` type; the
//! wire-format is the XDR-encoded address, interchangeable with the EVM
//! left-padded representation described in the spec.

use soroban_sdk::{contracttype, Address, Bytes};

/// Payment primitives supported by the protocol.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PaymentMode {
    OneTime,
    Stream,
    Milestone,
}

/// Approval mechanism for milestone tranche release.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalMode {
    Multisig,
    Vote,
    Oracle,
}

/// Canonical cross-chain message (PROTOCOL_SPEC.md §4).
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CrossChainMessage {
    pub nonce: u64,
    pub source_chain_id: u32,
    pub dest_chain_id: u32,
    pub sender: Address,
    pub token: Address,
    pub amount: i128,
    pub recipient: Address,
    pub mode: PaymentMode,
    pub metadata: Bytes,
}
