//! In-memory bridge for local/testnet development. Simulates the async
//! `send → deliver` flow of a real bridge, routing each message to the
//! destination router registered for its `dest_chain_id`.

use soroban_sdk::{contract, contractimpl, Address, Env, Map, Symbol};

use crate::payment_router::PaymentRouterClient;
use crate::types::CrossChainMessage;

const OWNER: Symbol = soroban_sdk::symbol_short!("owner");
const ROUTERS: Symbol = soroban_sdk::symbol_short!("routers");
const OUTBOX: Symbol = soroban_sdk::symbol_short!("outbox");
const NEXT_ID: Symbol = soroban_sdk::symbol_short!("next_id");

#[contract]
pub struct MockBridgeAdapter;

#[contractimpl]
impl MockBridgeAdapter {
    pub fn bridge_init(env: Env, owner: Address) {
        env.storage().instance().set(&OWNER, &owner);
        env.storage().instance().set(&NEXT_ID, &0u64);
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

    /// Queue a message and return its delivery id.
    pub fn send_message(env: Env, message: CrossChainMessage) -> u64 {
        let next: u64 = env.storage().instance().get(&NEXT_ID).unwrap();
        env.storage().instance().set(&NEXT_ID, &(next + 1));

        let mut outbox: Map<u64, CrossChainMessage> =
            env.storage().instance().get(&OUTBOX).unwrap_or(Map::new(&env));
        outbox.set(next, message);
        env.storage().instance().set(&OUTBOX, &outbox);

        next
    }

    /// Simulate a relayer delivering a queued message to the router registered
    /// for its destination chain.
    pub fn deliver(env: Env, delivery_id: u64) {
        let outbox: Map<u64, CrossChainMessage> =
            env.storage().instance().get(&OUTBOX).unwrap_or(Map::new(&env));
        let message = outbox.get(delivery_id).expect("not queued");

        let routers: Map<u32, Address> =
            env.storage().instance().get(&ROUTERS).unwrap_or(Map::new(&env));
        let router = routers.get(message.dest_chain_id).expect("no router for chain");

        PaymentRouterClient::new(&env, &router).receive_message(&message);
    }
}
