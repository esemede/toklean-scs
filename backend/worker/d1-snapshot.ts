import type { D1Database, D1PreparedStatement } from '@cloudflare/workers-types';
import type { SnapshotStore } from '../src/indexer/store-types.ts';
import type { IndexState } from '../src/types.ts';

type Meta = Pick<IndexState, 'version' | 'chainId' | 'lastBlock' | 'pendingWithdrawals'>;
type Table = 'merchants' | 'listings' | 'orders';
const TABLES: Table[] = ['merchants', 'listings', 'orders'];
const BATCH = 50;

/**
 * Persiste el índice en D1 (SQLite de Cloudflare) con una fila por comercio, publicación y pedido.
 * `save` compara con lo que ya se guardó en esta instancia y escribe sólo las filas que cambiaron: así una sincronización
 * sin novedades no gasta escrituras (el plan gratuito de D1 tiene un límite diario).
 */
export class D1SnapshotStore implements SnapshotStore {
  /** Último estado guardado o leído, por clave `tabla/clave` (o `meta`). */
  private last = new Map<string, string>();

  constructor(private readonly db: D1Database) {}

  async load(): Promise<IndexState | null> {
    const meta = await this.db.prepare('SELECT value FROM meta WHERE key = ?').bind('state').first<{ value: string }>();
    if (!meta) return null;
    const base = JSON.parse(meta.value) as Meta;
    const results = await this.db.batch<{ key: string; json: string }>(TABLES.map((t) => this.db.prepare(`SELECT key, json FROM ${t}`)));

    const state: IndexState = { ...base, merchants: {}, listings: {}, orders: {} };
    const next = new Map<string, string>([['meta', meta.value]]);
    TABLES.forEach((table, i) => {
      for (const row of results[i]!.results) {
        state[table][row.key] = JSON.parse(row.json);
        next.set(`${table}/${row.key}`, row.json);
      }
    });
    this.last = next;
    return state;
  }

  async save(state: IndexState): Promise<void> {
    const meta: Meta = {
      version: state.version,
      chainId: state.chainId,
      lastBlock: state.lastBlock,
      pendingWithdrawals: state.pendingWithdrawals,
    };
    const next = new Map<string, string>([['meta', JSON.stringify(meta)]]);
    for (const table of TABLES) {
      for (const [key, value] of Object.entries(state[table])) next.set(`${table}/${key}`, JSON.stringify(value));
    }

    const stmts: D1PreparedStatement[] = [];
    for (const [k, json] of next) {
      if (this.last.get(k) === json) continue;
      if (k === 'meta') {
        stmts.push(this.db.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').bind('state', json));
      } else {
        const [table, key] = [k.slice(0, k.indexOf('/')), k.slice(k.indexOf('/') + 1)] as [Table, string];
        stmts.push(
          this.db
            .prepare(`INSERT INTO ${table} (key, json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json`)
            .bind(key, json),
        );
      }
    }
    for (const k of this.last.keys()) {
      if (k === 'meta' || next.has(k)) continue;
      const [table, key] = [k.slice(0, k.indexOf('/')), k.slice(k.indexOf('/') + 1)] as [Table, string];
      stmts.push(this.db.prepare(`DELETE FROM ${table} WHERE key = ?`).bind(key));
    }

    for (let i = 0; i < stmts.length; i += BATCH) await this.db.batch(stmts.slice(i, i + BATCH));
    // Sólo después de escribir: si la escritura falla, la próxima vez se reintenta.
    this.last = next;
  }
}
