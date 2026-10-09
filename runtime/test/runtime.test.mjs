import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { zipSync, strToU8 } from 'fflate';
import { parsePackage, validateArchive, limits } from '../package.mjs';
import { parseHtml, sanitizeChapter } from '../html.mjs';
import { executeScript } from '../host.mjs';
import { runScript } from '../executor.mjs';
import { RuntimeStore } from '../store.mjs';
import { createServer } from '../server.mjs';

function makePackage({ base = 'https://example.invalid', type = 'novel', version = 1,
  encrypt = false, scripts = {}, mapping, extras = {} } = {}) {
  const manifest = { metadata: { name: 'Fixture', source: base, type, version, locale: 'en', encrypt },
    script: mapping ?? { search: 'search.js', detail: 'detail.js', toc: 'toc.js', chap: 'chap.js' },
    config: { DOMAIN: { mode: 'input', default: base } } };
  const code = {
    'shared.js': 'var GREETING = "chapter";',
    'search.js': 'function execute(query, page) { localStorage.setItem("query", query); return Response.success([{name: query, link: "/book", cover: "/cover.jpg"}], "2"); }',
    'detail.js': 'function execute(url) { return Response.success({name: localStorage.getItem("query") || "Book", author: "Author", description: "Description"}); }',
    'toc.js': 'function execute(url) { return Response.success([{name: "One", url: "/chapter/1"},{name:"Two",url:"/chapter/2"}]); }',
    'chap.js': 'load("shared.js"); function execute(url) { return Response.success("<p>" + GREETING + "</p>"); }',
    ...scripts,
  };
  return zipSync({ 'plugin.json': strToU8(JSON.stringify(manifest)),
    ...Object.fromEntries(Object.entries(code).map(([name, value]) => [`src/${name}`, strToU8(value)])),
    ...Object.fromEntries(Object.entries(extras).map(([name, value]) => [name, strToU8(value)])) });
}

async function listen(server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

test('plaintext package identity is stable across version updates and original ZIP preserved', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'vbook-runtime-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const store = await new RuntimeStore(directory).init();
  const firstBytes = makePackage();
  const first = await store.installBytes(firstBytes, 'https://repo.invalid/plugin.zip');
  const second = await store.installBytes(makePackage({ version: 2 }), 'https://repo.invalid/plugin.zip');
  assert.equal(first.id, second.id);
  assert.notEqual(first.packageHash, second.packageHash);
  assert.deepEqual(await readFile(store.versionPath(first.id, first.packageHash, 'package.zip')), Buffer.from(firstBytes));
  assert.equal(store.sources().length, 1);
  const reloaded = (await new RuntimeStore(directory).init()).extensions()[0];
  assert.equal(reloaded.version, 2);
  assert.equal(reloaded.packageUrl, 'https://repo.invalid/plugin.zip');
});

test('ZIP malformed/path/count/size/duplicate/encrypted packages are rejected before execution', () => {
  assert.throws(() => parsePackage(Buffer.from('not zip')), { code: 'INVALID_PACKAGE' });
  assert.throws(() => parsePackage(makePackage({ extras: { '../outside': 'x' } })), { code: 'INVALID_PACKAGE' });
  assert.throws(() => parsePackage(makePackage({ extras: { 'src\\bad.js': 'x' } })), { code: 'INVALID_PACKAGE' });
  assert.throws(() => parsePackage(makePackage({ extras: { 'src/shared.JS': 'x' } })), { code: 'INVALID_PACKAGE' });
  assert.throws(() => validateArchive(makePackage(), { ...limits, entries: 1 }), { code: 'INVALID_PACKAGE' });
  assert.throws(() => validateArchive(makePackage(), { ...limits, entryBytes: 4 }), { code: 'INVALID_PACKAGE' });
  assert.throws(() => validateArchive(makePackage(), { ...limits, totalBytes: 4 }), { code: 'INVALID_PACKAGE' });
  assert.throws(() => parsePackage(makePackage({ encrypt: true })), { code: 'UNSUPPORTED_CAPABILITY' });
  assert.throws(() => parsePackage(makePackage({ mapping: { detail: 'absent.js', toc: 'toc.js', chap: 'chap.js' } })), { code: 'INVALID_PACKAGE' });
});

