//! Axelar GMP bridge adapter for the Soroban (Stellar) side of
//! IPay.
//!
//! This contract is the Soroban mirror of `contracts/src/AxelarBridgeAdapter.sol`.
//! It sits between the payment router and Axelar's GMP gateway:
//!
//! ```text
//!   send:        router -> axelar_bridge -> gateway.call_contract(...)
//!   receive:     Axelar relayer -> gateway -> axelar_bridge.__execute -> router
//! ```
//!
//! # Note on crate layout
//!
//! This is a **separate crate** from `soroban/` because the Axelar contract
//! stack (`stellar-axelar-gateway` and friends) pins a `soroban-sdk` version
//! (~25.x) that predates the one used by the core router/escrow contracts.
//! Keeping it isolated avoids a dependency-version clash. See
//! `docs/AXELAR_BRIDGE.md`.

#![no_std]

use stellar_axelar_gas_service::AxelarGasServiceClient;
use stellar_axelar_gateway::executable::{AxelarExecutableInterface, CustomAxelarExecutable};
use stellar_axelar_gateway::AxelarGatewayMessagingClient;
use stellar_axelar_std::types::Token;
use stellar_axelar_std::{
    contract, contracterror, contractimpl, soroban_sdk, Address, AxelarExecutable, Bytes, Env,
    String,
};

mod storage {
    use stellar_axelar_std::soroban_sdk;
    use stellar_axelar_std::{Address, Env, String};

    pub const GATEWAY: soroban_sdk::Symbol = soroban_sdk::symbol_short!("gateway");
    pub const GAS_SERVICE: soroban_sdk::Symbol = soroban_sdk::symbol_short!("gas_svc");
    pub const ROUTER: soroban_sdk::Symbol = soroban_sdk::symbol_short!("router");
    pub const CHAIN_NAMES: soroban_sdk::Symbol = soroban_sdk::symbol_short!("chnames");
    pub const CHAIN_ROUTERS: soroban_sdk::Symbol = soroban_sdk::symbol_short!("chrtrs");

    pub type ChainMap = soroban_sdk::Map<u32, String>;

    pub fn gateway(env: &Env) -> Address {
        env.storage().instance().get(&GATEWAY).unwrap()
    }
    pub fn gas_service(env: &Env) -> Address {
        env.storage().instance().get(&GAS_SERVICE).unwrap()
    }
    pub fn router(env: &Env) -> Address {
        env.storage().instance().get(&ROUTER).unwrap()
    }
    pub fn set_gateway(env: &Env, value: &Address) {
        env.storage().instance().set(&GATEWAY, value);
    }
    pub fn set_gas_service(env: &Env, value: &Address) {
        env.storage().instance().set(&GAS_SERVICE, value);
    }
    pub fn set_router(env: &Env, value: &Address) {
        env.storage().instance().set(&ROUTER, value);
    }
}

#[contract]
#[derive(AxelarExecutable)]
#[axelar_executable(error = AxelarBridgeError)]
pub struct AxelarBridge;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AxelarBridgeError {
    NotApproved = 1,
    NoRouter = 2,
    UnknownChain = 3,
    NotOwner = 4,
}

impl CustomAxelarExecutable for AxelarBridge {
    type Error = AxelarBridgeError;

    fn __gateway(env: &Env) -> Address {
        storage::gateway(env)
    }

    fn __execute(
        env: &Env,
        _source_chain: String,
        _message_id: String,
        _source_address: String,
        payload: Bytes,
    ) -> Result<(), Self::Error> {
        // Forward the raw (ABI-encoded CrossChainMessage) payload to the local
        // payment router. The router decodes it, applies replay checks, and
        // validates the destination chain.
        let router = env
            .storage()
            .instance()
            .get::<_, Address>(&storage::ROUTER)
            .ok_or(AxelarBridgeError::NoRouter)?;

        let func = soroban_sdk::Symbol::new(env, "recv_bytes");
        let mut args: soroban_sdk::Vec<soroban_sdk::Val> = soroban_sdk::Vec::new(env);
        args.push_back(payload.into());
        env.invoke_contract::<()>(&router, &func, args);

        Ok(())
    }
}

/// Public contract interface. `#[contractimpl]` generates the client.
pub trait AxelarBridgeInterface: AxelarExecutableInterface {
    fn set_router(env: &Env, router: Address);
    fn set_chain_config(env: &Env, chain_id: u32, chain_name: String, router_address: String);
    fn send(
        env: &Env,
        caller: Address,
        dest_chain_id: u32,
        payload: Bytes,
        gas_token: Option<Token>,
    ) -> Result<(), AxelarBridgeError>;
    fn gas_service(env: &Env) -> Address;
    fn router(env: &Env) -> Address;
}

#[contractimpl]
impl AxelarBridge {
    pub fn __constructor(env: &Env, gateway: Address, gas_service: Address) {
        storage::set_gateway(env, &gateway);
        storage::set_gas_service(env, &gas_service);
    }
}

#[contractimpl]
impl AxelarBridgeInterface for AxelarBridge {
    fn set_router(env: &Env, router: Address) {
        env.current_contract_address().require_auth();
        storage::set_router(env, &router);
    }

    fn set_chain_config(env: &Env, chain_id: u32, chain_name: String, router_address: String) {
        env.current_contract_address().require_auth();

        let mut names: storage::ChainMap = env
            .storage()
            .instance()
            .get(&storage::CHAIN_NAMES)
            .unwrap_or(soroban_sdk::Map::new(env));
        names.set(chain_id, chain_name);
        env.storage().instance().set(&storage::CHAIN_NAMES, &names);

        let mut routers: storage::ChainMap = env
            .storage()
            .instance()
            .get(&storage::CHAIN_ROUTERS)
            .unwrap_or(soroban_sdk::Map::new(env));
        routers.set(chain_id, router_address);
        env.storage().instance().set(&storage::CHAIN_ROUTERS, &routers);
    }

    fn send(
        env: &Env,
        caller: Address,
        dest_chain_id: u32,
        payload: Bytes,
        gas_token: Option<Token>,
    ) -> Result<(), AxelarBridgeError> {
        caller.require_auth();

        let names: storage::ChainMap = env
            .storage()
            .instance()
            .get(&storage::CHAIN_NAMES)
            .unwrap_or(soroban_sdk::Map::new(env));
        let routers: storage::ChainMap = env
            .storage()
            .instance()
            .get(&storage::CHAIN_ROUTERS)
            .unwrap_or(soroban_sdk::Map::new(env));

        let destination_chain = names.get(dest_chain_id).ok_or(AxelarBridgeError::UnknownChain)?;
        let destination_address = routers.get(dest_chain_id).ok_or(AxelarBridgeError::UnknownChain)?;

        let gateway = AxelarGatewayMessagingClient::new(env, &Self::gateway(env));
        let gas_service = AxelarGasServiceClient::new(env, &Self::gas_service(env));

        if let Some(gas_token) = gas_token {
            gas_service.pay_gas(
                &env.current_contract_address(),
                &destination_chain,
                &destination_address,
                &payload,
                &caller,
                &gas_token,
                &Bytes::new(env),
            );
        }

        gateway.call_contract(
            &env.current_contract_address(),
            &destination_chain,
            &destination_address,
            &payload,
        );

        Ok(())
    }

    fn gas_service(env: &Env) -> Address {
        storage::gas_service(env)
    }

    fn router(env: &Env) -> Address {
        storage::router(env)
    }
}
