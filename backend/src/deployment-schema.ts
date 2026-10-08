import { z } from 'zod';
import type { Address } from 'viem';

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/).transform((v) => v as Address);

const schema = z.object({
  chainId: z.number().int().positive(),
  ToKleanToken: address,
  CircularProductNFT: address,
  ToKleanMerchantRegistry: address,
  ToKleanCatalog: address,
  ToKleanMarketplace: address,
  marketplaceStartBlock: z.number().int().min(0),
});

export type Deployment = z.infer<typeof schema>;

export function parseDeployment(raw: unknown): Deployment {
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    const missing = parsed.error.issues.map((i) => i.path.join('.')).join(', ');
    throw new Error(`deployments inválido (¿falta desplegar el marketplace? campos: ${missing})`);
  }
  return parsed.data;
}