test('legacy chinese_novel normalizes to novel', () => {
  assert.equal(parsePackage(makePackage({ type: 'chinese_novel' })).kind, 'novel');
});

test('Jsoup-style HTML collection chains include first/get/map/remove and safe empty selectors', () => {
  const doc = parseHtml('<ul><li><a href="/1">First</a></li><li><a href="/2">Second</a></li></ul><script>bad()</script>');
  assert.equal(doc.select('li').size(), 2);
  assert.deepEqual(doc.select('li').map(item => item.select('a').attr('href')), ['/1', '/2']);
  assert.equal(doc.select('li').get(1).text(), 'Second');
  assert.equal(doc.select('a').get(0).select('a').text(), 'First');
  assert.equal(doc.select('.missing').first().attr('href'), '');
  assert.equal(doc.select('a').get(-1).text(), '');
  assert.equal(doc.select('a').last().text(), 'Second');
  doc.select('script').remove();
  assert.ok(!doc.html().includes('<script>'));
  assert.equal(sanitizeChapter('<p onclick="bad()">Safe</p><script>bad()</script><img src="/x">', 'https://example.test/c'), '<p>Safe</p><img src="https://example.test/x">');
});

test('original script semantics: local load, config, Response, persistent storage and synchronous HTTP', async t => {
  const upstream = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    if (request.url.startsWith('/form')) {
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify({ body: Buffer.concat(chunks).toString(), header: request.headers['x-test'] }));
    } else {
      response.setHeader('Content-Type', 'text/html; charset=utf-8');
      response.end('<article><p>First</p><p>Second</p></article>');
    }
  });
  const base = await listen(upstream);
  t.after(() => new Promise(resolve => upstream.close(resolve)));
  const pkg = parsePackage(makePackage({ base, scripts: { 'chap.js': `load('shared.js'); function execute(url) {
    var doc = fetch(DOMAIN + '/html').html();
    var rows = doc.select('p').map(function(el) { return el.text(); });
    var form = fetch(DOMAIN + '/form', {method:'POST',headers:{'X-Test':'yes'},body:{value:'a b'}}).json();
    var legacy = Http.get(DOMAIN + '/html').params({page:2}).string();
    localStorage.setItem('count', Number(localStorage.getItem('count') || 0) + 1);
    return Response.success({rows:rows,form:form,legacy:legacy,greeting:GREETING,count:localStorage.getItem('count')});
  }` } }));
  const first = await runScript({ ...pkg, script: 'chap.js' });
  assert.deepEqual(first.data.rows, ['First', 'Second']);
  assert.equal(first.data.form.body, 'value=a+b');
  assert.equal(first.data.form.header, 'yes');
  assert.equal(first.data.greeting, 'chapter');
  assert.equal(first.data.count, '1');
  const second = await runScript({ ...pkg, script: 'chap.js', storage: first.storage });
  assert.equal(second.data.count, '2');
});

test('capability errors and script Response.error are explicit', async () => {
  const pkg = parsePackage(makePackage({ scripts: { 'chap.js': 'function execute(){ Engine.newBrowser(); return Response.success("bad"); }' } }));
  await assert.rejects(runScript({ ...pkg, script: 'chap.js' }), { code: 'UNSUPPORTED_CAPABILITY' });
  pkg.scripts['chap.js'] = 'function execute(){ return Response.error("upstream failed"); }';
  await assert.rejects(runScript({ ...pkg, script: 'chap.js' }), { code: 'SOURCE_ERROR' });
  pkg.scripts['chap.js'] = 'load("crypto.js"); function execute(){return Response.success(1);}';
  assert.throws(() => executeScript({ ...pkg, script: 'chap.js' }), { code: 'UNSUPPORTED_CAPABILITY' });
});

test('non-terminating script process is bounded by timeout', async () => {
  const pkg = parsePackage(makePackage({ scripts: { 'chap.js': 'function execute(){ while(true){} }' } }));
  const start = Date.now();
  await assert.rejects(runScript({ ...pkg, script: 'chap.js' }, { timeoutMs: 1000 }), { code: 'SCRIPT_TIMEOUT' });
  assert.ok(Date.now() - start < 3000);
});

