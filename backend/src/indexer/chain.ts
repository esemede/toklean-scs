import type { Address, Hex, PublicClient } from 'viem';
import { merchantRegistryAbi, catalogAbi, marketplaceAbi } from './abis.ts';
import type { Deployment } from '../deployments.ts';

export type ContractName = 'registry' | 'catalog' | 'market';

export interface ChainLog {
  contract: ContractName;
  name: string;
  args: Record<string, unknown>;
  blockNumber: bigint;
  logIndex: number;
}

export interface RawMerchant {
  address: Address;
  status: number;
  completedSales: number;
  ratingCount: number;
  ratingSum: number;
  since: number;
  profileHash: Hex;
}

export interface RawListing {
  id: number;
  seller: Address;
  kind: number;
  status: number;
  paymentId: number;
  hasProduct: boolean;
  nftEscrowed: boolean;
  stock: number;
  openOrders: number;
  createdAt: number;
  price: bigint;
  productTokenId: bigint;
  metadataHash: Hex;
  available: boolean;
  cleanVerified: boolean;
}

export interface RawOrder {
  id: number;
  listingId: number;
  buyer: Address;
  seller: Address;
  amount: bigint;
  qty: number;
  feeBps: number;
  porBps: number;
  paymentId: number;
  status: number;
  rated: boolean;
  deadline: number;
}

/** Todo lo que el indexador necesita de la cadena: permite probarlo sin nodo. */
export interface ChainReader {
  getBlockNumber(): Promise<bigint>;
  /** Eventos de los tres contratos en [from, to], ordenados por bloque e índice. */
  getLogs(from: bigint, to: bigint): Promise<ChainLog[]>;
  readMerchants(addresses: Address[]): Promise<RawMerchant[]>;
  readListings(ids: number[]): Promise<RawListing[]>;
  readOrders(ids: number[]): Promise<RawOrder[]>;
  readClaimable(account: Address): Promise<Record<number, bigint>>;
}

const CONTRACTS = [
  { key: 'registry', abi: merchantRegistryAbi, pick: (d: Deployment) => d.ToKleanMerchantRegistry },
  { key: 'catalog', abi: catalogAbi, pick: (d: Deployment) => d.ToKleanCatalog },
  { key: 'market', abi: marketplaceAbi, pick: (d: Deployment) => d.ToKleanMarketplace },
] as const;

export function viemChainReader(client: PublicClient, deployment: Deployment): ChainReader {
  const registry = deployment.ToKleanMerchantRegistry;
  const catalog = deployment.ToKleanCatalog;
  const market = deployment.ToKleanMarketplace;

  return {
    // viem cachea la altura ~4 s por defecto: el indexador necesita siempre la actual.
    getBlockNumber: () => client.getBlockNumber({ cacheTime: 0 }),

    async getLogs(from, to) {
      const out: ChainLog[] = [];
      for (const c of CONTRACTS) {
        const logs = await client.getContractEvents({
          address: c.pick(deployment),
          abi: c.abi,
          fromBlock: from,
          toBlock: to,
          strict: true,
        });
        for (const l of logs as unknown as { eventName: string; args: Record<string, unknown>; blockNumber: bigint; logIndex: number }[]) {
          out.push({ contract: c.key, name: l.eventName, args: l.args, blockNumber: l.blockNumber, logIndex: l.logIndex });
        }
      }
      return out.sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1));
    },

    async readMerchants(addresses) {
      return Promise.all(
        addresses.map(async (address) => {
          const m = await client.readContract({ address: registry, abi: merchantRegistryAbi, functionName: 'getMerchant', args: [address] });
          return {
            address,
            status: Number(m.status),
            completedSales: Number(m.completedSales),
            ratingCount: Number(m.ratingCount),
            ratingSum: Number(m.ratingSum),
            since: Number(m.since),
            profileHash: m.profileHash,
          };
        }),
      );
    },

    async readListings(ids) {
      return Promise.all(
        ids.map(async (id) => {
          const arg = BigInt(id);
          const [l, available, cleanVerified] = await Promise.all([
            client.readContract({ address: catalog, abi: catalogAbi, functionName: 'getListing', args: [arg] }),
            client.readContract({ address: catalog, abi: catalogAbi, functionName: 'isAvailable', args: [arg] }),
            client.readContract({ address: catalog, abi: catalogAbi, functionName: 'isCleanVerified', args: [arg] }),
          ]);
          return {
            id,
            seller: l.seller,
            kind: Number(l.kind),
            status: Number(l.status),
            paymentId: Number(l.paymentId),
            hasProduct: l.hasProduct,
            nftEscrowed: l.nftEscrowed,
            stock: Number(l.stock),
            openOrders: Number(l.openOrders),
            createdAt: Number(l.createdAt),
            price: l.price,
            productTokenId: l.productTokenId,
            metadataHash: l.metadataHash,
            available,
            cleanVerified,
          };
        }),
      );
    },

    async readOrders(ids) {
      return Promise.all(
        ids.map(async (id) => {
          const o = await client.readContract({ address: market, abi: marketplaceAbi, functionName: 'getOrder', args: [BigInt(id)] });
          return {
            id,
            listingId: Number(o.listingId),
            buyer: o.buyer,
            seller: o.seller,
            amount: o.amount,
            qty: Number(o.qty),
            feeBps: Number(o.feeBps),
            porBps: Number(o.porBps),
            paymentId: Number(o.paymentId),
            status: Number(o.status),
            rated: o.rated,
            deadline: Number(o.deadline),
          };
        }),
      );
    },

    async readClaimable(account) {
      const ids = [1, 2, 3];
      const values = await Promise.all(
        ids.map((id) => client.readContract({ address: market, abi: marketplaceAbi, functionName: 'claimable', args: [account, BigInt(id)] })),
      );
      return Object.fromEntries(ids.map((id, i) => [id, values[i]!]));
    },
  };
}
