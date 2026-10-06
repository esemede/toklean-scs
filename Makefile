-include .env
export

.PHONY: build test fmt anvil deploy-local deploy-amoy setup-amoy deploy-sepolia setup-sepolia deploy-economy-local deploy-economy-sepolia abis balance

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

deploy-economy-local:
	forge script script/DeployEconomy.s.sol --rpc-url local --broadcast

# Sepolia cobra hoy ~7x más gas por crear contratos que lo que simulan forge/anvil (token: 14,4M vs 2,06M),
# por eso el multiplicador de gas. El gas no usado se devuelve; el tope por transacción es 16,7M (EIP-7825).
deploy-economy-sepolia:
	forge script script/DeployEconomy.s.sol --rpc-url sepolia --broadcast --gas-estimate-multiplier 800 $(if $(ETHERSCAN_API_KEY),--verify,)

balance:
	cast balance --ether $$(cast wallet address $(PRIVATE_KEY)) --rpc-url $(AMOY_RPC_URL)

abis: build
	node script/export-abis.mjs ../toklean-front/src/abi/impact
