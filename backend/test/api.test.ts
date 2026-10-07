import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { parseEther, keccak256, toBytes } from 'viem';
import { createApi } from '../src/api/router.ts';
import { authHeader, uploadMessage } from '../src/auth.ts';
import type { Deployment } from '../src/deployments.ts';
import { Indexer } from '../src/indexer/indexer.ts';
import { MemorySnapshotStore } from '../src/indexer/snapshot.ts';
import { canonicalize, sha256Hex } from '../src/metadata/schema.ts';
import { FileStore } from '../src/metadata/store.ts';
import { emptyState, type ListingRecord, type MerchantRecord, type OrderRecord } from '../src/types.ts';
import { BUYER, CID, FakeChain, listingMeta, merchantProfile, merchantRaw, POLICY, SELLER, SELLER2 } from './helpers.ts';

const NOW = 1_800_000_000;
const ADDR = (n: number) => `0x${n.toString(16).padStart(40, '0')}` as const;
const DEPLOYMENT: Deployment = {
  chainId: 31337,
  ToKleanToken: ADDR(1),
  CircularProductNFT: ADDR(2),
  ToKleanMerchantRegistry: ADDR(3),
  ToKleanCatalog: ADDR(4),
  ToKleanMarketplace: ADDR(5),
  marketplaceStartBlock: 1,
};

const merchant = (address: `0x${string}`, over: Partial<MerchantRecord> = {}): MerchantRecord => ({
  address,
  status: 'approved',
  completedSales: 0,
  ratingCount: 0,
  ratingSum: 0,
  ratingAvg: 0,
  since: 1,
  profileHash: `0x${'0'.repeat(64)}`,
  profileStatus: 'ok',
  profile: { schema: 'toklean.merchant/1', name: 'EcoTienda' },
  profileAttempts: 0,
  profileRetryAt: 0,
  ...over,
});

function listing(id: number, over: Partial<ListingRecord> & { name?: string; category?: string; tags?: string[]; description?: string } = {}): ListingRecord {
  const { name, category, tags, description, ...rest } = over;
  return {
    id,
    seller: SELLER,
    kind: 'product',
    status: 'active',
    paymentId: 1,
    paymentSymbol: 'TKN',
    price: parseEther('10').toString(),
    stock: 3,
    openOrders: 0,
    createdAt: 1_700_000_000 + id,
    hasProduct: false,
    nftEscrowed: false,
    metadataHash: `0x${'1'.repeat(64)}`,
    metadataURI: `ipfs://${CID}`,
    metadata: { schema: 'toklean.listing/1', name: name ?? `Producto ${id}`, description: description ?? 'Descripción', image: `ipfs://${CID}`, category: (category ?? 'home') as never, tags },
    metadataStatus: 'ok',
    metadataAttempts: 0,
    metadataRetryAt: 0,
    cleanVerified: false,
    available: true,
    ...rest,
  };
}

let dir = '';
let chain: FakeChain;
let indexer: Indexer;
let api: (req: Request) => Promise<Response>;
let clock = NOW;

const get = (path: string, init?: RequestInit) => api(new Request(`http://api.test${path}`, init));
const body = async (res: Response) => (await res.json()) as any;

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'toklean-api-'));
});
afterAll(() => rm(dir, { recursive: true, force: true }));

beforeEach(() => {
  clock = NOW;
  chain = new FakeChain();
  indexer = new Indexer({ chain, chainId: 31337, startBlock: 1, snapshots: new MemorySnapshotStore(), fetchJson: async () => ({}), policy: POLICY });
  indexer.state = emptyState(31337, 1);
  indexer.state.lastBlock = 90;
  indexer.head = 100;
  api = createApi({
    indexer,
    chain,
    store: new FileStore(dir, POLICY.baseUrl),
    deployment: DEPLOYMENT,
    policy: POLICY,
    corsOrigins: ['https://app.toklean.cl'],
    uploadsPerHour: 10,
    now: () => clock,
  });
});

