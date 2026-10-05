'use strict';
// Minimal OSC 1.0 encoder / decoder for tests and the engine stand-in (the app itself leaves OSC to the engine).

function pad(buf) {
  const n = Math.ceil((buf.length + 1) / 4) * 4;
  const out = Buffer.alloc(n);
  buf.copy(out);
  return out;
}

function encode(address, args = []) {
  const parts = [pad(Buffer.from(address, 'utf8'))];
  let tags = ',';
  const data = [];
  for (const a of args) {
    if (typeof a === 'string') { tags += 's'; data.push(pad(Buffer.from(a, 'utf8'))); }
    else if (Buffer.isBuffer(a)) {
      tags += 'b';
      const len = Buffer.alloc(4); len.writeUInt32BE(a.length);
      const body = Buffer.alloc(Math.ceil(a.length / 4) * 4); a.copy(body);
      data.push(len, body);
    } else if (Number.isInteger(a.i)) { tags += 'i'; const b = Buffer.alloc(4); b.writeInt32BE(a.i); data.push(b); }
    else { tags += 'f'; const b = Buffer.alloc(4); b.writeFloatBE(typeof a === 'number' ? a : a.f); data.push(b); }
  }
  parts.push(pad(Buffer.from(tags, 'latin1')), ...data);
  return Buffer.concat(parts);
}

function readString(buf, i) {
  const end = buf.indexOf(0, i);
  const s = buf.toString('utf8', i, end);
  return [s, (end + 4) & ~3];
}

function decode(buf) {
  let [address, i] = readString(buf, 0);
  if (i >= buf.length) return { address, tags: '', args: [] };
  let tags;
  [tags, i] = readString(buf, i);
  const args = [];
  for (const t of tags.slice(1)) {
    if (t === 'i') { args.push(buf.readInt32BE(i)); i += 4; }
    else if (t === 'f') { args.push(buf.readFloatBE(i)); i += 4; }
    else if (t === 's') { let s; [s, i] = readString(buf, i); args.push(s); }
    else if (t === 'b') { const n = buf.readUInt32BE(i); args.push(buf.slice(i + 4, i + 4 + n)); i += 4 + Math.ceil(n / 4) * 4; }
  }
  return { address, tags: tags.slice(1), args };
}

module.exports = { encode, decode };
