#!/usr/bin/env node
// Genera src/generated/abis.ts desde los artefactos de Foundry (../out). Requiere `forge build`.
// El resultado se versiona para que el backend funcione sin Foundry instalado.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const CONTRACTS = [
  'ToKleanMerchantRegistry',
  'ToKleanCatalog',
  'ToKleanMarketplace',
  'ToKleanToken',
  'CircularProductNFT',
];

let out = '// Generado por backend/scripts/gen-abis.mjs desde out/. No editar a mano.\n';
for (const name of CONTRACTS) {
  const { abi } = JSON.parse(readFileSync(join(root, 'out', `${name}.sol`, `${name}.json`), 'utf8'));
  const constName = `${name[0].toLowerCase()}${name.slice(1)}Abi`;
  out += `\nexport const ${constName} = ${JSON.stringify(abi, null, 2)} as const;\n`;
  console.log(`✓ ${name} (${abi.length} entradas)`);
}
writeFileSync(join(root, 'backend', 'src', 'generated', 'abis.ts'), out);