function seedCatalog() {
  const s = indexer.state;
  s.merchants[SELLER.toLowerCase()] = merchant(SELLER, { ratingAvg: 4.5, ratingCount: 2, completedSales: 7 });
  s.merchants[SELLER2.toLowerCase()] = merchant(SELLER2, { ratingAvg: 3, ratingCount: 1, profile: { schema: 'toklean.merchant/1', name: 'Verde Chile' } });
  const rows: ListingRecord[] = [
    listing(1, { name: 'Banca de plástico reciclado', category: 'home', tags: ['jardín'], cleanVerified: true, hasProduct: true, productTokenId: '1' }),
    listing(2, { name: 'Maceta de cerámica', category: 'garden', price: parseEther('4').toString() }),
    listing(3, { name: 'Taller de compostaje', kind: 'service', category: 'education', paymentId: 2, paymentSymbol: 'REC', price: parseEther('25').toString() }),
    listing(4, { name: 'Bolsa de algodón', category: 'fashion', seller: SELLER2, price: parseEther('2.5').toString() }),
    listing(5, { name: 'Agotado', category: 'home', available: false, stock: 0 }),
    listing(6, { name: 'Sin metadata', metadataStatus: 'pending', metadata: null }),
  ];
  for (const l of rows) s.listings[l.id] = l;
}

describe('GET /v1/listings', () => {
  beforeEach(seedCatalog);

  it('lists available listings with metadata, newest first, hiding the unready and sold out', async () => {
    const res = await get('/v1/listings');
    expect(res.status).toBe(200);
    const data = await body(res);
    expect(data.items.map((i: any) => i.id)).toEqual([4, 3, 2, 1]);
    expect(data.total).toBe(4);
    expect(data.nextCursor).toBeNull();
    const first = data.items[3];
    expect(first).toMatchObject({ name: 'Banca de plástico reciclado', cleanVerified: true, paymentSymbol: 'TKN', imageUrl: `https://gw.test/ipfs/${CID}` });
    expect(first.seller).toMatchObject({ name: 'EcoTienda', ratingAvg: 4.5, completedSales: 7 });
  });

  it('includes unavailable listings with available=false (still requires metadata)', async () => {
    const data = await body(await get('/v1/listings?available=false'));
    expect(data.items.map((i: any) => i.id)).toEqual([5, 4, 3, 2, 1]);
  });

  it('filters by category, kind, payment token, seller and clean flag', async () => {
    expect((await body(await get('/v1/listings?category=garden'))).items.map((i: any) => i.id)).toEqual([2]);
    expect((await body(await get('/v1/listings?kind=service'))).items.map((i: any) => i.id)).toEqual([3]);
    expect((await body(await get('/v1/listings?payment=2'))).items.map((i: any) => i.id)).toEqual([3]);
    expect((await body(await get(`/v1/listings?seller=${SELLER2}`))).items.map((i: any) => i.id)).toEqual([4]);
    expect((await body(await get('/v1/listings?clean=true'))).items.map((i: any) => i.id)).toEqual([1]);
  });

  it('filters by price range in token units', async () => {
    expect((await body(await get('/v1/listings?minPrice=3&maxPrice=10'))).items.map((i: any) => i.id)).toEqual([2, 1]);
    expect((await body(await get('/v1/listings?maxPrice=2.5'))).items.map((i: any) => i.id)).toEqual([4]);
  });

  it('searches accent-insensitively across name, description, tags and seller name', async () => {
    expect((await body(await get('/v1/listings?q=ceramica'))).items.map((i: any) => i.id)).toEqual([2]);
    expect((await body(await get('/v1/listings?q=JARDIN'))).items.map((i: any) => i.id)).toEqual([1]);
    expect((await body(await get('/v1/listings?q=verde%20chile'))).items.map((i: any) => i.id)).toEqual([4]);
    expect((await body(await get('/v1/listings?q=banca%20reciclado'))).items.map((i: any) => i.id)).toEqual([1]);
    expect((await body(await get('/v1/listings?q=nada-coincide'))).items).toEqual([]);
  });

  it('sorts by price and seller rating', async () => {
    expect((await body(await get('/v1/listings?sort=priceAsc'))).items.map((i: any) => i.id)).toEqual([4, 2, 1, 3]);
    expect((await body(await get('/v1/listings?sort=priceDesc'))).items.map((i: any) => i.id)).toEqual([3, 1, 2, 4]);
    expect((await body(await get('/v1/listings?sort=rating'))).items.map((i: any) => i.id)).toEqual([3, 2, 1, 4]);
  });

  it('paginates with cursors and reports facets over the filtered set', async () => {
    const p1 = await body(await get('/v1/listings?limit=3'));
    expect(p1.items.map((i: any) => i.id)).toEqual([4, 3, 2]);
    expect(p1.nextCursor).toBe('3');
    const p2 = await body(await get(`/v1/listings?limit=3&cursor=${p1.nextCursor}`));
    expect(p2.items.map((i: any) => i.id)).toEqual([1]);
    expect(p2.nextCursor).toBeNull();
    expect(p1.facets.category).toEqual({ home: 1, garden: 1, education: 1, fashion: 1 });
    // Las facetas ignoran el filtro de categoría para poder mostrar las demás opciones
    const f = await body(await get('/v1/listings?category=garden'));
    expect(f.facets.category.home).toBe(1);
    expect(f.items).toHaveLength(1);
  });

  it('rejects invalid parameters with 400 and a structured error', async () => {
    for (const q of ['limit=0', 'limit=500', 'category=weapons', 'sort=random', 'minPrice=abc', 'seller=0x123', 'cursor=-1', 'payment=9']) {
      const res = await get(`/v1/listings?${q}`);
      expect(res.status, q).toBe(400);
      expect((await body(res)).error.code).toBe('invalid_query');
    }
  });
});

