import { readFileSync } from 'node:fs';

import { parseDeployment, type Deployment } from './deployment-schema.ts';

export { parseDeployment, type Deployment } from './deployment-schema.ts';

export function loadDeployment(file: string, expectedChainId?: number): Deployment {
  const d = parseDeployment(JSON.parse(readFileSync(file, 'utf8')));
  if (expectedChainId !== undefined && d.chainId !== expectedChainId) {
    throw new Error(`deployments es de la red ${d.chainId} pero CHAIN_ID=${expectedChainId}`);
  }
  return d;
}
