# Contributing

Thanks for helping build **cross-chain-payments**! This guide covers setup,
conventions, and how to find beginner-friendly work.

## Setup

You need Node.js, Foundry, and Rust (for Soroban). The three subprojects are
independent; install only what you plan to work on.

```bash
# Node / npm (SDK + frontend)
node --version   # >= 18

# Foundry (EVM contracts)
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Rust + Soroban target
rustup target add wasm32v1-none
```

Then clone and install dependencies:

```bash
git clone https://github.com/vijaymark/cross-chain-payments.git
cd cross-chain-payments

# npm workspace (sdk + app)
npm install

cd contracts && forge install foundry-rs/forge-std
```

## Development loop

```bash
# EVM contracts
cd contracts && forge test

# Soroban contracts
cd soroban && cargo test

# TypeScript SDK
npm run typecheck -w @cross-chain-payments/sdk
npm test -w @cross-chain-payments/sdk
```

Run all three before opening a PR.

## Branch & commit conventions

- Branch from `main`; name branches `feat/…`, `fix/…`, `docs/…`, `chore/…`.
- Keep commits focused; one logical change per commit.
- Write commit messages in the imperative ("Add X", "Fix Y").
- PRs must pass CI (`.github/workflows/ci.yml` and `contracts-test.yml`).

## Code style

- **Solidity** — follow `forge fmt`; keep escrow accounting behind explicit
  invariants and test them.
- **Rust** — `cargo fmt` and `cargo clippy` must be clean.
- **TypeScript** — `tsc --noEmit` must pass; export types from
  `sdk/src/types.ts`.

## Testing expectations

- New escrow behavior needs a Solidity test (and a mirroring Soroban test when
  it affects the cross-chain message format or accounting).
- Streaming math changes need fuzz tests for rounding/overflow.
- SDK changes need a unit test; adapter changes need an Anvil integration test
  where practical.

## Finding good-first-issue work

Issues labeled [`good first issue`](https://github.com/vijaymark/cross-chain-payments/labels/good%20first%20issue)
are scoped for newcomers. Common starter tasks:

- Adding a missing revert/guard test to push coverage higher.
- Improving doc examples or adding a mermaid diagram.
- Adding a script under `scripts/` for a single-chain deploy.
- Writing an SDK unit test for an uncovered branch.

## Code of Conduct

All contributors must follow the [Code of Conduct](CODE_OF_CONDUCT.md).