describe('detail endpoints', () => {
  beforeEach(seedCatalog);

  it('returns one listing, any status, and 404 for unknown ids', async () => {
    expect((await body(await get('/v1/listings/6'))).metadataStatus).toBe('pending');
    expect((await get('/v1/listings/99')).status).toBe(404);
    expect((await get('/v1/listings/abc')).status).toBe(404);
  });

  it('lists approved merchants by sales and returns a merchant card', async () => {
    indexer.state.merchants[ADDR(9)] = merchant(ADDR(9), { status: 'pending' });
    const list = await body(await get('/v1/merchants'));
    expect(list.items.map((m: any) => m.address)).toEqual([SELLER, SELLER2]);
    const one = await body(await get(`/v1/merchants/${SELLER}`));
    expect(one).toMatchObject({ name: 'EcoTienda', completedSales: 7, listings: 5 });
    expect((await get(`/v1/merchants/${ADDR(77)}`)).status).toBe(404);
  });

  it('serves orders by buyer or seller with the listing summary, and requires a filter', async () => {
    const order: OrderRecord = { id: 1, listingId: 1, buyer: BUYER, seller: SELLER, amount: '1', qty: 1, feeBps: 200, porBps: 0, paymentId: 1, paymentSymbol: 'TKN', status: 'shipped', rated: false, deadline: NOW + 100 };
    indexer.state.orders[1] = order;
    indexer.state.orders[2] = { ...order, id: 2, buyer: ADDR(55), status: 'paid' };
    const mine = await body(await get(`/v1/orders?buyer=${BUYER}`));
    expect(mine.items).toHaveLength(1);
    expect(mine.items[0]).toMatchObject({ id: 1, status: 'shipped', listing: { id: 1, name: 'Banca de plástico reciclado' } });
    expect((await body(await get(`/v1/orders?seller=${SELLER}&status=paid`))).items.map((o: any) => o.id)).toEqual([2]);
    expect((await get('/v1/orders')).status).toBe(400);
    expect((await body(await get('/v1/orders/1'))).id).toBe(1);
    expect((await get('/v1/orders/9')).status).toBe(404);
  });

  it('reads claimable balances live from the chain for an account', async () => {
    chain.claimable.set(SELLER.toLowerCase(), { 1: 5n * 10n ** 18n, 2: 0n, 3: 0n });
    const acc = await body(await get(`/v1/accounts/${SELLER}`));
    expect(acc.claimable).toEqual({ 1: '5000000000000000000', 2: '0', 3: '0' });
    expect(acc.merchant.name).toBe('EcoTienda');
  });

  it('aggregates stats and exposes health and config', async () => {
    indexer.state.orders[1] = { id: 1, listingId: 1, buyer: BUYER, seller: SELLER, amount: '3000', qty: 1, feeBps: 0, porBps: 0, paymentId: 1, paymentSymbol: 'TKN', status: 'completed', rated: false, deadline: 0 };
    indexer.state.orders[2] = { ...indexer.state.orders[1]!, id: 2, amount: '500' };
    const stats = await body(await get('/v1/stats'));
    expect(stats).toMatchObject({ merchants: 2, listings: 6, availableListings: 5, cleanVerifiedListings: 1, completedOrders: 2, volume: { TKN: '3500' } });
    const health = await body(await get('/health'));
    expect(health).toMatchObject({ ok: true, lagBlocks: 10, lastBlock: 90, head: 100, ready: false });
    const cfg = await body(await get('/v1/config'));
    expect(cfg.contracts.marketplace).toBe(DEPLOYMENT.ToKleanMarketplace);
    expect(cfg.paymentTokens).toEqual({ 1: 'TKN', 2: 'REC', 3: 'POR' });
  });
});

