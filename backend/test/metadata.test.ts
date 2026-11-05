import { describe, expect, it } from 'vitest';
import { canonicalize, listingMetadataSchema, merchantProfileSchema, sha256Hex } from '../src/metadata/schema.ts';
import { resolveUri } from '../src/metadata/uri.ts';
import { CID, listingMeta, merchantProfile, POLICY } from './helpers.ts';

describe('listing metadata schema', () => {
  it('accepts a complete valid document', () => {
    const ok = listingMetadataSchema.safeParse(
      listingMeta({
        images: [`ipfs://${CID}/2.png`, 'https://cdn.example.com/3.webp'],
        condition: 'new',
        sustainability: { recycledContentPct: 80, co2eKg: 1.5, certifications: ['ISO 14001'] },
        shipping: { regions: ['CL'], days: 5, carbonOffset: true },
      }),
    );
    expect(ok.success).toBe(true);
  });

  it.each([
    ['unknown field', { extra: 1 }],
    ['empty name', { name: '   ' }],
    ['name too long', { name: 'x'.repeat(121) }],
    ['bad category', { category: 'weapons' }],
    ['javascript: image', { image: 'javascript:alert(1)' }],
    ['data: image', { image: 'data:image/png;base64,AAAA' }],
    ['file: image', { image: 'file:///etc/passwd' }],
    ['too many tags', { tags: Array.from({ length: 9 }, (_, i) => `t${i}`) }],
    ['percentage over 100', { sustainability: { recycledContentPct: 101 } }],
    ['wrong schema version', { schema: 'toklean.listing/2' }],
  ])('rejects %s', (_label, over) => {
    expect(listingMetadataSchema.safeParse(listingMeta(over)).success).toBe(false);
  });

  it('trims strings', () => {
    const r = listingMetadataSchema.parse(listingMeta({ name: '  Maceta  ' }));
    expect(r.name).toBe('Maceta');
  });
});

describe('merchant profile schema', () => {
  it('accepts a profile and rejects bad fields', () => {
    expect(merchantProfileSchema.safeParse(merchantProfile({ website: 'https://ecotienda.cl' })).success).toBe(true);
    expect(merchantProfileSchema.safeParse(merchantProfile({ country: 'chile' })).success).toBe(false);
    expect(merchantProfileSchema.safeParse(merchantProfile({ website: 'http://ecotienda.cl' })).success).toBe(false);
    expect(merchantProfileSchema.safeParse(merchantProfile({ logo: 'javascript:1' })).success).toBe(false);
  });
});

describe('canonicalize', () => {
  it('is independent of key order and drops undefined', () => {
    const a = canonicalize({ b: 1, a: { d: [3, { y: 1, x: 2 }], c: undefined } });
    const b = canonicalize({ a: { c: undefined, d: [3, { x: 2, y: 1 }] }, b: 1 });
    expect(a).toBe(b);
    expect(a).toBe('{"a":{"d":[3,{"x":2,"y":1}]},"b":1}');
    expect(sha256Hex(a)).toBe(sha256Hex(b));
  });
});

describe('resolveUri policy', () => {
  it('maps ipfs:// through the gateway', () => {
    expect(resolveUri(`ipfs://${CID}`, POLICY)).toEqual({ kind: 'ipfs', url: `https://gw.test/ipfs/${CID}` });
    expect(resolveUri(`ipfs://${CID}/a/b.png`, POLICY)?.url).toBe(`https://gw.test/ipfs/${CID}/a/b.png`);
  });
  it('allows this backend and allow-listed https hosts only', () => {
    expect(resolveUri('http://localhost:8787/v1/media/abc', POLICY)?.kind).toBe('http');
    expect(resolveUri('https://cdn.example.com/a.png', POLICY)?.kind).toBe('http');
    expect(resolveUri('https://evil.example.org/a.png', POLICY)).toBeNull();
    expect(resolveUri('http://cdn.example.com/a.png', POLICY)).toBeNull();
    expect(resolveUri('http://localhost:9999/x', POLICY)).toBeNull();
  });
  it('rejects credentials, dangerous schemes and garbage', () => {
    for (const bad of ['https://user:pw@cdn.example.com/a', 'javascript:alert(1)', 'data:text/html,x', 'file:///etc/passwd', 'ipfs://short', 'not a url', '']) {
      expect(resolveUri(bad, POLICY), bad).toBeNull();
    }
  });
});
