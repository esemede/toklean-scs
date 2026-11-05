import { sha256Hex } from './schema.ts';
import type { ObjectKind, ObjectStore, StoredObject } from './object-store.ts';

/** Fija los archivos en IPFS con Pinata (requiere PINATA_JWT). */
export class PinataStore implements ObjectStore {
  readonly durable = true;
  constructor(
    private readonly jwt: string,
    private readonly fetchImpl: typeof fetch = fetch,
    /** Base de la API (en pruebas se apunta a un servidor local). */
    private readonly apiBase = 'https://api.pinata.cloud',
  ) {}

  async put(kind: ObjectKind, bytes: Uint8Array, contentType: string): Promise<StoredObject> {
    const id = sha256Hex(bytes);
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(bytes)], { type: contentType }), `${kind}-${id}`);
    form.append('pinataMetadata', JSON.stringify({ name: `toklean-${kind}-${id.slice(0, 16)}` }));
    form.append('pinataOptions', JSON.stringify({ cidVersion: 1 }));
    // Se llama como función suelta: `fetch` de Workers no acepta otro `this`.
    const doFetch = this.fetchImpl;
    const res = await doFetch(`${this.apiBase}/pinning/pinFileToIPFS`, {
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
