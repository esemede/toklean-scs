import { parseUnits } from 'viem';
import { z } from 'zod';
import { CATEGORIES } from '../metadata/schema.ts';
import type { UriPolicy } from '../metadata/uri.ts';
import type { IndexState, ListingRecord } from '../types.ts';
import { toListingDto } from './dto.ts';

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/, 'dirección inválida');
const ether = z.string().regex(/^\d{1,30}(\.\d{1,18})?$/, 'monto inválido (ej. 12.5)');
const flag = z.enum(['true', 'false']).transform((v) => v === 'true');

export const listingsQuery = z.object({
  q: z.string().trim().max(100).optional(),
  category: z.enum(CATEGORIES).optional(),
  kind: z.enum(['product', 'service']).optional(),
  payment: z.coerce.number().int().min(1).max(3).optional(),
  seller: address.optional(),
  /** Sólo productos limpios certificados. */
  clean: flag.optional(),
  /** `true` (por defecto): sólo comprables ahora; `false`: también agotadas, pausadas y cerradas. */
  available: flag.default(true),
  minPrice: ether.optional(),
  maxPrice: ether.optional(),
  sort: z.enum(['new', 'priceAsc', 'priceDesc', 'rating']).default('new'),
  limit: z.coerce.number().int().min(1).max(50).default(24),
  cursor: z.string().regex(/^\d{1,9}$/).optional(),
});
export type ListingsQuery = z.infer<typeof listingsQuery>;

export const ordersQuery = z
  .object({
    buyer: address.optional(),
    seller: address.optional(),
    status: z.enum(['paid', 'shipped', 'completed', 'refunded', 'disputed', 'resolved']).optional(),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    cursor: z.string().regex(/^\d{1,9}$/).optional(),
  })
  .refine((q) => q.buyer || q.seller, { message: 'indica buyer o seller' });

const norm = (s: string) => s.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();

function matchesText(l: ListingRecord, state: IndexState, q: string): boolean {
  const meta = l.metadata;
  const seller = state.merchants[l.seller.toLowerCase()]?.profile?.name ?? '';
  const hay = norm([meta?.name, meta?.description, ...(meta?.tags ?? []), seller].filter(Boolean).join(' '));
  return norm(q)
    .split(/\s+/)
    .filter(Boolean)
    .every((word) => hay.includes(word));
}

export interface ListingsPage {
  items: ReturnType<typeof toListingDto>[];
  total: number;
  nextCursor: string | null;
  facets: { category: Record<string, number>; kind: Record<string, number> };
}

export function searchListings(state: IndexState, q: ListingsQuery, policy: UriPolicy): ListingsPage {
  const min = q.minPrice ? parseUnits(q.minPrice, 18) : undefined;
  const max = q.maxPrice ? parseUnits(q.maxPrice, 18) : undefined;

  // Todo filtro salvo la categoría: sirve para contar las categorías disponibles.
  const base = Object.values(state.listings).filter((l) => {
    if (l.metadataStatus !== 'ok') return false;
    if (q.available && !l.available) return false;
    if (q.kind && l.kind !== q.kind) return false;
    if (q.payment && l.paymentId !== q.payment) return false;
    if (q.seller && l.seller.toLowerCase() !== q.seller.toLowerCase()) return false;
    if (q.clean && !l.cleanVerified) return false;
    const price = BigInt(l.price);
    if (min !== undefined && price < min) return false;
    if (max !== undefined && price > max) return false;
    if (q.q && !matchesText(l, state, q.q)) return false;
    return true;
  });

  const facets = { category: {} as Record<string, number>, kind: {} as Record<string, number> };
  for (const l of base) {
    const c = l.metadata?.category ?? 'other';
    facets.category[c] = (facets.category[c] ?? 0) + 1;
    facets.kind[l.kind] = (facets.kind[l.kind] ?? 0) + 1;
  }

  const filtered = q.category ? base.filter((l) => l.metadata?.category === q.category) : base;
  const rating = (l: ListingRecord) => state.merchants[l.seller.toLowerCase()]?.ratingAvg ?? 0;
  const sorters: Record<ListingsQuery['sort'], (a: ListingRecord, b: ListingRecord) => number> = {
    new: (a, b) => b.id - a.id,
    priceAsc: (a, b) => (BigInt(a.price) < BigInt(b.price) ? -1 : BigInt(a.price) > BigInt(b.price) ? 1 : b.id - a.id),
    priceDesc: (a, b) => (BigInt(a.price) > BigInt(b.price) ? -1 : BigInt(a.price) < BigInt(b.price) ? 1 : b.id - a.id),
    rating: (a, b) => rating(b) - rating(a) || b.id - a.id,
  };
  const sorted = [...filtered].sort(sorters[q.sort]);

  const offset = q.cursor ? Number(q.cursor) : 0;
  const slice = sorted.slice(offset, offset + q.limit);
  return {
    items: slice.map((l) => toListingDto(l, state, policy)),
    total: sorted.length,
    nextCursor: offset + q.limit < sorted.length ? String(offset + q.limit) : null,
    facets,
  };
}
