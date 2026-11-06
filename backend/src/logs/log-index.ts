/**
 * Índice de logs crudos de un conjunto de contratos. Existe porque los RPC públicos gratuitos podan el historial: un
 * navegador no puede pedir `eth_getLogs` de hace más de ~1,5 días de forma fiable. El Worker, en cambio, corre cada
 * minuto y siempre lee bloques recientes; guarda lo que ve y lo sirve desde su propio almacenamiento.
 */
import type { LogStore, LogsPage, LogsSource, RawLog, RawLogReader } from './types.ts';

export interface LogIndexOptions {
  reader: RawLogReader;
  store: LogStore;
  /** Primer bloque a indexar. Quien lo configura debe haber comprobado que antes no hay eventos de interés. */
  startBlock: number;
  addresses: string[];
  confirmations?: number;
  chunkBlocks?: number;
  maxChunksPerRun?: number;
  log?: (m: string) => void;
}

export interface LogSyncResult {
  from: number;
  to: number;
  head: number;
  logs: number;
}

export class LogIndex implements LogsSource {
  private readonly confirmations: number;
  private readonly chunk: number;
  private readonly maxChunks: number;
  private readonly addresses: string[];

  constructor(private readonly o: LogIndexOptions) {
    this.confirmations = o.confirmations ?? 2;
    this.chunk = o.chunkBlocks ?? 2_000;
    this.maxChunks = o.maxChunksPerRun ?? Infinity;
    this.addresses = o.addresses.map((a) => a.toLowerCase());
  }

  /** Indexa hasta `maxChunksPerRun` tramos nuevos. Repetir un tramo no duplica nada. */
  async sync(): Promise<LogSyncResult> {
    const head = Number(await this.o.reader.getBlockNumber());
    const target = Math.max(0, head - this.confirmations);
    const saved = await this.o.store.cursor();
    const first = Math.max((saved ?? 0) + 1, this.o.startBlock);
    let from = first;
    let total = 0;
    let chunks = 0;
    while (from <= target && chunks < this.maxChunks) {
      const to = Math.min(target, from + this.chunk - 1);
      const logs = await this.o.reader.getLogs(BigInt(from), BigInt(to));
      await this.o.store.append(logs, to);
      total += logs.length;
      chunks++;
      from = to + 1;
    }
    const last = from - 1;
    if (total > 0) this.o.log?.(`logs: ${total} nuevos entre ${first} y ${last}`);
    return { from: first, to: Math.max(last, saved ?? 0), head, logs: total };
  }

  async page({ address, limit }: { address?: string; limit: number }): Promise<LogsPage> {
    const cursor = (await this.o.store.cursor()) ?? this.o.startBlock - 1;
    const rows = await this.o.store.query({ address: address?.toLowerCase(), limit: limit + 1 });
    return {
      fromBlock: this.o.startBlock,
      lastBlock: cursor,
      addresses: this.addresses,
      truncated: rows.length > limit,
      logs: rows.slice(0, limit),
    };
  }
}

/** Almacén en memoria (tests y desarrollo). Ordena como el de D1: más recientes primero. */
export class MemoryLogStore implements LogStore {
  private last: number | null = null;
  private readonly rows = new Map<string, RawLog>();

  async cursor(): Promise<number | null> {
    return this.last;
  }

  async append(logs: RawLog[], lastBlock: number): Promise<void> {
    for (const l of logs) this.rows.set(`${l.block}:${l.index}`, l);
    this.last = lastBlock;
  }

  async query({ address, limit }: { address?: string; limit: number }): Promise<RawLog[]> {
    return [...this.rows.values()]
      .filter((l) => !address || l.address === address)
      .sort((a, b) => b.block - a.block || b.index - a.index)
      .slice(0, limit);
  }
}
