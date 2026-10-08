import { keccak256, toBytes, type Address } from 'viem';
import { z } from 'zod';
import { AuthError, RateLimiter, verifyUploadAuth, type UploadKind } from '../auth.ts';
import type { ChainReader } from '../indexer/chain.ts';
import type { Indexer } from '../indexer/indexer.ts';
import { canonicalize, schemaFor, sha256Hex, type MetadataKind } from '../metadata/schema.ts';
import type { ObjectStore } from '../metadata/object-store.ts';
import { resolveUri, type UriPolicy } from '../metadata/uri.ts';
import { ApiError } from './http.ts';

export const MAX_MEDIA_BYTES = 2 * 1024 * 1024;
export const MAX_METADATA_BYTES = 32 * 1024;
export const MEDIA_TYPES = ['image/png', 'image/jpeg', 'image/webp'] as const;

/** Tipo real según los primeros bytes (el `Content-Type` del cliente no es de fiar). SVG se rechaza: puede traer scripts. */
export function sniffImage(b: Uint8Array): (typeof MEDIA_TYPES)[number] | null {
  const startsWith = (sig: number[], at = 0) => sig.every((v, i) => b[at + i] === v);
  if (startsWith([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'image/png';
  if (startsWith([0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (startsWith([0x52, 0x49, 0x46, 0x46]) && startsWith([0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp';
  return null;
}

export interface UploadDeps {
  indexer: Indexer;
  chain: ChainReader;
  store: ObjectStore;
  policy: UriPolicy;
  perAddress: RateLimiter;
  global: RateLimiter;
  now: () => number;
}

async function authenticate(deps: UploadDeps, req: Request, kind: UploadKind, body: Uint8Array): Promise<Address> {
  const now = deps.now();
  if (!deps.global.take('*', now)) throw new ApiError(429, 'rate_limited', 'El servicio de subidas está saturado, intenta más tarde');
  let address: Address;
  try {
    address = await verifyUploadAuth(req.headers.get('authorization'), kind, sha256Hex(body), now);
  } catch (e) {
    if (e instanceof AuthError) throw new ApiError(401, `auth_${e.code}`, e.message);
    throw e;
  }
  if (!deps.perAddress.take(address.toLowerCase(), now)) {
    throw new ApiError(429, 'rate_limited', 'Superaste el máximo de subidas por hora para esta cuenta');
  }
  return address;
}

/** Imagen de producto o logo: PNG, JPEG o WebP de hasta 2 MB, firmada por la cuenta que sube. */
export async function uploadMedia(deps: UploadDeps, req: Request, body: Uint8Array) {
  if (body.byteLength === 0) throw new ApiError(400, 'empty_body', 'El cuerpo está vacío');
  const type = sniffImage(body);
  if (!type) throw new ApiError(415, 'unsupported_media', 'Sólo PNG, JPEG o WebP');
  await authenticate(deps, req, 'media', body);
  const stored = await deps.store.put('media', body, type);
  return { uri: stored.uri, id: stored.id, contentType: type, bytes: body.byteLength, durable: deps.store.durable };
}

const kindQuery = z.enum(['listing', 'merchant']);

/**
 * Metadata de una publicación o perfil de comercio: se valida contra el esquema, se canonicaliza y se guarda.
 * Devuelve la URI para usar en `createListing` / `applyAsMerchant` y su `keccak256` (lo que queda on-chain).
 */
export async function uploadMetadata(deps: UploadDeps, req: Request, kindParam: string | null, body: Uint8Array) {
  const kind = kindQuery.safeParse(kindParam);
  if (!kind.success) throw new ApiError(400, 'invalid_kind', 'kind debe ser listing o merchant');
  const address = await authenticate(deps, req, 'metadata', body);

  let json: unknown;
  try {
    json = JSON.parse(new TextDecoder().decode(body));
  } catch {
    throw new ApiError(400, 'invalid_json', 'El cuerpo no es JSON válido');
  }
  const parsed = schemaFor[kind.data as MetadataKind].safeParse(json);
  if (!parsed.success) {
    throw new ApiError(422, 'invalid_metadata', 'La metadata no cumple el esquema', parsed.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })));
  }

  const data = parsed.data as Record<string, unknown>;
  const media = [data.image, data.logo, ...((data.images as string[] | undefined) ?? [])].filter((u): u is string => typeof u === 'string');
  for (const uri of media) {
    if (!resolveUri(uri, deps.policy)) throw new ApiError(422, 'invalid_media_uri', `Imagen en un host no permitido: ${uri.slice(0, 80)}`);
  }

  if (kind.data === 'listing') {
    const known = deps.indexer.state.merchants[address.toLowerCase()];
    const status = known?.status === 'approved' ? 'approved' : ((await deps.chain.readMerchants([address]))[0]?.status === 2 ? 'approved' : 'other');
    if (status !== 'approved') throw new ApiError(403, 'not_merchant', 'Sólo los comercios aprobados pueden publicar');
  }

  const canonical = new TextEncoder().encode(canonicalize(parsed.data));
  if (canonical.byteLength > MAX_METADATA_BYTES) throw new ApiError(413, 'too_large', 'La metadata es demasiado grande');
  const stored = await deps.store.put('metadata', canonical, 'application/json');
  return { uri: stored.uri, uriHash: keccak256(toBytes(stored.uri)), id: stored.id, durable: deps.store.durable };
}
