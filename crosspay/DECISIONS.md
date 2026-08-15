# Decisions

Non-obvious choices made while building CrossPay, with the reasoning and the
rejected alternative. This is the project's audit trail for "why did they do X".

## D1 — LayerZero package: `@layerzerolabs/oapp-evm`, not `lz-evm-oapp-v2`

The spec references `@layerzerolabs/lz-evm-oapp-v2` while **also** requiring
OpenZeppelin **v5** (`Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`).
Those two are mutually exclusive:

- `lz-evm-oapp-v2` pins `@openzeppelin/contracts: ^4.8.1`. Its `OAppCore`
  inherits v4-style `Ownable` (a no-argument constructor), so compiling it
  against OZ v5 fails — v5 `Ownable` requires an `initialOwner` constructor
  argument that `OAppCore` never supplies.
- The current official package is `@layerzerolabs/oapp-evm` (v0.4.x), whose
  `package.json` declares `@openzeppelin/contracts: ^5.0.2` and whose docs use
  the `OApp(_endpoint, _owner) Ownable(_owner)` constructor pattern.

We use `oapp-evm` with OZ `v5.0.2`, wiring ownership as
`OApp(_endpoint, _owner) Ownable2Step(_owner)`.

## D2 — Double-claim reverts with `NothingToClaim()`

The spec allowed either a silent zero-amount second claim or a revert. We chose
to **revert** `NothingToClaim()`: it is more explicit for integrators, surfaces
bugs earlier, and the error is already part of the public ABI.
`test_stream_claimPartialThenFull` pins this behavior.

## D3 — `PeerSet` event is not redeclared

LayerZero's `IOAppCore` (inherited via `OApp`) already emits
`PeerSet(uint32 eid, bytes32 peer)` on every `setPeer`. Redeclaring an identical
event in `IPaymentRouter` would duplicate the declaration, so the base event is
used as-is.

## D4 — `setPeer` is not re-declared in `IPaymentRouter`

`setPeer`, `peers`, and `endpoint` are inherited from `IOAppCore`/`OAppCore`.
Redeclaring them would force an `override` with no benefit; the interface's
NatSpec documents the inheritance instead.

## D5 — `rescueTokens` is `nonReentrant`

It is not on the spec's explicit nonReentrant list, but it moves funds, so it
gets the guard for consistency with the "every function that moves funds" rule.

## D6 — `UnauthorizedCaller(address)` error added

`sendMessage` / `receiveMessage` (the transport entry points) must only be
callable by the router itself — otherwise anyone could inject a payload toward
the peer, or self-credit on the destination. The spec's error list had no fit
for this, so a dedicated `UnauthorizedCaller(address)` was added to
`IPaymentRouter`.

## D7 — `lzReceive` overridden to raise `UnauthorizedPeer()`

The spec requires rejecting an unregistered `origin.sender` with
`UnauthorizedPeer()`. The OApp base raises `OnlyPeer(uint32,bytes32)` instead,
so `lzReceive` is overridden to perform the endpoint + peer checks and revert
with this project's own error (kept testable via `test_lzReceive_unregisteredPeerReverts`).

## D8 — Cross-chain token identity

The payload carries the token address and the destination treats the *same*
address as the payout token. This is only correct when the token is deployed at
an identical address on both chains (CREATE2, or a canonical token). A
per-destination token registry is the production follow-up.

## D9 — Pre-funded destination (no mint/burn)

The destination router must hold the token; `_lzReceive` only updates bookkeeping
and `claim` transfers from the router's own balance. No mint/burn or fee
mechanism in this MVP.

## D10 — Stream packed into 3 storage slots

Field order (`recipient, start, periods, periodDuration, token, total, claimed`)
yields exactly 3 slots — the theoretical minimum (85 bytes of state):

- slot 0: `recipient` (20B) + `start` (5B) + `periods` (4B) — 29B
- slot 1: `periodDuration` (4B) + `token` (20B) — 24B
- slot 2: `total` (16B) + `claimed` (16B) — 32B

Confirm with `forge inspect PaymentRouter storage-layout`.
