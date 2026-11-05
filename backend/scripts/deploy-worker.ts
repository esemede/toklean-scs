/**
 * Despliega el Worker del marketplace en Cloudflare de punta a punta. Es idempotente: se puede repetir en cada
 * actualización y sólo hace lo que falta. Funciona igual en Windows, macOS y Linux (no usa bash).
 *
 *   pnpm worker:release                  # despliegue completo
 *   pnpm worker:release --dry-run        # compila y valida sin tocar Cloudflare (no pide credenciales)
 *   pnpm worker:release --keep-secrets   # redespliegue sin volver a subir los secretos
 *   pnpm worker:release --skip-health    # no consulta /health al terminar
 *
 * Credenciales de Cloudflare: `wrangler login` (interactivo) o CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID.
 * Secretos (variables de entorno, no argumentos): RPC_URL (obligatoria), PINATA_JWT y KEEPER_PRIVATE_KEY (opcionales).
 *
 * Pasos: 1) crea la base D1 si no existe y escribe su id en wrangler.toml, 2) aplica las migraciones, 3) despliega el
 * Worker con los secretos, 4) comprueba /health y /v1/config y dice qué falta hacer en el frontend.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
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
} from './deploy-lib.ts';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const wranglerBin = join(root, 'node_modules', 'wrangler', 'bin', 'wrangler.js');
const tomlPath = join(root, 'wrangler.toml');
const flags = new Set(process.argv.slice(2));

const log = (m: string) => console.log(`[release] ${m}`);
function die(m: string): never {
  console.error(`[release] ERROR: ${m}`);
  process.exit(1);
}

interface RunOptions {
  input?: string;
  env?: Record<string, string>;
  capture?: boolean;
}

/** Ejecuta wrangler con el mismo Node (sin shell: sirve igual en Windows). */
function wrangler(args: string[], opts: RunOptions = {}) {
  const r = spawnSync(process.execPath, [wranglerBin, ...args], {
    cwd: root,
    encoding: 'utf8',
    input: opts.input,
    env: { ...process.env, ...opts.env },
    stdio: [opts.input === undefined ? 'inherit' : 'pipe', opts.capture ? 'pipe' : 'inherit', opts.capture ? 'pipe' : 'inherit'],
  });
  return { status: r.status ?? 1, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function getJson(url: string): Promise<unknown | undefined> {
  try {
    const res = await fetch(url);
    if (!res.ok) {
      log(`${url} respondió ${res.status}`);
      return undefined;
    }
    return await res.json();
  } catch {
    return undefined;
  }
}

/** El subdominio workers.dev de un Worker nuevo tarda unos segundos en resolver. */
async function waitForHealth(base: string): Promise<unknown | undefined> {
  for (let i = 0; i < 8; i++) {
    const body = await getJson(`${base}/health`);
    if (body !== undefined) return body;
    log('esperando que el Worker responda...');
    await sleep(4000);
  }
  return undefined;
}

async function main() {
  if (!existsSync(wranglerBin)) die('falta wrangler: ejecuta `pnpm install` dentro de backend/');

  if (flags.has('--dry-run')) {
    log('dry-run: compila el Worker sin subir nada ni tocar Cloudflare');
    process.exit(wrangler(['deploy', '--dry-run']).status);
  }

  // Falla pronto, antes de tocar Cloudflare, si faltan o están mal los secretos.
  let secrets: Record<string, string> = {};
  if (flags.has('--keep-secrets')) log('--keep-secrets: no se suben secretos (se conservan los actuales)');
  else {
    try {
      const built = buildSecrets(process.env);
      secrets = built.secrets;
      for (const s of built.skipped) log(`aviso: sin ${s}`);
    } catch (e) {
      die((e as Error).message);
    }
  }

  // 1) Base de datos D1
  const listed = wrangler(['d1', 'list', '--json'], { capture: true });
  if (listed.status !== 0) {
    die(
      `no pude consultar Cloudflare:\n${listed.stderr || listed.stdout}\n` +
        'Inicia sesión con `npx wrangler login` o define CLOUDFLARE_API_TOKEN y CLOUDFLARE_ACCOUNT_ID.',
    );
  }
  let dbId = findDatabaseId(parseJsonOutput(listed.stdout), DB_NAME);
  if (dbId) log(`base D1 "${DB_NAME}" ya existe (${dbId})`);
  else {
    log(`creando la base D1 "${DB_NAME}"...`);
    const created = wrangler(['d1', 'create', DB_NAME], { capture: true });
    if (created.status !== 0) die(`no pude crear la base D1:\n${created.stderr || created.stdout}`);
    const again = wrangler(['d1', 'list', '--json'], { capture: true });
    dbId = findDatabaseId(parseJsonOutput(again.stdout), DB_NAME);
    if (!dbId) die('la base D1 se creó pero no aparece en `wrangler d1 list`; revisa el panel de Cloudflare');
    log(`base D1 creada (${dbId})`);
  }

  const toml = readFileSync(tomlPath, 'utf8');
  const before = currentDatabaseId(toml);
  const updated = setDatabaseId(toml, dbId);
  if (updated !== toml) {
    writeFileSync(tomlPath, updated);
    log(
      before === DB_PLACEHOLDER
        ? 'wrangler.toml: database_id definido. Haz commit de este cambio.'
        : `wrangler.toml: database_id cambió (${before} → ${dbId}). Revisa y haz commit.`,
    );
  }

  // 2) Migraciones (aplica sólo las pendientes)
  log('aplicando migraciones en D1...');
  const migrated = wrangler(['d1', 'migrations', 'apply', DB_NAME, '--remote'], { input: 'y\n' });
  if (migrated.status !== 0) die('falló `d1 migrations apply`');

  // 3) Despliegue con secretos. El archivo de secretos vive en un directorio temporal y se borra siempre.
  const dir = mkdtempSync(join(tmpdir(), 'toklean-release-'));
  const outFile = join(dir, 'wrangler-output.ndjson');
  const deployArgs = ['deploy'];
  if (Object.keys(secrets).length > 0) {
    const secretsFile = join(dir, 'secrets.json');
    writeFileSync(secretsFile, JSON.stringify(secrets), { mode: 0o600 });
    deployArgs.push('--secrets-file', secretsFile);
    log(`subiendo secretos: ${Object.keys(secrets).join(', ')}`);
  }
  let url: string | undefined;
  try {
    log('desplegando el Worker...');
    const deployed = wrangler(deployArgs, { capture: true, env: { WRANGLER_OUTPUT_FILE_PATH: outFile } });
    process.stdout.write(deployed.stdout);
    process.stderr.write(deployed.stderr);
    if (deployed.status !== 0) {
      die(
        'falló `wrangler deploy`. Si es la primera vez en esta cuenta, registra tu subdominio workers.dev en ' +
          'Cloudflare > Workers & Pages y vuelve a ejecutar.',
      );
    }
    const output = existsSync(outFile) ? readFileSync(outFile, 'utf8') : '';
    url = parseDeployUrl(output, deployed.stdout);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  if (!url) {
    log('Worker desplegado, pero no pude leer su URL en la salida de wrangler; búscala en el panel de Cloudflare.');
    return;
  }
  log(`Worker desplegado: ${url}`);

  // 4) Comprobación
  if (!flags.has('--skip-health')) {
    const health = await waitForHealth(url);
    if (health === undefined) log(`aviso: ${url}/health no respondió todavía. Reintenta en un minuto.`);
    else log(`/health: ${JSON.stringify(health)}`);
    const config = (await getJson(`${url}/v1/config`)) as { chainId?: number } | undefined;
    if (config) log(`/v1/config: red ${config.chainId ?? '?'}`);
    log('el índice se completa con el cron (cada minuto); al principio /health puede decir ready=false.');
  }

  // Lo que falta fuera de este repositorio
  const origins = corsOrigins(readFileSync(tomlPath, 'utf8'));
  console.log(`
Siguientes pasos:
  1. Cloudflare Pages (frontend) > Settings > Environment variables:
       VITE_MARKETPLACE_API_URL = ${url}
     y vuelve a desplegar el frontend (Vite lee la variable al compilar).
  2. CORS_ORIGINS del Worker (wrangler.toml) autoriza hoy: ${origins.join(', ') || '(ninguno)'}
     Debe incluir el dominio de Pages y el de producción; si lo cambias, repite este comando.
  3. Haz commit de wrangler.toml si el database_id cambió.`);
}

main().catch((e) => die(e instanceof Error ? e.message : String(e)));
