import { resolveUri, type UriPolicy } from '../metadata/uri.ts';
import type { IndexState, ListingRecord, MerchantRecord, OrderRecord } from '../types.ts';

export interface SellerDto {
  address: string;
  name: string | null;
  country: string | null;
  logoUrl: string | null;
  status: MerchantRecord['status'];
  ratingAvg: number;
  ratingCount: number;
  completedSales: number;
}

export function toSellerDto(address: string, m: MerchantRecord | undefined, policy: UriPolicy): SellerDto {
  return {
    address,
    name: m?.profile?.name ?? null,
    country: m?.profile?.country ?? null,
    logoUrl: m?.profile?.logo ? (resolveUri(m.profile.logo, policy)?.url ?? null) : null,
    status: m?.status ?? 'none',
    ratingAvg: m?.ratingAvg ?? 0,
    ratingCount: m?.ratingCount ?? 0,
    completedSales: m?.completedSales ?? 0,
  };
}

export function toListingDto(l: ListingRecord, state: IndexState, policy: UriPolicy) {
  const meta = l.metadata ?? null;
  const url = (uri: string | undefined) => (uri ? (resolveUri(uri, policy)?.url ?? null) : null);
  return {
    id: l.id,
    kind: l.kind,
    status: l.status,
    paymentId: l.paymentId,
    paymentSymbol: l.paymentSymbol,
    price: l.price,
    stock: l.stock,
    openOrders: l.openOrders,
    createdAt: l.createdAt,
    available: l.available,
    cleanVerified: l.cleanVerified,
    hasProduct: l.hasProduct,
    productTokenId: l.productTokenId ?? null,
    metadataStatus: l.metadataStatus,
    metadataURI: l.metadataURI ?? null,
    name: meta?.name ?? null,
    description: meta?.description ?? null,
    category: meta?.category ?? null,
    tags: meta?.tags ?? [],
    condition: meta?.condition ?? null,
    sustainability: meta?.sustainability ?? null,
    shipping: meta?.shipping ?? null,
    imageUrl: url(meta?.image),
    imageUrls: (meta ? [meta.image, ...(meta.images ?? [])] : []).map(url).filter((u): u is string => !!u),
    seller: toSellerDto(l.seller, state.merchants[l.seller.toLowerCase()], policy),
  };
}

export type ListingDto = ReturnType<typeof toListingDto>;

export function toOrderDto(o: OrderRecord, state: IndexState, policy: UriPolicy) {
  const listing = state.listings[o.listingId];
  const meta = listing?.metadata;
  return {
    ...o,
    listing: listing
      ? {
          id: listing.id,
          name: meta?.name ?? null,
          imageUrl: meta?.image ? (resolveUri(meta.image, policy)?.url ?? null) : null,
          hasProduct: listing.hasProduct,
          productTokenId: listing.productTokenId ?? null,
        }
      : null,
  };
}
