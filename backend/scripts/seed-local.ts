/**
 * Siembra el marketplace local (anvil) con comercios, publicaciones y pedidos en distintos estados, usando el
 * mismo camino que la app real: subidas firmadas al backend y transacciones on-chain.
 *
 *   anvil & (cd .. && make deploy-local deploy-economy-local && forge script script/SeedDemo.s.sol --rpc-url local --broadcast && make deploy-marketplace-local)
 *   pnpm start &         # el backend con DEPLOYMENTS_FILE=../deployments/31337.json
 *   pnpm seed:local
 *
 * Cuentas (mnemónico de anvil): 0 admin/compliance/árbitro, 4 fabricante (dueño del producto limpio de SeedDemo),
 * 6 comprador, 8 EcoTienda, 9 comercio pendiente de aprobación.
 */
import { createPublicClient, createWalletClient, defineChain, http, parseEther, type Address, type Hex, type PublicClient } from 'viem';
import { mnemonicToAccount, type HDAccount } from 'viem/accounts';
import { authHeader, uploadMessage, type UploadKind } from '../src/auth.ts';
import { sha256Hex } from '../src/metadata/schema.ts';
import { loadDeployment, type Deployment } from '../src/deployments.ts';
import { circularProductNFTAbi, toKleanCatalogAbi, toKleanMarketplaceAbi, toKleanMerchantRegistryAbi, toKleanTokenAbi } from '../src/generated/abis.ts';
import { gradientPng } from './png.ts';

const MNEMONIC = 'test test test test test test test test test test test junk';

export interface SeedOptions {
  rpcUrl: string;
  apiUrl: string;
  deploymentsFile: string;
  chainId?: number;
  log?: (m: string) => void;
}

export interface SeedResult {
  listings: { id: number; name: string }[];
  orders: Record<string, number>;
  accounts: Record<string, Address>;
}

