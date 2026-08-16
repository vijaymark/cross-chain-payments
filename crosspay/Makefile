.PHONY: all install-deps build test fmt fmt-check lint coverage slither

all: build test

install-deps:
	forge install foundry-rs/forge-std --no-git
	forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
	forge install LayerZero-Labs/devtools --no-git
	forge install LayerZero-Labs/LayerZero-v2 --no-git
	forge install GNSPS/solidity-bytes-utils --no-git

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
