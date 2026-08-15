# Axelar bridge adapter

This document describes the real-bridge integration for
**IPay** using [Axelar General Message Passing (GMP)][axelar-gmp].
It is Phase 1 of [`ROADMAP.md`](ROADMAP.md).

> **Status:** adapters implemented and locally tested (EVM) / compiled
> (Soroban). Live testnet deployment requires funded accounts — see below.

## Why Axelar

- **First-class Stellar/Soroban support.** Axelar is the most mature GMP layer
  for Stellar, with official [Stellar docs][stellar-crosschain] and a published
  [`stellar-gmp-example`][stellar-gmp-example].
- **Same abstraction as the mock.** The adapter implements `IBridgeAdapter`, so
  escrow logic is unchanged: the router still only calls `sendMessage` /
  `receiveMessage`.

## Components

| Component | File | Role |
| --------- | ---- | ---- |
| `AxelarBridgeAdapter` | `contracts/src/AxelarBridgeAdapter.sol` | EVM-side GMP adapter (source + destination) |
| `IAxelarGateway` / `IAxelarExecutable` | `contracts/src/interfaces/` | Minimal Axelar ABI (matches official SDK) |
| `axelar_bridge` | `soroban-axelar/src/lib.rs` | Soroban-side GMP adapter |
| `MockAxelarGateway` | `contracts/test/mocks/MockAxelarGateway.sol` | Test double for the EVM gateway |

```text
Sepolia (EVM)                              Stellar testnet (Soroban)
PaymentRouter ──► AxelarBridgeAdapter ──► AxelarGateway ──► relayer
      ▲                                            │
      └────────────────────────────────────────────┘
           (execute ──► axelar_bridge ──► PaymentRouter)
```

## Testnet addresses (Stellar testnet)

These are the published Axelar deployments on Stellar testnet:

| Contract | Address |
| -------- | ------- |
| AxelarGateway | `CCSNWHMQSPTW4PS7L32OIMH7Z6NFNCKYZKNFSWRSYX7MK64KHBDZDT5I` |
| GasService | `CAZUKAFB5XHZKFZR7B5HIKB6BBMYSZIV3V2VWFTQWKYEMONWK2ZLTZCT` |
| Gas token | `CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC` |
| InterchainTokenService | `CCXT3EAQ7GPQTJWENU62SIFBQ3D4JMNQSB77KRPTGBJ7ZWBYESZQBZRK` |

- Stellar testnet's Axelar chain name is `stellar-2025-q1`.
- Sepolia's Axelar chain name is `ethereum-sepolia`.
- Sepolia's Axelar gateway address is available in [Axelar's contract
  deployments][axelar-deployments].

## Deploy

### 1. EVM (Sepolia)

```bash
export CHAIN_ID=11155111
export AXELAR_GATEWAY=<sepolia axelar gateway>
export RPC_URL=<sepolia rpc>
export PRIVATE_KEY=<funded deployer>

./scripts/deploy-evm-axelar.sh
```

Then register the destination:

```bash
cast send <evm_adapter> "setChainConfig(uint256,string,string)" \
  1500 "stellar-2025-q1" <stellar_router_id> \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### 2. Soroban (Stellar testnet)

```bash
export STELLAR_NETWORK=testnet
export STELLAR_SOURCE=<funded stellar account>
export AXELAR_GATEWAY=CCSNWHMQSPTW4PS7L32OIMH7Z6NFNCKYZKNFSWRSYX7MK64KHBDZDT5I
export AXELAR_GAS_SERVICE=CAZUKAFB5XHZKFZR7B5HIKB6BBMYSZIV3V2VWFTQWKYEMONWK2ZLTZCT

./scripts/deploy-soroban-axelar.sh
```

Then configure the bridge to point at the Soroban router and the EVM chain:

```bash
stellar contract invoke --id $STELLAR_BRIDGE --network testnet --source $STELLAR_SOURCE \
  -- set_router --router $STELLAR_ROUTER_ID

stellar contract invoke --id $STELLAR_BRIDGE --network testnet --source $STELLAR_SOURCE \
  -- set_chain_config --chain_id 11155111 --chain_name "ethereum-sepolia" \
  --router_address "0x…"   # the Sepolia PaymentRouter address
```

## Send, track, verify

1. **Send** a payment on Sepolia through the router (see `sdk/` or the
   reference app). The router calls `adapter.sendMessage(payload, 1500)`, which
   calls `gateway.callContract("stellar-2025-q1", <router>, payload)`.
2. **Track** the GMP message on [Axelarscan testnet][axelarscan].
3. **Verify** delivery: the Axelar relayer calls `execute(...)` on the Soroban
   `axelar_bridge`, which forwards the payload to the Soroban router's
   `recv_bytes` entry point for decoding + replay check.

## Message encoding note

**Status: receive path wired; EVM ABI interop is the remaining step.**

The Soroban `PaymentRouter` now exposes a bytes-based receive entry point
(`recv_bytes`) that the `axelar_bridge.__execute` forwards payloads to, and the
router dispatches outbound messages through a generic `Bridge` interface
(`crate::bridge`, `send(env, caller, dest_chain_id, payload)`) instead of
hardcoding the mock bridge. `recv_bytes` decodes the Soroban-native codec in
`crate::codec` (`CrossChainMessage` <-> `Bytes`, length-prefixed big-endian).

The EVM router ABI-encodes the `CrossChainMessage` and hands the raw `bytes
payload` to the bridge, so full Ethereum <-> Soroban delivery still needs two
follow-ups:

1. **EVM ABI decode** — teach `recv_bytes` (or a dedicated entry point) to
   ABI-decode Ethereum-originated payloads, and ABI-encode outbound Soroban
   messages.
2. **Unified `send` signature** — align `axelar_bridge.send` with the
   `send(env, caller, dest_chain_id, payload)` interface (currently it takes an
   extra `gas_token` argument), so the Soroban router can dispatch to it via
   the `Bridge` client.

## Security

- **Trust boundary.** The adapter authenticates inbound messages via
  `gateway.validateContractCall(...)` (EVM) / the gateway's `validate_message`
  (Soroban), so only approved Axelar commands execute.
- **Exactly-once.** Axelar's gateway marks commands executed, and the router's
  `delivered[sourceChainId][nonce]` set is a second line of defense.
- **Unaudited.** See [`SECURITY.md`](SECURITY.md); this adapter has not been
  audited.

[axelar-gmp]: https://docs.axelar.dev/dev/general-message-passing/overview/
[stellar-crosschain]: https://developers.stellar.org/docs/tools/infra-tools/cross-chain
[stellar-gmp-example]: https://github.com/axelarnetwork/stellar-gmp-example
[axelar-deployments]: https://docs.axelar.dev/resources/contract-addresses/testnet
[axelarscan]: https://testnet.axelarscan.io/gmp/
