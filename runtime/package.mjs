import { createHash } from 'node:crypto';
import { unzipSync } from 'fflate';
import { RuntimeError, capabilityError } from './errors.mjs';

export const limits = Object.freeze({
  archiveBytes: 64 * 1024 * 1024,
  entryBytes: 10 * 1024 * 1024,
  totalBytes: 64 * 1024 * 1024,
  manifestBytes: 2 * 1024 * 1024,
  entries: 512,
  responseBytes: 12 * 1024 * 1024,
  registryEntries: 10000,
});

export function safePath(name) {
  const parts = name.replace(/\/$/, '').split('/');
  if (!name || name.startsWith('/') || /[\\:\0]/.test(name)
      || parts.some(part => !part || part === '.' || part === '..')) {
    throw new RuntimeError('INVALID_PACKAGE', `Unsafe ZIP/script path: ${JSON.stringify(name)}.`);
  }
  return name;
}

function invalid(message) { throw new RuntimeError('INVALID_PACKAGE', message); }

// Validate central-directory names and declared sizes before decompression.
// fflate's object result alone cannot detect duplicate ZIP names.
export function validateArchive(input, caps = limits) {
  const bytes = Buffer.from(input);
  if (bytes.length > caps.archiveBytes) invalid('ZIP exceeds input-size limit.');
  let end = -1;
  for (let offset = bytes.length - 22; offset >= Math.max(0, bytes.length - 65557); offset--) {
    if (bytes.readUInt32LE(offset) === 0x06054b50
        && offset + 22 + bytes.readUInt16LE(offset + 20) === bytes.length) {
      end = offset;
      break;
    }
  }
  if (end < 0) invalid('ZIP end-of-central-directory is missing.');
  const count = bytes.readUInt16LE(end + 10);
  const directorySize = bytes.readUInt32LE(end + 12);
  const directoryOffset = bytes.readUInt32LE(end + 16);
  if (count === 0xffff || directoryOffset === 0xffffffff || directorySize === 0xffffffff) {
    invalid('ZIP64 packages are unsupported.');
  }
  if (bytes.readUInt16LE(end + 4) !== 0 || bytes.readUInt16LE(end + 6) !== 0
      || bytes.readUInt16LE(end + 8) !== count) invalid('Multi-disk ZIP is unsupported.');
  if (count > caps.entries || directoryOffset + directorySize > end) {
    invalid('ZIP entry-count or central-directory limit exceeded.');
  }
  let offset = directoryOffset;
  let total = 0;
  const seen = new Set();
  const entries = [];
  const decoder = new TextDecoder('utf-8', { fatal: true });
  for (let index = 0; index < count; index++) {
    if (offset + 46 > end || bytes.readUInt32LE(offset) !== 0x02014b50) invalid('Malformed ZIP central directory.');
    const flags = bytes.readUInt16LE(offset + 8);
    const method = bytes.readUInt16LE(offset + 10);
    const compressedBytes = bytes.readUInt32LE(offset + 20);
    const size = bytes.readUInt32LE(offset + 24);
    const nameLength = bytes.readUInt16LE(offset + 28);
    const extraLength = bytes.readUInt16LE(offset + 30);
    const commentLength = bytes.readUInt16LE(offset + 32);
    const attributes = bytes.readUInt32LE(offset + 38);
    const localOffset = bytes.readUInt32LE(offset + 42);
    const next = offset + 46 + nameLength + extraLength + commentLength;
    if (next > directoryOffset + directorySize) invalid('Truncated ZIP entry.');
    let name;
    try { name = decoder.decode(bytes.subarray(offset + 46, offset + 46 + nameLength)); }
    catch { invalid('ZIP filenames must be UTF-8/ASCII.'); }
    safePath(name);
    const collision = name.replace(/\/$/, '').toLowerCase();
    if (seen.has(collision)) invalid(`Duplicate/case-colliding ZIP entry: ${name}.`);
    seen.add(collision);
    if (flags & 1) invalid('Password-encrypted ZIP is unsupported.');
    if (![0, 8].includes(method)) invalid('Unsupported ZIP compression method.');
    if (((attributes >>> 16) & 0xf000) === 0xa000) invalid('ZIP symlinks are unsupported.');
    if (size === 0xffffffff || compressedBytes === 0xffffffff || size > caps.entryBytes) {
      invalid(`ZIP entry exceeds size limit: ${name}.`);
    }
    total += size;
    if (total > caps.totalBytes) invalid('ZIP exceeds uncompressed-size limit.');
    if (localOffset + 30 > directoryOffset || bytes.readUInt32LE(localOffset) !== 0x04034b50) invalid('Invalid ZIP local header.');
    const localNameLength = bytes.readUInt16LE(localOffset + 26);
    const localExtraLength = bytes.readUInt16LE(localOffset + 28);
    const start = localOffset + 30 + localNameLength + localExtraLength;
    if (start + compressedBytes > directoryOffset) invalid('ZIP compressed data extends outside the package.');
    const localName = decoder.decode(bytes.subarray(localOffset + 30, localOffset + 30 + localNameLength));
    if (localName !== name || bytes.readUInt16LE(localOffset + 8) !== method
        || bytes.readUInt16LE(localOffset + 6) !== flags) invalid('ZIP local and central headers disagree.');
    entries.push({ name, size });
    offset = next;
  }
  if (offset !== directoryOffset + directorySize) invalid('Unexpected ZIP directory data.');
  const manifest = entries.find(entry => entry.name === 'plugin.json');
  if (!manifest || manifest.size > caps.manifestBytes) invalid('Root plugin.json is missing or exceeds its size limit.');
  return entries;
}

