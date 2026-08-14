#!/usr/bin/env bash
# Deploy the EVM PaymentRouter + AxelarBridgeAdapter and register the
# destination-chain config for cross-chain routing.
#
# Required env vars:
#   CHAIN_ID            Protocol chain id for this router (1 = Ethereum mainnet,
#                       11155111 = Sepolia).
#   AXELAR_GATEWAY      Axelar GMP gateway address on this chain.
#   RPC_URL             JSON-RPC endpoint to broadcast to.
#   PRIVATE_KEY         Deployer private key (0x-prefixed).
#
# Optional (post-deploy destination registration):
#   DEST_CHAIN_ID       Protocol chain id of the destination (e.g. 1500 for Stellar).
#   AXELAR_CHAIN_NAME   Axelar chain name of the destination (e.g. "stellar-2025-q1").
#   DEST_ROUTER         Destination router address string (Soroban contract id C…).
set -euo pipefail

cd "$(dirname "$0")/.."

: "${CHAIN_ID:?CHAIN_ID is required}"
: "${AXELAR_GATEWAY:?AXELAR_GATEWAY is required}"
: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

echo "Deploying EVM router + Axelar adapter on chain id $CHAIN_ID..."
forge script contracts/script/DeployAxelar.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

if [[ -n "${DEST_CHAIN_ID:-}" && -n "${AXELAR_CHAIN_NAME:-}" && -n "${DEST_ROUTER:-}" ]]; then
  ADAPTER="$(forge script contracts/script/DeployAxelar.s.sol --rpc-url "$RPC_URL" 2>/dev/null \
    | grep -oP 'AxelarBridgeAdapter:\s*\K0x[0-9a-fA-F]+' | head -1)"
  echo "Registering destination chain $DEST_CHAIN_ID -> $AXELAR_CHAIN_NAME @ $DEST_ROUTER"
  cast send "$ADAPTER" \
    "setChainConfig(uint256,string,string)" "$DEST_CHAIN_ID" "$AXELAR_CHAIN_NAME" "$DEST_ROUTER" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
fi

echo "Done."
