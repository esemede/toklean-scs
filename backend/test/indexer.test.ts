import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Indexer } from '../src/indexer/indexer.ts';
import { MemorySnapshotStore } from '../src/indexer/snapshot.ts';
import { MetadataFetchError } from '../src/metadata/fetch.ts';
import {
  BUYER,
  FakeChain,
  listingMeta,
  listingRaw,
  merchantProfile,
  merchantRaw,
  orderRaw,
  POLICY,
  SELLER,
  SELLER2,
  CID,
} from './helpers.ts';

const META_URI = `ipfs://${CID}`;
const PROFILE_URI = 'http://localhost:8787/v1/metadata/' + 'c'.repeat(64);

let chain: FakeChain;
let snapshots: MemorySnapshotStore;
let docs: Record<string, unknown>;
let fetchJson: ReturnType<typeof vi.fn>;
let nowSec: number;

function make(over: { confirmations?: number; chunkBlocks?: number } = {}) {
  return new Indexer({
    chain,
    chainId: 31337,
    startBlock: 10,
    snapshots,
    fetchJson: fetchJson as never,
    policy: POLICY,
    confirmations: over.confirmations ?? 0,
    chunkBlocks: over.chunkBlocks ?? 1000,
    now: () => nowSec,
  });
}

/** Un comercio aprobado con perfil y una publicación con metadata. */
function seed() {
  chain.setMerchant(SELLER, 2, { profileHash: merchantRaw(SELLER, 2, PROFILE_URI).profileHash });
  chain.emit(11, 'registry', 'MerchantApplied', { merchant: SELLER, profileURI: PROFILE_URI });
  chain.emit(12, 'registry', 'MerchantReviewed', { merchant: SELLER, approved: true });
  chain.listings.set(1, listingRaw(1, META_URI));
  chain.emit(13, 'catalog', 'ListingCreated', { listingId: 1n, seller: SELLER, metadataURI: META_URI });
}

beforeEach(() => {
  chain = new FakeChain();
  snapshots = new MemorySnapshotStore();
  nowSec = 1_800_000_000;
  docs = { [META_URI]: listingMeta(), [PROFILE_URI]: merchantProfile() };
  fetchJson = vi.fn(async (uri: string) => {
    if (!(uri in docs)) throw new MetadataFetchError('HTTP 404', false);
    return docs[uri];
  });
});

describe('Indexer.sync', () => {
  it('builds merchants and listings from events, reading the state from the contracts', async () => {
    seed();
    const idx = make();
    await idx.init();
    const r = await idx.sync();

    expect(r).toMatchObject({ from: 10, to: 100, events: 3 });
    expect(idx.ready).toBe(true);
    const m = idx.state.merchants[SELLER.toLowerCase()]!;
    expect(m.status).toBe('approved');
    expect(m.profileStatus).toBe('ok');
    expect(m.profile?.name).toBe('EcoTienda');
    const l = idx.state.listings[1]!;
    expect(l).toMatchObject({ id: 1, status: 'active', kind: 'product', paymentSymbol: 'TKN', price: '10000000000000000000', available: true });
    expect(l.metadataStatus).toBe('ok');
    expect(l.metadata?.name).toBe('Banca de plástico reciclado');
    expect(idx.state.lastBlock).toBe(100);
  });

  it('only reads what the events marked as changed', async () => {
    seed();
    chain.listings.set(2, listingRaw(2, META_URI));
    const idx = make();
    await idx.init();
    await idx.sync(); // 1 evento de publicación
    expect(chain.reads.listings).toBe(1);

    chain.head = 120n;
    chain.emit(110, 'catalog', 'ListingStatusChanged', { listingId: 2n });
    chain.listings.set(2, listingRaw(2, META_URI));
    await idx.sync();
    expect(chain.reads.listings).toBe(2); // +1 (sólo la 2), la 1 no se relee
    expect(idx.state.listings[2]).toBeDefined();
  });

  it('does nothing until new confirmed blocks arrive', async () => {
    seed();
    const idx = make({ confirmations: 5 });
    await idx.init();
    await idx.sync();
    expect(idx.state.lastBlock).toBe(95);
    const logsBefore = chain.reads.logs;
    await idx.sync();
    expect(chain.reads.logs).toBe(logsBefore);
    chain.head = 110n;
    await idx.sync();
    expect(idx.state.lastBlock).toBe(105);
  });

  it('walks the chain in chunks and checkpoints progress', async () => {
    seed();
    const idx = make({ chunkBlocks: 30 });
    await idx.init();
    await idx.sync();
    expect(chain.reads.logs).toBe(4); // 10-39, 40-69, 70-99, 100-100
    expect(snapshots.saved?.lastBlock).toBe(100);
  });

  it('resumes from the snapshot without re-reading old events', async () => {
    seed();
    const first = make();
    await first.init();
    await first.sync();

    chain.reads.logs = 0;
    const second = make();
    await second.init();
    expect(second.state.lastBlock).toBe(100);
    expect(second.state.listings[1]?.metadata?.name).toBeDefined();
    await second.sync();
    expect(chain.reads.logs).toBe(0);
    expect(fetchJson).toHaveBeenCalledTimes(2); // sólo las del primer arranque
  });

  it('ignores a snapshot from another chain', async () => {
    seed();
    const first = make();
    await first.init();
    await first.sync();
    const other = new Indexer({ chain, chainId: 1, startBlock: 10, snapshots, fetchJson: fetchJson as never, policy: POLICY });
    await other.init();
    expect(other.state.lastBlock).toBe(9);
    expect(Object.keys(other.state.listings)).toHaveLength(0);
  });

  it('never runs two syncs at once and gives late callers a run that starts after their call', async () => {
    seed();
    const idx = make();
    await idx.init();
    const first = idx.sync();
    // Llega actividad mientras la primera sincronización está en curso
    chain.listings.set(2, listingRaw(2, META_URI));
    chain.head = 120n;
    chain.emit(110, 'catalog', 'ListingCreated', { listingId: 2n, seller: SELLER, metadataURI: META_URI });
    const second = idx.sync();
    const third = idx.sync();
    expect(third).toBe(second);
    expect(second).not.toBe(first);
    await Promise.all([first, second]);
    expect(idx.state.listings[2]).toBeDefined();
    expect(idx.state.lastBlock).toBe(120);
  });
});

