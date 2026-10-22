# AGENTS.md – ToKlean (contratos, backend del marketplace y despliegues)

Guía para agentes y colaboradores. Describe el sistema completo, dónde vive cada pieza, cómo se prueba y cómo se
despliega. El frontend tiene su propia guía en `../toklean-front/AGENTS.md`.

- **Repositorio:** `esemede/toklean-scs` (este). Frontend: `toklean/toklean-front`.
- **Rama de trabajo:** `claude/upbeat-thompson-01mwke`. Este repositorio no tiene `main` en remoto; no abras PR sin
  que el usuario indique la rama base.
- **Idioma:** la documentación, los comentarios y los mensajes de error de dominio están en español. Mantén ese estilo.

---

## 1. Mapa del sistema

```
toklean-scs/                       contratos Solidity (Foundry) + backend TypeScript
├── src/                           contratos
│   ├── *NFT.sol                   TreeNFT, RecyclingIdeaNFT, RecyclingBatchNFT, CircularProductNFT, CleanupActionNFT
│   ├── common/                    ImpactNFTBase.sol, Types.sol
│   ├── token/                     ToKleanToken (ERC-1155: TKN, REC, POR), TokenFaucet (sólo testnets)
│   ├── staking/                   ToKleanStaking
│   ├── governance/                ToKleanGovernance (DAO)
│   ├── marketplace/               ToKleanMerchantRegistry, ToKleanCatalog, ToKleanMarketplace
│   └── interfaces/
├── test/                          pruebas Foundry (unitarias, fuzz, invariantes, tamaño)
├── script/                        Deploy, DeployEconomy, DeployMarketplace, SetupTestnet, SeedDemo, export-abis.mjs
├── deployments/                   <chainId>.json: direcciones que consumen frontend y backend
├── broadcast/                     registros de transacciones (Foundry) de los despliegues en Sepolia
├── backend/                       indexador, API y servicio de metadata del marketplace (Node y Cloudflare Workers)
├── Makefile                       atajos de despliegue (ver §5)
├── foundry.toml, foundry.lock, .gitmodules (lib/: forge-std, openzeppelin-contracts)
└── .github/workflows/test.yml     CI: formato, build con tamaños, tests Foundry, backend (check + e2e)
```

El frontend (`toklean-front`) consume:
- **ABIs** generadas aquí (`make abis` → `../toklean-front/src/abi/impact`).
- **Direcciones** de `deployments/<chainId>.json`, copiadas a `toklean-front/src/config/deployments/`.
- **API** del backend del marketplace (`VITE_MARKETPLACE_API_URL`).

### Redes y estado actual

| Red | chainId | Uso | Archivo de direcciones |
| --- | --- | --- | --- |
| Anvil local | 31337 | Desarrollo y pruebas e2e | `deployments/31337.json` (ignorado por git) |
| Ethereum Sepolia | 11155111 | Testnet activa del marketplace y la economía | `deployments/11155111.json` |
| Polygon Amoy | 80002 | Testnet anterior; el README la documenta como alternativa | `deployments/80002.json` (no está en el repo) |
| Polygon mainnet | 137 | Pendiente: requiere auditoría externa | — |

Sepolia tiene desplegados los NFT de impacto, la economía (token, staking, gobernanza, faucet) y el marketplace
(registro, catálogo y pedidos), con `marketplaceStartBlock` 11866001.

---

## 2. Contratos

### 2.1 NFT de impacto (`ImpactNFTBase`)

Todos usan `AccessControl`, pausa de emergencia, metadata on-chain (JSON base64, entradas escapadas) y evidencias
como `hash + URI` (IPFS o Arweave).

| Contrato | Símbolo | Qué representa | Transferible |
| --- | --- | --- | --- |
| `TreeNFT` | TKTREE | Árbol plantado con historial de crecimiento | Sí (apadrinamiento); el plantador queda fijo |
| `RecyclingIdeaNFT` | TKIDEA | Idea de reciclaje: autoría, respaldos, curaduría, implementaciones | Sí, regalías ERC-2981 del 5 % |
| `RecyclingBatchNFT` | TKBATCH | Pasaporte de un lote de material: custodia y pesajes | Sólo por handshake de custodia |
| `CircularProductNFT` | TKPROD | Pasaporte de producto con material reciclado y datos de fabricación | Sí |
| `CleanupActionNFT` | TKCLEAN | Insignia de jornada de limpieza verificada | No (soulbound, ERC-5192) |

