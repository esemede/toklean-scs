-- Logs crudos de los contratos que sigue la app (ver worker/d1-log-store.ts). (block, idx) es único: repetir un tramo
-- no duplica filas. El cursor del índice vive en `meta` con la clave 'logs'.
CREATE TABLE IF NOT EXISTS logs (
  block INTEGER NOT NULL,
  idx INTEGER NOT NULL,
  address TEXT NOT NULL,
  json TEXT NOT NULL,
  PRIMARY KEY (block, idx)
);
CREATE INDEX IF NOT EXISTS logs_address_block ON logs (address, block DESC);
