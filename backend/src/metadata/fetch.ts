import { concatBytes } from '../bytes.ts';
import { resolveUri, type UriPolicy } from './uri.ts';

export class MetadataFetchError extends Error {
  constructor(
    message: string,
    /** `permanent`: reintentar no sirve (URI no permitida, JSON roto, demasiado grande). */
    readonly permanent: boolean,
  ) {
    super(message);
    this.name = 'MetadataFetchError';
  }
}

export interface FetcherOptions {
  policy: UriPolicy;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  maxBytes?: number;
}

export type JsonFetcher = (uri: string) => Promise<unknown>;

/** Descarga un JSON respetando la política de URIs, un tope de tamaño y un tiempo máximo. */
export function createJsonFetcher({ policy, fetchImpl = fetch, timeoutMs = 8_000, maxBytes = 64 * 1024 }: FetcherOptions): JsonFetcher {
  return async (uri) => {
    const resolved = resolveUri(uri, policy);
    if (!resolved) throw new MetadataFetchError(`URI no permitida: ${uri.slice(0, 80)}`, true);

    let res: Response;
    try {
      res = await fetchImpl(resolved.url, { signal: AbortSignal.timeout(timeoutMs), redirect: 'manual', headers: { accept: 'application/json' } });
    } catch (e) {
      throw new MetadataFetchError(`no se pudo descargar: ${(e as Error).message}`, false);
    }
    // Sin seguir redirecciones (`manual`: Workers no admite `error`). Un 3xx no es contenido válido.
    if (res.status >= 300 && res.status < 400) throw new MetadataFetchError(`redirección HTTP ${res.status} no permitida`, true);
    if (!res.ok) {
      // 404 (aún no propagado), 429 y 5xx son transitorios; el resto de 4xx no mejora reintentando.
      const transient = res.status === 404 || res.status === 429 || res.status >= 500;
      throw new MetadataFetchError(`HTTP ${res.status}`, !transient);
    }
    const declared = Number(res.headers.get('content-length') ?? 0);
    if (declared > maxBytes) throw new MetadataFetchError('respuesta demasiado grande', true);

    const reader = res.body?.getReader();
    if (!reader) throw new MetadataFetchError('respuesta vacía', false);
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new MetadataFetchError('respuesta demasiado grande', true);
      }
      chunks.push(value);
    }
    try {
      return JSON.parse(new TextDecoder().decode(concatBytes(chunks)));
    } catch {
      throw new MetadataFetchError('no es JSON válido', true);
    }
  };
}
