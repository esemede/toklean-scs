import { keccak256, toBytes, type Address, type Hex } from 'viem';
import type { ChainLog, ChainReader, RawListing, RawMerchant, RawOrder } from './chain.ts';
import type { SnapshotStore } from './snapshot.ts';
import { MetadataFetchError, type JsonFetcher } from '../metadata/fetch.ts';
import { listingMetadataSchema, merchantProfileSchema } from '../metadata/schema.ts';
import { resolveUri, type UriPolicy } from '../metadata/uri.ts';
import {
  emptyState,
  LISTING_KIND,
  LISTING_STATUS,
  MERCHANT_STATUS,
  ORDER_STATUS,
  PAYMENT_SYMBOLS,
  type IndexState,
  type ListingRecord,
  type MerchantRecord,
  type OrderRecord,
} from '../types.ts';

export interface IndexerOptions {
  chain: ChainReader;
  chainId: number;
  /** Primer bloque con eventos del marketplace. */
  startBlock: number;
  snapshots: SnapshotStore;
  fetchJson: JsonFetcher;
  policy: UriPolicy;
  /** Bloques de espera antes de procesar (reorgs). */
  confirmations?: number;
  /** Tamaño de cada consulta de eventos. */
  chunkBlocks?: number;
  /** Segundos unix (inyectable en tests). */
  now?: () => number;
  log?: (message: string) => void;
}

export interface SyncResult {
  from: number;
  to: number;
  head: number;
  events: number;
}

const lower = (a: string) => a.toLowerCase();
const uriHash = (uri: string): Hex => keccak256(toBytes(uri));
const MAX_FETCH_ATTEMPTS_BEFORE_SLOW = 6;

export class Indexer {
  state: IndexState;
  /** Último bloque visible en la cadena (para medir el retraso). */
  head = 0;
  /** true tras la primera sincronización completa. */
  ready = false;
  private readonly confirmations: number;
  private readonly chunk: number;
  private readonly now: () => number;
  private readonly log: (message: string) => void;
  private current: Promise<SyncResult> | null = null;
  private queued: Promise<SyncResult> | null = null;

  constructor(private readonly o: IndexerOptions) {
    this.confirmations = o.confirmations ?? 2;
    this.chunk = o.chunkBlocks ?? 2_000;
    this.now = o.now ?? (() => Math.floor(Date.now() / 1000));
    this.log = o.log ?? (() => {});
    this.state = emptyState(o.chainId, o.startBlock);
  }

  /** Carga el último snapshot (si es de esta red) o empieza desde el bloque de despliegue. */
  async init(): Promise<void> {
    const saved = await this.o.snapshots.load();
    if (saved && saved.version === 1 && saved.chainId === this.o.chainId) {
      this.state = saved;
      this.log(`snapshot cargado: bloque ${saved.lastBlock}, ${Object.keys(saved.listings).length} publicaciones`);
    }
  }

  /**
   * Una sola sincronización a la vez. Si ya hay una en curso se encola exactamente otra a continuación (todas las
   * llamadas concurrentes comparten esa), para que quien pide sincronizar vea siempre lo ocurrido antes de su llamada.
   */
  sync(): Promise<SyncResult> {
    if (!this.current) return this.start();
    if (!this.queued) {
      this.queued = this.current
        .then(
          () => undefined,
          () => undefined,
        )
        .then(() => {
          this.queued = null;
          return this.start();
        });
    }
    return this.queued;
  }

  private start(): Promise<SyncResult> {
    const run: Promise<SyncResult> = this.doSync().finally(() => {
      if (this.current === run) this.current = null;
    });
    this.current = run;
    return run;
  }

  private async doSync(): Promise<SyncResult> {
    const headBig = await this.o.chain.getBlockNumber();
    this.head = Number(headBig);
    const target = Math.max(0, this.head - this.confirmations);
    let from = this.state.lastBlock + 1;
    let events = 0;
    const first = from;

    if (target < from) {
      await this.enrichMetadata();
      this.ready = true;
      return { from, to: this.state.lastBlock, head: this.head, events };
    }

    while (from <= target) {
      const to = Math.min(target, from + this.chunk - 1);
      const logs = await this.o.chain.getLogs(BigInt(from), BigInt(to));
      events += logs.length;
      await this.apply(logs);
      this.state.lastBlock = to;
      await this.o.snapshots.save(this.state);
      from = to + 1;
    }
    await this.enrichMetadata();
    await this.o.snapshots.save(this.state);
    this.ready = true;
    return { from: first, to: this.state.lastBlock, head: this.head, events };
  }