**Garantías que imponen los contratos**
- *Separación de funciones:* nadie verifica su propio árbol, idea, campaña o producto.
- *Balance de masa:* cada pesaje ≤ el anterior (+2 % de tolerancia de báscula sólo en cambios de custodia).
- *Sin doble gasto de material:* el producto descuenta gramos del lote; un lote agotado pasa a `Consumed`.
- *Custodia real:* `transferFrom` del lote está bloqueado; el custodio físico siempre lo tiene.
- *RAEE y baterías (Ley REP 20.920):* sólo `HAZARDOUS_HANDLER_ROLE` puede recibirlos antes de procesarse.
- *Crédito al recolector* con el peso medido por el centro de acopio.
- *Fabricación limpia:* criterios on-chain (`minRecycledContentBps`, `minRenewableEnergyBps`, `maxCo2eGramsPerKg`)
  y firma de un auditor; revocable.
- *Limpiezas:* Merkle root publicado por un verificador distinto del organizador; la suma reclamada nunca supera lo
  pesado; cualquiera puede pagar el gas del reclamo, pero el NFT va al participante.

**Roles**

| Rol | Contratos | Quién debería tenerlo |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE` | todos | Safe multisig / Timelock |
| `VERIFIER_ROLE` | todos | ONG, municipio, certificadora, auditor |
| `COLLECTOR_ROLE`, `COLLECTION_CENTER_ROLE`, `RECYCLER_ROLE`, `MANUFACTURER_ROLE` | Batch (y Product para fabricantes) | Actores de la cadena |
| `HAZARDOUS_HANDLER_ROLE` | Batch | Gestores con autorización sanitaria (D.S. 148/2003) |
| `CONSUMER_ROLE` | Batch | Sólo `CircularProductNFT` |
| `ORGANIZER_ROLE` | Cleanup | Organizadores de jornadas |

### 2.2 Economía

| Contrato | Qué hace |
| --- | --- |
| `ToKleanToken` (ERC-1155, 18 decimales) | id 1 **TKN** (utilidad y gobernanza, con tope), id 2 **REC** (recompensa quemable, sin tope), id 3 **POR** (Prueba de Reciclaje). Roles `MINTER`, `PAUSER`. |
| `ToKleanStaking` | Stake de TKN que rinde REC a un APR lineal (12,5 % inicial, tope 50 %). `unstake` siempre disponible, incluso en pausa. |
| `ToKleanGovernance` | DAO: voto con TKN en stake **un segundo antes** de crear la propuesta; quórum, timelock, aprobación del comité de compliance para propuestas de centros y fondos, pausa de emergencia del guardián (72 h, con 7 días entre pausas). |
| `TokenFaucet` | 50 TKN por dirección cada 24 h. **Sólo testnets**: el constructor revierte en redes principales. |

Límites conocidos: el poder de voto es el TKN en stake (los ERC-721 no guardan historial de saldos, así que votar con
ellos permitiría doble voto); no hay delegación; el admin puede pausar el token, que bloquea transferencias, emisión y
quema.

### 2.3 Marketplace

Tres contratos, cada uno < 10 KB (ver la nota de gas en §5). Los textos no se guardan on-chain: se guarda
`keccak256(uri)` y la URI completa se emite en eventos.

| Contrato | Qué hace |
| --- | --- |
| `ToKleanMerchantRegistry` | Postulación, aprobación por compliance (`MERCHANT_ADMIN_ROLE`), suspensión y reputación (ventas y valoraciones 1-5 de compras reales). Rol `MARKETPLACE_ROLE` para el marketplace. |
| `ToKleanCatalog` | Publicaciones de productos y servicios con stock, precio y medio de pago (TKN/REC). Puede vincular un `CircularProductNFT` certificado: el pasaporte queda en custodia y viaja al comprador al cerrarse la venta. Aquí vive la pausa. |
| `ToKleanMarketplace` | Pedidos con escrow: Pagada → Enviada → Completada. Confirmación del comprador; si vence, cualquiera libera. Si el vendedor no envía a tiempo, el comprador se reembolsa solo. Disputas con árbitro (si nadie resuelve, el comprador recupera todo). Pagos *pull* (`withdraw`), comisión 2 %, POR al comprador de un producto limpio, `maxUnitPrice` contra front-running. |

**Garantías:** ninguna cuenta que rechace tokens puede bloquear un pedido o una resolución; una venta nunca queda
atascada por un fallo al emitir POR; la pausa no bloquea liberar, reembolsar, disputar ni retirar.

**Pruebas:** unitarias, fuzz de conservación de fondos e invariantes (`test/MarketplaceInvariant.t.sol`: el
marketplace siempre tiene exactamente lo que debe a pedidos abiertos y saldos acreditados).
`test_DeployedSizeFitsTheGasBudget` vigila el tamaño de los contratos.

---

## 3. Backend del marketplace (`backend/`)

Indexa los eventos de los tres contratos del marketplace, verifica la metadata y sirve la API al frontend. Los
eventos sólo marcan *qué cambió*; el estado se **relee de los contratos**, así que el índice se corrige solo ante
reorgs o eventos perdidos.

### 3.1 Componentes

| Ruta | Responsabilidad |
| --- | --- |
| `src/indexer/` | `indexer.ts` (sincronización por bloques con confirmaciones), `chain.ts` (lectura de logs y estado con viem, `batch: true`), `snapshot.ts` |
| `src/metadata/` | `fetch.ts` (descarga con política de hosts, sin redirects, tope de tamaño y tiempo), `schema.ts` (esquemas zod `toklean.listing/1` y `toklean.merchant/1`, `keccak256` contra el hash on-chain), `pinata.ts` y `object-store.ts` (IPFS), `store.ts` (disco en Node) |
| `src/api/` | `router.ts`, `query.ts` (filtros, facetas, cursor), `dto.ts`, `upload.ts`, `http.ts` |
| `src/keeper.ts` | Libera pedidos vencidos y empuja los saldos acreditados (opcional) |
| `src/auth.ts` | Verificación de firmas EIP-191 de las subidas |
| `src/config.ts`, `src/deployments.ts`, `src/deployment-schema.ts` | Configuración y lectura de `deployments/<chainId>.json` |
| `src/server.ts` | Entrada en Node (`pnpm start`) |
| `worker/index.ts` | Entrada en Cloudflare Workers: `fetch` (API, caché de 15 s) y `scheduled` (cron cada minuto) |
| `worker/d1-snapshot.ts` | Guardado diferencial en D1 (una fila por comercio, publicación y pedido, lotes de 50) |
| `worker/migrations/` | Esquema D1 (`meta`, `merchants`, `listings`, `orders`) |
| `src/generated/abis.ts` | ABIs generadas (`pnpm abis`, desde `forge build`) |
| `scripts/` | `gen-abis.mjs`, `seed-local.ts` (datos de demo por el flujo real), `stub-pinata.mjs`, `worker-local.sh`, `png.ts`, `deploy-worker.ts` y `deploy-lib.ts` (`pnpm worker:release`, §5.2) |

### 3.2 API

| Ruta | Descripción |
| --- | --- |
| `GET /health` | `ready`, bloque indexado, altura de la cadena y retraso |
| `GET /v1/config` | red, direcciones, medios de pago, categorías y límites de subida |
| `GET /v1/listings` | Filtros `q`, `category`, `kind`, `payment`, `seller`, `clean`, `available`, `minPrice`, `maxPrice`; `sort` (`new`, `priceAsc`, `priceDesc`, `rating`); `limit`, `cursor`. Devuelve `items`, `total`, `nextCursor`, `facets` |
| `GET /v1/listings/:id` | Una publicación en cualquier estado |
| `GET /v1/merchants?status=`, `GET /v1/merchants/:address` | Comercios por estado (cola de compliance) y ficha |
| `POST /v1/sync` | Refresca el índice (la app lo llama tras cada transacción; coalescido en `Indexer.sync`) |
| `GET /v1/orders?buyer=\|seller=&status=` | Pedidos con resumen. Exige `buyer` o `seller` |
| `GET /v1/accounts/:address` | Comercio, pedidos y saldos retirables leídos de la cadena |
| `GET /v1/stats` | Comercios, publicaciones, pedidos y volumen por token |
| `POST /v1/media` | Imagen PNG/JPEG/WebP ≤ 2 MB; el tipo se valida por contenido (SVG rechazado) |
| `POST /v1/metadata?kind=listing\|merchant` | Valida el esquema y devuelve `{ uri, uriHash }` para `createListing` o `applyAsMerchant` |

Los montos viajan como strings en wei. Los errores tienen la forma `{ "error": { "code", "message", "details" } }`.

### 3.3 Subidas firmadas

Sin cuentas ni sesiones. La wallet firma con `personal_sign`:

```
Authorization: ToKlean <dirección>.<timestamp>.<firma>
mensaje = "ToKlean marketplace upload\nkind: <media|metadata>\nsha256: <hex del cuerpo>\ntimestamp: <unix>"
```

- La firma vale ±5 minutos y está atada al contenido exacto.
- Hay cuota por cuenta y global (`UPLOADS_PER_HOUR`). En Workers la cuota es por instancia, no global.
- Publicar una **publicación** exige ser comercio aprobado. El perfil del comercio sí lo puede subir cualquiera, porque
  va *antes* de `applyAsMerchant`.

### 3.4 Variables de entorno

Plantilla completa en `backend/.env.example`.

| Variable | Obligatoria | Descripción |
| --- | --- | --- |
| `RPC_URL` | Sí | RPC de la cadena (puede llevar API key; en Workers va como secreto) |
| `CHAIN_ID`, `DEPLOYMENTS_FILE` | Sí (Node) | Red y ruta a `deployments/<chainId>.json` |
| `PINATA_JWT` | Producción | Subidas a IPFS. Sin él, en Node se guarda en `DATA_DIR` (sólo desarrollo); en Workers las subidas fallan |
| `IPFS_GATEWAY` | No | Gateway para leer archivos (`https://gateway.pinata.cloud/ipfs/`) |
| `CORS_ORIGINS` | Sí en producción | Orígenes del frontend, separados por coma. `*` sólo en desarrollo |
| `ALLOWED_HOSTS` | No | Hosts https extra de los que se aceptan imágenes y metadata |
| `CONFIRMATIONS` | No (2) | Bloques de confirmación antes de indexar |
| `UPLOADS_PER_HOUR` | No (60) | Cuota de subidas por cuenta |
| `KEEPER_PRIVATE_KEY` | No | Clave del keeper. Paga gas: usa una cuenta dedicada |
| `KEEPER_AUTO_RELEASE`, `KEEPER_AUTO_WITHDRAW` | No (`false`) | Activan las acciones del keeper |
| `MAX_CHUNKS_PER_RUN`, `MAX_ENRICH_PER_RUN` | No (5, 20) | Límites por ejecución del cron (Workers) |
| `PUBLIC_BASE_URL`, `DATA_DIR`, `PORT`, `HOST` | No | Sólo modo Node |

