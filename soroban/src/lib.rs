//! Soroban contracts for cross-chain-payments.
//!
//! Mirrors the EVM contracts in `contracts/src` (see `docs/PROTOCOL_SPEC.md`).
//!
//! # Layout
//!
//! All contracts live in this single crate. Because Soroban compiles a crate to
//! one Wasm module whose exported symbols are keyed by function name (not full
//! signature), every contract function must have a globally unique name. For
//! that reason the per-contract initializers are named `stream_init`,
//! `milestone_init`, `router_init`, `bridge_init`, and `token_init`, and the
//! milestone escrow's overlapping helpers are prefixed with `milestone_`
//! (`fund_milestone`, `milestone_funded`, `milestone_cancelled`).
//!
//! In a production layout these would be split into one crate per contract.

#![no_std]

pub mod milestone_escrow;
pub mod mock_bridge;
pub mod mock_token;
pub mod payment_router;
pub mod stream_escrow;
pub mod types;
