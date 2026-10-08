import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { RuntimeStore, downloadBytes } from '../store.mjs';
import { parsePackage } from '../package.mjs';

// Opt-in live verification downloads original packages to TEMP. No extension or
// copyrighted image/chapter body is checked into the project or printed.
test('original MangaDex ZIP executes metadata search/detail/TOC/image-URL chapter',
  { skip: process.env.VBOOK_REAL_TEST !== '1', timeout: 120000 }, async t => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'vbook-real-test-'));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const store = await new RuntimeStore(directory, { executionTimeoutMs: 30000 }).init();
    const source = await store.installUrl('https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/mangadex/plugin.zip');
    const result = await store.search(source.id, 'Garden of Words');
    assert.ok(result.items.length > 0, 'Live source returned no books.');
    const book = await store.detail(source.id, result.items[0].ref);
    assert.ok(book.title);
    const chapters = await store.chapters(source.id, book.ref);
    assert.ok(chapters.length > 0, 'Live source returned no chapters.');
    const chapter = await store.chapter(source.id, chapters[0].ref);
    assert.equal(chapter.kind, 'manga');
    assert.ok(chapter.images.length > 0);
    assert.ok(chapter.images.every(image => image.url.startsWith('https://')));
  });

test('original encrypted Hako ZIP produces capability error without executing or decrypting it',
  { skip: process.env.VBOOK_REAL_TEST !== '1', timeout: 30000 }, async () => {
    const bytes = await downloadBytes('https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/hako/plugin.zip');
    assert.throws(() => parsePackage(bytes), { code: 'UNSUPPORTED_CAPABILITY' });
  });

test('original Syosetu ZIP executes search/detail/TOC and requires nonempty chapter output',
  { skip: process.env.VBOOK_REAL_TEST !== '1', timeout: 120000 }, async t => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'vbook-syosetu-test-'));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const store = await new RuntimeStore(directory).init();
    const source = await store.installUrl('https://raw.githubusercontent.com/khoa301020/vbook-ext/master/syosetu/plugin.zip');
    const result = await store.search(source.id, '吾輩は猫');
    assert.ok(result.items.length > 0);
    t.diagnostic(`Original search executed: ${result.items.length} metadata results.`);
    const choice = result.items.find(item => item.description.includes('短編')) || result.items[0];
    const book = await store.detail(source.id, choice.ref);
    assert.ok(book.title && book.author);
    t.diagnostic('Original detail executed with title and author.');
    const chapters = await store.chapters(source.id, book.ref);
    assert.ok(chapters.length > 0);
    t.diagnostic(`Original TOC executed: ${chapters.length} chapter references.`);
    const chapter = await store.chapter(source.id, chapters[0].ref);
    assert.equal(chapter.kind, 'novel');
    assert.ok(chapter.html.trim());
  });

test('original TruyenFull ZIP executes complete novel search/detail/TOC/chapter flow',
  { skip: process.env.VBOOK_REAL_TEST !== '1', timeout: 120000 }, async t => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'vbook-truyenfull-test-'));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const store = await new RuntimeStore(directory).init();
    const source = await store.installUrl('https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/truyenfull/plugin.zip');
    t.diagnostic(`Original ZIP SHA-256: ${source.packageHash}.`);
    const result = await store.search(source.id, 'Dế Mèn');
    assert.ok(result.items.length > 0, 'Live source returned no books.');
    t.diagnostic(`Original search executed: ${result.items.length} metadata results.`);
    const book = await store.detail(source.id, result.items[0].ref);
    assert.ok(book.title && book.author);
    t.diagnostic('Original detail executed with title and author.');
    const chapters = await store.chapters(source.id, book.ref);
    assert.ok(chapters.length > 0, 'Live source returned no chapter references.');
    t.diagnostic(`Original TOC executed: ${chapters.length} chapter references.`);
    const chapter = await store.chapter(source.id, chapters[0].ref);
    assert.equal(chapter.kind, 'novel');
    assert.ok(chapter.html.trim(), 'Live source returned an empty chapter.');
    t.diagnostic(`Original chapter executed: ${chapter.html.length} sanitized HTML characters; content is not printed.`);
  });
