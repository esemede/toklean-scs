import type { D1Database } from '@cloudflare/workers-types';
import { z } from 'zod';
import { parseDeployment, type Deployment } from '../src/deployment-schema.ts';

/** Bindings y variables del Worker (ver wrangler.toml). Los secretos se definen con `wrangler secret put`. */
export interface Env {
  DB: D1Database;
  /** Secreto: URL del RPC (puede llevar una API key). */
  RPC_URL: string;
  /** Secreto: JWT de Pinata. Sin él las subidas fallan (no hay disco donde guardarlas). */
  PINATA_JWT?: string;
  /** Opcional: base de la API de Pinata (sólo pruebas). */
  PINATA_API_URL?: string;
  /** Clave del keeper (opcional). */
  KEEPER_PRIVATE_KEY?: string;

  CHAIN_ID: string;
  MARKETPLACE_START_BLOCK: string;
  TOKLEAN_TOKEN: string;
  CIRCULAR_PRODUCT_NFT: string;
  MERCHANT_REGISTRY: string;
  CATALOG: string;
  MARKETPLACE: string;

  CORS_ORIGINS?: string;
  ALLOWED_HOSTS?: string;
  IPFS_GATEWAY?: string;
  CONFIRMATIONS?: string;
  UPLOADS_PER_HOUR?: string;
  MAX_CHUNKS_PER_RUN?: string;
  MAX_ENRICH_PER_RUN?: string;
  /** Contratos cuyos logs crudos se indexan para el frontend (coma). Requiere LOGS_START_BLOCK. */
  LOGS_ADDRESSES?: string;
  /** Primer bloque del índice de logs: antes de él no debe haber eventos que le interesen a la app. */
  LOGS_START_BLOCK?: string;
  KEEPER_AUTO_RELEASE?: string;
  KEEPER_AUTO_WITHDRAW?: string;
}

const csv = (v?: string) =>
  (v ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

const int = (v: string | undefined, fallback: number) => {
  const n = Number(v ?? fallback);
  if (!Number.isInteger(n) || n < 0) throw new Error(`variable numérica inválida: ${v}`);
  return n;
};

const envSchema = z.object({
  RPC_URL: z.url(),
  PINATA_JWT: z.string().optional(),
});

export interface WorkerConfig {
  rpcUrl: string;
  deployment: Deployment;
  pinataJwt?: string;
  pinataApiUrl?: string;
  keeperKey?: `0x${string}`;
  gateway: string;
  allowedHosts: string[];
  corsOrigins: string[];
  confirmations: number;
  uploadsPerHour: number;
  maxChunksPerRun: number;
  maxEnrichPerRun: number;
  keeperAutoRelease: boolean;
  keeperAutoWithdraw: boolean;
  /** Índice de logs crudos; `undefined` si no está configurado. */
  logs?: { addresses: `0x${string}`[]; startBlock: number };
}

export function readConfig(env: Env): WorkerConfig {
  const base = envSchema.parse({ RPC_URL: env.RPC_URL, PINATA_JWT: env.PINATA_JWT });
  const deployment = parseDeployment({
    chainId: int(env.CHAIN_ID, 0),
    ToKleanToken: env.TOKLEAN_TOKEN,
    CircularProductNFT: env.CIRCULAR_PRODUCT_NFT,
    ToKleanMerchantRegistry: env.MERCHANT_REGISTRY,
    ToKleanCatalog: env.CATALOG,
    ToKleanMarketplace: env.MARKETPLACE,
    marketplaceStartBlock: int(env.MARKETPLACE_START_BLOCK, 0),
  });
  return {
    rpcUrl: base.RPC_URL,
    deployment,
    pinataJwt: base.PINATA_JWT || undefined,
    pinataApiUrl: env.PINATA_API_URL || undefined,
    keeperKey: env.KEEPER_PRIVATE_KEY ? (env.KEEPER_PRIVATE_KEY as `0x${string}`) : undefined,
    gateway: env.IPFS_GATEWAY ?? 'https://gateway.pinata.cloud/ipfs/',
    allowedHosts: csv(env.ALLOWED_HOSTS),
    corsOrigins: csv(env.CORS_ORIGINS),
    confirmations: int(env.CONFIRMATIONS, 2),
    uploadsPerHour: int(env.UPLOADS_PER_HOUR, 60),
    maxChunksPerRun: int(env.MAX_CHUNKS_PER_RUN, 5),
    maxEnrichPerRun: int(env.MAX_ENRICH_PER_RUN, 20),
    keeperAutoRelease: env.KEEPER_AUTO_RELEASE === 'true',
    keeperAutoWithdraw: env.KEEPER_AUTO_WITHDRAW === 'true',
    logs: readLogs(env),
  };
}

function readLogs(env: Env): WorkerConfig['logs'] {
  const addresses = csv(env.LOGS_ADDRESSES);
  if (addresses.length === 0 && !env.LOGS_START_BLOCK) return undefined;
  if (addresses.length === 0 || !env.LOGS_START_BLOCK) throw new Error('LOGS_ADDRESSES y LOGS_START_BLOCK deben definirse juntas');
  for (const a of addresses) if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Error(`LOGS_ADDRESSES: dirección inválida ${a}`);
  return { addresses: addresses as `0x${string}`[], startBlock: int(env.LOGS_START_BLOCK, 0) };
}
