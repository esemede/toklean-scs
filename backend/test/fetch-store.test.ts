import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { createJsonFetcher, MetadataFetchError } from '../src/metadata/fetch.ts';
import { FileStore, PinataStore } from '../src/metadata/store.ts';
import { sha256Hex } from '../src/metadata/schema.ts';
import { CID, POLICY } from './helpers.ts';

const reply = (body: string | null, init: ResponseInit = {}) => Promise.resolve(new Response(body, init));

describe('createJsonFetcher', () => {
  it('downloads JSON through the gateway', async () => {
    const fetchImpl = vi.fn((_url: string, _init?: RequestInit) => reply('{"a":1}', { headers: { 'content-type': 'application/json' } }));
    const fetchJson = createJsonFetcher({ policy: POLICY, fetchImpl: fetchImpl as unknown as typeof fetch });
    await expect(fetchJson(`ipfs://${CID}`)).resolves.toEqual({ a: 1 });
    expect(fetchImpl.mock.calls[0]![0]).toBe(`https://gw.test/ipfs/${CID}`);
    expect(fetchImpl.mock.calls[0]![1]?.redirect).toBe('manual');
  });

  it('refuses URIs outside the policy without touching the network', async () => {
    const fetchImpl = vi.fn();
    const fetchJson = createJsonFetcher({ policy: POLICY, fetchImpl: fetchImpl as unknown as typeof fetch });
    await expect(fetchJson('https://evil.example.org/x.json')).rejects.toMatchObject({ permanent: true });
    await expect(fetchJson('http://169.254.169.254/latest/meta-data')).rejects.toMatchObject({ permanent: true });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('classifies failures as transient or permanent', async () => {
    const run = (res: () => Promise<Response>) => createJsonFetcher({ policy: POLICY, fetchImpl: res as unknown as typeof fetch })(`ipfs://${CID}`);
    await expect(run(() => reply('', { status: 404 }))).rejects.toMatchObject({ permanent: false });
    await expect(run(() => reply('', { status: 503 }))).rejects.toMatchObject({ permanent: false });
    await expect(run(() => reply('', { status: 429 }))).rejects.toMatchObject({ permanent: false });
    await expect(run(() => reply('', { status: 403 }))).rejects.toMatchObject({ permanent: true });
    await expect(run(() => reply('', { status: 302, headers: { location: 'https://evil.example/x' } }))).rejects.toMatchObject({ permanent: true });
    await expect(run(() => reply('not json'))).rejects.toMatchObject({ permanent: true });
    await expect(run(() => Promise.reject(new Error('ECONNRESET')))).rejects.toMatchObject({ permanent: false });
  });

  it('enforces the size cap on declared and streamed bodies', async () => {
    const big = 'x'.repeat(2000);
    const small = createJsonFetcher({ policy: POLICY, maxBytes: 1000, fetchImpl: (() => reply(big)) as unknown as typeof fetch });
    await expect(small(`ipfs://${CID}`)).rejects.toBeInstanceOf(MetadataFetchError);
    const declared = createJsonFetcher({
      policy: POLICY,
      maxBytes: 1000,
      fetchImpl: (() => reply('{}', { headers: { 'content-length': '5000' } })) as unknown as typeof fetch,
    });
    await expect(declared(`ipfs://${CID}`)).rejects.toMatchObject({ permanent: true });
  });
});

describe('FileStore', () => {
  let dir = '';
  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), 'toklean-store-'));
  });
  afterAll(() => rm(dir, { recursive: true, force: true }));

  it('stores by content hash and serves it back', async () => {
    const store = new FileStore(dir, 'http://localhost:8787');
    const bytes = new TextEncoder().encode('{"hello":"world"}');
    const put = await store.put('metadata', bytes, 'application/json');
    expect(put.id).toBe(sha256Hex(bytes));
    expect(put.uri).toBe(`http://localhost:8787/v1/metadata/${put.id}`);
    const got = await store.get('metadata', put.id);
    expect(got?.contentType).toBe('application/json');
    expect(Buffer.from(got!.bytes).toString()).toBe('{"hello":"world"}');
    // Mismo contenido, misma URI
    expect((await store.put('metadata', bytes, 'application/json')).uri).toBe(put.uri);
    expect(store.durable).toBe(false);
  });

  it('never resolves ids that are not a sha256 (no path traversal)', async () => {
    const store = new FileStore(dir, 'http://localhost:8787');
    for (const id of ['../../etc/passwd', '..%2f..%2fetc', 'abc', `${'a'.repeat(63)}/`, '']) {
      expect(await store.get('media', id), id).toBeNull();
    }
    expect(await store.get('media', 'f'.repeat(64))).toBeNull();
  });
});

describe('PinataStore', () => {
  it('pins through the Pinata API and returns an ipfs:// URI', async () => {
    const fetchImpl = vi.fn(() => reply(JSON.stringify({ IpfsHash: CID }), { status: 200 }));
    const store = new PinataStore('jwt-secret', fetchImpl as unknown as typeof fetch);
    const put = await store.put('media', new Uint8Array([1, 2, 3]), 'image/png');
    expect(put.uri).toBe(`ipfs://${CID}`);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://api.pinata.cloud/pinning/pinFileToIPFS');
    expect((init.headers as Record<string, string>).authorization).toBe('Bearer jwt-secret');
    expect(store.durable).toBe(true);
  });

  it('surfaces provider failures', async () => {
    const store = new PinataStore('jwt', (() => reply('nope', { status: 401 })) as unknown as typeof fetch);
    await expect(store.put('media', new Uint8Array([1]), 'image/png')).rejects.toThrow(/401/);
    const empty = new PinataStore('jwt', (() => reply('{}')) as unknown as typeof fetch);
    await expect(empty.put('media', new Uint8Array([1]), 'image/png')).rejects.toThrow(/CID/);
  });
});
