import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { Readable } from 'node:stream';
import { pathToFileURL } from 'node:url';
import { createPublicClient, createWalletClient, defineChain, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createApi } from './api/router.ts';
import { loadConfig, publicBaseUrl, type Config } from './config.ts';
import { loadDeployment } from './deployments.ts';
import { viemChainReader } from './indexer/chain.ts';
import { Indexer } from './indexer/indexer.ts';
import { FileSnapshotStore } from './indexer/snapshot.ts';
import { keeperTick, viemTxSender } from './keeper.ts';
import { createJsonFetcher } from './metadata/fetch.ts';
import { createStore } from './metadata/store.ts';
import type { UriPolicy } from './metadata/uri.ts';

/** Adapta un servidor `node:http` a un handler Fetch-API. */
function toNodeListener(handler: (req: Request) => Promise<Response>) {
  return async (nodeReq: IncomingMessage, nodeRes: ServerResponse) => {
    try {
      const host = nodeReq.headers.host ?? 'localhost';
      const hasBody = nodeReq.method !== 'GET' && nodeReq.method !== 'HEAD';
      const req = new Request(`http://${host}${nodeReq.url ?? '/'}`, {
        method: nodeReq.method,
        headers: nodeReq.headers as Record<string, string>,
        body: hasBody ? (Readable.toWeb(nodeReq) as ReadableStream) : undefined,
        duplex: 'half',
      } as RequestInit);
      const res = await handler(req);
      nodeRes.writeHead(res.status, Object.fromEntries(res.headers));
      nodeRes.end(new Uint8Array(await res.arrayBuffer()));
    } catch (e) {
      console.error('[server] error', e);
      if (!nodeRes.headersSent) nodeRes.writeHead(500, { 'content-type': 'application/json' });
      nodeRes.end('{"error":{"code":"internal","message":"Error interno"}}');
    }
  };
}

export interface RunningServer {
  server: Server;
  indexer: Indexer;
  port: number;
  stop(): Promise<void>;
}

export async function start(config: Config, log: (m: string) => void = console.log): Promise<RunningServer> {
  const deployment = loadDeployment(config.DEPLOYMENTS_FILE, config.CHAIN_ID);
  const chain = defineChain({
    id: config.CHAIN_ID,
    name: `chain-${config.CHAIN_ID}`,
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [config.RPC_URL] } },
  });
  const client = createPublicClient({ chain, transport: http(config.RPC_URL) });

  const baseUrl = publicBaseUrl(config);
  const policy: UriPolicy = { gateway: config.IPFS_GATEWAY, baseUrl, allowedHosts: config.ALLOWED_HOSTS };
  const reader = viemChainReader(client, deployment);
  const store = createStore({ pinataJwt: config.PINATA_JWT, dataDir: config.DATA_DIR, baseUrl });
  if (!store.durable) log('AVISO: sin PINATA_JWT los archivos se guardan en disco local (sólo desarrollo)');

  const indexer = new Indexer({
    chain: reader,
    chainId: deployment.chainId,
    startBlock: deployment.marketplaceStartBlock,
    snapshots: new FileSnapshotStore(`${config.DATA_DIR}/index-${deployment.chainId}.json`),
    fetchJson: createJsonFetcher({ policy }),
    policy,
    confirmations: config.CONFIRMATIONS,
    chunkBlocks: config.LOG_CHUNK_BLOCKS,
    log,
  });
  await indexer.init();

  const api = createApi({ indexer, chain: reader, store, deployment, policy, corsOrigins: config.CORS_ORIGINS, uploadsPerHour: config.UPLOADS_PER_HOUR });
  const server = createServer(toNodeListener(api));
  await new Promise<void>((resolve) => server.listen(config.PORT, config.HOST, resolve));
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : config.PORT;
  log(`API en http://${config.HOST}:${port} (red ${deployment.chainId}, marketplace ${deployment.ToKleanMarketplace})`);

  const timers: NodeJS.Timeout[] = [];
  const loop = (name: string, ms: number, fn: () => Promise<unknown>) => {
    let busy = false;
    const run = async () => {
      if (busy) return;
      busy = true;
      try {
        await fn();
      } catch (e) {
        log(`${name}: ${(e as Error).message}`);
      } finally {
        busy = false;
      }
    };
    void run();
    timers.push(setInterval(run, ms));
  };
  loop('indexer', config.POLL_INTERVAL_MS, async () => {
    const r = await indexer.sync();
    if (r.events) log(`indexados ${r.events} eventos hasta el bloque ${r.to} (head ${r.head})`);
  });

  if (config.KEEPER_PRIVATE_KEY && (config.KEEPER_AUTO_RELEASE || config.KEEPER_AUTO_WITHDRAW)) {
    const account = privateKeyToAccount(config.KEEPER_PRIVATE_KEY as `0x${string}`);
    const wallet = createWalletClient({ account, chain, transport: http(config.RPC_URL) });
    const tx = viemTxSender(client, wallet, deployment.ToKleanMarketplace);
    log(`keeper activo con ${account.address} (liberar: ${config.KEEPER_AUTO_RELEASE}, retirar: ${config.KEEPER_AUTO_WITHDRAW})`);
    loop('keeper', config.KEEPER_INTERVAL_MS, async () => {
      if (!indexer.ready) return;
      const r = await keeperTick({ indexer, chain: reader, tx, autoRelease: config.KEEPER_AUTO_RELEASE, autoWithdraw: config.KEEPER_AUTO_WITHDRAW, log });
      for (const e of r.errors) log(`keeper: ${e}`);
    });
  }

  return {
    server,
    indexer,
    port,
    stop: async () => {
      for (const t of timers) clearInterval(t);
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  start(loadConfig()).catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exit(1);
  });
}
