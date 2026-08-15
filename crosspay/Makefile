.PHONY: all install-deps build test fmt fmt-check lint coverage slither

all: build test

install-deps:
	forge install foundry-rs/forge-std --no-commit
	forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
	forge install LayerZero-Labs/devtools --no-commit
	forge install LayerZero-Labs/LayerZero-v2 --no-commit
	forge install GNSPS/solidity-bytes-utils --no-commit

build:
	forge build

test:
	forge test -vvv

fmt:
	forge fmt

fmt-check:
	forge fmt --check

lint:
	solhint 'src/**/*.sol'

coverage:
	bash scripts/coverage.sh 90

slither:
	slither . --config-file slither.config.json
