import * as kiwi from "kiwi-schema";
import * as pako from "pako";
import * as fzstd from "fzstd";
const MAGIC = "fig-kiwi";
const inflate = b => (b[0] === 0x28 && b[1] === 0xb5 && b[2] === 0x2f && b[3] === 0xfd) ? fzstd.decompress(b) : pako.inflateRaw(b);
export function readFig(buf) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  if (Buffer.from(buf.slice(0, 8)).toString() !== MAGIC) throw new Error("not fig-kiwi");
  const version = dv.getUint32(8, true);
  const chunks = []; let o = 12;
  while (o < buf.length) { const n = dv.getUint32(o, true); chunks.push(buf.slice(o + 4, o + 4 + n)); o += 4 + n; }
  const schemaBin = kiwi.decodeBinarySchema(inflate(chunks[0]));
  const schema = kiwi.compileSchema(schemaBin);
  const message = schema.decodeMessage(inflate(chunks[1]));
  return { version, schemaBin, schema, message, rawChunks: chunks };
}
export function writeFig({ version, schemaBin, schema, message, rawChunks }) {
  const c0 = pako.deflateRaw(kiwi.encodeBinarySchema(schemaBin));
  const c1 = pako.deflateRaw(schema.encodeMessage(message));
  const chunks = [c0, c1, ...rawChunks.slice(2)];
  const len = 12 + chunks.reduce((a, c) => a + 4 + c.length, 0);
  const out = new Uint8Array(len); const dv = new DataView(out.buffer);
  out.set(Buffer.from(MAGIC)); dv.setUint32(8, version, true);
  let o = 12; for (const c of chunks) { dv.setUint32(o, c.length, true); out.set(c, o + 4); o += 4 + c.length; }
  return out;
}