describe('order handling', () => {
  it('reads orders and the listing they touch, and queues withdrawals when they settle', async () => {
    seed();
    chain.orders.set(1, orderRaw(1, 1, { status: 2 }));
    chain.emit(20, 'market', 'OrderCreated', { orderId: 1n, listingId: 1n });
    chain.emit(21, 'market', 'OrderCompleted', { orderId: 1n });
    const idx = make();
    await idx.init();
    await idx.sync();

    expect(idx.state.orders[1]).toMatchObject({ status: 'completed', paymentSymbol: 'TKN', amount: '10000000000000000000' });
    expect(idx.state.pendingWithdrawals.map((a) => a.toLowerCase()).sort()).toEqual([BUYER.toLowerCase(), SELLER.toLowerCase()].sort());

    chain.head = 130n;
    chain.emit(125, 'market', 'Withdrawn', { account: SELLER, id: 1n, amount: 5n });
    await idx.sync();
    expect(idx.state.pendingWithdrawals).toEqual([BUYER]);
  });

  it('refreshes the listing when an order changes its stock', async () => {
    seed();
    chain.orders.set(1, orderRaw(1, 1));
    chain.emit(20, 'market', 'OrderCreated', { orderId: 1n, listingId: 1n });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.listings[1]!.stock).toBe(5);

    chain.listings.set(1, listingRaw(1, META_URI, { stock: 4, openOrders: 1 }));
    chain.orders.set(1, orderRaw(1, 1, { status: 1 }));
    chain.head = 120n;
    chain.emit(110, 'market', 'OrderShipped', { orderId: 1n });
    await idx.sync();
    expect(idx.state.orders[1]!.status).toBe('shipped');
    expect(idx.state.listings[1]).toMatchObject({ stock: 4, openOrders: 1 });
  });
});

describe('merchant and certification changes', () => {
  it('recomputes availability of every listing of a merchant that gets suspended', async () => {
    seed();
    chain.listings.set(2, listingRaw(2, META_URI));
    chain.emit(14, 'catalog', 'ListingCreated', { listingId: 2n, seller: SELLER, metadataURI: META_URI });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.listings[1]!.available && idx.state.listings[2]!.available).toBe(true);

    chain.setMerchant(SELLER, 4, { profileHash: merchantRaw(SELLER, 2, PROFILE_URI).profileHash });
    chain.listings.set(1, listingRaw(1, META_URI, { available: false }));
    chain.listings.set(2, listingRaw(2, META_URI, { available: false }));
    chain.head = 120n;
    chain.emit(110, 'registry', 'MerchantSuspended', { merchant: SELLER, suspended: true });
    await idx.sync();
    expect(idx.state.merchants[SELLER.toLowerCase()]!.status).toBe('suspended');
    expect(idx.state.listings[1]!.available).toBe(false);
    expect(idx.state.listings[2]!.available).toBe(false);
  });

  it('re-reads clean-product listings on every new block range (their certification can change elsewhere)', async () => {
    seed();
    chain.listings.set(3, listingRaw(3, META_URI, { hasProduct: true, nftEscrowed: true, productTokenId: 7n, cleanVerified: true }));
    chain.emit(15, 'catalog', 'ListingCreated', { listingId: 3n, seller: SELLER, metadataURI: META_URI });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.listings[3]).toMatchObject({ cleanVerified: true, productTokenId: '7' });

    // Se revoca la certificación en CircularProductNFT: ningún evento del marketplace lo avisa
    chain.listings.set(3, listingRaw(3, META_URI, { hasProduct: true, nftEscrowed: true, productTokenId: 7n, cleanVerified: false, available: false }));
    chain.head = 105n;
    await idx.sync();
    expect(idx.state.listings[3]).toMatchObject({ cleanVerified: false, available: false });
  });
});

