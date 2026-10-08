# ToKlean Marketplace – backend

Indexador, API de catálogo y servicio de metadata del marketplace. Vive en `toklean-scs` junto a los contratos
(`src/marketplace/`) porque comparte con ellos ABIs, despliegues y reglas; el frontend sólo consume la API y los
contratos.

## Por qué existe

Los contratos están bajo ~10 KB cada uno (en Sepolia hoy se pagan ~1.600 de gas por byte de código y el tope por
transacción es 16,7 M), así que **no guardan textos ni listas paginadas**: guardan `keccak256(uri)` y emiten la URI
completa en eventos. El backend:

1. **Indexa** los eventos de `ToKleanMerchantRegistry`, `ToKleanCatalog` y `ToKleanMarketplace`. Los eventos sólo
   marcan *qué cambió*; el estado se **relee de los contratos** (autocorrectivo ante reorgs y eventos perdidos).
2. **Verifica la metadata**: sólo acepta la URI cuyo `keccak256` coincide con el hash on-chain, la descarga con
   política de hosts (ipfs, este backend y `ALLOWED_HOSTS`; sin redirects, con tope de tamaño y tiempo) y la valida
   contra un esquema estricto (`toklean.listing/1`, `toklean.merchant/1`).
3. **Sirve** catálogo con búsqueda, filtros, facetas y paginación, pedidos, comercios, estadísticas y saldos.
4. **Recibe subidas firmadas** (imágenes y JSON) y las fija en IPFS (Pinata) o, en desarrollo, en disco.
5. **Keeper opcional**: libera pedidos cuyo plazo de confirmación venció y empuja a cada cuenta lo que tiene
   acreditado (`withdraw` lo puede ejecutar cualquiera y los fondos siempre van a su dueño).

## Arranque

```bash
cd backend
pnpm install
cp .env.example .env     # RPC_URL, CHAIN_ID, DEPLOYMENTS_FILE...
pnpm start               # http://localhost:8787
pnpm check               # tipos + 80 tests unitarios
pnpm test:e2e            # anvil + forge scripts + backend real (necesita Foundry)
```

Demo local completa (anvil):

```bash
anvil &
make deploy-local deploy-economy-local deploy-marketplace-local
forge script script/SeedDemo.s.sol --rpc-url local --broadcast     # NFTs de impacto de ejemplo
cd backend && RPC_URL=http://127.0.0.1:8545 CHAIN_ID=31337 DEPLOYMENTS_FILE=../deployments/31337.json pnpm start &
pnpm seed:local          # comercios, publicaciones y pedidos en todos los estados, por el flujo real
```

Los ABIs (`src/generated/abis.ts`) salen de `forge build` con `pnpm abis`.

## API

| Ruta | Descripción |
| --- | --- |
| `GET /health` | `ready`, bloque indexado, altura de la cadena y retraso |
| `GET /v1/config` | red, direcciones, medios de pago, categorías y límites de subida |
| `GET /v1/listings` | `q`, `category`, `kind`, `payment`, `seller`, `clean`, `available`, `minPrice`, `maxPrice` (en unidades del token), `sort` (`new`, `priceAsc`, `priceDesc`, `rating`), `limit`, `cursor`. Devuelve `items`, `total`, `nextCursor` y `facets` |
| `GET /v1/listings/:id` | una publicación (cualquier estado) |
| `GET /v1/merchants?status=approved\|pending\|suspended`, `/v1/merchants/:address` | comercios por estado (cola de compliance) / ficha |
| `POST /v1/sync` | refresca el índice ya mismo (máx. una vez cada 2 s); la app lo llama tras cada transacción |
| `GET /v1/orders?buyer=\|seller=&status=` | pedidos con resumen de la publicación |
| `GET /v1/accounts/:address` | comercio, pedidos y **saldos retirables leídos de la cadena** |
| `GET /v1/stats` | comercios, publicaciones, pedidos y volumen por token |
| `POST /v1/media` | imagen PNG/JPEG/WebP ≤ 2 MB (el tipo se valida por contenido; SVG se rechaza) |
| `POST /v1/metadata?kind=listing\|merchant` | valida el esquema y devuelve `{ uri, uriHash }` para `createListing` / `applyAsMerchant` |

Los montos viajan como strings en wei. Los errores son `{ "error": { "code", "message", "details" } }`.

### Subidas firmadas

Sin cuentas ni sesiones: la wallet firma (`personal_sign`) cada subida.

```
Authorization: ToKlean <dirección>.<timestamp>.<firma>
mensaje = "ToKlean marketplace upload\nkind: <media|metadata>\nsha256: <hex del cuerpo>\ntimestamp: <unix>"
```

La firma vale ±5 minutos, está atada al contenido exacto, hay cuota por cuenta y global, y publicar una
**publicación** exige ser comercio aprobado (el perfil del comercio puede subirlo cualquiera, porque va *antes* de
`applyAsMerchant`).

## Despliegue en Cloudflare Workers (plan gratuito)

Es la forma recomendada: un Worker (API + cron cada minuto), una base D1 para el índice y Pinata para los archivos.
Todo cabe en el plan gratuito con holgura (el script pesa ~290 KB comprimido, límite 3 MB).

```bash
cd backend
pnpm install
npx wrangler login
npx wrangler d1 create toklean-marketplace        # copia el database_id a wrangler.toml
npx wrangler d1 migrations apply toklean-marketplace --remote
npx wrangler secret put RPC_URL                   # p. ej. https://ethereum-sepolia-rpc.publicnode.com (o Alchemy)
npx wrangler secret put PINATA_JWT                # subidas a IPFS
# opcional, keeper: npx wrangler secret put KEEPER_PRIVATE_KEY  (y KEEPER_AUTO_RELEASE/WITHDRAW=true en wrangler.toml)
npx wrangler deploy                               # URL: https://toklean-marketplace.<cuenta>.workers.dev
```

Luego en Cloudflare Pages del frontend define `VITE_MARKETPLACE_API_URL` con esa URL y vuelve a desplegar.
Los contratos, la red y el dominio del frontend (`CORS_ORIGINS`) están en `wrangler.toml`.

Desarrollo local sin cuentas (anvil + contratos + Pinata simulado + `wrangler dev`):

```bash
pnpm worker:local      # levanta todo y siembra datos de demostración (ver scripts/worker-local.sh)
```

### Cómo funciona en Workers

- **Índice en D1:** una fila por comercio, publicación y pedido. Cada sincronización escribe sólo las filas que cambiaron.
- **Cron cada minuto:** indexa hasta `MAX_CHUNKS_PER_RUN` bloques, descarga la metadata pendiente (`MAX_ENRICH_PER_RUN`) y, si hay keeper, ejecuta hasta 5 acciones.
  Un índice atrasado se pone al día en las siguientes ejecuciones.
- **Peticiones:** la API lee el índice de D1 con una caché de 15 s por instancia. `POST /v1/sync` indexa en el momento (la app lo llama tras cada transacción).
- **Límites conocidos:** el límite de subidas por hora se aplica por instancia, no global. Las subidas van a IPFS (Pinata): en Workers no hay disco.
- **Plazos:** el keeper mide los plazos con el reloj de la cadena (timestamp del último bloque), no con el del servidor.

### Alternativas

El mismo núcleo corre en Node (`src/server.ts`, `pnpm start`) y en Docker (`Dockerfile`, contexto: raíz de `toklean-scs`),
por ejemplo en Render o Fly.io. Node guarda el índice y los archivos en disco (`DATA_DIR`).

