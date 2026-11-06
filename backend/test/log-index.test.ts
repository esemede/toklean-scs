import { describe, expect, it } from 'vitest';
import { LogIndex, MemoryLogStore } from '../src/logs/log-index.ts';
import type { RawLog, RawLogReader } from '../src/logs/types.ts';

const A = '0x00000000000000000000000000000000000000a1';
const B = '0x00000000000000000000000000000000000000b2';

const log = (block: number, index: number, address = A): RawLog => ({
  block,
  index,
  address,
  topics: [`0x${'11'.repeat(32)}`],
  data: '0x',
  tx: `0x${block.toString(16).padStart(64, '0')}`,
});

class FakeReader implements RawLogReader {
  calls: [bigint, bigint][] = [];
  constructor(
    public head: number,
    public logs: RawLog[] = [],
  ) {}
  async getBlockNumber() {
    return BigInt(this.head);
  }
  async getLogs(from: bigint, to: bigint) {
    this.calls.push([from, to]);
    return this.logs.filter((l) => l.block >= Number(from) && l.block <= Number(to));
  }
}

const make = (reader: FakeReader, over: Partial<ConstructorParameters<typeof LogIndex>[0]> = {}) => {
  const store = new MemoryLogStore();
  const index = new LogIndex({ reader, store, startBlock: 100, addresses: [A, B], confirmations: 2, chunkBlocks: 50, ...over });
  return { index, store };
};

describe('LogIndex.sync', () => {
  it('indexes from the start block up to head minus confirmations, in chunks', async () => {
    const reader = new FakeReader(300, [log(100, 0), log(160, 1), log(298, 0), log(299, 0)]);
    const { index, store } = make(reader);
    const r = await index.sync();
    expect(reader.calls).toEqual([
      [100n, 149n],
      [150n, 199n],
      [200n, 249n],
      [250n, 298n],
    ]);
    // El bloque 299 queda fuera: head 300 con 2 confirmaciones indexa hasta 298.
    expect(r).toMatchObject({ from: 100, to: 298, head: 300, logs: 3 });
    expect(await store.cursor()).toBe(298);
  });

  it('only reads new blocks on the next run and picks up new logs', async () => {
    const reader = new FakeReader(200, [log(110, 0)]);
    const { index, store } = make(reader);
    await index.sync();
    reader.calls = [];
    reader.head = 260;
    reader.logs.push(log(240, 3));
    const r = await index.sync();
    expect(reader.calls[0]?.[0]).toBe(199n);
    expect(r.logs).toBe(1);
    expect((await store.query({ limit: 10 })).map((l) => l.block)).toEqual([240, 110]);
  });

  it('caps the work per run and resumes where it left off', async () => {
    const reader = new FakeReader(1000, [log(120, 0), log(620, 0)]);
    const { index, store } = make(reader, { maxChunksPerRun: 2 });
    const first = await index.sync();
    expect(reader.calls).toHaveLength(2);
    expect(first.to).toBe(199);
    expect(await store.cursor()).toBe(199);
    for (let i = 0; i < 10; i++) await index.sync();
    expect(await store.cursor()).toBe(998);
    expect((await store.query({ limit: 10 })).length).toBe(2);
  });

  it('does nothing when already at the target block', async () => {
    const reader = new FakeReader(200, [log(110, 0)]);
    const { index } = make(reader);
    await index.sync();
    reader.calls = [];
    const r = await index.sync();
    expect(reader.calls).toEqual([]);
    expect(r).toMatchObject({ logs: 0, to: 198 });
  });

  it('does not duplicate a chunk that is read twice (idempotent)', async () => {
    const reader = new FakeReader(200, [log(110, 0)]);
    const { index, store } = make(reader);
    await index.sync();
    await store.append([log(110, 0)], 198);
    expect(await store.query({ limit: 10 })).toHaveLength(1);
  });

  it('never starts before the configured start block even if the cursor is older', async () => {
    const reader = new FakeReader(400);
    const store = new MemoryLogStore();
    await store.append([], 50);
    const index = new LogIndex({ reader, store, startBlock: 300, addresses: [A], chunkBlocks: 1000 });
    await index.sync();
    expect(reader.calls[0]?.[0]).toBe(300n);
  });

  it('propagates reader failures without advancing the cursor', async () => {
    const reader = new FakeReader(300);
    reader.getLogs = async () => {
      throw new Error('pruned history unavailable');
    };
    const { index, store } = make(reader);
    await expect(index.sync()).rejects.toThrow('pruned history unavailable');
    expect(await store.cursor()).toBeNull();
  });
});

describe('LogIndex.page', () => {
  it('reports the coverage and returns the newest logs first', async () => {
    const reader = new FakeReader(300, [log(110, 0), log(120, 1), log(120, 2, B), log(250, 0)]);
    const { index } = make(reader);
    await index.sync();
    const page = await index.page({ limit: 10 });
    expect(page).toMatchObject({ fromBlock: 100, lastBlock: 298, truncated: false, addresses: [A, B] });
    expect(page.logs.map((l) => `${l.block}:${l.index}`)).toEqual(['250:0', '120:2', '120:1', '110:0']);
  });

  it('flags truncation when there are more logs than the limit', async () => {
    const reader = new FakeReader(300, [log(110, 0), log(120, 0), log(130, 0)]);
    const { index } = make(reader);
    await index.sync();
    const page = await index.page({ limit: 2 });
    expect(page.truncated).toBe(true);
    expect(page.logs.map((l) => l.block)).toEqual([130, 120]);
  });

  it('filters by address case-insensitively', async () => {
    const reader = new FakeReader(300, [log(110, 0), log(120, 0, B)]);
    const { index } = make(reader);
    await index.sync();
    const page = await index.page({ address: B.toUpperCase().replace('0X', '0x'), limit: 10 });
    expect(page.logs.map((l) => l.address)).toEqual([B]);
  });

  it('before the first sync the coverage starts at the configured block', async () => {
    const { index } = make(new FakeReader(300));
    expect(await index.page({ limit: 5 })).toMatchObject({ fromBlock: 100, lastBlock: 99, logs: [], truncated: false });
  });
});
