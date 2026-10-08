#!/bin/bash
# Levanta la pila local completa con el backend en Worker: anvil + contratos + stub de Pinata + `wrangler dev` (D1 local)
# y siembra el marketplace por la API. Úsalo para probar el Worker sin cuentas de Cloudflare ni de Pinata.
set -e
BACK=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$BACK/.." && pwd)
export PATH=$PATH:/root/.foundry/bin
K=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
R=http://127.0.0.1:8545
LOG=${LOG_DIR:-/tmp/claude-0/worker-local}; mkdir -p "$LOG"

pkill -f "[a]nvil --port 8545" 2>/dev/null || true
pkill -f "[w]rangler" 2>/dev/null || true
pkill -f "[w]orkerd" 2>/dev/null || true
pkill -f "[s]tub-pinata" 2>/dev/null || true
sleep 2
(nohup anvil --port 8545 --chain-id 31337 --silent > "$LOG/anvil.log" 2>&1 &)
sleep 3
cd "$ROOT"; rm -f deployments/31337.json
for s in Deploy DeployEconomy SeedDemo DeployMarketplace; do
  env -i HOME=$HOME PATH=$PATH PRIVATE_KEY=$K IMAGE_BASE_URI=ipfs://CID/ forge script script/$s.s.sol --rpc-url $R --broadcast > "$LOG/$s.log" 2>&1 || { echo "falló $s"; tail -20 "$LOG/$s.log"; exit 1; }
done

cd "$BACK"
(PORT=9000 nohup node scripts/stub-pinata.mjs > "$LOG/stub.log" 2>&1 &)
cat > .dev.vars <<VARS
RPC_URL=$R
PINATA_JWT=test-jwt
PINATA_API_URL=http://127.0.0.1:9000
VARS
# Dirección de los contratos recién desplegados (sobrescribe las de wrangler.toml para anvil).
DEP=$ROOT/deployments/31337.json
TOKEN=$(python3 -c "import json;print(json.load(open('$DEP'))['ToKleanToken'])")
PRODS=$(python3 -c "import json;print(json.load(open('$DEP'))['CircularProductNFT'])")
REG=$(python3 -c "import json;print(json.load(open('$DEP'))['ToKleanMerchantRegistry'])")
CAT=$(python3 -c "import json;print(json.load(open('$DEP'))['ToKleanCatalog'])")
MKT=$(python3 -c "import json;print(json.load(open('$DEP'))['ToKleanMarketplace'])")
START=$(python3 -c "import json;print(json.load(open('$DEP'))['marketplaceStartBlock'])")
VARS_OVERRIDE="--var CHAIN_ID:31337 --var MARKETPLACE_START_BLOCK:$START --var TOKLEAN_TOKEN:$TOKEN --var CIRCULAR_PRODUCT_NFT:$PRODS --var MERCHANT_REGISTRY:$REG --var CATALOG:$CAT --var MARKETPLACE:$MKT --var IPFS_GATEWAY:http://127.0.0.1:9000/ipfs/ --var CONFIRMATIONS:0 --var MAX_CHUNKS_PER_RUN:50 --var MAX_ENRICH_PER_RUN:50 --var UPLOADS_PER_HOUR:1000 --var CORS_ORIGINS:http://localhost:4174"
# Anvil arranca de cero: el índice local de D1 de una corrida anterior no sirve.
rm -rf .wrangler/state
npx wrangler d1 migrations apply toklean-marketplace --local > "$LOG/migrate.log" 2>&1
(nohup npx wrangler dev --port 8787 --test-scheduled --ip 127.0.0.1 $VARS_OVERRIDE > "$LOG/wrangler.log" 2>&1 &)
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8787/health && break; sleep 1; done
echo "worker: $(curl -s http://127.0.0.1:8787/health)"
