import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Indexer } from '../src/indexer/indexer.ts';
import { MemorySnapshotStore } from '../src/indexer/snapshot.ts';
import { keeperTick, type TxSender } from '../src/keeper.ts';
import { emptyState, type OrderRecord } from '../src/types.ts';
import { BUYER, FakeChain, POLICY, SELLER } from './helpers.ts';

const NOW = 1_800_000_000;
const order = (id: number, status: OrderRecord['status'], deadline: number): OrderRecord => ({
  id,
  listingId: 1,
  buyer: BUYER,
  seller: SELLER,
  amount: '1',
  qty: 1,
  feeBps: 0,
  porBps: 0,
  paymentId: 1,
  paymentSymbol: 'TKN',
  status,
  rated: false,
  deadline,
});

let chain: FakeChain;
let indexer: Indexer;
let tx: { releaseAfterTimeout: ReturnType<typeof vi.fn>; withdraw: ReturnType<typeof vi.fn> };

beforeEach(() => {
  chain = new FakeChain();
  indexer = new Indexer({ chain, chainId: 31337, startBlock: 1, snapshots: new MemorySnapshotStore(), fetchJson: async () => ({}), policy: POLICY });
  indexer.state = emptyState(31337, 1);
  tx = { releaseAfterTimeout: vi.fn(async () => '0xabc' as const), withdraw: vi.fn(async () => '0xdef' as const) };
});

const run = (flags: { autoRelease: boolean; autoWithdraw: boolean }) =>
  keeperTick({ indexer, chain, tx: tx as unknown as TxSender, now: () => NOW, ...flags });

describe('keeperTick', () => {
  it('releases only shipped orders whose confirmation window expired', async () => {
    indexer.state.orders = {
      1: order(1, 'shipped', NOW - 1),
      2: order(2, 'shipped', NOW + 100),
      3: order(3, 'paid', NOW - 1000),
      4: order(4, 'disputed', NOW - 1000),
      5: order(5, 'completed', NOW - 1000),
      6: order(6, 'shipped', NOW),
    };
    const r = await run({ autoRelease: true, autoWithdraw: false });
    expect(r.released.sort()).toEqual([1, 6]);
    expect(tx.releaseAfterTimeout).toHaveBeenCalledTimes(2);
    expect(tx.withdraw).not.toHaveBeenCalled();
  });

  it('does nothing when both features are off', async () => {
    indexer.state.orders = { 1: order(1, 'shipped', NOW - 1) };
    indexer.state.pendingWithdrawals = [SELLER];
    const r = await run({ autoRelease: false, autoWithdraw: false });
    expect(r).toEqual({ released: [], withdrawn: [], errors: [] });
    expect(tx.releaseAfterTimeout).not.toHaveBeenCalled();
    expect(tx.withdraw).not.toHaveBeenCalled();
  });

  it('withdraws every non-zero balance to its owner and clears the queue', async () => {
    indexer.state.pendingWithdrawals = [SELLER, BUYER];
    chain.claimable.set(SELLER.toLowerCase(), { 1: 5n, 2: 3n, 3: 0n });
    const r = await run({ autoRelease: false, autoWithdraw: true });
    expect(tx.withdraw.mock.calls).toEqual([[SELLER, 1], [SELLER, 2]]);
    expect(r.withdrawn).toEqual([{ account: SELLER, id: 1 }, { account: SELLER, id: 2 }]);
    expect(indexer.state.pendingWithdrawals).toEqual([]);
  });

  it('keeps an account queued when its transaction fails, and keeps going', async () => {
    indexer.state.orders = { 1: order(1, 'shipped', NOW - 1), 2: order(2, 'shipped', NOW - 1) };
    indexer.state.pendingWithdrawals = [SELLER, BUYER];
    chain.claimable.set(SELLER.toLowerCase(), { 1: 5n, 2: 0n, 3: 0n });
    chain.claimable.set(BUYER.toLowerCase(), { 1: 0n, 2: 7n, 3: 0n });
    tx.releaseAfterTimeout.mockRejectedValueOnce(new Error('revert'));
    tx.withdraw.mockRejectedValueOnce(new Error('out of gas'));

    const r = await run({ autoRelease: true, autoWithdraw: true });
    expect(r.released).toEqual([2]);
    expect(r.errors).toHaveLength(2);
    expect(r.withdrawn).toEqual([{ account: BUYER, id: 2 }]);
    expect(indexer.state.pendingWithdrawals).toEqual([SELLER]);
  });
});
