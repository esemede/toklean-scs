import type { Address, PublicClient } from 'viem';
import type { RawLog, RawLogReader } from './types.ts';

/** Lector de logs crudos de varios contratos con un cliente viem. */
export function viemRawLogReader(client: PublicClient, addresses: Address[]): RawLogReader {
  return {
    getBlockNumber: () => client.getBlockNumber({ cacheTime: 0 }),
    async getLogs(from, to) {
      const logs = await client.getLogs({ address: addresses, fromBlock: from, toBlock: to });
      return logs.flatMap((l): RawLog[] =>
        l.blockNumber == null || l.logIndex == null
          ? []
          : [{ block: Number(l.blockNumber), index: l.logIndex, address: l.address.toLowerCase(), topics: [...l.topics], data: l.data, tx: l.transactionHash ?? '' }],
      );
    },
  };
}
