import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { parsePackage, limits } from './package.mjs';
import { runScript } from './executor.mjs';
import { httpUrl } from './host.mjs';
import { sanitizeChapter } from './html.mjs';
import { RuntimeError, capabilityError } from './errors.mjs';

export async function downloadBytes(value, cap = limits.archiveBytes) {
  const url = httpUrl(value);
  const response = await fetch(url, { signal: AbortSignal.timeout(15000), redirect: 'follow' });
  if (!response.ok) throw new RuntimeError('DOWNLOAD_FAILED', `HTTP ${response.status} while fetching package/registry.`, 502);
  if (Number(response.headers.get('content-length')) > cap) throw new RuntimeError('DOWNLOAD_LIMIT', 'Download exceeds size limit.');
  const chunks = [];
  let size = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { value: chunk, done } = await reader.read();
      if (done) break;
      size += chunk.byteLength;
      if (size > cap) throw new RuntimeError('DOWNLOAD_LIMIT', 'Download exceeds size limit.');
      chunks.push(Buffer.from(chunk));
    }
  } finally { await reader.cancel().catch(() => {}); }
  return Buffer.concat(chunks, size);
}

async function readJson(filename, fallback) {
  try { return JSON.parse(await readFile(filename, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}

async function atomicJson(filename, value) {
  const temporary = `${filename}.${randomUUID()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  await rename(temporary, filename);
}

function absolute(value, base) {
  if (!value) return '';
  try { return httpUrl(value, base).href; } catch { return ''; }
}

function sourceOf(pkg) {
  return { id: pkg.id, name: pkg.manifest.metadata.name,
    lang: pkg.manifest.metadata.locale ?? '', baseUrl: pkg.manifest.metadata.source,
    kind: pkg.kind, engine: 'vbook' };
}

function bookOf(item, pkg) {
  if (!item || typeof item !== 'object' || Array.isArray(item)) throw new RuntimeError('INVALID_SOURCE_DATA', 'Book result must be an object.', 502);
  const base = item.host || pkg.manifest.metadata.source;
  const ref = absolute(item.link ?? item.url ?? item.ref, base);
  return { ref, title: String(item.name ?? item.title ?? ''), author: String(item.author ?? ''),
    description: String(item.description ?? ''), coverUrl: absolute(item.cover ?? item.coverUrl, base),
    sourceId: pkg.id, kind: pkg.kind, engine: 'vbook' };
}

export class RuntimeStore {
  constructor(directory, { executionTimeoutMs = 20000 } = {}) {
    this.directory = path.resolve(directory);
    this.executionTimeoutMs = executionTimeoutMs;
    this.index = { extensions: [], repositories: [] };
    this.packages = new Map();
    this.queues = new Map();
  }
  async init() {
    await mkdir(this.directory, { recursive: true });
    this.index = await readJson(path.join(this.directory, 'index.json'), this.index);
    if (!Array.isArray(this.index.extensions) || !Array.isArray(this.index.repositories)) {
      throw new RuntimeError('INVALID_RUNTIME_DATA', 'Runtime index is malformed.', 500);
    }
    for (const entry of this.index.extensions) {
      if (!/^vb-[a-f0-9]{24}$/.test(entry.id) || !/^[a-f0-9]{64}$/.test(entry.hash)) {
        throw new RuntimeError('INVALID_RUNTIME_DATA', 'Invalid installed package identity.', 500);
      }
      const bytes = await readFile(this.versionPath(entry.id, entry.hash, 'package.zip'));
      const pkg = parsePackage(bytes);
      if (pkg.id !== entry.id || pkg.hash !== entry.hash) throw new RuntimeError('INVALID_RUNTIME_DATA', 'Stored package hash/identity mismatch.', 500);
      this.packages.set(pkg.id, pkg);
    }
    return this;
  }
  versionPath(id, hash, filename) { return path.join(this.directory, 'extensions', id, 'versions', hash, filename); }
  async saveIndex() { await atomicJson(path.join(this.directory, 'index.json'), this.index); }
  async serialized(key, operation) {
    const previous = this.queues.get(key) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(operation);
    this.queues.set(key, next);
    try { return await next; }
    finally { if (this.queues.get(key) === next) this.queues.delete(key); }
  }
  sources() { return [...this.packages.values()].map(sourceOf); }
  extensions() {
    return [...this.packages.values()].map(pkg => ({ ...sourceOf(pkg), type: pkg.type,
      version: pkg.manifest.metadata.version ?? 0, packageHash: pkg.hash,
      packageUrl: this.index.extensions.find(entry => entry.id === pkg.id)?.origin ?? '',
      limitations: ['Browser/WebView, encrypted scripts, native crypto and newer native APIs are unsupported.'] }));
  }
  package(id) {
    const pkg = this.packages.get(id);
    if (!pkg) throw new RuntimeError('SOURCE_NOT_FOUND', 'Source is not installed.', 404);
    return pkg;
  }
  async installBytes(bytes, origin = 'local-test') {
    const pkg = parsePackage(bytes);
    return this.serialized('index', async () => {
      const directory = this.versionPath(pkg.id, pkg.hash, '');
      await mkdir(path.join(directory, 'src'), { recursive: true });
      await writeFile(path.join(directory, 'package.zip'), pkg.bytes);
      await atomicJson(path.join(directory, 'plugin.json'), pkg.manifest);
      for (const [name, source] of Object.entries(pkg.scripts)) await writeFile(path.join(directory, 'src', name), source, 'utf8');
      this.index.extensions = this.index.extensions.filter(entry => entry.id !== pkg.id);
      this.index.extensions.push({ id: pkg.id, hash: pkg.hash, origin });
      await this.saveIndex();
      this.packages.set(pkg.id, pkg);
      return { ...sourceOf(pkg), version: pkg.manifest.metadata.version ?? 0, packageHash: pkg.hash };
    });
  }
  async installUrl(url) { return this.installBytes(await downloadBytes(url), httpUrl(url).href); }
  async addRepository(url) {
    const target = httpUrl(url).href;
    const bytes = await downloadBytes(target, 8 * 1024 * 1024);
    let value;
    try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
    catch { throw new RuntimeError('INVALID_REGISTRY', 'Registry is not UTF-8 JSON.'); }
    const items = Array.isArray(value) ? value : value?.data;
    if (!Array.isArray(items) || items.length > limits.registryEntries) {
      throw new RuntimeError('INVALID_REGISTRY', 'Registry requires a data array within its item limit.');
    }
    const entries = items.map((item, index) => {
      if (!item || typeof item !== 'object' || Array.isArray(item) || typeof item.path !== 'string') {
        throw new RuntimeError('INVALID_REGISTRY', `Invalid registry entry ${index}.`);
      }
      return { name: String(item.name ?? ''), author: String(item.author ?? ''),
        path: httpUrl(item.path, target).href, version: item.version ?? 0,
        source: String(item.source ?? ''), type: String(item.type ?? 'novel'),
        locale: String(item.locale ?? ''), icon: absolute(item.icon, target),
        description: String(item.description ?? '') };
    });
    const repo = { url: target, metadata: Array.isArray(value) ? {} : value.metadata ?? {}, entries };
    await this.serialized('index', async () => {
      this.index.repositories = this.index.repositories.filter(item => item.url !== target);
      this.index.repositories.push(repo);
      await this.saveIndex();
    });
    return repo;
  }
  async execute(id, key, args) {
    return this.serialized(id, async () => {
      const pkg = this.package(id);
      const script = pkg.manifest.script[key];
      if (!script) throw capabilityError(`script ${key} for source ${pkg.manifest.metadata.name}`);
      const storagePath = path.join(this.directory, 'extensions', id, 'storage.json');
      const storage = await readJson(storagePath, {});
      const output = await runScript({ manifest: pkg.manifest, scripts: pkg.scripts, script, args, storage },
        { timeoutMs: this.executionTimeoutMs });
      await atomicJson(storagePath, output.storage);
      return output;
    });
  }
  async search(id, query, page = '') {
    const pkg = this.package(id);
    const output = await this.execute(id, 'search', [query, page]);
    if (!Array.isArray(output.data) || output.data.length > 2000) throw new RuntimeError('INVALID_SOURCE_DATA', 'Search result must be a bounded array.', 502);
    return { items: output.data.map(item => bookOf(item, pkg)).filter(item => item.ref && item.title),
      nextPage: output.data2 == null ? '' : String(output.data2) };
  }
  async detail(id, ref) {
    const pkg = this.package(id);
    const output = await this.execute(id, 'detail', [String(ref).replace(/\/$/, '')]);
    if (!output.data || typeof output.data !== 'object' || Array.isArray(output.data)) {
      throw new RuntimeError('INVALID_SOURCE_DATA', 'Detail result must be an object.', 502);
    }
    return bookOf({ ...output.data, link: ref }, pkg);
  }
  async chapters(id, ref) {
    const pkg = this.package(id);
    ref = String(ref).replace(/\/$/, '');
    let pages = [ref];
    if (pkg.manifest.script.page) {
      const output = await this.execute(id, 'page', [ref]);
      if (!Array.isArray(output.data) || output.data.length > 50) throw new RuntimeError('INVALID_SOURCE_DATA', 'TOC pages must be an array of at most 50 URLs.', 502);
      pages = output.data;
    }
    const chapters = [];
    const seen = new Set();
    for (const page of pages) {
      const output = await this.execute(id, 'toc', [String(page).replace(/\/$/, '')]);
      if (!Array.isArray(output.data)) throw new RuntimeError('INVALID_SOURCE_DATA', 'TOC result must be an array.', 502);
      for (const item of output.data) {
        if (chapters.length >= 20000) throw new RuntimeError('EXECUTION_LIMIT', 'Chapter-count limit exceeded.');
        const chapterRef = absolute(item?.url ?? item?.link, item?.host || pkg.manifest.metadata.source);
        if (!chapterRef || seen.has(chapterRef)) continue;
        seen.add(chapterRef);
        chapters.push({ ref: chapterRef, title: String(item.name ?? item.title ?? ''), index: chapters.length });
      }
    }
    return chapters;
  }
  async chapter(id, ref) {
    const pkg = this.package(id);
    const output = await this.execute(id, 'chap', [String(ref).replace(/\/$/, '')]);
    if (pkg.kind === 'novel') {
      if (typeof output.data !== 'string') throw new RuntimeError('INVALID_SOURCE_DATA', 'Novel chapter must be an HTML string.', 502);
      const html = sanitizeChapter(output.data, ref);
      if (!html.trim()) throw new RuntimeError('EMPTY_CHAPTER', 'Source returned empty chapter content; its selectors may be outdated.', 502);
      return { kind: 'novel', html, title: String(output.data2 ?? '') };
    }
    if (!Array.isArray(output.data) || output.data.length > 2000) throw new RuntimeError('INVALID_SOURCE_DATA', 'Comic chapter must be a bounded image array.', 502);
    const images = output.data.map(item => {
      const value = typeof item === 'string' ? { url: item } : item;
      if (!value || typeof value !== 'object') throw new RuntimeError('INVALID_SOURCE_DATA', 'Invalid image entry.', 502);
      const url = absolute(value.url ?? value.src ?? value.link, ref);
      if (!url) throw capabilityError('non-HTTP image payloads or image transforms');
      return { url, ...(value.headers && typeof value.headers === 'object' ? { headers: value.headers } : {}) };
    });
    if (!images.length) throw new RuntimeError('EMPTY_CHAPTER', 'Source returned no chapter images.', 502);
    return { kind: 'manga', images };
  }
}
