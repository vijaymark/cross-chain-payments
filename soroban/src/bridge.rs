//! Bridge transport interface for the Soroban router.
//!
//! The router depends only on this trait, never on a concrete bridge. The mock
//! bridge (`mock_bridge`) and external adapters (e.g. `soroban-axelar`) expose
//! the same `send` entry point. Soroban cross-contract calls are dispatched by
//! function name + positional `ScVal` arguments, so an adapter in a separate
//! crate (possibly pinned to a different `soroban-sdk`) only needs to expose a
//! function with this exact signature:
//!
//! ```text
//! send(env: Env, caller: Address, dest_chain_id: u32, payload: Bytes)
//! ```

use soroban_sdk::{contractclient, Address, Bytes, Env};

/// The router calls `send` to hand an opaque, encoded `CrossChainMessage`
/// payload to the configured bridge for delivery to `dest_chain_id`.
#[contractclient(name = "BridgeClient")]
pub trait Bridge {
    fn send(env: Env, caller: Address, dest_chain_id: u32, payload: Bytes);
}
