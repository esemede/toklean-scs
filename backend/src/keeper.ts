import type { Address, Hex, PublicClient, WalletClient } from 'viem';
import type { ChainReader } from './indexer/chain.ts';
import { marketplaceAbi } from './indexer/abis.ts';
import type { Indexer } from './indexer/indexer.ts';

/** Transacciones que el keeper puede enviar (inyectable en tests). */
export interface TxSender {
  releaseAfterTimeout(orderId: number): Promise<Hex>;
  withdraw(account: Address, id: number): Promise<Hex>;
}

/**
 * Envía las transacciones del keeper. Con `wait` (por defecto) espera el recibo y revisa que no revirtiera; el Worker
 * lo desactiva porque cada consulta de recibo cuenta como subrequest: el siguiente tick ve el estado ya cambiado y un
 * duplicado revierte en la simulación previa (no gasta gas).
 */
export function viemTxSender(pub: PublicClient, wallet: WalletClient, market: Address, wait = true): TxSender {
  const account = wallet.account;
  if (!account) throw new Error('El wallet client necesita una cuenta');
  const send = async (functionName: 'releaseAfterTimeout' | 'withdraw', args: readonly unknown[]) => {
    const { request } = await pub.simulateContract({ address: market, abi: marketplaceAbi, functionName, args: args as never, account } as never);
    const hash = await wallet.writeContract(request as never);
    if (!wait) return hash;
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${functionName} revirtió (${hash})`);
    return hash;
  };
  return {
    releaseAfterTimeout: (orderId) => send('releaseAfterTimeout', [BigInt(orderId)]),
    withdraw: (acct, id) => send('withdraw', [acct, BigInt(id)]),
  };
}

export interface KeeperOptions {
  indexer: Indexer;
  chain: ChainReader;
  tx: TxSender;
  autoRelease: boolean;
  autoWithdraw: boolean;
  /** Tope de transacciones por tick (liberaciones + retiros). */
  maxActions?: number;
  now?: () => number;
  log?: (message: string) => void;
}

export interface KeeperReport {
  released: number[];
  withdrawn: Array<{ account: Address; id: number }>;
  errors: string[];
}

/**
 * Tareas que nadie debería tener que hacer a mano y que cualquiera puede ejecutar sin riesgo (los fondos siempre
 * van a su dueño): liberar pedidos enviados cuya ventana de confirmación venció y empujar a cada cuenta lo que
 * tiene acreditado. Opt-in: el keeper paga el gas.
 */
export async function keeperTick(o: KeeperOptions): Promise<KeeperReport> {
  // Los plazos se miden con el reloj de la cadena (el del último bloque), no con el del servidor.
  const now = o.now ? o.now() : await o.chain.getTimestamp();
  const log = o.log ?? (() => {});
  const report: KeeperReport = { released: [], withdrawn: [], errors: [] };
  const { state } = o.indexer;
  let budget = o.maxActions ?? Infinity;

  if (o.autoRelease) {
    for (const order of Object.values(state.orders)) {
      if (order.status !== 'shipped' || order.deadline > now) continue;
      if (budget-- <= 0) break;
      try {
        await o.tx.releaseAfterTimeout(order.id);
        report.released.push(order.id);
        log(`pedido ${order.id} liberado`);
      } catch (e) {
        report.errors.push(`release ${order.id}: ${(e as Error).message}`);
      }
    }
  }

  if (o.autoWithdraw) {
    for (const account of [...state.pendingWithdrawals]) {
      try {
        const balances = await o.chain.readClaimable(account);
        for (const [id, amount] of Object.entries(balances)) {
          if (amount === 0n) continue;
          if (budget-- <= 0) break;
          await o.tx.withdraw(account, Number(id));
          report.withdrawn.push({ account, id: Number(id) });
          log(`retiro ${id} → ${account}`);
        }
        state.pendingWithdrawals = state.pendingWithdrawals.filter((a) => a.toLowerCase() !== account.toLowerCase());
      } catch (e) {
        report.errors.push(`withdraw ${account}: ${(e as Error).message}`);
      }
    }
  }
  return report;
}
