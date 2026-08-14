//! A minimal SEP-41 / TokenInterface token used for local and testnet
//! development. Not for production issuance.

use soroban_sdk::{
    contract, contractimpl, token::TokenInterface, Address, Env, MuxedAddress, String, Symbol,
};

const ADMIN: Symbol = soroban_sdk::symbol_short!("admin");
const NAME: Symbol = soroban_sdk::symbol_short!("name");
const SYMBOL: Symbol = soroban_sdk::symbol_short!("symbol");
const DECIMALS: Symbol = soroban_sdk::symbol_short!("decimals");

#[contract]
pub struct MockToken;

#[contractimpl]
impl MockToken {
    pub fn token_init(env: Env, admin: Address, name: String, symbol: String, decimals: u32) {
        env.storage().instance().set(&ADMIN, &admin);
        env.storage().instance().set(&NAME, &name);
        env.storage().instance().set(&SYMBOL, &symbol);
        env.storage().instance().set(&DECIMALS, &decimals);
    }

    /// Mint tokens to `to`. Admin-only.
    pub fn mint(env: Env, to: Address, amount: i128) {
        let admin: Address = env.storage().instance().get(&ADMIN).unwrap();
        admin.require_auth();
        let balance: i128 = env.storage().persistent().get(&to).unwrap_or(0);
        env.storage().persistent().set(&to, &(balance + amount));
    }
}

#[contractimpl]
impl TokenInterface for MockToken {
    fn allowance(env: Env, from: Address, spender: Address) -> i128 {
        env.storage().temporary().get(&(from, spender)).unwrap_or(0)
    }

    fn approve(env: Env, from: Address, spender: Address, amount: i128, _expiration_ledger: u32) {
        from.require_auth();
        env.storage().temporary().set(&(from, spender), &amount);
    }

    fn balance(env: Env, id: Address) -> i128 {
        env.storage().persistent().get(&id).unwrap_or(0)
    }

    fn transfer(env: Env, from: Address, to_muxed: MuxedAddress, amount: i128) {
        from.require_auth();
        let to: Address = to_muxed.address();
        Self::spend(&env, &from, amount);
        Self::receive(&env, &to, amount);
    }

    fn transfer_from(env: Env, spender: Address, from: Address, to: Address, amount: i128) {
        spender.require_auth();
        let allow: i128 = env.storage().temporary().get(&(from.clone(), spender.clone())).unwrap_or(0);
        if allow != i128::MAX {
            assert!(allow >= amount, "insufficient allowance");
            env.storage().temporary().set(&(from.clone(), spender), &(allow - amount));
        }
        Self::spend(&env, &from, amount);
        Self::receive(&env, &to, amount);
    }

    fn burn(env: Env, from: Address, amount: i128) {
        from.require_auth();
        Self::spend(&env, &from, amount);
    }

    fn burn_from(env: Env, spender: Address, from: Address, amount: i128) {
        spender.require_auth();
        let allow: i128 = env.storage().temporary().get(&(from.clone(), spender.clone())).unwrap_or(0);
        assert!(allow >= amount, "insufficient allowance");
        env.storage().temporary().set(&(from.clone(), spender), &(allow - amount));
        Self::spend(&env, &from, amount);
    }

    fn decimals(env: Env) -> u32 {
        env.storage().instance().get(&DECIMALS).unwrap()
    }

    fn name(env: Env) -> String {
        env.storage().instance().get(&NAME).unwrap()
    }

    fn symbol(env: Env) -> String {
        env.storage().instance().get(&SYMBOL).unwrap()
    }
}

impl MockToken {
    fn spend(env: &Env, from: &Address, amount: i128) {
        let balance: i128 = env.storage().persistent().get(from).unwrap_or(0);
        assert!(balance >= amount, "insufficient balance");
        env.storage().persistent().set(from, &(balance - amount));
    }

    fn receive(env: &Env, to: &Address, amount: i128) {
        let balance: i128 = env.storage().persistent().get(to).unwrap_or(0);
        env.storage().persistent().set(to, &(balance + amount));
    }
}
