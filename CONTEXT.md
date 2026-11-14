# CONTEXT.md – Traspaso completo de ToKlean (contratos + backend + infraestructura)

> **Para quién:** otra sesión de Claude (o una persona) que retoma el proyecto sin haber visto la conversación anterior.
> **Estado documentado:** 2026-11-07, `main` de `toklean-scs` en `e8e3707`, `main` de `toklean-front` en `830f428`.
> **Cómo leerlo:** `AGENTS.md` explica *cómo está construido* el sistema (arquitectura, API, variables). Este archivo
> cuenta *en qué estado está*, *por qué* se decidió cada cosa, *qué se rompió y cómo se arregló*, *qué falta* y *cómo
> operarlo*. El frontend tiene su propio `CONTEXT.md` (`toklean/toklean-front`); la infraestructura compartida vive **aquí**.
>
> **Regla de oro:** todo dato sobre la cadena o la producción se **mide**, no se supone. Varias suposiciones de este
> proyecto resultaron falsas (ver §10) y cada una costó horas.

---

## 1. Resumen ejecutivo

**ToKlean** es una plataforma Web3 de economía circular: NFT que trazan acciones ambientales (árboles, ideas de
reciclaje, lotes de material, productos fabricados con material reciclado, jornadas de limpieza), una economía con
token (TKN/REC/POR, staking, DAO, faucet de testnet) y un **marketplace sostenible** con escrow entre comercios
aprobados y compradores. Todo está desplegado en la testnet **Ethereum Sepolia (11155111)**; el sitio público es
`https://toklean.cl` (Cloudflare Pages) y el backend del marketplace es un Cloudflare Worker.

| Pieza | Estado | Nota |
| --- | --- | --- |
| Contratos de impacto (5 NFT) | Desplegados en Sepolia | Sin ningún NFT creado todavía: los contadores del sitio valen 0 |
| Economía (token, staking, DAO, faucet) | Desplegada en Sepolia | El frontend la usa de verdad |
| Marketplace (registro, catálogo, pedidos) | Desplegado en Sepolia | `listingCount` = 0 y `orderCount` = 0: nadie lo ha usado |
| Backend en Cloudflare Workers + D1 | **En producción** | Cron cada minuto, índice al día, `/v1/logs` activo |
| Frontend en Cloudflare Pages | **En producción** | Compilado con las variables correctas (verificado por API) |
| Flujo completo de marketplace con wallet real en Sepolia | **Nunca probado** | Sólo se probó contra anvil (27 comprobaciones e2e) y con subidas firmadas por API |
| Auditoría externa de contratos | No hecha | Obligatoria antes de mainnet |
| Mainnet (Polygon 137) | No existe | Sólo hay un fallback de configuración |

**Lo más urgente al retomar** (detalle en §13):
1. `PINATA_JWT` del Worker está guardado como variable **de texto plano**, no como secreto: pasarlo a *Secret*
   (si no, el siguiente `pnpm worker:release` la borra).
2. `CORS_ORIGINS` del Worker **no incluye `https://www.toklean.cl`** (el dominio `www` sí está en Pages).
3. Probar el flujo de marketplace con una wallet real en Sepolia (nadie lo ha hecho).
4. Revocar el token de Cloudflare de la sesión (expira el 2026-11-11).
5. Cambiar la rama por defecto de `esemede/toklean-scs` a `main`.

---

## 2. Repositorios, ramas y cuentas

