#!/usr/bin/env bash
# Deploy the EVM contracts (PaymentRouter + MockBridgeAdapter) with Foundry.
#
# Required env vars:
#   CHAIN_ID       Protocol chain id for the router (e.g. 1 for Ethereum).
#   RPC_URL        JSON-RPC endpoint to broadcast to.
#   PRIVATE_KEY    Deployer private key (0x-prefixed).
#
# Optional:
#   ETHERSCAN_API_KEY  If set, verify the contracts after deployment.
#   ETHERSCAN_URL      Explorer API URL (defaults to the public Etherscan).
#   VERIFY             Set to "1" to force verification when the key is present.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${CHAIN_ID:?CHAIN_ID is required}"
: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

echo "Deploying EVM contracts on chain id $CHAIN_ID..."
forge script contracts/script/Deploy.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

if [[ "${VERIFY:-}" == "1" || -n "${ETHERSCAN_API_KEY:-}" ]]; then
  : "${ETHERSCAN_URL:-https://api.etherscan.io/api}"
  echo "Verifying contracts..."
  # Verification is performed per-contract; the router and bridge are the two
  # deployment outputs. Adjust addresses as needed after a fresh deploy.
  forge verify-contract \
    --rpc-url "$RPC_URL" \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --chain "$CHAIN_ID" \
    "$(forge script contracts/script/Deploy.s.sol --rpc-url "$RPC_URL" 2>/dev/null | grep -oP 'PaymentRouter\s*:\s*\K0x[0-9a-fA-F]+' | head -1)" \
    contracts/src/PaymentRouter.sol:PaymentRouter \
    --constructor-args "$(cast abi-encode 'constructor(uint256)' "$CHAIN_ID")"
fi

echo "Done."