export async function seedLocal(opts: SeedOptions): Promise<SeedResult> {
  const log = opts.log ?? console.log;
  const d: Deployment = loadDeployment(opts.deploymentsFile, opts.chainId);
  const chain = defineChain({ id: d.chainId, name: 'local', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [opts.rpcUrl] } } });
  const pub = createPublicClient({ chain, transport: http(opts.rpcUrl) }) as PublicClient;
  const acct = (i: number) => mnemonicToAccount(MNEMONIC, { addressIndex: i });
  const admin = acct(0);
  const maker = acct(4);
  const buyer = acct(6);
  const eco = acct(8);
  const pendingShop = acct(9);

  const send = async (account: HDAccount, address: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[]): Promise<Hex> => {
    const wallet = createWalletClient({ account, chain, transport: http(opts.rpcUrl) });
    const { request } = await pub.simulateContract({ account, address, abi, functionName, args } as never);
    const hash = await wallet.writeContract(request as never);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${functionName} revirtió`);
    return hash;
  };

  /** Sube un archivo firmando con la cuenta, igual que la app. */
  const upload = async (account: HDAccount, path: string, kind: UploadKind, bytes: Uint8Array, contentType: string): Promise<{ uri: string }> => {
    const ts = Math.floor(Date.now() / 1000);
    const signature = await account.signMessage({ message: uploadMessage(kind, sha256Hex(bytes), ts) });
    const res = await fetch(`${opts.apiUrl}${path}`, {
      method: 'POST',
      headers: { 'content-type': contentType, authorization: authHeader(account.address, ts, signature) },
      body: new Uint8Array(bytes),
    });
    if (!res.ok) throw new Error(`${path} → ${res.status} ${await res.text()}`);
    return (await res.json()) as { uri: string };
  };
  const uploadJson = (account: HDAccount, kind: 'listing' | 'merchant', doc: unknown) =>
    upload(account, `/v1/metadata?kind=${kind}`, 'metadata', new TextEncoder().encode(JSON.stringify(doc)), 'application/json');
  const uploadImage = (account: HDAccount, from: [number, number, number], to: [number, number, number]) =>
    upload(account, '/v1/media', 'media', gradientPng(from, to), 'image/png');

  // ---- comercios
  const shops: Array<[HDAccount, Record<string, unknown>, [number, number, number]]> = [
    [maker, { name: 'Planta Recicladora Sur', description: 'Fabricamos mobiliario con plástico 100% reciclado.', country: 'CL', website: 'https://example.com/planta-sur' }, [16, 120, 98]],
    [eco, { name: 'EcoTienda Valparaíso', description: 'Productos y talleres sostenibles para el hogar.', country: 'CL' }, [14, 116, 144]],
  ];
  for (const [account, profile, color] of shops) {
    const logo = await uploadImage(account, color, [240, 250, 245]);
    const meta = await uploadJson(account, 'merchant', { schema: 'toklean.merchant/1', logo: logo.uri, ...profile });
    await send(account, d.ToKleanMerchantRegistry, toKleanMerchantRegistryAbi, 'applyAsMerchant', [meta.uri]);
    await send(admin, d.ToKleanMerchantRegistry, toKleanMerchantRegistryAbi, 'reviewMerchant', [account.address, true]);
    log(`comercio aprobado: ${profile.name}`);
  }
  const pendingMeta = await uploadJson(pendingShop, 'merchant', { schema: 'toklean.merchant/1', name: 'Tienda Nueva (pendiente)', country: 'CL' });
  await send(pendingShop, d.ToKleanMerchantRegistry, toKleanMerchantRegistryAbi, 'applyAsMerchant', [pendingMeta.uri]);

  // ---- publicaciones
  const created: { id: number; name: string }[] = [];
  const catalogCount = async () => Number(await pub.readContract({ address: d.ToKleanCatalog, abi: toKleanCatalogAbi, functionName: 'listingCount' }));
  const TKN = 1n;
  const REC = 2n;
  const list = async (
    seller: HDAccount,
    doc: Record<string, unknown>,
    colors: [[number, number, number], [number, number, number]],
    o: { kind: 0 | 1; payment: bigint; price: string; stock: number; productTokenId?: bigint },
  ) => {
    const image = await uploadImage(seller, colors[0], colors[1]);
    const meta = await uploadJson(seller, 'listing', { schema: 'toklean.listing/1', image: image.uri, ...doc });
    await send(seller, d.ToKleanCatalog, toKleanCatalogAbi, 'createListing', [o.kind, o.payment, parseEther(o.price), o.stock, meta.uri, o.productTokenId !== undefined, o.productTokenId ?? 0n]);
    const id = await catalogCount();
    created.push({ id, name: String(doc.name) });
    log(`publicación ${id}: ${doc.name}`);
    return id;
  };

  // Producto limpio certificado de SeedDemo (si existe): su pasaporte viaja con la venta.
  let benchId = 0;
  for (let tokenId = 1n; tokenId <= 10n; tokenId++) {
    let owner: Address;
    try {
      owner = (await pub.readContract({ address: d.CircularProductNFT, abi: circularProductNFTAbi, functionName: 'ownerOf', args: [tokenId] })) as Address;
    } catch {
      break;
    }
    const product = (await pub.readContract({ address: d.CircularProductNFT, abi: circularProductNFTAbi, functionName: 'getProduct', args: [tokenId] })) as { status: number };
    if (owner.toLowerCase() === maker.address.toLowerCase() && Number(product.status) === 1) {
      await send(maker, d.CircularProductNFT, circularProductNFTAbi, 'approve', [d.ToKleanCatalog, tokenId]);
      benchId = await list(
        maker,
        {
          name: 'Banca de plástico reciclado',
          description: 'Banca de jardín para 3 personas fabricada con 90% de plástico reciclado post-consumo. Incluye pasaporte digital con trazabilidad completa.',
          category: 'garden',
          tags: ['banca', 'reciclado', 'jardín'],
          condition: 'new',
          sustainability: { recycledContentPct: 90, co2eKg: 150, certifications: ['Fabricación limpia ToKlean'] },
          shipping: { regions: ['CL'], days: 7, carbonOffset: true },
        },
        [[16, 120, 98], [120, 190, 160]],
        { kind: 0, payment: TKN, price: '120', stock: 1, productTokenId: tokenId },
      );
      break;
    }
  }

  const compost = await list(eco, { name: 'Taller de compostaje en casa', description: 'Taller práctico de 2 horas para aprender a compostar en departamento. Incluye kit de inicio.', category: 'education', tags: ['taller', 'compost'], shipping: { regions: ['CL', 'online'] } }, [[110, 80, 40], [200, 170, 110]], { kind: 1, payment: REC, price: '25', stock: 20 });
  const bag = await list(eco, { name: 'Bolsas de algodón orgánico (pack x3)', description: 'Tres bolsas reutilizables de algodón orgánico certificado.', category: 'fashion', tags: ['bolsas', 'algodón'], condition: 'new', sustainability: { certifications: ['GOTS'] }, shipping: { regions: ['CL'], days: 4 } }, [[190, 150, 90], [240, 220, 170]], { kind: 0, payment: TKN, price: '9.5', stock: 40 });
  const pot = await list(eco, { name: 'Maceta de cerámica reciclada', description: 'Maceta artesanal hecha con cerámica recuperada de talleres locales.', category: 'home', tags: ['maceta', 'cerámica'], condition: 'refurbished', shipping: { regions: ['CL'], days: 6 } }, [[150, 70, 50], [230, 160, 130]], { kind: 0, payment: TKN, price: '14', stock: 8 });
  await list(eco, { name: 'Pack de empaques compostables', description: 'Cien empaques compostables para ecommerce, sin plástico.', category: 'packaging', tags: ['empaque'], sustainability: { recycledContentPct: 60 }, shipping: { regions: ['CL'], days: 5 } }, [[60, 130, 80], [170, 220, 150]], { kind: 0, payment: REC, price: '32', stock: 15 });

  // ---- compras en distintos estados
  await send(admin, d.ToKleanToken, toKleanTokenAbi, 'grantRole', [(await pub.readContract({ address: d.ToKleanToken, abi: toKleanTokenAbi, functionName: 'MINTER_ROLE' })) as Hex, admin.address]).catch(() => undefined);
  for (const id of [TKN, REC]) await send(admin, d.ToKleanToken, toKleanTokenAbi, 'mint', [buyer.address, id, parseEther('1000')]);
  await send(buyer, d.ToKleanToken, toKleanTokenAbi, 'setApprovalForAll', [d.ToKleanMarketplace, true]);

  const price = async (id: number) => ((await pub.readContract({ address: d.ToKleanCatalog, abi: toKleanCatalogAbi, functionName: 'getListing', args: [BigInt(id)] })) as { price: bigint }).price;
  const orderCount = async () => Number(await pub.readContract({ address: d.ToKleanMarketplace, abi: toKleanMarketplaceAbi, functionName: 'orderCount' }));
  const buy = async (id: number, qty: number) => {
    await send(buyer, d.ToKleanMarketplace, toKleanMarketplaceAbi, 'buy', [BigInt(id), qty, await price(id)]);
    return orderCount();
  };
  const m = (account: HDAccount, fn: string, args: readonly unknown[]) => send(account, d.ToKleanMarketplace, toKleanMarketplaceAbi, fn, args);
  const orders: Record<string, number> = {};

  if (benchId) {
    orders.completedClean = await buy(benchId, 1);
    await m(maker, 'markShipped', [BigInt(orders.completedClean), 'https://tracking.example.com/CL123456']);
    await m(buyer, 'confirmReceived', [BigInt(orders.completedClean)]);
    await m(buyer, 'rate', [BigInt(orders.completedClean), 5]);
  }
  orders.completed = await buy(bag, 2);
  await m(eco, 'markShipped', [BigInt(orders.completed), 'https://tracking.example.com/CL777']);
  await m(buyer, 'confirmReceived', [BigInt(orders.completed)]);
  await m(buyer, 'rate', [BigInt(orders.completed), 4]);

  orders.shipped = await buy(pot, 1);
  await m(eco, 'markShipped', [BigInt(orders.shipped), 'https://tracking.example.com/CL888']);
  orders.paid = await buy(compost, 2);
  orders.disputed = await buy(pot, 2);
  await m(eco, 'markShipped', [BigInt(orders.disputed), 'https://tracking.example.com/CL999']);
  await m(buyer, 'openDispute', [BigInt(orders.disputed), 'https://example.com/evidence/chipped-pots']);

  log(`pedidos sembrados: ${JSON.stringify(orders)}`);
  return { listings: created, orders, accounts: { admin: admin.address, maker: maker.address, buyer: buyer.address, eco: eco.address, pendingShop: pendingShop.address } };
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  seedLocal({
    rpcUrl: process.env.RPC_URL ?? 'http://127.0.0.1:8545',
    apiUrl: process.env.API_URL ?? 'http://localhost:8787',
    deploymentsFile: process.env.DEPLOYMENTS_FILE ?? '../deployments/31337.json',
    chainId: 31337,
  }).catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