En Workers, las variables no secretas están en `backend/wrangler.toml` (`[vars]`): red, direcciones de contratos,
`MARKETPLACE_START_BLOCK`, `CORS_ORIGINS` y límites.

---

## 4. Desarrollo

### 4.1 Contratos

```sh
git submodule update --init --recursive
forge build --sizes
forge test -vvv        # 182 pruebas
forge fmt --check
```

`foundry.toml`: Solidity 0.8.28, EVM `cancun`, `via_ir`, optimizer 200 runs, fuzz 512 runs, formato con
`line_length = 110` y 4 espacios.

### 4.2 Backend

```sh
cd backend
pnpm install
pnpm check             # tipos (Node y Workers) + pruebas unitarias
pnpm test:e2e          # anvil + scripts de Foundry + backend real (necesita Foundry)
pnpm start             # Node, http://localhost:8787
pnpm worker:local      # Workers local: anvil + contratos + Pinata simulado + wrangler dev en :8787
```

Demo completa en anvil:

```sh
anvil --chain-id 31337 &
make deploy-local deploy-economy-local deploy-marketplace-local
forge script script/SeedDemo.s.sol --rpc-url local --broadcast
cd backend && pnpm seed:local
```

`worker-local.sh` permite el origen `http://localhost:4174` (preview del frontend). Si el seed falla por estado de D1
de una cadena anterior, el script borra `.wrangler/state`.

