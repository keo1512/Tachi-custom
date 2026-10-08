import test from 'node:test';
import assert from 'node:assert/strict';

// Requires the real Suwayomi server with the original Komga APK installed,
// and a real Komga library containing the self-authored two-page fixture.
// No mock server, replacement extension or publisher content is used here.
test('original Komga APK executes search/detail/TOC/page metadata and real image bytes',
  { skip: process.env.TACHI_REAL_TEST !== '1', timeout: 120000 }, async t => {
    const base = process.env.SUWAYOMI_TEST_URL || 'http://127.0.0.1:4567';
    const sourceId = process.env.KOMGA_TEST_SOURCE || '4508733312114627536';
    async function json(route, options) {
      const response = await fetch(base + route, { ...options, signal: AbortSignal.timeout(30000) });
      assert.equal(response.ok, true, `HTTP ${response.status} for ${route}`);
      return response.json();
    }
    const about = await json('/api/v1/settings/about');
    assert.equal(about.name, 'Suwayomi-Server');
    const extensions = await json('/api/v1/extension/list');
    const extension = extensions.find(item => item.pkgName === 'eu.kanade.tachiyomi.extension.all.komga');
    assert.equal(extension?.installed, true, 'Original Komga APK must be installed.');
    t.diagnostic(`Actual Suwayomi ${about.version}; installed Komga APK ${extension.versionName}.`);
    const search = await json(`/api/v1/source/${sourceId}/quick-search?pageNum=1`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ searchTerm: 'Tachi Books Runtime Fixture', filter: null }),
    });
    const book = search.mangaList.find(item => item.title === 'Tachi Books Runtime Fixture');
    assert.ok(book, 'Real Komga fixture must be indexed.');
    const detail = await json(`/api/v1/manga/${book.id}?onlineFetch=true`);
    assert.equal(detail.title, book.title);
    assert.equal(detail.author, 'Tachi Books test fixture');
    const chapters = await json(`/api/v1/manga/${book.id}/chapters?onlineFetch=true`);
    assert.equal(chapters.length, 1);
    const chapter = chapters[0];
    assert.equal(Number.isInteger(chapter.index), true);
    const metadata = await json(`/api/v1/manga/${book.id}/chapter/${chapter.index}`);
    assert.equal(metadata.pageCount, 2);
    let totalBytes = 0;
    for (let page = 0; page < metadata.pageCount; page++) {
      const response = await fetch(base + `/api/v1/manga/${book.id}/chapter/${chapter.index}/page/${page}?updateProgress=false`,
        { signal: AbortSignal.timeout(30000) });
      assert.equal(response.ok, true);
      assert.ok(response.headers.get('content-type').startsWith('image/png'));
      const bytes = Buffer.from(await response.arrayBuffer());
      assert.deepEqual(bytes.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
      totalBytes += bytes.length;
    }
    t.diagnostic(`Original APK executed complete flow: one book, one chapter, ${metadata.pageCount} real PNG pages (${totalBytes} bytes).`);
  });