export function parsePackage(input, caps = limits) {
  const bytes = Buffer.from(input);
  const entries = validateArchive(bytes, caps);
  let files;
  try {
    files = unzipSync(bytes, { filter: file => file.name === 'plugin.json'
      || /^src\/[^/]+\.js$/.test(file.name) });
  } catch (error) { invalid(`Cannot decompress package: ${error.message}`); }
  let manifest;
  try { manifest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(files['plugin.json'])); }
  catch { invalid('plugin.json is not valid UTF-8 JSON.'); }
  if (!manifest || Array.isArray(manifest) || typeof manifest !== 'object'
      || !manifest.metadata || Array.isArray(manifest.metadata) || typeof manifest.metadata !== 'object'
      || !manifest.script || Array.isArray(manifest.script) || typeof manifest.script !== 'object') {
    invalid('Manifest requires metadata and script objects.');
  }
  if (manifest.metadata.encrypt === true) throw capabilityError('encrypted vBook scripts');
  if (manifest.metadata.encrypt !== undefined && typeof manifest.metadata.encrypt !== 'boolean') {
    invalid('metadata.encrypt must be a boolean.');
  }
  const metadata = manifest.metadata;
  if (!metadata.name || !metadata.source || typeof metadata.name !== 'string' || typeof metadata.source !== 'string') {
    invalid('A stable source identity requires string metadata.name and metadata.source.');
  }
  const type = String(metadata.type ?? 'novel').toLowerCase();
  if (!['novel', 'chinese_novel', 'comic'].includes(type)) throw capabilityError(`extension type ${type}`);
  const scripts = {};
  for (const entry of entries) {
    if (!/^src\/[^/]+\.js$/.test(entry.name)) continue;
    if (files[entry.name].byteLength !== entry.size) invalid('Decompressed size does not match ZIP metadata.');
    try { scripts[entry.name.slice(4)] = new TextDecoder('utf-8', { fatal: true }).decode(files[entry.name]); }
    catch { invalid(`Script is not UTF-8: ${entry.name}.`); }
  }
  for (const key of ['detail', 'toc', 'chap']) {
    if (!manifest.script[key]) invalid(`Required script mapping missing: ${key}.`);
  }
  for (const [key, filename] of Object.entries(manifest.script)) {
    if (typeof filename !== 'string' || !/^[^/\\:]+\.js$/.test(filename)) invalid(`Invalid script filename for ${key}.`);
    safePath(filename);
    if (!Object.hasOwn(scripts, filename)) invalid(`Declared script is missing: ${filename}.`);
  }
  if (manifest.config !== undefined && (!manifest.config || Array.isArray(manifest.config) || typeof manifest.config !== 'object')) {
    invalid('Manifest config must be an object.');
  }
  const id = `vb-${createHash('sha256').update(`${metadata.name}\0${metadata.source}`).digest('hex').slice(0, 24)}`;
  return { id, manifest, scripts, type, kind: type === 'comic' ? 'manga' : 'novel',
    hash: createHash('sha256').update(bytes).digest('hex'), entries: entries.length, bytes };
}