### 4.3 Reglas de trabajo

- No subas `.env`, `.dev.vars`, claves privadas ni `deployments/31337.json`. Están en `.gitignore`.
- Tras cambiar un contrato con eventos o funciones públicas: `make abis` y revisa `backend/src/generated/abis.ts`.
  La CI falla si las ABIs no coinciden.
- Tras cambiar el tamaño de un contrato del marketplace: `test_DeployedSizeFitsTheGasBudget` debe pasar, y recalcula
  el multiplicador de gas (§5).
- El backend no debe usar `node:crypto` en el Worker: el hash está en `@noble/hashes`.
- `fetch` del Worker no se llama como método de clase (`Illegal invocation`): guarda la función en una variable.
- Redirecciones en la descarga de metadata: `redirect: 'manual'`; cualquier 3xx es un error permanente.
- No escribas cifras de gas o tamaños en el código sin medirlas; el README de `toklean-scs` ya tiene algunas
  desactualizadas (ver §7).

---

## 5. Despliegue

### 5.1 Contratos

Variables en `.env` (plantilla en `.env.example`): `PRIVATE_KEY`, `SEPOLIA_RPC_URL`, `AMOY_RPC_URL`,
`POLYGON_RPC_URL`, `ETHERSCAN_API_KEY`, `POLYGONSCAN_API_KEY`, `ADMIN_ADDRESS` (obligatoria en mainnet), `TESTERS`.
Usa una wallet de despliegue dedicada, sólo para testnet.

