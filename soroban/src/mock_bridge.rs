//! In-memory bridge for local/testnet development. Simulates the async
//! `send → deliver` flow of a real bridge, routing each message to the
//! destination router registered for its `dest_chain_id`.
//!
//! `send` implements the `Bridge` interface (`crate::bridge`): it accepts an
//! opaque `payload: Bytes` so the router is transport-agnostic.

use soroban_sdk::{contract, contractimpl, contracttype, Address, Bytes, BytesN, Env, Map, Symbol};

use crate::payment_router::PaymentRouterClient;

const OWNER: Symbol = soroban_sdk::symbol_short!("owner");
const ROUTERS: Symbol = soroban_sdk::symbol_short!("routers");
const OUTBOX: Symbol = soroban_sdk::symbol_short!("outbox");

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Outbound {
    pub dest_chain_id: u32,
    pub payload: Bytes,
}

#[contract]
pub struct MockBridgeAdapter;

#[contractimpl]
impl MockBridgeAdapter {
    pub fn bridge_init(env: Env, owner: Address) {
        let existing: Option<Address> = env.storage().instance().get(&OWNER);
        assert!(existing.is_none(), "already initialized");

        env.storage().instance().set(&OWNER, &owner);
    }

    /// Register the destination router for a chain id.
    pub fn set_router(env: Env, chain_id: u32, router: Address) {
        let owner: Address = env.storage().instance().get(&OWNER).unwrap();
        owner.require_auth();

        let mut routers: Map<u32, Address> =
            env.storage().instance().get(&ROUTERS).unwrap_or(Map::new(&env));
        routers.set(chain_id, router);
        env.storage().instance().set(&ROUTERS, &routers);
    }

    /// Queue a raw payload for delivery to `dest_chain_id`. `caller` is unused
    /// by the mock transport (real adapters use it to pay relayer gas).
    pub fn send(env: Env, _caller: Address, dest_chain_id: u32, payload: Bytes) {
        let delivery_id = env.crypto().sha256(&payload);
        let mut outbox: Map<BytesN<32>, Outbound> =
            env.storage().instance().get(&OUTBOX).unwrap_or(Map::new(&env));
        outbox.set(delivery_id, Outbound { dest_chain_id, payload });
        env.storage().instance().set(&OUTBOX, &outbox);
    }

    /// Simulate a relayer delivering a queued message to the router registered
    /// for its destination chain.
    pub fn deliver(env: Env, delivery_id: BytesN<32>) {
        let outbox: Map<BytesN<32>, Outbound> =
            env.storage().instance().get(&OUTBOX).unwrap_or(Map::new(&env));
        let outbound = outbox.get(delivery_id).expect("not queued");

        let routers: Map<u32, Address> =
            env.storage().instance().get(&ROUTERS).unwrap_or(Map::new(&env));
        let router = routers.get(outbound.dest_chain_id).expect("no router for chain");

        PaymentRouterClient::new(&env, &router).recv_bytes(&outbound.payload);
    }
}
