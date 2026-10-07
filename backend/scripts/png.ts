import { crc32, deflateSync } from 'node:zlib';

/** PNG RGBA de un degradado diagonal entre dos colores (sin dependencias): imágenes de demostración. */
export function gradientPng(from: [number, number, number], to: [number, number, number], width = 240, height = 180): Uint8Array {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0; // filtro "none"
    for (let x = 0; x < width; x++) {
      const t = (x / width + y / height) / 2;
      const o = y * (width * 4 + 1) + 1 + x * 4;
      for (let c = 0; c < 3; c++) raw[o + c] = Math.round(from[c]! + (to[c]! - from[c]!) * t);
      raw[o + 3] = 255;
    }
  }
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // profundidad
  ihdr[9] = 6; // RGBA
  return new Uint8Array(
    Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]),
  );
}