describe('http behaviour', () => {
  it('answers CORS only for allowed origins', async () => {
    const ok = await get('/health', { headers: { origin: 'https://app.toklean.cl' } });
    expect(ok.headers.get('access-control-allow-origin')).toBe('https://app.toklean.cl');
    const bad = await get('/health', { headers: { origin: 'https://evil.example' } });
    expect(bad.headers.get('access-control-allow-origin')).toBeNull();
    const pre = await get('/v1/media', { method: 'OPTIONS', headers: { origin: 'https://app.toklean.cl' } });
    expect(pre.status).toBe(204);
    expect(pre.headers.get('access-control-allow-headers')).toContain('authorization');
  });

  it('returns structured 404s and never leaks internals on unexpected errors', async () => {
    const res = await get('/v1/nope');
    expect(res.status).toBe(404);
    expect((await body(res)).error.code).toBe('not_found');
    chain.readClaimable = async () => {
      throw new Error('secret rpc url http://10.0.0.1');
    };
    const err = await get(`/v1/accounts/${SELLER}`);
    expect(err.status).toBe(500);
    expect(JSON.stringify(await body(err))).not.toContain('10.0.0.1');
  });
});

// ------------------------------------------------------------------ subidas

const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);
const signer = privateKeyToAccount(generatePrivateKey());

async function signed(kind: 'metadata' | 'media', payload: Uint8Array, ts = clock, who = signer) {
  const signature = await who.signMessage({ message: uploadMessage(kind, sha256Hex(payload), ts) });
  return authHeader(who.address, ts, signature);
}

async function post(path: string, payload: Uint8Array | string, auth: string | null, type = 'application/json') {
  const bytes = typeof payload === 'string' ? new TextEncoder().encode(payload) : payload;
  return get(path, { method: 'POST', headers: { 'content-type': type, ...(auth ? { authorization: auth } : {}) }, body: bytes });
}

describe('POST /v1/media', () => {
  it('stores a signed PNG and serves it back with safe headers', async () => {
    const res = await post('/v1/media', PNG, await signed('media', PNG), 'image/png');
    expect(res.status).toBe(201);
    const out = await body(res);
    expect(out).toMatchObject({ contentType: 'image/png', bytes: PNG.length, durable: false });
    expect(out.uri).toBe(`http://localhost:8787/v1/media/${sha256Hex(PNG)}`);

    const file = await get(`/v1/media/${out.id}`);
    expect(file.status).toBe(200);
    expect(file.headers.get('content-type')).toBe('image/png');
    expect(file.headers.get('x-content-type-options')).toBe('nosniff');
    expect(file.headers.get('content-security-policy')).toContain('sandbox');
    expect(new Uint8Array(await file.arrayBuffer())).toEqual(PNG);
  });

  it('rejects unsigned, mis-signed and stale uploads', async () => {
    expect((await post('/v1/media', PNG, null)).status).toBe(401);
    const other = privateKeyToAccount(generatePrivateKey());
    const forged = authHeader(signer.address, clock, await other.signMessage({ message: uploadMessage('media', sha256Hex(PNG), clock) }));
    expect((await post('/v1/media', PNG, forged)).status).toBe(401);
    expect((await post('/v1/media', PNG, await signed('media', PNG, clock - 1000))).status).toBe(401);
    // Firma de otro contenido
    expect((await post('/v1/media', PNG, await signed('media', new Uint8Array([9, 9, 9])))).status).toBe(401);
  });

  it('rejects non-images by content, even with an image Content-Type', async () => {
    const svg = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
    const res = await post('/v1/media', svg, await signed('media', svg), 'image/png');
    expect(res.status).toBe(415);
    const html = new TextEncoder().encode('<html></html>');
    expect((await post('/v1/media', html, await signed('media', html), 'image/jpeg')).status).toBe(415);
    expect((await post('/v1/media', new Uint8Array(), null)).status).toBe(400);
  });

  it('enforces the size limit before reading the body', async () => {
    const big = new Uint8Array(2 * 1024 * 1024 + 1);
    big.set(PNG);
    const res = await post('/v1/media', big, await signed('media', big), 'image/png');
    expect(res.status).toBe(413);
  });

  it('rate limits per account', async () => {
    for (let i = 0; i < 10; i++) {
      const png = Uint8Array.from([...PNG, i]);
      expect((await post('/v1/media', png, await signed('media', png), 'image/png')).status).toBe(201);
    }
    const png = Uint8Array.from([...PNG, 99]);
    const res = await post('/v1/media', png, await signed('media', png), 'image/png');
    expect(res.status).toBe(429);
    clock += 3601;
    const again = Uint8Array.from([...PNG, 100]);
    expect((await post('/v1/media', again, await signed('media', again), 'image/png')).status).toBe(201);
  });
});