describe('metadata verification and enrichment', () => {
  it('only trusts a URI whose keccak256 matches the hash stored on-chain', async () => {
    seed();
    // La URI del evento no es la que el contrato commiteó
    chain.listings.set(1, listingRaw(1, 'ipfs://otra-cosa'));
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.listings[1]).toMatchObject({ metadataStatus: 'missing' });
    expect(idx.state.listings[1]!.metadataURI).toBeUndefined();
    expect(fetchJson).not.toHaveBeenCalledWith(META_URI);
  });

  it('keeps the latest URI that matches after an update and refetches', async () => {
    seed();
    const idx = make();
    await idx.init();
    await idx.sync();

    const v2 = `ipfs://${CID}/v2`;
    docs[v2] = listingMeta({ name: 'Banca v2' });
    chain.listings.set(1, listingRaw(1, v2));
    chain.head = 120n;
    chain.emit(110, 'catalog', 'ListingUpdated', { listingId: 1n, metadataURI: v2 });
    await idx.sync();
    expect(idx.state.listings[1]).toMatchObject({ metadataURI: v2, metadataStatus: 'ok' });
    expect(idx.state.listings[1]!.metadata?.name).toBe('Banca v2');
  });

  it('marks schema-invalid documents as invalid and does not retry them', async () => {
    seed();
    docs[META_URI] = listingMeta({ category: 'weapons' });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.listings[1]!.metadataStatus).toBe('invalid');
    const calls = fetchJson.mock.calls.length;
    nowSec += 10_000;
    chain.head = 110n;
    await idx.sync();
    expect(fetchJson.mock.calls.length).toBe(calls);
  });

  it('rejects metadata whose main image points to a disallowed host', async () => {
    seed();
    docs[META_URI] = listingMeta({ image: 'https://tracker.evil.example/p.png' });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.listings[1]!.metadataStatus).toBe('invalid');
  });

  it('drops disallowed extra images but keeps the listing', async () => {
    seed();
    docs[META_URI] = listingMeta({ images: ['https://tracker.evil.example/p.png', 'https://cdn.example.com/ok.png'] });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.listings[1]!.metadata?.images).toEqual(['https://cdn.example.com/ok.png']);
  });

  it('retries transient failures with backoff and recovers', async () => {
    seed();
    delete docs[META_URI];
    const idx = make();
    await idx.init();
    await idx.sync();
    let l = idx.state.listings[1]!;
    expect(l.metadataStatus).toBe('pending');
    expect(l.metadataAttempts).toBe(1);
    expect(l.metadataRetryAt).toBeGreaterThan(nowSec);

    // Antes de tiempo: no reintenta
    const calls = fetchJson.mock.calls.length;
    chain.head = 105n;
    await idx.sync();
    expect(fetchJson.mock.calls.length).toBe(calls);

    // Cuando el contenido aparece y pasa el backoff, se completa
    docs[META_URI] = listingMeta();
    nowSec += 120;
    chain.head = 110n;
    await idx.sync();
    l = idx.state.listings[1]!;
    expect(l.metadataStatus).toBe('ok');
    expect(l.metadataAttempts).toBe(0);
  });

  it('stays quiet about merchants without a profile', async () => {
    chain.setMerchant(SELLER2, 1);
    chain.emit(12, 'registry', 'MerchantApplied', { merchant: SELLER2, profileURI: 'x' });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.merchants[SELLER2.toLowerCase()]).toMatchObject({ status: 'pending', profileStatus: 'missing' });
  });

  it('computes the rating average from the contract totals', async () => {
    chain.setMerchant(SELLER, 2, { ratingSum: 14, ratingCount: 3, completedSales: 3 });
    chain.emit(12, 'registry', 'Rated', { merchant: SELLER, score: 5 });
    const idx = make();
    await idx.init();
    await idx.sync();
    expect(idx.state.merchants[SELLER.toLowerCase()]).toMatchObject({ ratingAvg: 4.67, ratingCount: 3, completedSales: 3 });
  });
});