test('failed HTTP cannot silently become an empty successful catalogue', async t => {
  const upstream = http.createServer((_, response) => { response.writeHead(403); response.end('Denied'); });
  const base = await listen(upstream);
  t.after(() => new Promise(resolve => upstream.close(resolve)));
  const pkg = parsePackage(makePackage({ base, scripts: {
    'search.js': 'function execute(){ var r = fetch(DOMAIN); return Response.success([]); }',
  } }));
  await assert.rejects(runScript({ ...pkg, script: 'search.js' }), { code: 'UPSTREAM_UNAVAILABLE' });
});

test('HTTP API installs ZIP, registry, sources and complete search/detail/TOC/chapter flow', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'vbook-api-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  let bytes;
  let registry;
  const upstream = http.createServer((request, response) => {
    if (request.url === '/plugin.zip') response.end(bytes);
    else response.end(JSON.stringify(registry));
  });
  const upstreamBase = await listen(upstream);
  t.after(() => new Promise(resolve => upstream.close(resolve)));
  bytes = makePackage({ base: upstreamBase });
  registry = { metadata: { author: 'Test' }, data: [{ name: 'Fixture', path: upstreamBase + '/plugin.zip', type: 'novel' }] };
  const store = await new RuntimeStore(directory).init();
  const server = createServer(store);
  const base = await listen(server);
  t.after(() => new Promise(resolve => server.close(resolve)));
  const post = route => fetch(base + route, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url: upstreamBase + (route.includes('repositories') ? '/registry.json' : '/plugin.zip') }) });
  const repoResponse = await post('/v1/repositories');
  assert.equal(repoResponse.status, 201);
  assert.equal((await repoResponse.json()).entries.length, 1);
  const installedResponse = await post('/v1/extensions/install');
  assert.equal(installedResponse.status, 201);
  const installed = await installedResponse.json();
  assert.equal((await (await fetch(base + '/v1/health')).json()).engine, 'vbook');
  assert.equal((await (await fetch(base + '/v1/sources')).json())[0].id, installed.id);
  const sourceBase = `${base}/v1/sources/${installed.id}`;
  const searchResponse = await fetch(sourceBase + '/search?query=Test');
  assert.equal(searchResponse.headers.get('X-Next-Page'), '2');
  const book = (await searchResponse.json())[0];
  assert.equal(book.title, 'Test');
  const detail = await (await fetch(sourceBase + '/detail?ref=' + encodeURIComponent(book.ref))).json();
  assert.equal(detail.title, 'Test');
  assert.equal(detail.author, 'Author');
  const chapters = await (await fetch(sourceBase + '/chapters?ref=' + encodeURIComponent(book.ref))).json();
  assert.equal(chapters.length, 2);
  assert.equal(chapters[1].index, 1);
  const content = await (await fetch(sourceBase + '/chapter?ref=' + encodeURIComponent(chapters[0].ref))).json();
  assert.equal(content.html, '<p>chapter</p>');
  const rejected = await fetch(base + '/v1/health', { headers: { Origin: 'https://untrusted.example' } });
  assert.equal(rejected.status, 403);
  const cors = await fetch(base + '/v1/health', { headers: { Origin: 'http://localhost:12345' } });
  assert.equal(cors.headers.get('Access-Control-Allow-Origin'), 'http://localhost:12345');
});

test('comic chapter URLs and request headers normalize without downloading image data', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'vbook-comic-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const store = await new RuntimeStore(directory).init();
  const source = await store.installBytes(makePackage({ type: 'comic', scripts: {
    'chap.js': 'function execute(){return Response.success(["/one.png",{url:"/two.png",headers:{Referer:"https://example.invalid"}}]);}',
  } }));
  const content = await store.chapter(source.id, 'https://example.invalid/chapter');
  assert.equal(content.kind, 'manga');
  assert.equal(content.images[1].headers.Referer, 'https://example.invalid');
  assert.equal(content.images[0].url, 'https://example.invalid/one.png');
});
