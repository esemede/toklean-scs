-- Estado del índice del marketplace (ver worker/d1-snapshot.ts). Cada fila es un registro en JSON.
-- Sólo se reescriben las filas que cambiaron; el estado completo se reconstruye desde la cadena si falta.
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS merchants (key TEXT PRIMARY KEY, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS listings (key TEXT PRIMARY KEY, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS orders (key TEXT PRIMARY KEY, json TEXT NOT NULL);
