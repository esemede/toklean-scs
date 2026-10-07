import type { Address } from 'viem';
import type { ListingMetadata, MerchantProfile } from './metadata/schema.ts';

/** Todo número que pueda superar 2^53 (wei, ids de NFT) viaja como string decimal. */
export type WeiString = string;

export const PAYMENT_SYMBOLS = { 1: 'TKN', 2: 'REC', 3: 'POR' } as const;
export type PaymentId = keyof typeof PAYMENT_SYMBOLS;

export const MERCHANT_STATUS = ['none', 'pending', 'approved', 'rejected', 'suspended'] as const;
export const LISTING_KIND = ['product', 'service'] as const;
export const LISTING_STATUS = ['active', 'paused', 'closed'] as const;
export const ORDER_STATUS = ['paid', 'shipped', 'completed', 'refunded', 'disputed', 'resolved'] as const;

export type MetadataStatus = 'ok' | 'pending' | 'invalid' | 'missing';

export interface MerchantRecord {
  address: Address;
  status: (typeof MERCHANT_STATUS)[number];
  completedSales: number;
  ratingCount: number;
  ratingSum: number;
  /** Promedio 0-5 con dos decimales (0 sin valoraciones). */
  ratingAvg: number;
  since: number;
  profileHash: `0x${string}`;
  profileURI?: string;
  profile?: MerchantProfile | null;
  profileStatus: MetadataStatus;
  profileFor?: `0x${string}`;
  profileAttempts: number;
  profileRetryAt: number;
}

export interface ListingRecord {
  id: number;
  seller: Address;
  kind: (typeof LISTING_KIND)[number];
  status: (typeof LISTING_STATUS)[number];
  paymentId: number;
  paymentSymbol: string;
  price: WeiString;
  stock: number;
  openOrders: number;
  createdAt: number;
  hasProduct: boolean;
  productTokenId?: string;
  nftEscrowed: boolean;
  metadataHash: `0x${string}`;
  metadataURI?: string;
  metadata?: ListingMetadata | null;
  metadataStatus: MetadataStatus;
  metadataFor?: `0x${string}`;
  metadataAttempts: number;
  metadataRetryAt: number;
  /** Producto limpio certificado ahora mismo (lo calcula el contrato). */
  cleanVerified: boolean;
  /** Se puede comprar ahora mismo (lo calcula el contrato). */
  available: boolean;
}

export interface OrderRecord {
  id: number;
  listingId: number;
  buyer: Address;
  seller: Address;
  amount: WeiString;
  qty: number;
  feeBps: number;
  porBps: number;
  paymentId: number;
  paymentSymbol: string;
  status: (typeof ORDER_STATUS)[number];
  rated: boolean;
  /** Paid: límite de envío; Shipped: liberación automática; Disputed: límite de resolución (segundos unix). */
  deadline: number;
}

export interface IndexState {
  version: 1;
  chainId: number;
  /** Último bloque procesado. */
  lastBlock: number;
  merchants: Record<string, MerchantRecord>;
  listings: Record<string, ListingRecord>;
  orders: Record<string, OrderRecord>;
  /** Cuentas con fondos posiblemente acreditados pendientes de retiro (lo usa el keeper). */
  pendingWithdrawals: Address[];
}

export const emptyState = (chainId: number, startBlock: number): IndexState => ({
  version: 1,
  chainId,
  lastBlock: Math.max(0, startBlock - 1),
  merchants: {},
  listings: {},
  orders: {},
  pendingWithdrawals: [],
});
