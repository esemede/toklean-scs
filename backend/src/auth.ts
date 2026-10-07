import { recoverMessageAddress, type Address, type Hex } from 'viem';

export type UploadKind = 'metadata' | 'media';

export class AuthError extends Error {
  constructor(
    readonly code: 'missing' | 'format' | 'expired' | 'signature',
    message: string,
  ) {
    super(message);
    this.name = 'AuthError';
  }
}

/** Mensaje que la wallet firma (EIP-191 `personal_sign`) para autorizar una subida concreta. */
export function uploadMessage(kind: UploadKind, sha256: string, timestamp: number): string {
  return `ToKlean marketplace upload\nkind: ${kind}\nsha256: ${sha256}\ntimestamp: ${timestamp}`;
}

export const authHeader = (address: Address, timestamp: number, signature: Hex) => `ToKlean ${address}.${timestamp}.${signature}`;

const HEADER = /^ToKlean (0x[0-9a-fA-F]{40})\.(\d{1,12})\.(0x[0-9a-fA-F]{130})$/;

/**
 * Verifica que la cuenta firmó esta subida (mismo contenido y hora reciente). Sólo prueba control de la
 * dirección: quién puede subir qué lo decide el llamador.
 */
export async function verifyUploadAuth(
  header: string | null,
  kind: UploadKind,
  sha256: string,
  nowSeconds: number,
  windowSeconds = 300,
): Promise<Address> {
  if (!header) throw new AuthError('missing', 'Falta el encabezado Authorization');
  const m = HEADER.exec(header);
  if (!m) throw new AuthError('format', 'Authorization debe ser "ToKlean <dirección>.<timestamp>.<firma>"');
  const [, claimed, ts, signature] = m as unknown as [string, Address, string, Hex];
  const timestamp = Number(ts);
  if (Math.abs(nowSeconds - timestamp) > windowSeconds) throw new AuthError('expired', 'La firma venció o el reloj está desfasado');

  let recovered: Address;
  try {
    recovered = await recoverMessageAddress({ message: uploadMessage(kind, sha256, timestamp), signature });
  } catch {
    throw new AuthError('signature', 'Firma inválida');
  }
  if (recovered.toLowerCase() !== claimed.toLowerCase()) throw new AuthError('signature', 'La firma no corresponde a la dirección');
  return recovered;
}

/** Ventana deslizante en memoria: máximo `limit` eventos por clave en la última hora. */
export class RateLimiter {
  private readonly hits = new Map<string, number[]>();
  constructor(
    private readonly limit: number,
    private readonly windowSeconds = 3600,
  ) {}

  /** Registra un intento. Devuelve false si la clave ya agotó su cuota. */
  take(key: string, nowSeconds: number): boolean {
    const recent = (this.hits.get(key) ?? []).filter((t) => nowSeconds - t < this.windowSeconds);
    if (recent.length >= this.limit) {
      this.hits.set(key, recent);
      return false;
    }
    recent.push(nowSeconds);
    this.hits.set(key, recent);
    if (this.hits.size > 10_000) this.prune(nowSeconds);
    return true;
  }

  private prune(now: number) {
    for (const [k, v] of this.hits) if (v.every((t) => now - t >= this.windowSeconds)) this.hits.delete(k);
  }
}
