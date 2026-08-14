#!/usr/bin/env bash
# Build and deploy the Soroban Axelar GMP bridge adapter (soroban-axelar/).
#
# Requires the `stellar` CLI (successor to `soroban`):
#   https://developers.stellar.org/docs/tools/cli
#
# Required env vars:
#   STELLAR_NETWORK    e.g. "testnet"
#   STELLAR_SOURCE     Funding/signer account (name from `stellar keys` or secret S…)
#   AXELAR_GATEWAY     Axelar gateway contract id on this network.
#   AXELAR_GAS_SERVICE Axelar gas-service contract id on this network.
#
# Stellar testnet reference values (see docs/AXELAR_BRIDGE.md):
#   AXELAR_GATEWAY      = CCSNWHMQSPTW4PS7L32OIMH7Z6NFNCKYZKNFSWRSYX7MK64KHBDZDT5I
#   AXELAR_GAS_SERVICE  = CAZUKAFB5XHZKFZR7B5HIKB6BBMYSZIV3V2VWFTQWKYEMONWK2ZLTZCT
set -euo pipefail

cd "$(dirname "$0")/.."

: "${STELLAR_NETWORK:?STELLAR_NETWORK is required}"
: "${STELLAR_SOURCE:?STELLAR_SOURCE is required}"
: "${AXELAR_GATEWAY:?AXELAR_GATEWAY is required}"
: "${AXELAR_GAS_SERVICE:?AXELAR_GAS_SERVICE is required}"

echo "Building Soroban Axelar bridge..."
(cd soroban-axelar && cargo build --release --target wasm32v1-none)

WASM=soroban-axelar/target/wasm32v1-none/release/ipay_axelar.wasm
if [[ ! -f "$WASM" ]]; then
  echo "Error: wasm not found at $WASM" >&2
  exit 1
fi

echo "Deploying Axelar bridge to $STELLAR_NETWORK..."
BRIDGE_ID="$(stellar contract deploy \
  --wasm "$WASM" \
  --source "$STELLAR_SOURCE" \
  --network "$STELLAR_NETWORK" \
  -- \
  --gateway "$AXELAR_GATEWAY" \
  --gas_service "$AXELAR_GAS_SERVICE")"

echo "AxelarBridge contract id: $BRIDGE_ID"
echo "Next: set_router($ROUTER_ID) and set_chain_config(...) via the stellar CLI."
