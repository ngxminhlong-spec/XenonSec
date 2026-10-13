"use strict";
// Minimal .zip reader for the playground. It reads the central directory, then
// each entry's local header and data. Only stored (0) and deflate (8) entries
// are supported.
//
// Refused, with an Error whose message is shown to the user:
//   - not a zip, zip64, encrypted entries, unknown compression
//   - symbolic links (a zip can hide them in the unix mode bits)
//   - unsafe names: absolute paths, "..", backslashes, drive letters
//   - more entries, or more unpacked bytes, than the limits allow
// Only .lua and .luau files are returned. Other files are counted and skipped.

const zlib = require("zlib");

const EOCD_SIG = 0x06054b50;
const CD_SIG = 0x02014b50;
const LOCAL_SIG = 0x04034b50;
const SOURCE_RE = /\.(lua|luau)$/i;

function safeName(name) {
  if (name.length === 0 || name.length > 256) throw new Error("A file name in the archive is too long.");
  if (name.includes("\\") || name.includes("\0") || name.includes(":") || name.startsWith("/")) {
    throw new Error(`Unsafe file name in the archive: ${JSON.stringify(name)}`);
  }
  for (const part of name.split("/")) {
    if (part === "." || part === ".." || part === "") {
      throw new Error(`Unsafe file name in the archive: ${JSON.stringify(name)}`);
    }
  }
  return name;
}

// limits: { maxEntries, maxUnpackedBytes }
// returns { files: [{ name, data: Buffer }], skipped: number }
function readZip(buf, limits) {
  const { maxEntries, maxUnpackedBytes } = limits;

  // The end-of-central-directory record is the last 22 bytes plus an optional
  // comment of up to 65535 bytes, so search backwards from the end.
  let eocd = -1;
  const lowest = Math.max(0, buf.length - 22 - 0xffff);
  for (let i = buf.length - 22; i >= lowest; i--) {
    if (buf.readUInt32LE(i) === EOCD_SIG) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("This is not a valid .zip file.");

  const count = buf.readUInt16LE(eocd + 10);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  if (count === 0xffff || cdOffset === 0xffffffff) throw new Error("Zip64 archives are not supported.");
  if (count > maxEntries) throw new Error(`The archive has more than ${maxEntries} entries.`);

  const files = [];
  const seen = new Set();
  let skipped = 0;
  let total = 0;
  let p = cdOffset;

  for (let k = 0; k < count; k++) {
    if (p + 46 > buf.length || buf.readUInt32LE(p) !== CD_SIG) {
      throw new Error("The archive's directory is damaged.");
    }
    const flags = buf.readUInt16LE(p + 8);
    const method = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const usize = buf.readUInt32LE(p + 24);
    const nlen = buf.readUInt16LE(p + 28);
    const xlen = buf.readUInt16LE(p + 30);
    const clen = buf.readUInt16LE(p + 32);
    const externalAttr = buf.readUInt32LE(p + 38);
    const localOffset = buf.readUInt32LE(p + 42);
    const name = buf.toString("utf8", p + 46, p + 46 + nlen);
    p = p + 46 + nlen + xlen + clen;

    if (csize === 0xffffffff || usize === 0xffffffff || localOffset === 0xffffffff) {
      throw new Error("Zip64 archives are not supported.");
    }
    if (flags & 1) throw new Error("Password-protected zip files are not supported.");

    const unixMode = externalAttr >>> 16;
    if ((unixMode & 0o170000) === 0o120000) throw new Error("Symbolic links are not allowed in the archive.");
    if (name.endsWith("/")) continue; // directory entry

    safeName(name);
    if (!SOURCE_RE.test(name)) { skipped++; continue; }
    if (seen.has(name)) throw new Error(`The archive has two files named ${JSON.stringify(name)}.`);
    seen.add(name);

    if (method !== 0 && method !== 8) throw new Error(`Unsupported compression in ${JSON.stringify(name)}.`);
    if (total + usize > maxUnpackedBytes) {
      throw new Error(`The unpacked .lua files are over ${Math.round(maxUnpackedBytes / 1024)} KB.`);
    }

    if (localOffset + 30 > buf.length || buf.readUInt32LE(localOffset) !== LOCAL_SIG) {
      throw new Error(`The archive's data for ${JSON.stringify(name)} is damaged.`);
    }
    const dataStart = localOffset + 30 + buf.readUInt16LE(localOffset + 26) + buf.readUInt16LE(localOffset + 28);
    const dataEnd = dataStart + csize;
    if (dataEnd > buf.length) throw new Error(`The archive's data for ${JSON.stringify(name)} is damaged.`);
    const raw = buf.subarray(dataStart, dataEnd);

    let data;
    try {
      data = method === 0 ? Buffer.from(raw) : zlib.inflateRawSync(raw, { maxOutputLength: usize + 1 });
    } catch (_) {
      throw new Error(`The file ${JSON.stringify(name)} in the archive could not be decompressed.`);
    }
    if (data.length !== usize) throw new Error(`The file ${JSON.stringify(name)} has the wrong size.`);

    total += data.length;
    files.push({ name, data });
  }

  if (files.length === 0) throw new Error("The archive has no .lua or .luau files.");
  return { files, skipped };
}

module.exports = { readZip };