| Objetivo | Comando |
| --- | --- |
| NFT de impacto en anvil | `make anvil` y luego `make deploy-local` |
| NFT de impacto en Sepolia | `make deploy-sepolia` (escribe `deployments/11155111.json`) y `make setup-sepolia` |
| NFT de impacto en Amoy | `make deploy-amoy` y `make setup-amoy` (usa ≥ 2 wallets: nadie se auto-verifica) |
| Economía | `make deploy-economy-local` o `make deploy-economy-sepolia` |
| Marketplace | `make deploy-marketplace-local` o `make deploy-marketplace-sepolia` |
| ABIs para el frontend | `make abis` (copia a `../toklean-front/src/abi/impact`) |

**Gas en Sepolia:** la red cobra hoy ~7 veces más gas por crear contratos que lo que simulan `forge` y `anvil`.
`deploy-economy-sepolia` usa `--gas-estimate-multiplier 800`. `deploy-marketplace-sepolia` usa **710**, porque con 800
el marketplace (2,34 M simulados) excedería el tope por transacción de 16,7 M (EIP-7825). Antes de desplegar en otra
red, compara `cast rpc eth_estimateGas` con la simulación. Un byte de código cuesta ~1.600 de gas en Sepolia, por eso
cada contrato del marketplace pesa < 10 KB. Los NFT grandes (`RecyclingBatchNFT`, ~18 KB) ya no se podrían volver a
desplegar en Sepolia.

Despliegue general en red pública:

```sh
source .env
forge script script/Deploy.s.sol --rpc-url amoy --broadcast --verify      # testnet
forge script script/Deploy.s.sol --rpc-url polygon --broadcast --verify   # mainnet
```

El script cablea `CONSUMER_ROLE`, transfiere admin y pauser a `ADMIN_ADDRESS`, y el deployer renuncia a sus roles.
Los `DeployEconomy` usan opcionales `ADMIN_ADDRESS`, `COMPLIANCE_ADDRESS`, `GUARDIAN_ADDRESS`, `TKN_CAP`,
`STAKING_APR_BPS`, `VOTING_DELAY`, `VOTING_PERIOD`, `TIMELOCK_DELAY`, `QUORUM_BPS`, `PROPOSAL_THRESHOLD`,
`DEPLOY_FAUCET`.

**Después de cada despliegue:** copia `deployments/<chainId>.json` a `toklean-front/src/config/deployments/` y haz
commit de los registros de `broadcast/` (el hook de git avisa de archivos sin seguir).

### 5.2 Backend en Cloudflare Workers (recomendado, plan gratuito)

Un Worker con la API y un cron cada minuto, una base D1 para el índice y Pinata para los archivos. El script pesa
~290 KB comprimido (límite 3 MB).

Un solo comando, idempotente y multiplataforma (Node, sin bash). Las credenciales de Cloudflare vienen de
`npx wrangler login` o de `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`; los secretos, de variables de entorno
(nunca argumentos): `RPC_URL` (obligatoria, https), `PINATA_JWT` y `KEEPER_PRIVATE_KEY` (opcionales).

```bash
cd backend
pnpm install
pnpm worker:release                # crea D1 si falta, aplica migraciones, despliega con secretos y comprueba /health
pnpm worker:release --dry-run      # compila y valida sin tocar Cloudflare ni pedir credenciales
pnpm worker:release --keep-secrets # redespliegue sin volver a subir secretos
```