| Repo | Contenido | Rama de producción | Notas |
| --- | --- | --- | --- |
| [`esemede/toklean-scs`](https://github.com/esemede/toklean-scs) | Contratos Solidity (Foundry) + backend TypeScript + infraestructura (Worker) | `main` | La **rama por defecto en GitHub sigue siendo `claude/upbeat-thompson-01mwke`**: cámbiala a `main` en *Settings → Branches* (administración, no se hizo desde sesión) |
| [`toklean/toklean-front`](https://github.com/ToKlean/toklean-front) | SPA React + Pages Functions | `main` (la compila Cloudflare Pages) | CI en GitHub Actions: `pnpm check` |

- **Personas:** `esemede` (autor de los PR de esta etapa, dueño del trabajo con Claude) y `esemedev` (autor del historial
  anterior del frontend, 2025). El usuario trabaja en **Windows** y programa en Python, JavaScript y cloud: prefiere
  scripts en Node (multiplataforma) antes que bash, y respuestas **en español**.
- **Rama de trabajo de las sesiones de Claude:** `claude/upbeat-thompson-01mwke` en ambos repos. Tras fusionarse un
  PR, la rama se **reinicia desde `main`** (mismo nombre) y se sigue ahí; **nunca** se apila sobre historia ya
  fusionada. `git push --force-with-lease` fue **bloqueado** por el sistema (ver §11): usa un *merge* normal en vez de
  reescribir historia.
- **No se abre PR sin que el usuario lo pida.** Una vez abierto, se vigila con `subscribe_pr_activity` y se fusiona
  sólo con orden explícita ("fusiona…"), con la CI en verde.

---

## 3. Producción (todo lo no secreto, para no tener que redescubrirlo)

### 3.1 Cloudflare

| Dato | Valor |
| --- | --- |
| Cuenta | `Esemedev@gmail.com's Account`, ID `aa2525a8aadbdfdcf033b5ecc5ca3141` (no es secreto) |
| Subdominio `workers.dev` | `esemedev` |
| Worker del backend | **`toklean-marketplace`** → `https://toklean-marketplace.esemedev.workers.dev` |
| Cron del Worker | `* * * * *` (cada minuto) |
| Base D1 | `toklean-marketplace`, id `2717d782-838e-4bfd-882e-603dbb6e18dc` (ya está en `backend/wrangler.toml`) |
| Proyecto Pages | `toklean-front`, rama de producción `main`, dominios `toklean-front.pages.dev`, `toklean.cl`, `www.toklean.cl` |
| Otros Workers de la cuenta | `acheseme-*`, `maestra-control-plane-staging`, `proyecto-san-jose`, `tenisypadelsolis-web`, `turnstile-siteverify-acheseme`: **no son de este proyecto, no tocar** |

**Bindings del Worker** (nombre → tipo; los valores no secretos están en `backend/wrangler.toml`):
`DB` (d1), `RPC_URL` (**secret_text**), `PINATA_JWT` (**plain_text: corregir**, ver §13), más ~18 variables de texto
(`CHAIN_ID`, direcciones de contratos, `CORS_ORIGINS`, límites, `LOGS_ADDRESSES`, `LOGS_START_BLOCK`…).
`KEEPER_PRIVATE_KEY` **no está definido**: el keeper está apagado (`KEEPER_AUTO_RELEASE/WITHDRAW = "false"`).

**Variables de Pages** (producción): `VITE_MARKETPLACE_API_URL=https://toklean-marketplace.esemedev.workers.dev`,
`VITE_PUBLIC_CHAIN_ID=11155111`, `VITE_REOWN_PROJECT_ID` (secret), `PINATA_JWT` (secret, usado por la Pages Function
de subida de evidencias NFT). **Vista previa:** sólo las dos primeras (sin Reown ni Pinata: la wallet y las subidas no
funcionan en previews).

**Token de API de Cloudflare de la sesión:** se inyectó como variable de entorno `CLOUDFLARE_API_TOKEN` en el entorno
de Claude Code (nunca en el chat). Permisos: *Workers Scripts: Edit*, *D1: Edit*, *Account Settings: Read*,
*Cloudflare Pages: Edit*. **Expira el 2026-11-11**; debe revocarse cuando no se use. `CLOUDFLARE_ACCOUNT_ID` no está
inyectado: pásalo en la línea de comandos.

### 3.2 Contratos en Sepolia (`deployments/11155111.json`)

| Contrato | Dirección |
| --- | --- |
| TreeNFT | `0x38253411B52cE8648e1B8E3478E0159BBa7Dc05c` |
| RecyclingIdeaNFT | `0x1749f719acf82425B14e507513157D1D161Ca1b1` |
| RecyclingBatchNFT | `0xb6A3Cf654A910337030A4D8CE143900e01B0C228` |
| CircularProductNFT | `0xb29143Dec2c9ac2Ed615ff0606255c9DaF4eC377` |
| CleanupActionNFT | `0xa7A5248CF4045F19fdBDD04013d15F9affEA4832` |
| ToKleanToken (ERC-1155) | `0xB08A41C3a475976F08F87598C5966D92A4386F9f` |
| ToKleanStaking | `0x52664e40d9b5fF74AE83264Ed5BdA40ABE67aF2E` |
| ToKleanGovernance | `0xF74BDE5bB5283Aaa195e23FF2C7B3d4150ac03b4` |
| TokenFaucet | `0x616525aa149BC542Ce52d11AB06F052485F6C350` |
| ToKleanMerchantRegistry | `0xC6c1Ad7774c8A48961Dd31517b0B8d177a15BB53` |
| ToKleanCatalog | `0x148b1B053727dEDfAa9626B197266adb420390d5` |
| ToKleanMarketplace | `0x1072732BDFC2b77bc889Bcb3FBb2B26f37BA1102` |
| Admin / deployer | `0x48332BEf71a2f41E7EAf4d1d57891828633A6360` |

Bloques de inicio: impacto `startBlock` 11841856, economía `economyStartBlock` 11857186, marketplace
`marketplaceStartBlock` 11866001.

**Configuración medida on-chain (2026-11-07):** comisión `feeBps` = 200 (2 %); `porRewardBps` = 1000 (10 % del pago
en POR al comprar un producto limpio); tesorería = admin; `shipWindow` 7 días, `confirmWindow` 14 días,
`resolutionWindow` 30 días; catálogo **no** en pausa. La cuenta admin tiene `DEFAULT_ADMIN_ROLE` y
`MERCHANT_ADMIN_ROLE` (registro) y `ARBITER_ROLE` (marketplace): **hoy una sola cuenta es admin, comité de compliance,
árbitro y tesorería** (aceptable en testnet; en mainnet deben ser multisigs distintos). El marketplace tiene
`MARKETPLACE_ROLE` en el registro (necesario para registrar ventas y valoraciones).

### 3.3 Servicios de terceros

- **RPC:** `https://ethereum-sepolia-rpc.publicnode.com` (gratuito, CORS abierto). Es el `RPC_URL` del Worker y el RPC
  de Sepolia del frontend. **Poda el historial de logs** (§10.1).
- **Pinata (IPFS):** la clave sólo tiene el permiso `pinFileToIPFS` (*Legacy endpoints → Pinning*); ambos clientes usan
  `https://api.pinata.cloud/pinning/pinFileToIPFS`. Verificado: una subida firmada por el Worker devolvió 201. Los
  archivos se leen por el gateway público `https://gateway.pinata.cloud/ipfs/`.
- **Reown (WalletConnect/AppKit):** `VITE_REOWN_PROJECT_ID`. El dominio de producción debe estar en la lista de dominios
  permitidos del proyecto Reown (no verificado).

---

## 4. Arquitectura (resumen; detalle en `AGENTS.md`)

```
ESCRITURAS (dinero, nunca pasan por el backend)
  wallet ──tx──► ToKleanMarketplace / Catalog / Registry / NFT / Staking / Governance  (Sepolia)

LECTURAS DEL MARKETPLACE
  navegador ─GET /v1/listings,orders,merchants,accounts,stats─► Worker ─lee─► D1 (índice)
                                                                  ▲
  cron cada minuto: Indexer ──eth_getLogs──► RPC; relee el estado de los contratos y guarda sólo lo que cambió

LECTURA DE EVENTOS (NFT de impacto, verificación, contadores)
  navegador ─GET /v1/logs?address=…─► Worker ─lee─► D1.logs  (el cron los guarda desde LOGS_START_BLOCK)
        + el tramo reciente posterior a lastBlock se lee directo del RPC (así un evento propio aparece al instante)

SUBIDAS
  evidencias NFT:  navegador ─firma EIP-191─► Pages Function /api/ipfs/upload ─► Pinata
  marketplace:     navegador ─firma personal_sign─► Worker /v1/media, /v1/metadata ─► Pinata ─► ipfs://CID
                   (luego la URI va a la tx de createListing / applyAsMerchant; on-chain sólo se guarda keccak256(uri))
```

Principios de diseño que **no** debes romper sin pensarlo:
- Los contratos guardan `keccak256(uri)` y **emiten** la URI completa en eventos; el texto vive off-chain (IPFS).
- El índice **relee el estado de los contratos**; los eventos sólo marcan *qué cambió* (autocorrectivo ante reorgs).
- El backend **nunca** mueve dinero: sólo el keeper opcional ejecuta `releaseAfterTimeout` y `withdraw`, que son
  permissionless y mandan los fondos a su dueño.

---

## 5. Contratos (detalle operativo)

### 5.1 Marketplace

**Pedido (`OrderStatus`):** `Paid → Shipped → Completed`, con salidas `Refunded`, `Disputed → Resolved`.

| Función | Quién | Qué hace |
| --- | --- | --- |
| `buy(listingId, qty, maxUnitPrice)` | comprador | Paga a escrow; `maxUnitPrice` protege contra front-running (revierte si el precio sube) |
| `markShipped(orderId, trackingURI)` | vendedor | Pasa a `Shipped` |
| `confirmReceived(orderId)` | comprador | Libera al vendedor (menos comisión) y emite POR si el producto es limpio |
| `releaseAfterTimeout(orderId)` | **cualquiera** | Libera si venció `confirmWindow` (14 d) tras el envío |
| `refundUnshipped(orderId)` | comprador | Reembolso si el vendedor no envió dentro de `shipWindow` (7 d) |
| `refundBySeller(orderId)` | vendedor | Reembolso voluntario |
| `openDispute(orderId, reasonURI)` | comprador/vendedor | Pasa a `Disputed` |
| `resolveDispute(orderId, buyerBps, nftToBuyer, rulingURI)` | árbitro (`ARBITER_ROLE`) | Reparte el pago entre comprador y vendedor (`buyerBps` sobre 10.000), decide a quién va el NFT del producto y emite la URI del fallo |
| `claimDisputeTimeout(orderId)` | comprador | Si nadie resuelve en `resolutionWindow` (30 d), recupera todo |
| `rate(orderId, score)` | comprador | Valoración 1-5 de una compra real; alimenta la reputación del comercio |
| `withdraw(account, id)` | **cualquiera** | Empuja a `account` su saldo acreditado (pagos *pull*); los fondos siempre van al dueño |
| `setRates / setTreasury / setWindows` | `PARAMETERS_ROLE` | Tope `MAX_FEE_BPS` 10 %, `MAX_POR_BPS` 50 % |

**Catálogo:** `createListing(kind, paymentId, price (uint128), stock, metadataURI, hasProduct, productTokenId)` (kind =
Producto/Servicio; `paymentId` = TKN id 1 o REC id 2), `setListingPaused`, `closeListing`, `finish` (sólo el marketplace),
`setAcceptedPayment`, `pause/unpause` (PAUSER_ROLE). Un producto vinculado debe ser un `CircularProductNFT`
**certificado**: queda en custodia del catálogo y viaja al comprador al cerrarse la venta; si la certificación se
revoca, la publicación deja de estar disponible.

**Registro de comercios:** `applyAsMerchant(profileURI)` → `Pending`; el comité (`MERCHANT_ADMIN_ROLE`) hace
`reviewMerchant(addr, approved)`; `setSuspended`. Estados: None, Pending, Approved, Rejected, Suspended. Sólo un
comercio **Approved** puede publicar. Un rechazado puede volver a postular.

**Garantías (con tests de invariantes):** ninguna cuenta que rechace tokens bloquea un pedido; una venta nunca queda
atascada por un fallo al emitir POR; la pausa no bloquea liberar/reembolsar/disputar/retirar; el marketplace siempre
tiene exactamente lo que debe a pedidos abiertos y saldos acreditados.

### 5.2 Restricción dura: tamaño y gas en Sepolia

En Sepolia cada byte de código cuesta ~**1.600 de gas** y el tope por transacción es **16,7 M** (EIP-7825). Un contrato
debe pesar **< ~10 KB** (`test_DeployedSizeFitsTheGasBudget` lo vigila) y los despliegues usan un multiplicador de gas
(`--gas-estimate-multiplier`: 800 economía, **710** marketplace, porque 800 excede el tope). **Por eso el marketplace son
3 contratos** (registro, catálogo, pedidos). Consecuencia: `RecyclingBatchNFT` (~18 KB) ya **no se podría volver a
desplegar** en Sepolia. **Los contratos desplegados son inmutables: no se editan sin pedirlo expresamente.**

### 5.3 Economía y NFT de impacto
Ver `AGENTS.md` §2.1 y §2.2. Roles de los NFT: `VERIFIER_ROLE`, `COLLECTOR_ROLE`, `COLLECTION_CENTER_ROLE`,
`RECYCLER_ROLE`, `MANUFACTURER_ROLE`, `HAZARDOUS_HANDLER_ROLE`, `CONSUMER_ROLE` (sólo `CircularProductNFT`),
`ORGANIZER_ROLE`. Gobernanza: voto = TKN en stake un segundo antes de crear la propuesta; sin delegación; las
propuestas de centros y fondos requieren aprobación de compliance.

### 5.4 Tests y herramientas
- `forge test` (182 pruebas según la sesión anterior: unitarias, fuzz de 512 corridas e invariantes). La CI las corre en
  cada push/PR (`test` en `.github/workflows/test.yml`, verde en el último PR). **Foundry no está instalado** en el
  contenedor de Claude Code: para correrlo hay que instalarlo (`foundryup`) o confiar en la CI.
- Scripts: `script/Deploy.s.sol`, `DeployEconomy.s.sol`, `DeployMarketplace.s.sol`, `SeedDemo.s.sol`,
  `SetupTestnet.s.sol`, `export-abis.mjs` (`make abis` → `../toklean-front/src/abi/impact`).
- `Makefile`: `deploy-*-local|sepolia`, `abis`, `anvil`, `test`, `fmt`.

---

## 6. Backend (`backend/`)

### 6.1 Cómo funciona por dentro
- **`Indexer`** (`src/indexer/indexer.ts`): por tramos de 2.000 bloques con `CONFIRMATIONS` (2); en cada tramo aplica los
  eventos (`MerchantApplied/Reviewed/Suspended`, `SaleRecorded`, `Rated` del registro; `ListingCreated/Updated/
  StatusChanged` del catálogo; `OrderCreated/Shipped/Completed/Refunded`, `DisputeOpened/Resolved`, `Rated`,
  `Withdrawn` del marketplace) y **relee el estado de los contratos** para las entidades afectadas. Guarda el snapshot
  tras cada tramo. `ready` = alcanzó la cabeza (por instancia del Worker, ver §13).
- **Metadata** (`src/metadata/`): descarga `ipfs://` o hosts permitidos sin seguir redirects (`redirect: 'manual'`),
  con tope de tamaño/tiempo, y **sólo la acepta si `keccak256(uri)` coincide con el hash on-chain** y valida con zod
  (`toklean.listing/1`: nombre ≤120, descripción ≤2000, hasta 6 imágenes, categoría de una lista fija, etiquetas,
  condición, sostenibilidad y envío; `toklean.merchant/1`: nombre, descripción, país ISO-2, logo, web https, contacto).
  Reintenta con backoff (`metadataAttempts`, `metadataRetryAt`).
- **Subidas firmadas** (`src/auth.ts`, `src/api/upload.ts`): `Authorization: ToKlean <dirección>.<timestamp>.<firma>`;
  la firma cubre `kind` + `sha256(cuerpo)` + `timestamp` y vale ±5 min. Publicar una **publicación** exige ser comercio
  aprobado; el perfil de comercio lo puede subir cualquiera (va antes de `applyAsMerchant`). Límites: imagen
  PNG/JPEG/WebP ≤ 2 MB validada por contenido (SVG rechazado), metadata ≤ 32 KB, `UPLOADS_PER_HOUR` = 60 **por
  instancia** (no global en Workers).
- **Keeper** (`src/keeper.ts`): opcional y apagado. Usa el timestamp del **último bloque** (no el reloj del servidor).
  Libera pedidos enviados cuya ventana venció y empuja saldos; `maxActions` 5 por corrida.
- **Índice de logs** (`src/logs/`, `worker/d1-log-store.ts`): ver §4 y `AGENTS.md` §5.2.

### 6.2 Cloudflare Workers
- `worker/index.ts`: `fetch` (API con caché de 15 s por instancia) y `scheduled`. El cron corre **dos trabajos
  aislados** (marketplace y logs); si uno falla el otro sigue y el error se relanza al final.
- **D1** (`worker/migrations/`): `0001_init.sql` (`meta`, `merchants`, `listings`, `orders`: `key` + `json`),
  `0002_logs.sql` (`logs`: `(block, idx)` único, índice por dirección). Escritura diferencial en lotes de 50.
- **Límites del plan gratuito** que condicionan el diseño: pocas subrequests y CPU por invocación (`MAX_CHUNKS_PER_RUN`
  5, `MAX_ENRICH_PER_RUN` 20), sin disco (todo archivo va a Pinata), `viem` con `http({ batch: true })`.
- **Trampas de Workers ya encontradas:** `fetch` no se puede llamar como método de clase (`Illegal invocation`: guardar la
  función en una variable); `redirect: 'error'` no existe (se usa `'manual'`); no hay `node:crypto` (hash con
  `@noble/hashes`).

### 6.3 Despliegue
- **Un comando:** `pnpm worker:release` (`scripts/deploy-worker.ts` + `deploy-lib.ts`). Idempotente: crea la base D1 si
  falta (y escribe su id en `wrangler.toml`), aplica migraciones, despliega, comprueba `/health` y `/v1/config`.
  Banderas: `--dry-run` (compila sin tocar Cloudflare), `--keep-secrets` (no sube secretos). Los secretos se leen de
  **variables de entorno** (`RPC_URL` obligatoria salvo `--keep-secrets`, `PINATA_JWT`, `KEEPER_PRIVATE_KEY`), nunca de
  argumentos. Credenciales: `wrangler login` o `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`.
- **Workflow manual** `.github/workflows/deploy-worker.yml` (entorno `production`, `workflow_dispatch`): mismo comando
  con secretos del repo. **Nunca se ha ejecutado**; se desplegó siempre con el comando local.
- **Ojo:** `wrangler deploy` **reemplaza las variables de texto del Worker por las de `wrangler.toml`** (los secretos se
  conservan). Por eso todo lo sensible debe ser *Secret*.

### 6.4 Pruebas
`pnpm check` (tipos para Node y Workers + **111 pruebas** vitest) y `pnpm test:e2e` (anvil + scripts de Foundry +
backend real; necesita Foundry). Hay una prueba de punta a punta **local** del Worker con `pnpm worker:local`
(`scripts/worker-local.sh`: anvil + contratos + Pinata simulado + `wrangler dev` en :8787, CORS para `localhost:4174`).

---

## 7. Historia (para entender por qué las cosas son como son)

| Fecha | Hito |
| --- | --- |
| 2026-09-27 | Primer commit: contratos NFT de impacto (`cd43275`); herramientas de testnet |
| 2026-10-03/04 | Soporte de despliegue en Sepolia; NFT de impacto desplegados |
| 2026-10-06 | Economía ERC-1155 (token, staking, DAO, faucet) desplegada; se documenta el gas real de Sepolia; `SeedDemo` |
| 2026-10-07 | **Marketplace**: 3 contratos + backend + despliegue Sepolia (`ffc19c9`); cola de revisión de comercios |
| 2026-10-08 | Backend portado a **Cloudflare Workers + D1** (`d3cad9f`); registros de despliegue subidos |
| 2026-10-17 | `AGENTS.md` en ambos repos |
| 2026-10-22 | Script de despliegue de un comando (`1b86842`) |
| 2026-11-01 | Frontend **comprimido** a las funciones reales (7 páginas informativas retiradas) y lema sin juego |
| 2026-11-03 | Worker **desplegado por primera vez**; D1 creada; incidente del RPC podado (§10.1) |
| 2026-11-04/05 | `main` creada en `toklean-scs` (en `7772a99`); PR #1 fusionado |
| 2026-11-05/06 | Índice de logs en D1 + `GET /v1/logs`; PR #2 (backend) y #21 (frontend) fusionados; limpieza con los principios de Karpathy |
| 2026-11-07 | Verificada la subida a Pinata por el Worker; descubierto `PINATA_JWT` como texto plano |

PR del frontend: #16 (migración a Cloudflare Pages, 2026-09-20), #17 (NFT de impacto + IPFS), #18 (rediseño, economía,
marketplace), #19, #20 (sitio comprimido), #21 (logs desde el backend). PR de `toklean-scs`: #1, #2.

---

## 8. Decisiones de diseño y su porqué

1. **Tres contratos para el marketplace y URIs sólo en eventos** → tope de gas/tamaño de Sepolia (§5.2).
2. **Pagos *pull* + escrow** → ninguna cuenta hostil puede bloquear un pedido; `withdraw`/`releaseAfterTimeout` son
   permissionless para que un keeper (o cualquiera) los ejecute sin riesgo.
3. **Backend = índice, no autoridad** → el estado se relee de la cadena; si el índice se corrompe, se reconstruye.
4. **Cloudflare Workers + D1 + Pinata** → plan gratuito, sin servidores; el mismo núcleo corre en Node/Docker para
   desarrollo y pruebas. La versión Node/Docker (`src/server.ts`, `Dockerfile`, `FileStore`) sólo se usa en local y e2e.
5. **Índice de logs propio** → los RPC públicos gratuitos podan el historial (§10.1); el navegador no puede leer
   historial de eventos de forma fiable. Sólo se indexan los 5 NFT de impacto (los únicos cuyos logs lee el frontend).
6. **`LOGS_START_BLOCK` = compromiso de datos**: antes de ese bloque no hay eventos de interés (se comprobó). Adelantarlo
   sin repetir la comprobación descarta datos en silencio.
7. **Subidas firmadas sin cuentas ni sesiones** → la wallet firma cada subida; cuota por cuenta.
8. **Sitio comprimido** → se retiraron páginas que anunciaban funciones inexistentes (un juego "Recycling War", IoT con
   oráculo, testimonios). La portada describe sólo lo que existe.
9. **Scripts en Node, no bash** → el usuario trabaja en Windows.
10. **Merge en vez de rebase/force-push** → el entorno bloquea reescrituras de historia.

---

## 9. Entorno de Claude Code web (lo que sorprende)

- **Contenedor efímero:** se reconstruye entre sesiones. Los clones son *shallow*; `toklean-scs` puede aparecer **vacío**
  (sin commits): `git fetch --depth=N origin <rama>` y `git checkout -B <rama> FETCH_HEAD`. Tras clonar con
  `add_repo`, hay que llamar a `register_repo_root`. Para empujar desde un clon poco profundo: antes
  `git fetch origin main`.
- **GitHub:** no hay `gh`. Se usan las herramientas MCP `mcp__github__*` (crear/leer/fusionar PR, ver checks con
  `pull_request_read` método `get_check_runs`) y `subscribe_pr_activity` (los eventos llegan como notificaciones; se
  leen con `ReadNotifications`). Toda publicación en GitHub termina con el pie `_Generated by [Claude Code](…)_`.
- **Red (lista de permitidos):** alcanzables `api.cloudflare.com`, `*.workers.dev`, `ethereum-sepolia-rpc.publicnode.com`
  y registros de paquetes; **bloqueados** `*.pages.dev`, `toklean.cl`, `api.pinata.cloud` y los demás RPC. No se puede
  abrir el sitio publicado desde la sesión; se verifica por la API de Cloudflare (`/pages/projects/toklean-front/
  deployments`) y por el Worker. Para cambiar la red, el usuario edita el entorno (menú de la barra de título).
- **Clasificador de seguridad** (bloqueó, y **no se debe rodear**): `git push` a `main` creando ramas por primera vez,
  `push --force-with-lease`, despliegues a producción sin orden explícita del usuario, y `npx` descargando paquetes
  (p. ej. `knip`). Con orden explícita ("sí, despliega") el despliegue sí se permitió.
- **Otras limitaciones:** `sleep` en primer plano está bloqueado (usar tareas en segundo plano con bucle y
  `run_in_background`, o suscribirse a eventos); **no lances dos comandos `Bash` en paralelo con `cd`**: comparten el
  directorio de trabajo y el segundo puede ejecutarse en el repo equivocado (pasó); `pkill -f` puede matar la propia
  shell (usa patrones con corchetes, `[w]rangler`, o mata por PID); `node` con *type stripping* **no** ejecuta los `.ts`
  del backend (usa `tsx`); `pnpm install` falla en la descarga del binario de Cypress (usa `CYPRESS_INSTALL_BINARY=0`).
- **Secretos:** nunca se pegan en el chat. Se inyectan como variables de entorno del entorno de Claude Code y sólo
  están disponibles en sesiones que arrancan después (aunque el token apareció en la sesión en curso en una ocasión).
- **Skills:** el skill `karpathy-guidelines` no estaba cargado en la sesión (sólo los de la cuenta). Sus 4 principios
  están transcritos en `AGENTS.md`.

---

## 10. Incidentes y lecciones

### 10.1 RPC público con historial podado (el más importante)
- **Síntoma:** el Worker no avanzaba (`head: 0`, `ready: false`) y la portada mostraba *"No pudimos leer la blockchain
  ahora"*. Error: `RpcRequestError … pruned history unavailable` (código **4444**) en `eth_getLogs`.
- **Causa (medida contra `publicnode`):** el servicio reparte las peticiones entre servidores; la mayoría conserva sólo
  ~10.000 bloques (~1,5 días). Rangos que **terminan en el último bloque: 40/40 correctos**; rangos que empiezan unos
  miles de bloques atrás: ~**75 % fallan**; el mismo rango reintentado acaba funcionando (cae en un servidor completo).
- **Primera solución errónea:** un "piso de escaneo" en el frontend. Caducaba en un día; se retiró.
- **Solución real:** el Worker (que siempre lee bloques recientes) guarda los logs en D1 (`/v1/logs`); el frontend los
  usa y sólo lee del RPC el tramo reciente. Para el índice del marketplace se fijó a mano el cursor en D1
  (`UPDATE meta SET value = json_set(value,'$.lastBlock',N) WHERE key='state'`) tras **comprobar con reintentos** que no
  había eventos de comercios/publicaciones/pedidos.
- **Lección:** para historial de logs usa un **RPC con historial** (Alchemy/Infura) o un índice propio. Nunca asumas que
  un RPC público gratuito conserva datos antiguos.

### 10.2 `PINATA_JWT` agregado como texto plano
Al añadirlo desde el panel quedó `plain_text`: legible por cualquiera con acceso y borrado por el próximo
`wrangler deploy`. Detectado listando los *bindings* por API (sólo nombre y tipo, sin leer el valor). **Pendiente de corregir.**

### 10.3 Otros
- *"El servicio del catálogo no está configurado"*: faltaba `VITE_MARKETPLACE_API_URL` en el build de Pages (Vite lee las
  `VITE_*` **al compilar**; cambiarlas exige redeploy).
- Al aplicar `PATCH` a las variables de Pages se probó **antes en Vista previa (vacía)** que el API **fusiona** y no
  reemplaza: un reemplazo habría borrado los secretos de producción sin posibilidad de reponerlos.
- `getOrders` exige `buyer` o `seller`; `/v1/sync` no se limita por tiempo (la app lo llama tras cada tx).
- El keeper usaba el reloj del servidor; ahora usa el timestamp del último bloque.
- Se borraron por error 3 tests al editar `api.test.ts`: se restauraron desde git. **Revisa siempre el diff antes de
  commitear.**

---

## 11. Cómo retomar (runbooks)

### 11.1 Primeros 10 minutos
```bash
# contratos + backend
cd toklean-scs && git submodule update --init --recursive      # lib/: forge-std y openzeppelin
cd backend && pnpm install --frozen-lockfile && pnpm check       # 111 pruebas + tipos (Node y Workers)
# frontend
cd ../../toklean-front && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm check   # 393 pruebas + build
```

### 11.2 Verificar producción (sin navegador)
```bash
U=https://toklean-marketplace.esemedev.workers.dev
curl -s $U/health                 # lastBlock cerca de la cabeza (ready/head pueden salir false/0: ver §13)
curl -s $U/v1/config              # red, contratos, uploads.durable debe ser true
curl -s "$U/v1/logs?limit=5"      # fromBlock 12074051, lastBlock reciente, addresses = 5
curl -s -H "Origin: https://toklean.cl" -i $U/v1/logs?limit=1 | grep -i access-control   # CORS
# despliegue de Pages por API (requiere CLOUDFLARE_API_TOKEN):
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/aa2525a8aadbdfdcf033b5ecc5ca3141/pages/projects/toklean-front/deployments?env=production&per_page=1"
```

### 11.3 Desplegar el Worker
```bash
cd toklean-scs/backend
CLOUDFLARE_ACCOUNT_ID=aa2525a8aadbdfdcf033b5ecc5ca3141 RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
  pnpm worker:release                      # primera vez o para cambiar RPC_URL
CLOUDFLARE_ACCOUNT_ID=aa2525a8aadbdfdcf033b5ecc5ca3141 pnpm worker:release --keep-secrets   # redespliegue normal
```
Requiere `CLOUDFLARE_API_TOKEN` (o `wrangler login`). **Pide permiso explícito al usuario antes de desplegar a producción.**

### 11.4 Probar el marketplace a mano en `toklean.cl` (con wallet en Sepolia)
1. `/faucet` → reclamar TKN. 2. `/marketplace/sell` → postular como comercio (firma + tx; sube el perfil a Pinata por el
Worker). 3. Con la wallet admin (`0x4833…6360`), aprobar el comercio en la cola de revisión. 4. Publicar un producto con
foto (`/v1/media`). 5. Comprar con otra cuenta y recorrer pedidos (enviar, confirmar, valorar, retirar).
**Nadie lo ha hecho todavía en Sepolia.**

### 11.5 Cambios habituales
- **Cambió un contrato (ABI):** `make abis` (copia a `../toklean-front/src/abi/impact`) y `pnpm abis` en `backend/`
  (regenera `src/generated/abis.ts`; la CI falla si no coincide).
- **Se redesplegaron contratos:** copiar `deployments/<chainId>.json` a `toklean-front/src/config/deployments/`; actualizar en
  `backend/wrangler.toml` las direcciones, `MARKETPLACE_START_BLOCK`, `LOGS_ADDRESSES` y un `LOGS_START_BLOCK` **nuevo**
  (verificado); aplicar `pnpm worker:release`; reiniciar el cursor del índice si cambia el marketplace.
- **Adelantar `LOGS_START_BLOCK` o reindexar:** repetir la comprobación (`AGENTS.md` §5.2) o usar un RPC con historial.
- **Cambiar el RPC del Worker:** `RPC_URL=… pnpm worker:release` (sube el secreto).

---

## 12. Convenciones

- **Idioma:** documentación, comentarios y mensajes de dominio en **español**; UI bilingüe es/en.
- **Commits:** mensaje en inglés, imperativo, cuerpo explicando el porqué, y al final `Claude-Session: <url>`. **No**
  incluir identificadores de modelo en commits, PR ni código. Commits convencionales en el frontend (`feat:`, `fix:`).
- **PR:** descripción en español con *Resumen, Pruebas, A tener en cuenta*, pie `_Generated by [Claude Code](…)_`.
- **Principios de trabajo** (`AGENTS.md`, de karpathy-guidelines): pensar antes de codificar, simplicidad primero, cambios
  quirúrgicos, metas verificables. En la práctica: sin configuración especulativa, y cada línea del diff debe trazar al pedido.
- **Antes de afirmar algo sobre la cadena o la producción, mídelo.** Si no pudiste verificarlo, dilo.

---

## 13. Pendientes (priorizados)

**Bloqueantes / riesgo real**
1. `PINATA_JWT` del Worker → pasar a *Secret* (§10.2). Sin esto, el próximo `pnpm worker:release` rompe las subidas.
2. Añadir `https://www.toklean.cl` (y decidir qué hacer con los previews `*.pages.dev`) a `CORS_ORIGINS` en
   `backend/wrangler.toml` y redesplegar; hoy sólo están `https://toklean.cl` y `https://toklean-front.pages.dev`.
3. Probar el flujo completo del marketplace con wallet real en Sepolia (§11.4).
4. Revocar el token de Cloudflare (expira 2026-11-11). Cambiar la rama por defecto de `toklean-scs` a `main`.

**Producto**
5. Árbitro, comité de compliance y tesorería son **la misma cuenta**: separarlos en multisigs (Safe) antes de mainnet.
6. Auditoría externa de los contratos.
7. Encender el keeper (`KEEPER_PRIVATE_KEY` dedicada + `KEEPER_AUTO_RELEASE/WITHDRAW=true`) si se quiere liberar pedidos
   vencidos automáticamente.
8. `whitepaper` (`/whitepaper`) conserva un texto que habla de un juego ("Recycling War") y un oráculo que no existen:
   decidir qué es visión y qué es realidad.
9. Los factores de CO₂ de reciclaje son aproximados y requieren revisión técnica/DAO.
10. El poder de voto es sólo TKN en stake (sin delegación): decisión de diseño documentada.

**Técnica**
11. `/health`: `ready` y `head` son por instancia del Worker (a menudo `false`/`0` aunque el índice esté al día); para
    monitoreo, fiarse de `lastBlock`. Mejora posible: persistir la cabeza en D1.
12. `GET /v1/logs` no pagina (máx. 5.000 por consulta y marca `truncated`; el frontend vuelve a escanear la cadena si
    recibe `truncated`). Habrá que paginar si hay mucha actividad.
13. El límite de subidas por hora es por instancia, no global; agregar una regla de *Rate limiting* de Cloudflare sobre
    `/api/ipfs/*` y el Worker.
14. Código muerto pendiente de decidir (no se borró por el principio de cambios quirúrgicos): en el frontend `blend`
    (`lib/color.ts`), `TREE_STEPS` (`services/verification.ts`), `ProposalStateKey`, `BadgeTone`; claves de idioma
    probablemente huérfanas (`dashboard.stake/governance/whitepaperBtn/stakeBtn`, `por.*`, `iot.*`: verificar antes de borrar).
15. 2 avisos de `pnpm audit` sin arreglo seguro (frontend).
16. El README raíz de `toklean-scs` está desactualizado (presenta Polygon/Amoy como red principal; "Pendiente" menciona
    `RecToken`/Mumbai). `AGENTS.md` y este archivo son la referencia vigente.

---

## 14. Supuestos y cosas **no** verificadas

- Que el flujo completo del marketplace funcione con una wallet real en Sepolia (sólo hay e2e contra anvil).
- Que `toklean.cl` ya muestre la portada sin el aviso de blockchain: se verificó el despliegue y las variables por API
  y el Worker responde, pero **la sesión no puede abrir el sitio** (red bloqueada). Confirmar abriéndolo.
- Que el RPC por defecto de viem para Sepolia (`11155111.rpc.thirdweb.com`) falle: no se pudo medir; por eso el frontend
  usa `publicnode` (medido).
- Que el dominio de producción esté en la lista de dominios permitidos de Reown.
- Que `wrangler deploy` borre variables de texto no declaradas en `wrangler.toml`: es el comportamiento documentado de
  wrangler, **no** se comprobó en esta cuenta.
- Las cifras de gas (1.600 por byte, ~7 veces lo simulado) son mediciones de Sepolia de octubre de 2026: vuelve a medirlas.

---

## 15. Glosario

- **TKN** (id 1 del ERC-1155): token de utilidad y gobernanza, con tope. **REC** (id 2): recompensa quemable, sin tope.
  **POR** (id 3): *Prueba de Reciclaje*, que recibe quien compra un producto limpio.
- **Producto limpio:** `CircularProductNFT` certificado (criterios on-chain de contenido reciclado, energía renovable y
  CO₂e por kg, más firma de un auditor).
- **Comité de compliance:** cuenta(s) con `MERCHANT_ADMIN_ROLE` que aprueban comercios (y propuestas de centros/fondos).
- **Keeper:** proceso opcional que ejecuta acciones permissionless (liberar, retirar) por cuenta de otros.
- **Pulling vs pushing:** *pull payments* = el beneficiario (o cualquiera, en su nombre) retira; el contrato no empuja fondos.
- **RAEE / REP:** residuos de aparatos eléctricos y electrónicos / Responsabilidad Extendida del Productor (Ley 20.920, Chile).
