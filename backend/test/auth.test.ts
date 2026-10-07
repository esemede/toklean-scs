import { describe, expect, it } from 'vitest';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { authHeader, RateLimiter, uploadMessage, verifyUploadAuth, AuthError } from '../src/auth.ts';

const account = privateKeyToAccount(generatePrivateKey());
const NOW = 1_800_000_000;
const HASH = 'a'.repeat(64);

async function sign(kind: 'metadata' | 'media', hash: string, ts: number, signer = account) {
  const signature = await signer.signMessage({ message: uploadMessage(kind, hash, ts) });
  return authHeader(signer.address, ts, signature);
}

describe('verifyUploadAuth', () => {
  it('accepts a fresh signature over the same content', async () => {
    expect(await verifyUploadAuth(await sign('media', HASH, NOW), 'media', HASH, NOW)).toBe(account.address);
  });

  it('rejects a missing or malformed header', async () => {
    await expect(verifyUploadAuth(null, 'media', HASH, NOW)).rejects.toMatchObject({ code: 'missing' });
    await expect(verifyUploadAuth('Bearer x', 'media', HASH, NOW)).rejects.toMatchObject({ code: 'format' });
    await expect(verifyUploadAuth(`ToKlean ${account.address}.${NOW}.0x12`, 'media', HASH, NOW)).rejects.toMatchObject({ code: 'format' });
  });

  it('rejects stale and future timestamps', async () => {
    await expect(verifyUploadAuth(await sign('media', HASH, NOW - 301), 'media', HASH, NOW)).rejects.toMatchObject({ code: 'expired' });
    await expect(verifyUploadAuth(await sign('media', HASH, NOW + 301), 'media', HASH, NOW)).rejects.toMatchObject({ code: 'expired' });
    await expect(verifyUploadAuth(await sign('media', HASH, NOW - 299), 'media', HASH, NOW)).resolves.toBe(account.address);
  });

  it('binds the signature to the content, the kind and the signer', async () => {
    const header = await sign('media', HASH, NOW);
    await expect(verifyUploadAuth(header, 'media', 'b'.repeat(64), NOW)).rejects.toMatchObject({ code: 'signature' });
    await expect(verifyUploadAuth(header, 'metadata', HASH, NOW)).rejects.toMatchObject({ code: 'signature' });

    // Firma de otra cuenta con la dirección de la víctima en el encabezado
    const attacker = privateKeyToAccount(generatePrivateKey());
    const forged = authHeader(account.address, NOW, await attacker.signMessage({ message: uploadMessage('media', HASH, NOW) }));
    await expect(verifyUploadAuth(forged, 'media', HASH, NOW)).rejects.toBeInstanceOf(AuthError);
  });
});

describe('RateLimiter', () => {
  it('allows `limit` hits per window per key and recovers afterwards', () => {
    const rl = new RateLimiter(3, 100);
    expect([1, 2, 3, 4].map(() => rl.take('a', 1000))).toEqual([true, true, true, false]);
    expect(rl.take('b', 1000)).toBe(true);
    expect(rl.take('a', 1099)).toBe(false);
    expect(rl.take('a', 1101)).toBe(true);
  });
});
