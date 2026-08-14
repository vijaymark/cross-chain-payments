#!/usr/bin/env bash
# Build and deploy the Soroban (Stellar) contracts.
#
# Requires the `soroban` CLI (https://soroban.stellar.org/docs/reference/cli).
#
# Required env vars:
#   SOROBAN_NETWORK   Network to target (e.g. "testnet", "futurenet", "standalone").
#   SOROBAN_SECRET    Secret key (S…) that funds and signs the deployment.
#
# Optional:
#   SOURCE_ACCOUNT    Funding account (defaults to the account behind SOROBAN_SECRET).
set -euo pipefail

cd "$(dirname "$0")/.."

: "${SOROBAN_NETWORK:?SOROBAN_NETWORK is required}"
: "${SOROBAN_SECRET:?SOROBAN_SECRET is required}"

NETWORK_ARGS=(--network "$SOROBAN_NETWORK" --source "$SOROBAN_SECRET")

echo "Building Soroban contracts..."
cargo build --release --target wasm32v1-none

WASM=soroban/target/wasm32v1-none/release/ipay.wasm
if [[ ! -f "$WASM" ]]; then
  echo "Error: wasm not found at $WASM" >&2
  exit 1
fi

echo "Deploying payment_router wasm..."
ROUTER_ID="$(soroban contract deploy "${NETWORK_ARGS[@]}" --wasm "$WASM" -- --init)"
echo "payment_router contract id: $ROUTER_ID"

# NOTE: The Soroban router requires additional `init` wiring (bridge + chain id)
# and escrow wasm registration. Invoke the router's `init`-style entry points
# here once a network and bridge are chosen.
echo "Done. Remember to configure the bridge and chain id on $ROUTER_ID."
