/** Un log crudo de la cadena, tal como lo guarda el índice y lo sirve la API. El cliente lo decodifica con las ABIs. */
export interface RawLog {
  block: number;
  /** Posición del log dentro del bloque. */
  index: number;
  /** En minúsculas. */
  address: string;
  topics: string[];
  data: string;
  tx: string;
}

export interface LogsPage {
  /** Primer bloque indexado. Se asume (lo verifica quien configura el índice) que antes de él no hay eventos de interés. */
  fromBlock: number;
  /** Último bloque ya indexado. */
  lastBlock: number;
  /** Contratos que sigue el índice (en minúsculas). */
  addresses: string[];
  /** `true` si hay más logs que `limit`: sólo se devuelven los más recientes. */
  truncated: boolean;
  /** Más recientes primero. */
  logs: RawLog[];
}

export interface LogsSource {
  page(opts: { address?: string; limit: number }): Promise<LogsPage>;
}

/** Lee logs crudos de la cadena (viem en producción, un falso en los tests). */
export interface RawLogReader {
  getBlockNumber(): Promise<bigint>;
  getLogs(from: bigint, to: bigint): Promise<RawLog[]>;
}

/** Dónde se guardan los logs (D1 en el Worker, memoria en los tests). */
export interface LogStore {
  /** Último bloque indexado, o `null` si nunca se sincronizó. */
  cursor(): Promise<number | null>;
  /** Guarda los logs y avanza el cursor a `lastBlock`. Idempotente: repetir un tramo no duplica. */
  append(logs: RawLog[], lastBlock: number): Promise<void>;
  /** Más recientes primero. */
  query(opts: { address?: string; limit: number }): Promise<RawLog[]>;
}