El script (`backend/scripts/deploy-worker.ts`, con la lógica pura probada en `deploy-lib.ts`) escribe el `database_id`
real en `wrangler.toml`: **haz commit de ese cambio**. Imprime la URL del Worker y los pasos siguientes. Los pasos
manuales equivalentes están en `backend/README.md`.

También se puede lanzar desde GitHub Actions: workflow `deploy-worker` (manual, entorno `production`) con los secretos
`CLOUDFLARE_API_TOKEN` (*Workers Scripts: Edit*, *D1: Edit*, *Account Settings: Read*), `CLOUDFLARE_ACCOUNT_ID`,
`RPC_URL`, `PINATA_JWT` y opcional `KEEPER_PRIVATE_KEY`. La cuenta necesita un subdominio `workers.dev` registrado.

Después, en Cloudflare Pages del frontend define `VITE_MARKETPLACE_API_URL` con esa URL y vuelve a desplegar.

Antes de desplegar revisa `wrangler.toml`:
- `CORS_ORIGINS` debe incluir el dominio de producción del frontend y los previews de Pages.
- `TOKLEAN_TOKEN`, `CIRCULAR_PRODUCT_NFT`, `MERCHANT_REGISTRY`, `CATALOG`, `MARKETPLACE` y `MARKETPLACE_START_BLOCK`
  deben corresponder al `deployments/11155111.json` vigente. Si se redespliega el marketplace, cámbialos.
- Los límites `MAX_CHUNKS_PER_RUN` y `MAX_ENRICH_PER_RUN` existen por el plan gratuito (subrequests y CPU por
  invocación). Un índice atrasado se pone al día en varias ejecuciones.

Cómo funciona:
- **Índice en D1:** una fila por comercio, publicación y pedido. Cada sincronización escribe sólo lo que cambió.
- **Cron:** indexa hasta `MAX_CHUNKS_PER_RUN` bloques, descarga la metadata pendiente y, con keeper, ejecuta hasta 5
  acciones.
- **Lecturas:** la API lee D1 con caché de 15 s por instancia. `POST /v1/sync` indexa en el momento.
- **Plazos:** el keeper mide plazos con el timestamp del último bloque, no con el reloj del servidor.

Pendiente de validar en Cloudflare real: despliegue, D1 remoto, cron y límites del plan gratuito en producción.

### 5.3 Alternativa Node / Docker

`src/server.ts` (`pnpm start`) y `backend/Dockerfile` (contexto: raíz de `toklean-scs`) sirven el mismo núcleo en
Render o Fly.io. Node guarda el índice y los archivos en `DATA_DIR`; en producción conviene un volumen persistente y
`PINATA_JWT`.

### 5.4 Verificación de contratos

`--verify` usa `ETHERSCAN_API_KEY` (Sepolia) o `POLYGONSCAN_API_KEY` (Polygon y Amoy). Sin clave, el despliegue sigue
pero no se verifica.

---

## 6. CI

`.github/workflows/test.yml` (en push y pull request):

- **contracts:** `forge fmt --check`, `forge build --sizes`, `forge test -vvv`.
- **backend:** `pnpm check`; comprueba que `src/generated/abis.ts` coincide con `forge build`; `pnpm test:e2e`.

`.github/workflows/deploy-worker.yml` despliega el Worker en Cloudflare. Es **manual** (`workflow_dispatch`, entorno
`production`) a propósito: un push no debe cambiar producción sin que alguien lo decida.

El frontend tiene su propia CI (`toklean-front/.github/workflows/ci.yml`).

---

## 7. Discrepancias conocidas en la documentación

Corrige estos puntos al tocar la sección correspondiente:

- El README raíz presenta Polygon como red objetivo y describe Amoy y Sepolia como testnets; hoy la testnet activa
  con marketplace y economía desplegados es **Sepolia**. Su sección "Pendiente" menciona `RecToken`/`TokleanToken`
  y Mumbai (80001), ya obsoletos.
- `toklean-front/README.md` documenta `VITE_PUBLIC_CHAIN_ID=80002`, mientras que su `.env.example` usa `11155111`.
- Las cifras de gas del README ("~7 veces", "~1.600 por byte") son mediciones de Sepolia de este momento: vuelve a
  medirlas antes de cambiar el multiplicador.
- `backend/wrangler.toml` tiene un `database_id` de marcador de posición hasta el primer `pnpm worker:release`, que lo
  reemplaza por el id real (haz commit de ese cambio).
