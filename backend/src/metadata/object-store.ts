/** Contrato de almacenamiento de archivos y metadata (sin dependencias de Node). */

export type ObjectKind = 'metadata' | 'media';

export interface StoredObject {
  /** URI que se guarda on-chain / dentro de la metadata (ipfs://... o URL de este backend). */
  uri: string;
  id: string;
}

export interface ObjectStore {
  put(kind: ObjectKind, bytes: Uint8Array, contentType: string): Promise<StoredObject>;
  /** Sólo el almacenamiento local sirve archivos; con IPFS los sirve el gateway. */
  get(kind: ObjectKind, id: string): Promise<{ bytes: Uint8Array; contentType: string } | null>;
  readonly durable: boolean;
}
