/** Contrato de persistencia del índice (sin dependencias de Node). */
import type { IndexState } from '../types.ts';

export interface SnapshotStore {
  load(): Promise<IndexState | null>;
  save(state: IndexState): Promise<void>;
}
