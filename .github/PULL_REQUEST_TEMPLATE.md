## Summary

<!-- What does this PR do and why? Link the issue it closes. -->

## Checklist

- [ ] Solidity changes have tests (`forge test`)
- [ ] Soroban changes have tests and were built (`cargo build --release --target wasm32v1-none && cargo test`)
- [ ] SDK changes typecheck and pass tests (`npm run typecheck -w @ipay/sdk && npm test -w @ipay/sdk`)
- [ ] Docs updated if the message format or protocol behavior changed
- [ ] Linked to an issue (e.g. `Closes #123`)

## Test plan

<!-- How did you verify this change? List commands run. -->
