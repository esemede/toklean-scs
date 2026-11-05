import { z } from 'zod';

const csv = z
  .string()
  .optional()
  .transform((v) =>
    (v ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  );

const bool = z
  .enum(['true', 'false'])
  .optional()
  .transform((v) => v === 'true');

/** Forma de la configuración (la comparten el servidor Node y el Worker). */
export const configSchema = z.object({
  /** RPC de la red (Sepolia, anvil...). */
  RPC_URL: z.url(),
  CHAIN_ID: z.coerce.number().int().positive(),
  /** deployments/<chainId>.json generado por los scripts de Foundry. */
  DEPLOYMENTS_FILE: z.string().min(1),
  HOST: z.string().default('127.0.0.1'),
  PORT: z.coerce.number().int().min(0).max(65535).default(8787),
  /** Estado del indexador y archivos subidos (modo sin Pinata). */
  DATA_DIR: z.string().default('./.data'),
  /** URL pública del backend: se usa para los enlaces de los archivos que guarda localmente. */
  PUBLIC_BASE_URL: z.string().optional(),
  /** Con JWT de Pinata los archivos se fijan en IPFS; sin él se guardan en DATA_DIR (sólo desarrollo). */
  PINATA_JWT: z.string().optional(),
  IPFS_GATEWAY: z.string().default('https://gateway.pinata.cloud/ipfs/'),
  /** Hosts https adicionales desde los que se aceptan imágenes y metadata (además de ipfs:// y este backend). */
  ALLOWED_HOSTS: csv,
  /** Orígenes CORS permitidos ('*' = cualquiera; en producción lista el dominio del frontend). */
  CORS_ORIGINS: z.string().default('*').transform((v) => v.split(',').map((s) => s.trim()).filter(Boolean)),
  CONFIRMATIONS: z.coerce.number().int().min(0).max(64).default(2),
  POLL_INTERVAL_MS: z.coerce.number().int().min(500).default(10_000),
  LOG_CHUNK_BLOCKS: z.coerce.number().int().min(10).default(2_000),
  /** Subidas por hora y por cuenta. */
  UPLOADS_PER_HOUR: z.coerce.number().int().min(1).default(60),
  /** Clave del keeper (opcional): libera pedidos vencidos y retira fondos acreditados por cuenta de sus dueños. */
  KEEPER_PRIVATE_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/).optional(),
  KEEPER_AUTO_RELEASE: bool,
  KEEPER_AUTO_WITHDRAW: bool,
  KEEPER_INTERVAL_MS: z.coerce.number().int().min(1_000).default(60_000),
});

export type Config = z.infer<typeof configSchema>;

export function loadConfig(env: Record<string, string | undefined> = process.env): Config {
  const parsed = configSchema.safeParse(env);
  if (!parsed.success) {
    const detail = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ');
    throw new Error(`Configuración inválida: ${detail}`);
  }
  return parsed.data;
}

export const publicBaseUrl = (c: Config) => (c.PUBLIC_BASE_URL ?? `http://localhost:${c.PORT}`).replace(/\/$/, '');
