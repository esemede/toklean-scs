import type { D1Database } from '@cloudflare/workers-types';
import type { LogStore, RawLog } from '../src/logs/types.ts';

/** D1 acepta lotes de decenas de sentencias; el cursor va siempre en el último. */
const BATCH = 50;

interface Row {
  block: number;
  idx: number;
  address: string;
  json: string;
}

/** Logs crudos en D1 (tabla `logs`, cursor en `meta`). `INSERT OR IGNORE` hace idempotente repetir un tramo. */
export class D1LogStore implements LogStore {
  constructor(private readonly db: D1Database) {}

  async cursor(): Promise<number | null> {
    const row = await this.db.prepare('SELECT value FROM meta WHERE key = ?').bind('logs').first<{ value: string }>();
    return row ? (JSON.parse(row.value) as { lastBlock: number }).lastBlock : null;
  }

  async append(logs: RawLog[], lastBlock: number): Promise<void> {
    const insert = this.db.prepare('INSERT OR IGNORE INTO logs (block, idx, address, json) VALUES (?, ?, ?, ?)');
    const stmts = logs.map((l) => insert.bind(l.block, l.index, l.address, JSON.stringify({ topics: l.topics, data: l.data, tx: l.tx })));
    stmts.push(
      this.db
        .prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
        .bind('logs', JSON.stringify({ lastBlock })),
    );
    for (let i = 0; i < stmts.length; i += BATCH) await this.db.batch(stmts.slice(i, i + BATCH));
  }

  async query({ address, limit }: { address?: string; limit: number }): Promise<RawLog[]> {
    const order = 'ORDER BY block DESC, idx DESC LIMIT ?';
    const stmt = address
      ? this.db.prepare(`SELECT block, idx, address, json FROM logs WHERE address = ? ${order}`).bind(address, limit)
      : this.db.prepare(`SELECT block, idx, address, json FROM logs ${order}`).bind(limit);
    const { results } = await stmt.all<Row>();
    return results.map((r) => {
      const body = JSON.parse(r.json) as { topics: string[]; data: string; tx: string };
      return { block: r.block, index: r.idx, address: r.address, topics: body.topics, data: body.data, tx: body.tx };
    });
  }
}
