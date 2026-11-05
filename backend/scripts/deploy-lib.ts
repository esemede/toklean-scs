/**
 * Funciones puras del despliegue en Cloudflare (`deploy-worker.ts`): parseo de la salida de wrangler, validación de
 * secretos y edición de wrangler.toml. Sin E/S para poder probarlas sin credenciales.
 */

export const DB_NAME = 'toklean-marketplace';
export const DB_PLACEHOLDER = 'REEMPLAZAR-CON-EL-ID-DE-D1';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PRIVATE_KEY = /^0x[0-9a-f]{64}$/i;

/** Extrae el primer JSON de una salida que puede traer avisos de wrangler antes (proxy, actualizaciones). */
export function parseJsonOutput(out: string): unknown {
  for (let i = 0; i < out.length; i++) {
    const c = out[i];
    if (c !== '[' && c !== '{') continue;
    try {
      return JSON.parse(out.slice(i));
    } catch {
      // no era el inicio del JSON (p. ej. un código ANSI "[33m"): seguir buscando
    }
  }
  throw new Error('la salida no contiene JSON');
}

/** UUID de la base D1 `name` dentro del resultado de `wrangler d1 list --json`; undefined si no existe. */
export function findDatabaseId(list: unknown, name: string): string | undefined {
  if (!Array.isArray(list)) return undefined;
  for (const item of list) {
    if (typeof item !== 'object' || item === null) continue;
    const row = item as Record<string, unknown>;
    if (row.name !== name) continue;
    for (const key of ['uuid', 'database_id', 'id']) {
      const v = row[key];
      if (typeof v === 'string' && UUID.test(v)) return v;
    }
  }
  return undefined;
}

/** Reemplaza el `database_id` de wrangler.toml. Falla si no hay ninguno que reemplazar. */
export function setDatabaseId(toml: string, id: string): string {
  if (!UUID.test(id)) throw new Error(`database_id inválido: ${id}`);
  const re = /^(\s*database_id\s*=\s*)"[^"]*"/m;
  if (!re.test(toml)) throw new Error('wrangler.toml no tiene database_id en [[d1_databases]]');
  return toml.replace(re, `$1"${id}"`);
}

/** Valor actual de `database_id` en wrangler.toml (puede ser el marcador de posición). */
export function currentDatabaseId(toml: string): string | undefined {
  return /^\s*database_id\s*=\s*"([^"]*)"/m.exec(toml)?.[1];
}

/** `CORS_ORIGINS` de wrangler.toml como lista, para recordar qué orígenes quedan autorizados. */
export function corsOrigins(toml: string): string[] {
  const raw = /^\s*CORS_ORIGINS\s*=\s*"([^"]*)"/m.exec(toml)?.[1] ?? '';
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/** URL pública del Worker: primero el archivo de salida de wrangler (ndjson) y, si no, la salida de texto. */
export function parseDeployUrl(outputFile: string, stdout: string): string | undefined {
  for (const line of outputFile.split('\n')) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line) as { type?: string; targets?: unknown };
      if (entry.type === 'deploy' && Array.isArray(entry.targets)) {
        const url = entry.targets.find((t): t is string => typeof t === 'string');
        if (url) return url.replace(/\/+$/, '');
      }
    } catch {
      // línea que no es JSON: ignorar
    }
  }
  return /https:\/\/[a-z0-9-]+(?:\.[a-z0-9-]+)*\.workers\.dev/i.exec(stdout)?.[0];
}

export interface SecretsResult {
  secrets: Record<string, string>;
  /** Secretos opcionales que no se definieron (sólo para informar). */
  skipped: string[];
}

/**
 * Secretos que se suben con el despliegue, tomados de variables de entorno (nunca por argumentos, para que no
 * queden en el historial del shell). `RPC_URL` es obligatoria: sin ella el Worker no puede leer la cadena.
 */
export function buildSecrets(env: Record<string, string | undefined>): SecretsResult {
  const secrets: Record<string, string> = {};
  const skipped: string[] = [];

  const rpc = env.RPC_URL?.trim();
  if (!rpc) throw new Error('falta la variable de entorno RPC_URL (o usa --keep-secrets para no tocar los secretos)');
  let url: URL;
  try {
    url = new URL(rpc);
  } catch {
    throw new Error('RPC_URL no es una URL válida');
  }
  if (url.protocol !== 'https:') throw new Error('RPC_URL debe ser https');
  secrets.RPC_URL = rpc;

  const pinata = env.PINATA_JWT?.trim();
  if (pinata) secrets.PINATA_JWT = pinata;
  else skipped.push('PINATA_JWT (sin ella las subidas de imágenes fallan)');

  const keeper = env.KEEPER_PRIVATE_KEY?.trim();
  if (keeper) {
    if (!PRIVATE_KEY.test(keeper)) throw new Error('KEEPER_PRIVATE_KEY debe ser 0x + 64 hex');
    secrets.KEEPER_PRIVATE_KEY = keeper;
  } else skipped.push('KEEPER_PRIVATE_KEY (el keeper queda desactivado)');

  return { secrets, skipped };
}
