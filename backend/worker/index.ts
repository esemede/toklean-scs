/**
 * Backend del marketplace como Cloudflare Worker (plan gratuito). Mismo núcleo que `src/server.ts` (Node):
 *  - `fetch`: la API pública (catálogo, pedidos, subidas firmadas). Lee el índice desde D1 con una caché de pocos segundos.
 *  - `scheduled` (cron cada minuto): indexa los bloques nuevos, descarga la metadata pendiente y, si hay keeper,
 *    libera pedidos vencidos y empuja los fondos a sus dueños.
 */
import { createPublicClient, createWalletClient, http, type PublicClient } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createApi } from '../src/api/router.ts';
import { RateLimiter } from '../src/auth.ts';
import { viemChainReader, type ChainReader } from '../src/indexer/chain.ts';
import { Indexer } from '../src/indexer/indexer.ts';
import { keeperTick, viemTxSender, type TxSender } from '../src/keeper.ts';
import { viemRawLogReader } from '../src/logs/chain.ts';
import { LogIndex } from '../src/logs/log-index.ts';
import { createJsonFetcher } from '../src/metadata/fetch.ts';
import type { ObjectStore, StoredObject } from '../src/metadata/object-store.ts';
import { PinataStore } from '../src/metadata/pinata.ts';
import type { UriPolicy } from '../src/metadata/uri.ts';
import { D1LogStore } from './d1-log-store.ts';
import { D1SnapshotStore } from './d1-snapshot.ts';
import { readConfig, type Env } from './env.ts';

/** Cuánto tiempo puede reutilizarse el índice leído desde D1 antes de releerlo. */
const REFRESH_MS = 15_000;

interface App {
  indexer: Indexer;
  api: (req: Request) => Promise<Response>;
  chain: ChainReader;
  tx?: TxSender;
  logIndex?: LogIndex;
  keeper: { release: boolean; withdraw: boolean };
  loadedAt: number;
}

/** Sin Pinata no hay dónde guardar archivos: las subidas responden error en vez de perderse. */
const unavailableStore: ObjectStore = {
  durable: false,
  async put(): Promise<StoredObject> {
    throw new Error('almacenamiento de archivos no configurado (falta el secreto PINATA_JWT)');
  },
  async get() {
    return null;
  },
};

/** Una instancia por isolate: las peticiones y el cron que caen en el mismo isolate comparten el índice en memoria. */
let app: App | undefined;

function build(env: Env): App {
  const cfg = readConfig(env);
  const client: PublicClient = createPublicClient({ transport: http(cfg.rpcUrl, { batch: true }) });
  const chain = viemChainReader(client, cfg.deployment);
  // En Workers las URIs http sólo son propias del backend en desarrollo; los archivos viven en IPFS.
  const policy: UriPolicy = { gateway: cfg.gateway, baseUrl: 'https://backend.invalid', allowedHosts: cfg.allowedHosts };
  const indexer = new Indexer({
    chain,
    chainId: cfg.deployment.chainId,
    startBlock: cfg.deployment.marketplaceStartBlock,
    snapshots: new D1SnapshotStore(env.DB),
    fetchJson: createJsonFetcher({ policy }),
    policy,
    confirmations: cfg.confirmations,
    maxChunksPerRun: cfg.maxChunksPerRun,
    maxEnrichPerRun: cfg.maxEnrichPerRun,
    log: (m) => console.log(m),
  });

  let tx: TxSender | undefined;
  if (cfg.keeperKey) {
    const wallet = createWalletClient({ account: privateKeyToAccount(cfg.keeperKey), transport: http(cfg.rpcUrl, { batch: true }) });
    tx = viemTxSender(client, wallet, cfg.deployment.ToKleanMarketplace, false);
  }

  const logIndex = cfg.logs
    ? new LogIndex({
        reader: viemRawLogReader(client, cfg.logs.addresses),
        store: new D1LogStore(env.DB),
        startBlock: cfg.logs.startBlock,
        addresses: cfg.logs.addresses,
        confirmations: cfg.confirmations,
        maxChunksPerRun: cfg.maxChunksPerRun,
        log: (m) => console.log(m),
      })
    : undefined;

  const api = createApi({
    indexer,
    chain,
    store: cfg.pinataJwt ? new PinataStore(cfg.pinataJwt, fetch, cfg.pinataApiUrl) : unavailableStore,
    deployment: cfg.deployment,
    policy,
    corsOrigins: cfg.corsOrigins,
    uploadsPerHour: cfg.uploadsPerHour,
    logs: logIndex,
    // Límite de subidas por isolate (no global): suficiente para frenar abusos simples.
    now: () => Math.floor(Date.now() / 1000),
  });
  return { indexer, api, chain, tx, logIndex, keeper: { release: cfg.keeperAutoRelease, withdraw: cfg.keeperAutoWithdraw }, loadedAt: 0 };
}

async function getApp(env: Env): Promise<App> {
  if (!app) app = build(env);
  return app;
}

/** Recarga el índice si quedó viejo (otra instancia pudo indexar) y no hay una sincronización en curso aquí. */
async function fresh(a: App): Promise<void> {
  if (a.indexer.busy || Date.now() - a.loadedAt < REFRESH_MS) return;
  await a.indexer.init();
  a.loadedAt = Date.now();
}

/** Índice del marketplace (y keeper). */
async function indexMarketplace(a: App): Promise<void> {
  // Partimos del estado guardado (por si la API lo actualizó desde otra instancia) antes de indexar.
  await a.indexer.init();
  a.loadedAt = Date.now();
  const r = await a.indexer.sync();
  console.log(`indexado hasta ${r.to} (cabeza ${r.head}, ${r.events} eventos)`);

  if (a.tx && a.indexer.ready && (a.keeper.release || a.keeper.withdraw)) {
    const report = await keeperTick({
      indexer: a.indexer,
      chain: a.chain,
      tx: a.tx,
      autoRelease: a.keeper.release,
      autoWithdraw: a.keeper.withdraw,
      maxActions: 5,
      log: (m) => console.log(m),
    });
    for (const e of report.errors) console.log(`keeper: ${e}`);
    if (report.released.length || report.withdrawn.length) await a.indexer.persist();
  }
}

/** Cada parte corre aunque la otra falle (un RPC que falla en una no debe frenar a la otra); los errores se relanzan al final. */
async function tick(env: Env): Promise<void> {
  const a = await getApp(env);
  const errors: unknown[] = [];
  const run = async (name: string, job: () => Promise<void>) => {
    try {
      await job();
    } catch (e) {
      console.log(`${name}: error ${e instanceof Error ? e.message : String(e)}`);
      errors.push(e);
    }
  };
  await run('marketplace', () => indexMarketplace(a));
  if (a.logIndex) {
    const logIndex = a.logIndex;
    await run('logs', async () => {
      const r = await logIndex.sync();
      console.log(`logs indexados hasta ${r.to} (cabeza ${r.head}, ${r.logs} nuevos)`);
    });
  }
  if (errors.length > 0) throw new AggregateError(errors, `${errors.length} tarea(s) del cron fallaron`);
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const a = await getApp(env);
    await fresh(a);
    return a.api(req);
  },

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(tick(env));
  },
};

export { RateLimiter };