describe('POST /v1/metadata', () => {
  const listingBody = () => JSON.stringify(listingMeta({ image: `ipfs://${CID}` }));

  it('lets any signed account publish a merchant profile', async () => {
    const payload = JSON.stringify(merchantProfile());
    const res = await post('/v1/metadata?kind=merchant', payload, await signed('metadata', new TextEncoder().encode(payload)));
    expect(res.status).toBe(201);
    const out = await body(res);
    expect(out.uriHash).toBe(keccak256(toBytes(out.uri)));
    const stored = await get(`/v1/metadata/${out.id}`);
    expect(await stored.text()).toBe(canonicalize(merchantProfile()));
  });

  it('only lets approved merchants publish listing metadata (checked on-chain when the index lags)', async () => {
    const payload = new TextEncoder().encode(listingBody());
    expect((await post('/v1/metadata?kind=listing', payload, await signed('metadata', payload))).status).toBe(403);

    chain.setMerchant(signer.address, 2);
    const res = await post('/v1/metadata?kind=listing', payload, await signed('metadata', payload));
    expect(res.status).toBe(201);

    // Pendiente no basta
    const pending = privateKeyToAccount(generatePrivateKey());
    chain.setMerchant(pending.address, 1);
    expect((await post('/v1/metadata?kind=listing', payload, await signed('metadata', payload, clock, pending))).status).toBe(403);
  });

  it('uses the index when it already knows the merchant (no chain read needed)', async () => {
    indexer.state.merchants[signer.address.toLowerCase()] = merchant(signer.address);
    chain.readMerchants = async () => {
      throw new Error('no debería consultarse la cadena');
    };
    const payload = new TextEncoder().encode(listingBody());
    expect((await post('/v1/metadata?kind=listing', payload, await signed('metadata', payload))).status).toBe(201);
  });

  it('validates schema, JSON, kind and media hosts', async () => {
    indexer.state.merchants[signer.address.toLowerCase()] = merchant(signer.address);
    const send = async (raw: string, kind = 'listing') => {
      const bytes = new TextEncoder().encode(raw);
      return post(`/v1/metadata?kind=${kind}`, bytes, await signed('metadata', bytes));
    };
    const bad = await send(JSON.stringify(listingMeta({ category: 'weapons' })));
    expect(bad.status).toBe(422);
    expect((await body(bad)).error.details[0].path).toBe('category');
    expect((await send('{not json')).status).toBe(400);
    expect((await send(listingBody(), 'other')).status).toBe(400);
    const evil = await send(JSON.stringify(listingMeta({ image: 'https://tracker.evil.example/x.png' })));
    expect(evil.status).toBe(422);
    expect((await body(evil)).error.code).toBe('invalid_media_uri');
    expect((await send(JSON.stringify(listingMeta({ image: 'https://cdn.example.com/x.png' })))).status).toBe(201);
  });

  it('is content-addressed: key order does not change the stored URI', async () => {
    indexer.state.merchants[signer.address.toLowerCase()] = merchant(signer.address);
    const a = JSON.stringify(listingMeta());
    const b = JSON.stringify(Object.fromEntries(Object.entries(listingMeta()).reverse()));
    const ra = await body(await post('/v1/metadata?kind=listing', a, await signed('metadata', new TextEncoder().encode(a))));
    const rb = await body(await post('/v1/metadata?kind=listing', b, await signed('metadata', new TextEncoder().encode(b))));
    expect(ra.uri).toBe(rb.uri);
  });

  it('does not serve arbitrary ids or other kinds of file', async () => {
    expect((await get('/v1/metadata/not-a-hash')).status).toBe(404);
    expect((await get(`/v1/metadata/${'f'.repeat(64)}`)).status).toBe(404);
    expect((await get('/v1/media/../../etc/passwd')).status).toBe(404);
  });
});

void merchantRaw;
