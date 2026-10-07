import { z } from 'zod';
import { RateLimiter } from '../auth.ts';
import type { Deployment } from '../deployments.ts';
import type { ChainReader } from '../indexer/chain.ts';
import type { Indexer } from '../indexer/indexer.ts';
import { CATEGORIES } from '../metadata/schema.ts';
import type { ObjectStore } from '../metadata/store.ts';
import type { UriPolicy } from '../metadata/uri.ts';
import { PAYMENT_SYMBOLS } from '../types.ts';
import { toListingDto, toOrderDto, toSellerDto } from './dto.ts';
import { ApiError, corsHeaders, errorResponse, json, readBody } from './http.ts';
import { listingsQuery, ordersQuery, searchListings } from './query.ts';
import { MAX_MEDIA_BYTES, MAX_METADATA_BYTES, MEDIA_TYPES, uploadMedia, uploadMetadata, type UploadDeps } from './upload.ts';

export interface ApiDeps {
  indexer: Indexer;
  chain: ChainReader;
  store: ObjectStore;
  deployment: Deployment;
  policy: UriPolicy;
  corsOrigins: string[];
  uploadsPerHour: number;
  now?: () => number;
}

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/);

/** Handler Fetch-API (sirve en Node, Workers, Bun o Deno). */
export function createApi(deps: ApiDeps): (req: Request) => Promise<Response> {
  const now = deps.now ?? (() => Math.floor(Date.now() / 1000));
  const upload: UploadDeps = {
    indexer: deps.indexer,
    chain: deps.chain,
    store: deps.store,
    policy: deps.policy,
    perAddress: new RateLimiter(deps.uploadsPerHour),
    global: new RateLimiter(deps.uploadsPerHour * 20),
    now,
  };

  let lastForcedSync = 0;

  async function route(req: Request, url: URL): Promise<Response> {
    const { state } = deps.indexer;
    const path = url.pathname.replace(/\/+$/, '') || '/';
    const params = Object.fromEntries(url.searchParams);
    const method = req.method;
    const cache = 'public, max-age=5, stale-while-revalidate=30';

    if (method === 'GET' && path === '/health') {
      const lag = Math.max(0, deps.indexer.head - state.lastBlock);
      return json({
        ok: true,
        ready: deps.indexer.ready,
        chainId: state.chainId,
        lastBlock: state.lastBlock,
        head: deps.indexer.head,
        lagBlocks: lag,
        listings: Object.keys(state.listings).length,
        orders: Object.keys(state.orders).length,
        merchants: Object.keys(state.merchants).length,
      });
    }

    if (method === 'GET' && path === '/v1/config') {
      return json(
        {
          chainId: deps.deployment.chainId,
          contracts: {
            token: deps.deployment.ToKleanToken,
            products: deps.deployment.CircularProductNFT,
            registry: deps.deployment.ToKleanMerchantRegistry,
            catalog: deps.deployment.ToKleanCatalog,
            marketplace: deps.deployment.ToKleanMarketplace,
          },
          paymentTokens: PAYMENT_SYMBOLS,
          categories: CATEGORIES,
          uploads: { maxMediaBytes: MAX_MEDIA_BYTES, mediaTypes: MEDIA_TYPES, maxMetadataBytes: MAX_METADATA_BYTES, durable: deps.store.durable },
        },
        {},
        cache,
      );
    }

    if (method === 'GET' && path === '/v1/listings') {
      const q = listingsQuery.parse(params);
      return json(searchListings(state, q, deps.policy), {}, cache);
    }

    const listingId = /^\/v1\/listings\/(\d{1,9})$/.exec(path);
    if (method === 'GET' && listingId) {
      const l = state.listings[Number(listingId[1])];
      if (!l) throw new ApiError(404, 'not_found', 'Publicación inexistente');
      return json(toListingDto(l, state, deps.policy), {}, cache);
    }

    if (method === 'GET' && path === '/v1/merchants') {
      const status = z.enum(['approved', 'pending', 'suspended']).default('approved').parse(params.status);
      const items = Object.values(state.merchants)
        .filter((m) => m.status === status)
        .sort((a, b) => b.completedSales - a.completedSales || b.ratingAvg - a.ratingAvg)
        .map((m) => toSellerDto(m.address, m, deps.policy));
      return json({ items }, {}, cache);
    }

    const merchant = /^\/v1\/merchants\/(0x[0-9a-fA-F]{40})$/.exec(path);
    if (method === 'GET' && merchant) {
      const addr = merchant[1]!;
      const m = state.merchants[addr.toLowerCase()];
      if (!m) throw new ApiError(404, 'not_found', 'Comercio inexistente');
      const listings = Object.values(state.listings).filter((l) => l.seller.toLowerCase() === addr.toLowerCase() && l.status !== 'closed');
      return json({ ...toSellerDto(addr, m, deps.policy), description: m.profile?.description ?? null, website: m.profile?.website ?? null, since: m.since, listings: listings.length }, {}, cache);
    }

    if (method === 'GET' && path === '/v1/orders') {
      const q = ordersQuery.parse(params);
      const all = Object.values(state.orders)
        .filter((o) => (!q.buyer || o.buyer.toLowerCase() === q.buyer.toLowerCase()) && (!q.seller || o.seller.toLowerCase() === q.seller.toLowerCase()) && (!q.status || o.status === q.status))
        .sort((a, b) => b.id - a.id);
      const offset = q.cursor ? Number(q.cursor) : 0;
      const items = all.slice(offset, offset + q.limit).map((o) => toOrderDto(o, state, deps.policy));
      return json({ items, total: all.length, nextCursor: offset + q.limit < all.length ? String(offset + q.limit) : null });
    }

    const order = /^\/v1\/orders\/(\d{1,9})$/.exec(path);
    if (method === 'GET' && order) {
      const o = state.orders[Number(order[1])];
      if (!o) throw new ApiError(404, 'not_found', 'Pedido inexistente');
      return json(toOrderDto(o, state, deps.policy));
    }

    const account = /^\/v1\/accounts\/(0x[0-9a-fA-F]{40})$/.exec(path);
    if (method === 'GET' && account) {
      const addr = address.parse(account[1]) as `0x${string}`;
      const key = addr.toLowerCase();
      const claimable = await deps.chain.readClaimable(addr);
      const orders = Object.values(state.orders);
      return json({
        address: addr,
        merchant: state.merchants[key] ? toSellerDto(addr, state.merchants[key], deps.policy) : null,
        claimable: Object.fromEntries(Object.entries(claimable).map(([id, v]) => [id, v.toString()])),
        orders: { asBuyer: orders.filter((o) => o.buyer.toLowerCase() === key).length, asSeller: orders.filter((o) => o.seller.toLowerCase() === key).length },
        listings: Object.values(state.listings).filter((l) => l.seller.toLowerCase() === key).length,
      });
    }

    if (method === 'GET' && path === '/v1/stats') {
      const volume: Record<string, bigint> = {};
      let completed = 0;
      for (const o of Object.values(state.orders)) {
        if (o.status !== 'completed') continue;
        completed++;
        volume[o.paymentSymbol] = (volume[o.paymentSymbol] ?? 0n) + BigInt(o.amount);
      }
      const listings = Object.values(state.listings);
      return json(
        {
          merchants: Object.values(state.merchants).filter((m) => m.status === 'approved').length,
          listings: listings.length,
          availableListings: listings.filter((l) => l.available).length,
          cleanVerifiedListings: listings.filter((l) => l.cleanVerified).length,
          orders: Object.keys(state.orders).length,
          completedOrders: completed,
          volume: Object.fromEntries(Object.entries(volume).map(([k, v]) => [k, v.toString()])),
        },
        {},
        cache,
      );
    }

    // Refresca el índice ya mismo (la app lo llama justo después de una transacción). Frecuencia limitada.
    if (method === 'POST' && path === '/v1/sync') {
      const t = now();
      if (t - lastForcedSync < 2) return json({ ok: true, throttled: true, lastBlock: state.lastBlock });
      lastForcedSync = t;
      const r = await deps.indexer.sync();
      return json({ ok: true, throttled: false, lastBlock: r.to, head: r.head });
    }

    // ---- subidas (firmadas por la wallet) y archivos del almacenamiento local
    if (method === 'POST' && path === '/v1/media') {
      return json(await uploadMedia(upload, req, await readBody(req, MAX_MEDIA_BYTES)), { status: 201 });
    }
    if (method === 'POST' && path === '/v1/metadata') {
      return json(await uploadMetadata(upload, req, url.searchParams.get('kind'), await readBody(req, MAX_METADATA_BYTES)), { status: 201 });
    }
    const file = /^\/v1\/(media|metadata)\/([a-f0-9]{64})$/.exec(path);
    if (method === 'GET' && file) {
      const kind = file[1] as 'media' | 'metadata';
      const found = await deps.store.get(kind, file[2]!);
      if (!found) throw new ApiError(404, 'not_found', 'Archivo inexistente');
      return new Response(Buffer.from(found.bytes), {
        headers: {
          'content-type': found.contentType,
          'cache-control': 'public, max-age=31536000, immutable',
          'x-content-type-options': 'nosniff',
          'content-security-policy': "default-src 'none'; sandbox",
          'cross-origin-resource-policy': 'cross-origin',
        },
      });
    }

    throw new ApiError(404, 'not_found', 'Ruta inexistente');
  }

  return async (req) => {
    const url = new URL(req.url);
    const cors = corsHeaders(req.headers.get('origin'), deps.corsOrigins);
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });

    let res: Response;
    try {
      res = await route(req, url);
    } catch (e) {
      if (e instanceof ApiError) res = errorResponse(e);
      else if (e instanceof z.ZodError) {
        res = errorResponse(new ApiError(400, 'invalid_query', 'Parámetros inválidos', e.issues.map((i) => ({ path: i.path.join('.'), message: i.message }))));
      } else {
        console.error('[api] error inesperado', e);
        res = errorResponse(new ApiError(500, 'internal', 'Error interno'));
      }
    }
    for (const [k, v] of Object.entries(cors)) res.headers.set(k, v);
    return res;
  };
}
