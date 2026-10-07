import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { IndexState } from '../types.ts';

export interface SnapshotStore {
  load(): Promise<IndexState | null>;
  save(state: IndexState): Promise<void>;
}

export class MemorySnapshotStore implements SnapshotStore {
  saved: IndexState | null = null;
  async load() {
    return this.saved ? structuredClone(this.saved) : null;
  }
  async save(state: IndexState) {
    this.saved = structuredClone(state);
  }
}

/** JSON en disco con escritura atómica (archivo temporal + rename). */
export class FileSnapshotStore implements SnapshotStore {
  constructor(private readonly path: string) {}

  async load() {
    try {
      return JSON.parse(await readFile(this.path, 'utf8')) as IndexState;
    } catch {
      return null;
    }
  }

  async save(state: IndexState) {
    await mkdir(dirname(this.path), { recursive: true });
    const tmp = `${this.path}.tmp-${process.pid}`;
    await writeFile(tmp, JSON.stringify(state));
    await rename(tmp, this.path);
  }
}