  /** Aplica un lote de eventos: marcan qué cambió y el estado se relee de los contratos. */
  private async apply(logs: ChainLog[]): Promise<void> {
    const merchants = new Set<string>();
    const listings = new Set<number>();
    const orders = new Set<number>();
    const uris = { listing: new Map<number, string[]>(), merchant: new Map<string, string[]>() };
    const settled = new Set<number>();
    const withdrawn = new Set<string>();

    const push = <K>(map: Map<K, string[]>, key: K, uri: unknown) => {
      if (typeof uri !== 'string') return;
      map.set(key, [...(map.get(key) ?? []), uri]);
    };

    for (const l of logs) {
      const a = l.args;
      const key = `${l.contract}:${l.name}`;
      switch (key) {
        case 'registry:MerchantApplied':
          merchants.add(lower(String(a.merchant)));
          push(uris.merchant, lower(String(a.merchant)), a.profileURI);
          break;
        case 'registry:MerchantReviewed':
        case 'registry:MerchantSuspended':
        case 'registry:SaleRecorded':
        case 'registry:Rated':
          merchants.add(lower(String(a.merchant)));
          break;
        case 'catalog:ListingCreated':
        case 'catalog:ListingUpdated':
          listings.add(Number(a.listingId));
          push(uris.listing, Number(a.listingId), a.metadataURI);
          break;
        case 'catalog:ListingStatusChanged':
          listings.add(Number(a.listingId));
          break;
        case 'market:OrderCreated':
          orders.add(Number(a.orderId));
          listings.add(Number(a.listingId));
          break;
        case 'market:OrderCompleted':
        case 'market:OrderRefunded':
        case 'market:DisputeResolved':
          orders.add(Number(a.orderId));
          settled.add(Number(a.orderId));
          break;
        case 'market:OrderShipped':
        case 'market:DisputeOpened':
        case 'market:Rated':
          orders.add(Number(a.orderId));
          break;
        case 'market:Withdrawn':
          withdrawn.add(lower(String(a.account)));
          break;
        default:
          break;
      }
    }

    // 1. Pedidos: su lectura revela qué publicaciones y comercios cambiaron.
    if (orders.size) {
      const raw = await this.o.chain.readOrders([...orders]);
      for (const r of raw) {
        this.state.orders[r.id] = toOrder(r);
        listings.add(r.listingId);
        merchants.add(lower(r.seller));
        if (settled.has(r.id)) this.markPendingWithdrawal(r.seller, r.buyer);
      }
    }
    for (const acc of withdrawn) {
      this.state.pendingWithdrawals = this.state.pendingWithdrawals.filter((p) => lower(p) !== acc);
    }

    // 2. Comercios (y, si cambió su estado, todas sus publicaciones).
    if (merchants.size) {
      const raw = await this.o.chain.readMerchants([...merchants] as Address[]);
      for (const r of raw) {
        const key = lower(r.address);
        this.state.merchants[key] = mergeMerchant(this.state.merchants[key], r, uris.merchant.get(key));
        for (const l of Object.values(this.state.listings)) if (lower(l.seller) === key) listings.add(l.id);
      }
    }

    // 3. Productos limpios: su certificación cambia fuera de este marketplace, así que se releen siempre.
    for (const l of Object.values(this.state.listings)) {
      if (l.hasProduct && l.status !== 'closed') listings.add(l.id);
    }

    if (listings.size) {
      const raw = await this.o.chain.readListings([...listings]);
      for (const r of raw) {
        this.state.listings[r.id] = mergeListing(this.state.listings[r.id], r, uris.listing.get(r.id));
      }
    }
  }

  private markPendingWithdrawal(...accounts: Address[]) {
    const known = new Set(this.state.pendingWithdrawals.map(lower));
    for (const a of accounts) if (!known.has(lower(a))) this.state.pendingWithdrawals.push(a);
  }

  // ------------------------------------------------------------------ metadata

  /** Descarga y valida la metadata pendiente (publicaciones y perfiles de comercio). */
  async enrichMetadata(): Promise<void> {
    const now = this.now();
    const jobs: Array<() => Promise<void>> = [];

    for (const l of Object.values(this.state.listings)) {
      if (l.metadataStatus === 'pending' && l.metadataURI && l.metadataRetryAt <= now) {
        jobs.push(() => this.enrich(l, l.metadataURI!, l.metadataHash, listingMetadataSchema, now, (meta) => {
          const image = sanitizeMedia(meta.image, this.o.policy);
          if (!image) return null;
          return { ...meta, images: meta.images?.filter((u) => sanitizeMedia(u, this.o.policy)) };
        }));
      }
    }
    for (const m of Object.values(this.state.merchants)) {
      if (m.profileStatus === 'pending' && m.profileURI && m.profileRetryAt <= now) {
        jobs.push(() => this.enrich(m, m.profileURI!, m.profileHash, merchantProfileSchema, now, (p) => (p.logo && !sanitizeMedia(p.logo, this.o.policy) ? { ...p, logo: undefined } : p)));
      }
    }

    for (let i = 0; i < jobs.length; i += 4) await Promise.all(jobs.slice(i, i + 4).map((j) => j()));
  }

