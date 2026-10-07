import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { sha256Hex } from './schema.ts';

export type ObjectKind = 'metadata' | 'media';

export interface StoredObject {
  /** URI que se guarda on-chain / dentro de la metadata (ipfs://... o URL de este backend). */
  uri: string;
  id: string;
}

export interface ObjectStore {
  put(kind: ObjectKind, bytes: Uint8Array, contentType: string): Promise<StoredObject>;
  /** Sólo el almacenamiento local sirve archivos; con IPFS los sirve el gateway. */
  get(kind: ObjectKind, id: string): Promise<{ bytes: Uint8Array; contentType: string } | null>;
  readonly durable: boolean;
}

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

/** Fija los archivos en IPFS con Pinata (requiere PINATA_JWT). */
export class PinataStore implements ObjectStore {
  readonly durable = true;
  constructor(
    private readonly jwt: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async put(kind: ObjectKind, bytes: Uint8Array, contentType: string): Promise<StoredObject> {
    const id = sha256Hex(bytes);
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(bytes)], { type: contentType }), `${kind}-${id}`);
    form.append('pinataMetadata', JSON.stringify({ name: `toklean-${kind}-${id.slice(0, 16)}` }));
    form.append('pinataOptions', JSON.stringify({ cidVersion: 1 }));
    const res = await this.fetchImpl('https://api.pinata.cloud/pinning/pinFileToIPFS', {
      method: 'POST',
      headers: { authorization: `Bearer ${this.jwt}` },
      body: form,
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) throw new Error(`Pinata respondió ${res.status}`);
    const body = (await res.json()) as { IpfsHash?: string };
    if (!body.IpfsHash) throw new Error('Pinata no devolvió un CID');
    return { id, uri: `ipfs://${body.IpfsHash}` };
  }

  async get() {
    return null;
  }
}

export function createStore(opts: { pinataJwt?: string; dataDir: string; baseUrl: string }): ObjectStore {
  return opts.pinataJwt ? new PinataStore(opts.pinataJwt) : new FileStore(join(opts.dataDir, 'objects'), opts.baseUrl);
}
