#!/usr/bin/env node
// Servidor local que imita lo que el backend usa de Pinata: `POST /pinning/pinFileToIPFS` y el gateway `GET /ipfs/<cid>`.
// Sólo para pruebas y desarrollo sin cuenta: guarda en memoria y calcula un CID determinista desde el contenido.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';

const PORT = Number(process.env.PORT ?? 9000);
const files = new Map(); // cid -> { bytes, type }

const server = createServer(async (req, res) => {
  try {
    if (req.method === 'POST' && req.url === '/pinning/pinFileToIPFS') {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const form = await new Request('http://stub/', { method: 'POST', headers: req.headers, body: Buffer.concat(chunks) }).formData();
      const file = form.get('file');
      const bytes = new Uint8Array(await file.arrayBuffer());
      const cid = 'bafy' + createHash('sha256').update(bytes).digest('hex').slice(0, 52);
      files.set(cid, { bytes, type: file.type || 'application/octet-stream' });
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ IpfsHash: cid }));
    }
    const m = /^\/ipfs\/([A-Za-z0-9]+)/.exec(req.url ?? '');
    if (req.method === 'GET' && m) {
      const f = files.get(m[1]);
      if (!f) {
        res.writeHead(404);
        return res.end('no');
      }
      res.writeHead(200, { 'content-type': f.type, 'access-control-allow-origin': '*' });
      return res.end(Buffer.from(f.bytes));
    }
    res.writeHead(404);
    res.end('no');
  } catch (e) {
    res.writeHead(500);
    res.end(String(e));
  }
});
server.listen(PORT, '127.0.0.1', () => console.log(`stub pinata en http://127.0.0.1:${PORT}`));
