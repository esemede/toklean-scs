import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { sha256Hex } from './schema.ts';
import type { ObjectKind, ObjectStore, StoredObject } from './object-store.ts';

export type { ObjectKind, ObjectStore, StoredObject } from './object-store.ts';
export { PinataStore } from './pinata.ts';
import { PinataStore } from './pinata.ts';

const SAFE_ID = /^[a-f0-9]{64}$/;

/** Archivos en disco, direccionados por sha256. Sólo desarrollo: no es durable ni replicado. */
export class FileStore implements ObjectStore {
  readonly durable = false;
  constructor(
    private readonly dir: string,
    private readonly baseUrl: string,
  ) {}

  async put(kind: ObjectKind, bytes: Uint8Array, contentType: string): Promise<StoredObject> {
    const id = sha256Hex(bytes);
    const base = join(this.dir, kind);
    await mkdir(base, { recursive: true });
    const tmp = join(base, `${id}.tmp-${process.pid}-${Date.now()}`);
    await writeFile(tmp, bytes);
    await rename(tmp, join(base, id));
    await writeFile(join(base, `${id}.type`), contentType);
    return { id, uri: `${this.baseUrl}/v1/${kind}/${id}` };
  }

  async get(kind: ObjectKind, id: string) {
    if (!SAFE_ID.test(id)) return null;
    try {
      const base = join(this.dir, kind);
      const [bytes, type] = await Promise.all([readFile(join(base, id)), readFile(join(base, `${id}.type`), 'utf8')]);
      return { bytes, contentType: type };
    } catch {
      return null;
    }
  }
}

export function createStore(opts: { pinataJwt?: string; dataDir: string; baseUrl: string }): ObjectStore {
  return opts.pinataJwt ? new PinataStore(opts.pinataJwt) : new FileStore(join(opts.dataDir, 'objects'), opts.baseUrl);
}