  private async enrich<T>(
    rec: ListingRecord | MerchantRecord,
    uri: string,
    hash: Hex,
    schema: { safeParse(v: unknown): { success: true; data: T } | { success: false } },
    now: number,
    refine: (v: T) => T | null,
  ): Promise<void> {
    const isListing = 'metadataStatus' in rec;
    const set = (status: 'ok' | 'pending' | 'invalid', value: unknown, attempts: number, retryAt: number) => {
      if (isListing) {
        const l = rec as ListingRecord;
        l.metadataStatus = status;
        l.metadata = value as ListingRecord['metadata'];
        l.metadataAttempts = attempts;
        l.metadataRetryAt = retryAt;
        if (status !== 'pending') l.metadataFor = hash;
      } else {
        const m = rec as MerchantRecord;
        m.profileStatus = status;
        m.profile = value as MerchantRecord['profile'];
        m.profileAttempts = attempts;
        m.profileRetryAt = retryAt;
        if (status !== 'pending') m.profileFor = hash;
      }
    };
    const attempts = isListing ? (rec as ListingRecord).metadataAttempts : (rec as MerchantRecord).profileAttempts;

    try {
      const json = await this.o.fetchJson(uri);
      const parsed = schema.safeParse(json);
      const refined = parsed.success ? refine(parsed.data) : null;
      if (!refined) return set('invalid', null, 0, 0);
      set('ok', refined, 0, 0);
    } catch (e) {
      if (e instanceof MetadataFetchError && e.permanent) return set('invalid', null, 0, 0);
      const n = attempts + 1;
      const delay = n >= MAX_FETCH_ATTEMPTS_BEFORE_SLOW ? 600 : Math.min(600, 15 * 2 ** n);
      this.log(`metadata pendiente (${uri.slice(0, 60)}): ${(e as Error).message}`);
      set('pending', null, n, now + delay);
    }
  }
}

// ---------------------------------------------------------------------- mapeo

function sanitizeMedia(uri: string, policy: UriPolicy): string | null {
  return resolveUri(uri, policy) ? uri : null;
}

function toOrder(r: RawOrder): OrderRecord {
  return {
    id: r.id,
    listingId: r.listingId,
    buyer: r.buyer,
    seller: r.seller,
    amount: r.amount.toString(),
    qty: r.qty,
    feeBps: r.feeBps,
    porBps: r.porBps,
    paymentId: r.paymentId,
    paymentSymbol: PAYMENT_SYMBOLS[r.paymentId as 1 | 2 | 3] ?? String(r.paymentId),
    status: ORDER_STATUS[r.status] ?? 'paid',
    rated: r.rated,
    deadline: r.deadline,
  };
}

function pickUri(candidates: string[] | undefined, hash: Hex, previous?: string): string | undefined {
  for (const c of [...(candidates ?? [])].reverse()) if (uriHash(c) === hash) return c;
  if (previous && uriHash(previous) === hash) return previous;
  return undefined;
}

function mergeListing(prev: ListingRecord | undefined, r: RawListing, candidates: string[] | undefined): ListingRecord {
  const metadataURI = pickUri(candidates, r.metadataHash, prev?.metadataURI);
  const same = prev && prev.metadataFor === r.metadataHash && prev.metadataURI === metadataURI;
  return {
    id: r.id,
    seller: r.seller,
    kind: LISTING_KIND[r.kind] ?? 'product',
    status: LISTING_STATUS[r.status] ?? 'active',
    paymentId: r.paymentId,
    paymentSymbol: PAYMENT_SYMBOLS[r.paymentId as 1 | 2 | 3] ?? String(r.paymentId),
    price: r.price.toString(),
    stock: r.stock,
    openOrders: r.openOrders,
    createdAt: r.createdAt,
    hasProduct: r.hasProduct,
    productTokenId: r.hasProduct ? r.productTokenId.toString() : undefined,
    nftEscrowed: r.nftEscrowed,
    metadataHash: r.metadataHash,
    metadataURI,
    metadata: same ? prev.metadata : null,
    metadataStatus: !metadataURI ? 'missing' : same ? prev.metadataStatus : 'pending',
    metadataFor: same ? prev.metadataFor : undefined,
    metadataAttempts: same ? prev.metadataAttempts : 0,
    metadataRetryAt: same ? prev.metadataRetryAt : 0,
    cleanVerified: r.cleanVerified,
    available: r.available,
  };
}

function mergeMerchant(prev: MerchantRecord | undefined, r: RawMerchant, candidates: string[] | undefined): MerchantRecord {
  const hasProfile = /[1-9a-f]/.test(r.profileHash.slice(2));
  const profileURI = hasProfile ? pickUri(candidates, r.profileHash, prev?.profileURI) : undefined;
  const same = prev && prev.profileFor === r.profileHash && prev.profileURI === profileURI;
  return {
    address: r.address,
    status: MERCHANT_STATUS[r.status] ?? 'none',
    completedSales: r.completedSales,
    ratingCount: r.ratingCount,
    ratingSum: r.ratingSum,
    ratingAvg: r.ratingCount ? Math.round((r.ratingSum / r.ratingCount) * 100) / 100 : 0,
    since: r.since,
    profileHash: r.profileHash,
    profileURI,
    profile: same ? prev.profile : null,
    profileStatus: !profileURI ? 'missing' : same ? prev.profileStatus : 'pending',
    profileFor: same ? prev.profileFor : undefined,
    profileAttempts: same ? prev.profileAttempts : 0,
    profileRetryAt: same ? prev.profileRetryAt : 0,
  };
}
