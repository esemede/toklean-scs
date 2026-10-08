import { concatBytes } from '../bytes.ts';

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export const json = (data: unknown, init: ResponseInit = {}, cache = 'no-store'): Response =>
  new Response(JSON.stringify(data), {
    ...init,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': cache, 'x-content-type-options': 'nosniff', ...init.headers },
  });

export const errorResponse = (e: ApiError): Response => json({ error: { code: e.code, message: e.message, details: e.details } }, { status: e.status });

/** Lee el cuerpo con tope de tamaño (rechaza apenas lo supera, sin cargarlo entero). */
export async function readBody(req: Request, maxBytes: number): Promise<Uint8Array> {
  const declared = Number(req.headers.get('content-length') ?? 0);
  if (declared > maxBytes) throw new ApiError(413, 'too_large', `El cuerpo supera ${maxBytes} bytes`);
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new ApiError(413, 'too_large', `El cuerpo supera ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  return concatBytes(chunks);
}

export function corsHeaders(origin: string | null, allowed: string[]): Record<string, string> {
  const any = allowed.includes('*');
  if (!origin || (!any && !allowed.includes(origin))) return {};
  return {
    'access-control-allow-origin': any ? '*' : origin,
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type',
    'access-control-max-age': '86400',
    vary: 'origin',
  };
}
