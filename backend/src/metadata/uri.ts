/** Resolución segura de URIs de metadata e imágenes: sólo ipfs://, este backend y hosts permitidos. */
export interface UriPolicy {
  /** Gateway HTTP de IPFS (con barra final). */
  gateway: string;
  /** URL pública de este backend. */
  baseUrl: string;
  /** Hosts https adicionales permitidos. */
  allowedHosts: string[];
}

export type ResolvedUri = { kind: 'ipfs' | 'http'; url: string };

const IPFS = /^ipfs:\/\/([A-Za-z0-9]{46,100})(\/[^\s]*)?$/;

/** URL https/http descargable, o `null` si la URI no está permitida. */
export function resolveUri(uri: string, policy: UriPolicy): ResolvedUri | null {
  const ipfs = IPFS.exec(uri);
  if (ipfs) {
    const path = ipfs[2] ?? '';
    return { kind: 'ipfs', url: `${policy.gateway.replace(/\/?$/, '/')}${ipfs[1]}${path}` };
  }
  let u: URL;
  try {
    u = new URL(uri);
  } catch {
    return null;
  }
  if (u.username || u.password) return null;
  const own = new URL(policy.baseUrl);
  const isOwn = u.origin === own.origin;
  if (isOwn) return { kind: 'http', url: u.toString() };
  if (u.protocol !== 'https:') return null;
  if (!policy.allowedHosts.includes(u.host)) return null;
  return { kind: 'http', url: u.toString() };
}
