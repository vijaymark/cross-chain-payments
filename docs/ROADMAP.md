# Roadmap

Each phase is sized to be a realistic, funding-tranche-sized milestone with a
clear deliverable and exit criteria. Phases are sequential; later phases assume
earlier ones are complete and green.

## Phase 0 — MVP (mock bridge) ✅

**Delivered in this repo.**

- EVM contracts: `PaymentRouter`, `StreamEscrow`, `MilestoneEscrow`,
  `MockBridgeAdapter`.
- Soroban mirror of the same contracts.
- TypeScript SDK with EVM + Stellar adapters.
- Full test suites: Solidity (Foundry), Rust (cargo), SDK (Vitest + Anvil).

**Exit criteria:** all test suites green; protocol spec and architecture docs
match the code.

## Phase 1 — Real-bridge testnet integration 🚧

**In progress.**

- ✅ Implement a production `IBridgeAdapter` for **Axelar** GMP
  (`contracts/src/AxelarBridgeAdapter.sol`, EVM-tested; `soroban-axelar/`,
  compiled). See [`AXELAR_BRIDGE.md`](AXELAR_BRIDGE.md).
- ⬜ Wire the adapter to a live testnet (Ethereum Sepolia ↔ Stellar testnet) —
  deploy scripts are ready (`scripts/deploy-*-axelar.sh`, `scripts/demo-cross-chain.sh`);
  needs funded testnet accounts.
- ⬜ Produce a working end-to-end demo and exercise the timeout fallback.
- ⬜ Add token allowlist mapping (`sourceToken → destToken`) in the router.

**Exit criteria:** an end-to-end payment is routed across two testnets and
confirmed on-chain, with the timeout fallback exercised.

## Phase 2 — Third chain

- Add a second EVM L2 or an additional non-EVM chain (e.g. Solana or an EVM
  rollup) to the router registry and SDK.
- Generalize per-chain address/token encoding where needed.

**Exit criteria:** the SDK can route from any of three chains to any other,
with tests for each pair.

## Phase 3 — External audit

- Engage a reputable security firm for a full audit of the contracts and the
  bridge adapter.
- Fix findings; publish the audit report and remediation notes.

**Exit criteria:** no open critical/high findings; audit report published.

## Phase 4 — Mainnet

- Deploy audited contracts with a multisig admin and a real bridge adapter.
- Enable the per-chain token allowlist; enable monitoring/alerting.
- Publish mainnet docs and a bug-bounty scope.

**Exit criteria:** mainnet launch with a limited-value beta, then gradual
unlock.

## Non-goals (for now)

- A pooled/vaulted architecture — funds stay in per-payment escrows.
- Building a bridge protocol — we integrate existing bridges, never compete.
- A single-chain funding dashboard — Drips/GrantFox-style UIs can build *on
  top of* this routing layer.
