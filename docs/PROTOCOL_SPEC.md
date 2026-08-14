# Protocol Specification

**cross-chain-payments** — non-custodial, open-source routing layer for grant,
salary, and donation payments across blockchain networks.

- Version: `0.1.0` (MVP, unaudited)
- Status: draft
- Audience: implementers of the EVM and Soroban contracts, the TypeScript SDK,
  and future bridge adapters.

---

## 1. Design goals

1. **Chain-agnostic primitives.** A payment is described once, in a single
   canonical message format, and executed identically on any supported chain.
2. **Non-custodial.** Assets are held only in per-payment escrow contracts
   controlled by the protocol. There is no pooled vault or keeper balance.
3. **Bridge-agnostic.** Cross-chain delivery is behind a single adapter
   interface. Escrow logic never knows which bridge carried a message.
4. **Replay-safe.** Every message is nonce-protected and delivered exactly once
   per `(sourceChainId, sender)`.
5. **Timeout-safe.** If a message cannot be delivered, senders can always
   recover funds through an on-chain fallback after a deadline.

---

## 2. Network identifiers

Chain IDs are protocol-level, stable identifiers registered by the router.

| Name                | Chain ID | Environment      |
| ------------------- | -------- | ---------------- |
| Ethereum (EVM)      | `1`      | EVM / Solidity   |
| Stellar (Soroban)   | `1500`   | Soroban / Rust   |
| Local / mock        | `0`      | MockBridgeAdapter |

Chain IDs are `uint256` on-chain and `bigint`/`string` off-chain.

---

## 3. Payment primitives

| Mode | Enum | Description |
| ---- | ---- | ----------- |
| `OneTime`   | `0` | Full amount released immediately once funded and delivered. |
| `Stream`    | `1` | Linear per-second release over a duration; withdrawable anytime; cancelable by sender with pro-rata settlement. |
| `Milestone` | `2` | Funds locked in escrow, released in tranches via multisig, DAO vote, or oracle attestation. Primary mode for grant disbursement. |

---

## 4. Cross-chain message format

Canonical field order (ABI-encoded on EVM, `env.bytes()`-packed on Soroban):

```text
nonce          uint256   monotonically increasing, per (sourceChainId, sender)
sourceChainId  uint256   chain that originates the message
destChainId    uint256   chain that must receive the message
token          bytes32   canonical token identifier (address on EVM, contract id on Soroban)
amount         uint256   base-unit amount (e.g. wei / stroops)
recipient      bytes     destination address encoded per-chain (20 bytes EVM, 32 bytes Soroban)
mode           uint8     payment mode enum (0 / 1 / 2)
metadata       bytes     mode-specific payload (see below)
```

### 4.1 `metadata` per mode

**OneTime** — empty.

**Stream** — packed:

```text
ratePerSecond  uint256  amount / duration, truncated to base units per second
duration       uint256  total stream duration in seconds
```

The escrow computes `ratePerSecond = amount / duration` on creation; any
remainder (`amount - ratePerSecond * duration`) is returned to the sender at
funding time so accounting stays exact.

**Milestone** — packed:

```text
trancheCount    uint256  number of tranches
trancheAmounts  uint256[] amounts per tranche (sum must equal amount)
releaseDeadline uint256  timestamp after which the sender may claim the timeout fallback
```

### 4.2 Encoding rules

- On EVM the message is `abi.encode(CrossChainMessage)` and the bridge adapter
  carries the opaque `bytes payload`.
- On Soroban the message is encoded with `soroban_sdk::xdr` / `env.bytes()` into
  a `Bytes` blob using the same logical fields.
- Endianness and integer widths must match (`uint256` ↔ 32 bytes big-endian).
- `token` and `recipient` are padded left to a fixed width (32 bytes for
  Soroban, 20 bytes left-padded to 32 for EVM addresses) so both chains can
  decode a message deterministically.

---

## 5. Escrow state machines

### 5.1 StreamEscrow

```text
               fund()
Created ─────────────────────► Funded
                                 │
                                 │ start stream (on first funded block/time)
                                 ▼
                              Streaming
                              │        │
            withdraw()        │        │  cancel()
            (recipient)       │        │  (sender)
                              ▼        ▼
                        (accrued)   Cancelled
                        Completed  (pro-rata split)
```

**Accounting**

- `released = ratePerSecond * elapsed(streamStartTime, now)`
- `withdrawable(recipient) = released - alreadyWithdrawn`
- `refundable(sender) = totalFunded - released - alreadyWithdrawn`
- On `cancel()`, recipient keeps accrued-but-unwithdrawn amount; the remainder
  returns to the sender.

**Invariants**

- `withdrawn + refunded + remaining == totalFunded` at every point.
- A stream may only transition out of `Streaming` exactly once (to
  `Completed` when fully released, or `Cancelled`).

### 5.2 MilestoneEscrow

```text
              fund()
Created ──────────────► Funded
                          │
                          ▼
                   PendingMilestone
                     │           │
   releaseMilestone()│           │  timeout + sender claim
   (multisig / vote) │           │  (after releaseDeadline)
                     ▼           ▼
               PartiallyReleased  Cancelled (refund sender)
                     │
                     │ all tranches released
                     ▼
                  Completed
```

- Each tranche is `Locked | Released`.
- `releaseMilestone(i)` requires one of the configured approvers:
  - **multisig** — `m-of-n` signatures,
  - **vote** — a simple majority of a configured DAO voter set, or
  - **oracle** — a trusted attestation key.
- Timeout fallback: if `releaseDeadline` passes and not all tranches are
  released, the sender may claim the unreleased remainder.

---

## 6. Nonce / replay protection

- Each sender keeps a `nonce` counter on the **source** chain, incremented on
  every `sendPayment`/`streamPayment`/`createMilestonePayment` call.
- The router emits `PaymentInitiated(nonce, sourceChainId, destChainId, ...)`.
- The **destination** router maintains a `deliveredNonces[sourceChainId][sender]`
  set (or `highestNonce`), and rejects any message whose nonce has already been
  processed. This guarantees **exactly-once** delivery even if a bridge adapter
  redelivers a message.

## 7. Timeout-based fallback

Every cross-chain payment has a user-supplied (or defaulted) `timeout` deadline.

- If the destination message is not confirmed by `timeout`, the source escrow
  may be cancelled by the sender and funds returned.
- On the destination chain, the escrow records the expected delivery window; if
  the message is never delivered, no escrow is created and no funds are locked
  on that chain (funds were held on the source chain and are recoverable there).

This guarantees the sender can never lose funds to a bridge that fails to
deliver.

---

## 8. Bridge adapter interface (logical)

```text
sendMessage(CrossChainMessage message) -> bytes deliveryId
receiveMessage(bytes payload) -> CrossChainMessage   // only callable by the adapter
event MessageSent(deliveryId, nonce, sourceChainId, destChainId)
event MessageReceived(nonce, sourceChainId, destChainId)
```

- `PaymentRouter` calls `sendMessage`; the adapter emits `MessageSent`.
- The bridge relayer eventually calls `receiveMessage` on the destination
  router, which decodes and dispatches to the correct escrow.
- `MockBridgeAdapter` is a fully synchronous/in-memory implementation for local
  and testnet development.

---

## 9. Security notes

- Contracts are **unaudited**. See `docs/SECURITY.md` for the full threat model.
- The bridge adapter is the single trust boundary; escrow accounting is
  independent of it and is fully covered by on-chain tests.
- `token` must be validated against a per-chain allowlist by the router to
  prevent spoofed cross-chain token claims.
