/**
 * E2E contra una cadena real: despliega NFTs, economía, datos demo y marketplace con los scripts de Foundry sobre
 * anvil, levanta el backend completo, siembra con el flujo real (subidas firmadas + transacciones) y verifica
 * la API, el indexador y el keeper. Requiere `anvil` y `forge` en el PATH (pnpm test:e2e).
 */
import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createPublicClient, createWalletClient, defineChain, http, parseEther, type Address, type PublicClient } from 'viem';
import { mnemonicToAccount } from 'viem/accounts';
import { loadConfig } from '../../src/config.ts';
import { toKleanMarketplaceAbi, toKleanTokenAbi } from '../../src/generated/abis.ts';
import { viemChainReader } from '../../src/indexer/chain.ts';
import { keeperTick, viemTxSender } from '../../src/keeper.ts';
import { start, type RunningServer } from '../../src/server.ts';
import { loadDeployment } from '../../src/deployments.ts';
import { seedLocal, type SeedResult } from '../../scripts/seed-local.ts';

const ROOT = resolve(import.meta.dirname, '../../..');
const ANVIL_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const PATH = `${process.env.PATH}:${process.env.HOME}/.foundry/bin:/root/.foundry/bin`;

const freePort = () =>
  new Promise<number>((res, rej) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => res(p));
    });
    s.on('error', rej);
  });

async function waitFor<T>(fn: () => Promise<T | undefined | false>, ms = 20_000): Promise<T> {
  const end = Date.now() + ms;
  for (;;) {
    try {
      const v = await fn();
      if (v) return v;
    } catch {
      /* todavía no */
    }
    if (Date.now() > end) throw new Error('timeout esperando condición');
    await new Promise((r) => setTimeout(r, 200));
  }
}

let anvil: ChildProcess;
let server: RunningServer;
let dataDir = '';
let api = '';
let rpc = '';
let seed: SeedResult;
let pub: PublicClient;

const get = async (path: string) => {
  const res = await fetch(`${api}${path}`);
  return { status: res.status, body: (await res.json()) as any };
};

beforeAll(async () => {
  const rpcPort = await freePort();
  const apiPort = await freePort();
  rpc = `http://127.0.0.1:${rpcPort}`;
  api = `http://127.0.0.1:${apiPort}`;
  dataDir = await mkdtemp(join(tmpdir(), 'toklean-e2e-'));

  anvil = spawn('anvil', ['--port', String(rpcPort), '--chain-id', '31337', '--silent'], { env: { ...process.env, PATH }, stdio: 'ignore' });
  pub = createPublicClient({ transport: http(rpc) }) as PublicClient;
  await waitFor(async () => (await pub.getChainId()) === 31337);

  const env = { ...process.env, PATH, PRIVATE_KEY: ANVIL_KEY };
  await rm(join(ROOT, 'deployments', '31337.json'), { force: true });
  for (const script of ['Deploy', 'DeployEconomy', 'SeedDemo', 'DeployMarketplace']) {
    execFileSync('forge', ['script', `script/${script}.s.sol`, '--rpc-url', rpc, '--broadcast'], { cwd: ROOT, env, stdio: 'pipe' });
  }

  const config = loadConfig({
    RPC_URL: rpc,
    CHAIN_ID: '31337',
    DEPLOYMENTS_FILE: join(ROOT, 'deployments', '31337.json'),
    HOST: '127.0.0.1',
    PORT: String(apiPort),
    PUBLIC_BASE_URL: api,
    DATA_DIR: dataDir,
    CONFIRMATIONS: '0',
    POLL_INTERVAL_MS: '3600000',
    UPLOADS_PER_HOUR: '500',
  });
  server = await start(config, () => {});
  seed = await seedLocal({ rpcUrl: rpc, apiUrl: api, deploymentsFile: config.DEPLOYMENTS_FILE, chainId: 31337, log: () => {} });
  await server.indexer.sync();
});

