#!/usr/bin/env node
// Exporta los ABIs compilados (out/) a TypeScript `as const` para viem/wagmi.
// Uso: forge build && node script/export-abis.mjs ../toklean-front/src/abi/impact
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

const CONTRACTS = [
  'TreeNFT',
  'RecyclingIdeaNFT',
  'RecyclingBatchNFT',
  'CircularProductNFT',
  'CleanupActionNFT',
  'ToKleanToken',
  'ToKleanStaking',
  'ToKleanGovernance',
  'TokenFaucet',
  'ToKleanMerchantRegistry',
  'ToKleanCatalog',
  'ToKleanMarketplace',
];
const target = resolve(process.argv[2] ?? '../toklean-front/src/abi/impact');
mkdirSync(target, { recursive: true });

const exports = [];
for (const name of CONTRACTS) {
  const { abi } = JSON.parse(readFileSync(join('out', `${name}.sol`, `${name}.json`), 'utf8'));
  const constName = `${name[0].toLowerCase()}${name.slice(1)}Abi`;
  writeFileSync(
    join(target, `${name}.ts`),
    `// Generado por toklean-scs/script/export-abis.mjs. No editar a mano.\n` +
      `export const ${constName} = ${JSON.stringify(abi, null, 2)} as const;\n`,
  );
  exports.push(`export { ${constName} } from './${name}';`);
  console.log(`✓ ${name}`);
}
writeFileSync(join(target, 'index.ts'), exports.join('\n') + '\n');
