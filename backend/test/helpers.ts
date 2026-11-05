import { keccak256, toBytes, type Address, type Hex } from 'viem';
import type { ChainLog, ChainReader, RawListing, RawMerchant, RawOrder } from '../src/indexer/chain.ts';
import type { UriPolicy } from '../src/metadata/uri.ts';

export const POLICY: UriPolicy = { gateway: 'https://gw.test/ipfs/', baseUrl: 'http://localhost:8787', allowedHosts: ['cdn.example.com'] };

export const SELLER = '0x00000000000000000000000000000000000000a1' as Address;
export const SELLER2 = '0x00000000000000000000000000000000000000a2' as Address;
export const BUYER = '0x00000000000000000000000000000000000000b1' as Address;
export const CID = 'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi';

export const uriHash = (uri: string): Hex => keccak256(toBytes(uri));

export const listingMeta = (over: Record<string, unknown> = {}) => ({
  schema: 'toklean.listing/1',
  name: 'Banca de plástico reciclado',
  description: 'Banca hecha con 80% de plástico reciclado.',
  image: `ipfs://${CID}`,
  category: 'home',
  tags: ['reciclado', 'jardín'],
  ...over,
});

export const merchantProfile = (over: Record<string, unknown> = {}) => ({ schema: 'toklean.merchant/1', name: 'EcoTienda', country: 'CL', ...over });

/** Cadena simulada: el test mueve el estado y agrega eventos; el indexador sólo ve la interfaz ChainReader. */
export class FakeChain implements ChainReader {
  head = 100n;
  logs: ChainLog[] = [];
  merchants = new Map<string, RawMerchant>();
  listings = new Map<number, RawListing>();
  orders = new Map<number, RawOrder>();
  claimable = new Map<string, Record<number, bigint>>();
  reads = { merchants: 0, listings: 0, orders: 0, logs: 0 };

  timestamp = 1_800_000_000;

  async getBlockNumber() {
    return this.head;
  }

  async getTimestamp() {
    return this.timestamp;
  }

  async getLogs(from: bigint, to: bigint) {
    this.reads.logs++;
    return this.logs.filter((l) => l.blockNumber >= from && l.blockNumber <= to);
  }

  async readMerchants(addresses: Address[]) {
    this.reads.merchants += addresses.length;
    return addresses.map((a) => this.merchants.get(a.toLowerCase()) ?? merchantRaw(a, 0));
  }

  async readListings(ids: number[]) {
    this.reads.listings += ids.length;
    return ids.map((id) => {
      const l = this.listings.get(id);
      if (!l) throw new Error(`listing ${id} inexistente`);
      return l;
    });
  }

  async readOrders(ids: number[]) {
    this.reads.orders += ids.length;
    return ids.map((id) => {
      const o = this.orders.get(id);
      if (!o) throw new Error(`order ${id} inexistente`);
      return o;
    });
  }

  async readClaimable(account: Address) {
    return this.claimable.get(account.toLowerCase()) ?? { 1: 0n, 2: 0n, 3: 0n };
  }

  // ---- helpers de escenario
  setMerchant(address: Address, status: number, over: Partial<RawMerchant> = {}) {
    this.merchants.set(address.toLowerCase(), { ...merchantRaw(address, status), ...over });
  }

  emit(block: number, contract: ChainLog['contract'], name: string, args: Record<string, unknown>) {
    this.logs.push({ contract, name, args, blockNumber: BigInt(block), logIndex: this.logs.length });
  }
}

export function merchantRaw(address: Address, status: number, profileURI?: string): RawMerchant {
  return {
    address,
    status,
    completedSales: 0,
    ratingCount: 0,
    ratingSum: 0,
    since: 1_700_000_000,
    profileHash: profileURI ? uriHash(profileURI) : (`0x${'0'.repeat(64)}` as Hex),
  };
}

export function listingRaw(id: number, uri: string, over: Partial<RawListing> = {}): RawListing {
  return {
    id,
    seller: SELLER,
    kind: 0,
    status: 0,
    paymentId: 1,
    hasProduct: false,
    nftEscrowed: false,
    stock: 5,
    openOrders: 0,
    createdAt: 1_700_000_000 + id,
    price: 10n * 10n ** 18n,
    productTokenId: 0n,
    metadataHash: uriHash(uri),
    available: true,
    cleanVerified: false,
    ...over,
  };
}

export function orderRaw(id: number, listingId: number, over: Partial<RawOrder> = {}): RawOrder {
  return {
    id,
    listingId,
    buyer: BUYER,
    seller: SELLER,
    amount: 10n * 10n ** 18n,
    qty: 1,
    feeBps: 200,
    porBps: 0,
    paymentId: 1,
    status: 0,
    rated: false,
    deadline: 1_800_000_000,
    ...over,
  };
}
