-include .env
export

.PHONY: build test fmt anvil deploy-local deploy-amoy setup-amoy deploy-sepolia setup-sepolia abis balance

build:
	forge build --sizes

test:
	forge test -vvv

fmt:
	forge fmt

# Nodo local con 10 cuentas con fondos (sin faucet)
anvil:
	anvil --chain-id 31337

deploy-local:
	forge script script/Deploy.s.sol --rpc-url local --broadcast

deploy-amoy:
	forge script script/Deploy.s.sol --rpc-url amoy --broadcast $(if $(POLYGONSCAN_API_KEY),--verify,)

setup-amoy:
	forge script script/SetupTestnet.s.sol --rpc-url amoy --broadcast

deploy-sepolia:
	forge script script/Deploy.s.sol --rpc-url sepolia --broadcast $(if $(ETHERSCAN_API_KEY),--verify,)

setup-sepolia:
	forge script script/SetupTestnet.s.sol --rpc-url sepolia --broadcast

balance:
	cast balance --ether $$(cast wallet address $(PRIVATE_KEY)) --rpc-url $(AMOY_RPC_URL)

abis: build
	node script/export-abis.mjs ../toklean-front/src/abi/impact
