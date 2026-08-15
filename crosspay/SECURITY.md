# Security

> **Status:** unaudited MVP. Testnet only. Do not deploy to mainnet.

## Trust assumptions

1. **LayerZero endpoint + DVNs/executors are trusted** for message integrity and
   delivery on the configured pathway. This is the single largest trust
   boundary in the system.
2. **Peer whitelisting.** The router only processes a message when
   `origin.sender == peers[origin.srcEid]`, enforced in `lzReceive`
   (`UnauthorizedPeer()` otherwise). A compromised peer — or a compromised
   LayerZero pathway — could therefore mint arbitrary claimable credit on the
   destination.
3. **Owner (Ownable2Step).** The owner can pause, toggle supported tokens, and
   change peers. The owner **cannot** seize or freeze already-claimable or
   vested funds: pause never blocks `claim`/`claimDirect`, and `rescueTokens`
   structurally reverts (`TokenIsSupported()`) for any token in
   `supportedTokens`.

## Known limitations

- **No message-failure retry / timeout refund.** A permanently undelivered
  message leaves funds locked on the source chain with no cancel/refund path.
- **Single-owner admin** (two-step transfer, but still centralized).
- **Single token address per asset** — no cross-chain token registry.
- **No rate limiting or monitoring.**

## Out of scope (and why)

- **Fee-on-transfer / rebasing tokens** are not supported and MUST NOT be
  whitelisted: the router locks `amount` via `safeTransferFrom` and later pays
  `amount` out, so a fee-on-transfer token would credit more than it actually
  received, leaving the destination short.
- Slippage/fee accounting, gasless claims, batch claims, and meshes beyond two
  chains.

## Recommended before mainnet

1. Independent third-party audit.
2. Multiple **required** DVNs from independent operators (per LayerZero's
   production guidance) — a single-DVN config means one compromised verifier can
   forge messages.
3. Message delivery timeout + refund path.
4. Per-destination token registry + canonical token allowlist.
5. Multi-sig / timelock ownership.

## Reporting

Report vulnerabilities privately to the maintainers. Do **not** open a public
issue for security findings.
