# Security

> **These contracts are unaudited.** Do not deploy to mainnet or use with
> real funds. The MVP is intended for local and testnet development only.

This document describes the known threat model for **IPay**,
how each risk is mitigated in the current code, and how to report
vulnerabilities.

## Threat model

| # | Threat | Impact | Mitigation / status |
| - | ------ | ------ | ------------------- |
| 1 | **Bridge compromise** — a malicious or buggy bridge delivers forged `receiveMessage` payloads | Funds on the destination are released without a real source payment | `receiveMessage` is callable only by the configured adapter (`onlyBridge`). Escrow funds are custodied on the *source* chain, so a forged destination message cannot drain source escrows. **Remaining risk:** adapter contract trust — see below. |
| 2 | **Replay attack** — a valid message is redelivered | Double-settlement / double-announcement | Per-sender nonces on the source chain and `delivered[sourceChainId][nonce]` on the destination guarantee exactly-once processing. |
| 3 | **Oracle manipulation** — a corrupt oracle attests a milestone that is not complete | Grant tranches released prematurely | Oracle is a single configured attestation key. **Mitigation:** prefer multisig/vote modes for production grants; document the oracle's trusted role. |
| 4 | **Escrow lock-up on bridge failure** — a message never arrives | Sender funds stranded | Timeout fallback: one-time payments refund after `timeout`; milestone escrows refund unreleased tranches after `releaseDeadline`; streams refund on `cancel()`. |
| 5 | **MEV on payment release** — release transactions are front-run | Recipient receives less than intended (indirectly, via ordering) | Release functions are permissioned to the recipient/sender/approvers and deterministic; amounts are fixed by the escrow, so ordering cannot change *who* receives *how much*. |
| 6 | **Spoofed token** — a fake cross-chain token id is claimed | Recipient believes they will receive a token that was never funded | **Mitigated.** The router enforces a token allowlist: a source `token` may only claim the `destToken` registered via `setTokenMapping` (`tokenMap[token][destChainId] == destToken`), and `receiveMessage` rejects tokens not in `allowedDestTokens`. |
| 7 | **Router admin compromise** — owner key is stolen | Attacker can set a malicious bridge or take ownership | `onlyOwner` guards bridge/ownership changes. **Mitigation:** use a multisig owner in production; see Roadmap. |
| 8 | **Rounding / overflow in stream math** | Incorrect release amounts | Streams compute `ratePerSecond = amount / duration` and refund the division dust at funding; accounting is tested with fuzz tests against rounding and overflow. |

## Trust boundaries

```text
Funder ──► Router ──► Escrow (custody)          ← on-chain, permissioned
                │
                └──► Bridge Adapter             ← the single trust boundary
                        │
                        └──► relayer            ← assumed honest (or mocked)
```

The bridge adapter is the only component that can trigger cross-chain
settlement. Its correctness and the honesty of its relayer set the security
ceiling for the whole protocol. Escrow accounting is independent of the
bridge and is fully covered by on-chain tests.

## Known limitations (MVP)

- Contracts are **unaudited**; see the disclaimer above.
- The `MockBridgeAdapter` is for development only and provides no
  authenticity. An Axelar GMP adapter is now implemented
  (`AxelarBridgeAdapter`, `soroban-axelar/`) but is **unaudited**; it must be
  audited before any real value is routed.
- Cross-chain token mapping is enforced via an allowlist
  (`setTokenMapping` / `allowedDestTokens` on EVM, `set_allowed_token` on
  Soroban), but wrapped-asset supply verification (confirming the destination
  token is backed) is not yet implemented.
- No pausability / emergency circuit-breaker exists yet.

## Responsible disclosure

If you find a vulnerability, please do **not** open a public issue or disclose
it in public channels. Report it privately to the maintainers via a
security advisory:

1. Go to **Security → Advisories → Report a vulnerability** on the GitHub repo
   (or email the maintainers listed in `CODEOWNERS` if configured).
2. Include a clear description, reproduction steps, affected versions, and
   (if possible) a suggested fix.
3. Allow a reasonable window for a fix and public disclosure before publishing
   details.

We will acknowledge reports promptly and treat them confidentially.

## Scope

- In scope: `contracts/src/*`, `soroban/src/*`, `sdk/src/*`, and the message
  format defined in `docs/PROTOCOL_SPEC.md`.
- Out of scope: third-party bridge infrastructure, the reference frontend's
  server-side code, and social-engineering of maintainers.
