#!/usr/bin/env bash
# Two-testnet demo: route a payment from Ethereum Sepolia to Stellar testnet
# through the Axelar GMP adapter.
#
# This script *documents and validates* the steps; it does not hold keys. Run
# each phase with the required env vars exported. See docs/AXELAR_BRIDGE.md for
# the full walkthrough and testnet addresses.
#
#   Phase 1  deploy-evm-axelar.sh      (Sepolia)
#   Phase 2  deploy-soroban-axelar.sh  (Stellar testnet)
#   Phase 3  configure both adapters
#   Phase 4  send a payment from Sepolia, track on Axelarscan
#   Phase 5  verify delivery on Stellar testnet
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== cross-chain-payments two-testnet demo ==="
echo "Chain A (source): Ethereum Sepolia (chain id 11155111)"
echo "Chain B (dest)  : Stellar testnet  (chain id 1500, Axelar name stellar-2025-q1)"
echo

# ---- Phase 1: deploy on Sepolia ----
if [[ -n "${DEPLOY_SEPOLIA:-}" ]]; then
  echo "--- Phase 1: deploy on Sepolia ---"
  CHAIN_ID=11155111 \
  AXELAR_GATEWAY="${SEPOLIA_AXELAR_GATEWAY}" \
  RPC_URL="${SEPOLIA_RPC_URL}" \
  PRIVATE_KEY="${SEPOLIA_PRIVATE_KEY}" \
    ./scripts/deploy-evm-axelar.sh
fi

# ---- Phase 2: deploy on Stellar testnet ----
if [[ -n "${DEPLOY_STELLAR:-}" ]]; then
  echo "--- Phase 2: deploy on Stellar testnet ---"
  STELLAR_NETWORK=testnet \
  STELLAR_SOURCE="${STELLAR_SOURCE}" \
  AXELAR_GATEWAY="${STELLAR_AXELAR_GATEWAY}" \
  AXELAR_GAS_SERVICE="${STELLAR_AXELAR_GAS_SERVICE}" \
    ./scripts/deploy-soroban-axelar.sh
fi

# ---- Phase 3: register cross-chain config (both directions) ----
# EVM adapter: chainId 1500 -> "stellar-2025-q1" -> <stellar router id>
#   cast send $EVM_ADAPTER "setChainConfig(uint256,string,string)" \
#     1500 "stellar-2025-q1" "$STELLAR_ROUTER_ID" --rpc-url ... --private-key ...
#
# Soroban adapter: chainId 11155111 -> "ethereum-sepolia" -> <sepolia router address>
#   stellar contract invoke --id $STELLAR_BRIDGE --network testnet --source $STELLAR_SOURCE \
#     -- set_chain_config --chain_id 11155111 --chain_name "ethereum-sepolia" \
#     --router_address "$SEPOLIA_ROUTER_ADDRESS"

echo
echo "Deploy and configuration are intentionally left as explicit steps above."
echo "See docs/AXELAR_BRIDGE.md for the send + track + verify walkthrough."
