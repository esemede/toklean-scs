import { describe, expect, it } from 'vitest';
import {
  DB_NAME,
  DB_PLACEHOLDER,
  buildSecrets,
  corsOrigins,
  currentDatabaseId,
  findDatabaseId,
  parseDeployUrl,
  parseJsonOutput,
  setDatabaseId,
} from '../scripts/deploy-lib.ts';

const ID = '3f2c1d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f';

const TOML = `name = "toklean-marketplace"

[[d1_databases]]
binding = "DB"
database_name = "toklean-marketplace"
database_id = "${DB_PLACEHOLDER}"
migrations_dir = "worker/migrations"

[vars]
CORS_ORIGINS = "https://toklean.cl, https://toklean-front.pages.dev"
`;

describe('parseJsonOutput', () => {
  it('lee el JSON aunque wrangler imprima avisos antes', () => {
    const out = '\u001b[33m▲ [WARNING] Proxy environment variables detected.\n\n[{"name":"a","uuid":"x"}]\n';
    expect(parseJsonOutput(out)).toEqual([{ name: 'a', uuid: 'x' }]);
  });
  it('falla si no hay JSON', () => {
    expect(() => parseJsonOutput('sin json')).toThrow();
  });
});

describe('findDatabaseId', () => {
  it('encuentra la base por nombre', () => {
    const list = [
      { name: 'otra', uuid: '11111111-1111-4111-8111-111111111111' },
      { name: DB_NAME, uuid: ID },
    ];
    expect(findDatabaseId(list, DB_NAME)).toBe(ID);
  });
  it('acepta database_id o id como nombre del campo', () => {
    expect(findDatabaseId([{ name: DB_NAME, database_id: ID }], DB_NAME)).toBe(ID);
    expect(findDatabaseId([{ name: DB_NAME, id: ID }], DB_NAME)).toBe(ID);
  });
  it('devuelve undefined si no existe o el id no es un UUID', () => {
    expect(findDatabaseId([], DB_NAME)).toBeUndefined();
    expect(findDatabaseId([{ name: DB_NAME, uuid: 'no-es-uuid' }], DB_NAME)).toBeUndefined();
    expect(findDatabaseId({ not: 'array' }, DB_NAME)).toBeUndefined();
  });
});

describe('wrangler.toml', () => {
  it('reemplaza el marcador por el id real y es idempotente', () => {
    expect(currentDatabaseId(TOML)).toBe(DB_PLACEHOLDER);
    const next = setDatabaseId(TOML, ID);
    expect(currentDatabaseId(next)).toBe(ID);
    expect(next).toContain('binding = "DB"');
    expect(setDatabaseId(next, ID)).toBe(next);
  });
  it('rechaza ids inválidos y archivos sin database_id', () => {
    expect(() => setDatabaseId(TOML, 'abc')).toThrow(/inválido/);
    expect(() => setDatabaseId('name = "x"', ID)).toThrow(/database_id/);
  });
  it('lista los orígenes CORS', () => {
    expect(corsOrigins(TOML)).toEqual(['https://toklean.cl', 'https://toklean-front.pages.dev']);
    expect(corsOrigins('name = "x"')).toEqual([]);
  });
});

describe('parseDeployUrl', () => {
  it('usa el archivo de salida de wrangler', () => {
    const file =
      '{"type":"wrangler-session","version":1}\n' +
      '{"type":"deploy","targets":["https://toklean-marketplace.cuenta.workers.dev/"]}\n';
    expect(parseDeployUrl(file, '')).toBe('https://toklean-marketplace.cuenta.workers.dev');
  });
  it('cae a la salida de texto si el archivo no sirve', () => {
    const stdout = 'Deployed toklean-marketplace triggers\n  https://toklean-marketplace.cuenta.workers.dev\n';
    expect(parseDeployUrl('', stdout)).toBe('https://toklean-marketplace.cuenta.workers.dev');
    expect(parseDeployUrl('basura\n', 'nada')).toBeUndefined();
  });
});

describe('buildSecrets', () => {
  const KEY = `0x${'ab'.repeat(32)}`;

  it('exige RPC_URL https', () => {
    expect(() => buildSecrets({})).toThrow(/RPC_URL/);
    expect(() => buildSecrets({ RPC_URL: 'no-es-url' })).toThrow(/válida/);
    expect(() => buildSecrets({ RPC_URL: 'http://rpc.example' })).toThrow(/https/);
  });
  it('incluye sólo los secretos presentes y avisa de los opcionales', () => {
    const r = buildSecrets({ RPC_URL: 'https://rpc.example/key' });
    expect(r.secrets).toEqual({ RPC_URL: 'https://rpc.example/key' });
    expect(r.skipped).toHaveLength(2);
  });
  it('incluye Pinata y keeper cuando se definen', () => {
    const r = buildSecrets({ RPC_URL: 'https://rpc.example', PINATA_JWT: ' jwt ', KEEPER_PRIVATE_KEY: KEY });
    expect(r.secrets).toEqual({ RPC_URL: 'https://rpc.example', PINATA_JWT: 'jwt', KEEPER_PRIVATE_KEY: KEY });
    expect(r.skipped).toEqual([]);
  });
  it('rechaza una clave del keeper mal formada sin imprimirla', () => {
    try {
      buildSecrets({ RPC_URL: 'https://rpc.example', KEEPER_PRIVATE_KEY: '0x1234' });
      expect.unreachable();
    } catch (e) {
      expect((e as Error).message).toMatch(/KEEPER_PRIVATE_KEY/);
      expect((e as Error).message).not.toContain('0x1234');
    }
  });
});