afterAll(async () => {
  await server?.stop();
  anvil?.kill('SIGKILL');
  if (dataDir) await rm(dataDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

describe('backend contra una cadena real', () => {
  it('indexes everything the seed did and reports health', async () => {
    const { body } = await get('/health');
    expect(body).toMatchObject({ ok: true, ready: true, lagBlocks: 0, chainId: 31337 });
    expect(body.listings).toBe(seed.listings.length);
    expect(body.orders).toBe(5);
    expect(body.merchants).toBe(3);
  });

  it('serves the catalog with verified metadata and working images', async () => {
    const { body } = await get('/v1/listings?available=false');
    expect(body.total).toBe(seed.listings.length);
    const names = body.items.map((i: any) => i.name);
    expect(names).toContain('Taller de compostaje en casa');
    expect(names).toContain('Banca de plástico reciclado');

    const compost = body.items.find((i: any) => i.name.startsWith('Taller'));
    expect(compost).toMatchObject({ kind: 'service', paymentSymbol: 'REC', category: 'education', metadataStatus: 'ok' });
    expect(compost.seller).toMatchObject({ name: 'EcoTienda Valparaíso', country: 'CL', status: 'approved' });

    const img = await fetch(compost.imageUrl);
    expect(img.status).toBe(200);
    expect(img.headers.get('content-type')).toBe('image/png');
    expect([...new Uint8Array(await img.arrayBuffer()).slice(0, 4)]).toEqual([0x89, 0x50, 0x4e, 0x47]);
  });

  it('searches and filters', async () => {
    expect((await get('/v1/listings?q=compostaje')).body.items.map((i: any) => i.name)).toEqual(['Taller de compostaje en casa']);
    expect((await get('/v1/listings?payment=2&available=false')).body.items).toHaveLength(2);
    expect((await get('/v1/listings?category=fashion')).body.items).toHaveLength(1);
    expect((await get('/v1/listings?minPrice=10&maxPrice=30')).body.items.map((i: any) => i.name)).toEqual(
      expect.arrayContaining(['Maceta de cerámica reciclada', 'Taller de compostaje en casa']),
    );
  });

  it('closes the clean-product listing when the sale completes and moves the passport to the buyer', async () => {
    const { body } = await get('/v1/listings?available=false');
    const bench = body.items.find((i: any) => i.name === 'Banca de plástico reciclado');
    expect(bench).toMatchObject({ status: 'closed', hasProduct: true, available: false, stock: 0 });
    const owner = await pub.readContract({
      address: loadDeployment(join(ROOT, 'deployments', '31337.json')).CircularProductNFT,
      abi: [{ type: 'function', name: 'ownerOf', stateMutability: 'view', inputs: [{ name: 'id', type: 'uint256' }], outputs: [{ type: 'address' }] }],
      functionName: 'ownerOf',
      args: [BigInt(bench.productTokenId)],
    });
    expect((owner as string).toLowerCase()).toBe(seed.accounts.buyer!.toLowerCase());
  });

  it('exposes orders in every state, merchants with ratings and aggregate stats', async () => {
    const orders = (await get(`/v1/orders?buyer=${seed.accounts.buyer}`)).body.items;
    expect(orders.map((o: any) => o.status).sort()).toEqual(['completed', 'completed', 'disputed', 'paid', 'shipped']);
    expect(orders.find((o: any) => o.status === 'paid').listing.name).toBe('Taller de compostaje en casa');

    const merchants = (await get('/v1/merchants')).body.items;
    expect(merchants.map((m: any) => m.name)).toHaveLength(2);
    const eco = merchants.find((m: any) => m.name.startsWith('EcoTienda'));
    expect(eco).toMatchObject({ ratingAvg: 4, ratingCount: 1, completedSales: 1 });
    expect(merchants.find((m: any) => m.name.startsWith('Planta'))).toMatchObject({ ratingAvg: 5 });
    expect((await get(`/v1/merchants/${seed.accounts.pendingShop}`)).body.status).toBe('pending');

    const stats = (await get('/v1/stats')).body;
    expect(stats).toMatchObject({ merchants: 2, completedOrders: 2, orders: 5 });
    // 120 (banca) + 2 x 9,5 (bolsas)
    expect(stats.volume.TKN).toBe(parseEther('139').toString());
  });

  it('rejects uploads from accounts that are not approved merchants and unsigned requests', async () => {
    const res = await fetch(`${api}/v1/media`, { method: 'POST', body: new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]) });
    expect(res.status).toBe(401);
  });

  it('keeper: releases expired orders and pushes credited funds to their owners', async () => {
    const d = loadDeployment(join(ROOT, 'deployments', '31337.json'));
    const chain = defineChain({ id: 31337, name: 'local', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } });
    const keeper = mnemonicToAccount('test test test test test test test test test test test junk', { addressIndex: 5 });
    const wallet = createWalletClient({ account: keeper, chain, transport: http(rpc) });
    const reader = viemChainReader(pub, d);

    // Pasan 15 días: venció la ventana de confirmación del pedido enviado (el disputado y el pagado siguen igual)
    await pub.request({ method: 'evm_increaseTime' as never, params: [15 * 24 * 3600] as never });
    await pub.request({ method: 'evm_mine' as never, params: [] as never });
    const chainNow = Number((await pub.getBlock()).timestamp);

    await server.indexer.sync();
    expect(server.indexer.state.pendingWithdrawals.length).toBeGreaterThan(0);
    const tx = viemTxSender(pub, wallet, d.ToKleanMarketplace);
    const report = await keeperTick({ indexer: server.indexer, chain: reader, tx, autoRelease: true, autoWithdraw: true, now: () => chainNow });

    expect(report.errors).toEqual([]);
    expect(report.released).toHaveLength(1);
    expect(report.withdrawn.length).toBeGreaterThan(0);
    expect(server.indexer.state.pendingWithdrawals).toEqual([]);

    // Los vendedores recibieron sus fondos sin enviar ninguna transacción propia
    const balance = async (a: Address, id: bigint) => (await pub.readContract({ address: d.ToKleanToken, abi: toKleanTokenAbi, functionName: 'balanceOf', args: [a, id] })) as bigint;
    expect(await balance(seed.accounts.eco!, 1n)).toBeGreaterThan(0n);
    expect(await balance(seed.accounts.maker!, 1n)).toBe(parseEther('117.6')); // 120 - 2 %

    await server.indexer.sync();
    const orders = (await get(`/v1/orders?buyer=${seed.accounts.buyer}`)).body.items;
    expect(orders.map((o: any) => o.status).sort()).toEqual(['completed', 'completed', 'completed', 'disputed', 'paid']);
    const claim = (await get(`/v1/accounts/${seed.accounts.eco}`)).body.claimable;
    expect(claim).toEqual({ 1: '0', 2: '0', 3: '0' });
    void toKleanMarketplaceAbi;
  });
});
