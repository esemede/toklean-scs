import { createHash } from 'node:crypto';
import { z } from 'zod';

export const CATEGORIES = [
  'home',
  'garden',
  'fashion',
  'electronics',
  'packaging',
  'food',
  'services',
  'education',
  'other',
] as const;
export type Category = (typeof CATEGORIES)[number];

/**
 * Forma de una URI de imagen: `ipfs://<cid>[/ruta]` o `http(s)://...`. Nada más (ni data:, javascript:, file:).
 * Qué hosts se aceptan lo decide `resolveUri` según la configuración (http sólo para este backend en desarrollo).
 */
export const MEDIA_URI = /^(ipfs:\/\/[A-Za-z0-9]{46,100}(\/[^\s]*)?|https?:\/\/[^\s]+)$/;

const mediaUri = z.string().max(256).regex(MEDIA_URI, 'URI no permitida (usa ipfs:// o https://)');
const text = (min: number, max: number) => z.string().trim().min(min).max(max);

export const listingMetadataSchema = z.strictObject({
  schema: z.literal('toklean.listing/1'),
  name: text(1, 120),
  description: text(1, 2000),
  image: mediaUri,
  images: z.array(mediaUri).max(6).optional(),
  category: z.enum(CATEGORIES),
  tags: z.array(text(1, 30)).max(8).optional(),
  condition: z.enum(['new', 'refurbished']).optional(),
  sustainability: z
    .strictObject({
      recycledContentPct: z.number().min(0).max(100).optional(),
      co2eKg: z.number().min(0).max(1_000_000).optional(),
      certifications: z.array(text(1, 60)).max(10).optional(),
    })
    .optional(),
  shipping: z
    .strictObject({
      regions: z.array(text(1, 40)).max(20),
      days: z.number().int().min(0).max(120).optional(),
      carbonOffset: z.boolean().optional(),
    })
    .optional(),
});
export type ListingMetadata = z.infer<typeof listingMetadataSchema>;

export const merchantProfileSchema = z.strictObject({
  schema: z.literal('toklean.merchant/1'),
  name: text(1, 80),
  description: text(1, 1000).optional(),
  country: z.string().regex(/^[A-Z]{2}$/, 'código ISO-3166 alfa-2 en mayúsculas').optional(),
  logo: mediaUri.optional(),
  website: z.string().max(200).regex(/^https:\/\/[^\s]+$/).optional(),
  contact: text(1, 120).optional(),
});
export type MerchantProfile = z.infer<typeof merchantProfileSchema>;

export type MetadataKind = 'listing' | 'merchant';
export const schemaFor = { listing: listingMetadataSchema, merchant: merchantProfileSchema } as const;

/** JSON con claves ordenadas: el mismo contenido siempre produce los mismos bytes (y el mismo hash). */
export function canonicalize(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalize(v)}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

export const sha256Hex = (data: Uint8Array | string) => createHash('sha256').update(data).digest('hex');
