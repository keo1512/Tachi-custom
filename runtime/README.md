# vBook companion runtime

This Node.js service installs original plaintext vBook ZIP packages and executes their original JavaScript for search, book details, chapter lists and chapter content. The Flutter app connects through its source adapter. The service runs on a computer or server; it is **not an embedded iOS runtime**.

Use Node.js 22 or newer. Install dependencies from this directory with `npm install --ignore-scripts` or `pnpm install --frozen-lockfile --ignore-scripts`, then run `npm start` or `node server.mjs`. The default address is `http://127.0.0.1:4570`. Private installed packages, original ZIPs and per-extension storage live in `.data/`, which is ignored by Git. Set `VBOOK_DATA_DIR` to choose another runtime data directory.

The bundled Node executable used during development on this machine is `C:/Users/Nosgnoh/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe`.

To connect a phone on your LAN, explicitly set `HOST` to the computer's LAN IP (or `0.0.0.0`) and set the app's vBook endpoint to that computer's address. Keep the service on a trusted LAN. The phone's `127.0.0.1` address refers to the phone itself. `PORT` overrides port 4570. For browser preview, localhost origins are accepted; add exact other browser origins with comma-separated `ALLOWED_ORIGINS`. Optional `VBOOK_API_TOKEN` requires `Authorization: Bearer <token>` from clients.

Only install third-party extensions you trust. Each script runs in a child process with a wall-clock deadline and a limited Node heap. HTTP bodies, output, package sizes, script counts and ZIP paths are bounded. **Node `vm` and child processes are not a security sandbox**, and these limits do not make untrusted code safe to run on your computer.

## Supported compatibility surface

- Original ZIP with root `plugin.json` and top-level `src/*.js`; legacy `novel`, `chinese_novel` and `comic` sources.
- `execute(...)`, `Response.success/error`, synchronous `fetch` with GET/POST/forms/query parameters, headers and text/JSON/HTML/base64/blob responses; legacy `Http.get/post` builders.
- `Html.parse`, common jsoup-style selectors and `select/get/first/last/text/html/attr/remove/attributes/map/forEach` chains via Cheerio. This is a compatibility subset, not every jsoup selector or behavior.
- Local `load(...)` scripts, static manifest config defaults, `UserAgent`, log helpers, bounded `sleep` and per-extension persistent `localStorage`. `cacheStorage` is transient during a script execution.

Encrypted scripts, built-in `crypto.js`/native crypto, browser/WebView, persistent cookie APIs, graphics, WebSocket, dynamic config, localBook/localDatabase, Qt translation and nested Script.execute return explicit unsupported-capability errors. A package installing successfully does not establish that all its scripts or its upstream website work. Source changes and package versions can still cause failures.

The interface was checked against source assets in the user-provided vBook IPA: `core.js` routes helpers to `JSBridge.execFunction`, with synchronous native handles for HTTP and HTML. Its implementation was not copied into this project and the IPA binaries were not executed. Public references: [legacy extension contract](https://github.com/duongden/vbook), [current maintainer API documentation](https://github.com/Darkrai9x/vbook-extensions/blob/master/extension-api.md).

## HTTP contract

Successful endpoints return their document/array directly. Errors use a non-2xx HTTP status and `{ "error": { "code": "...", "message": "..." } }`.

| Route | Response |
|---|---|
| `GET /v1/health` | Engine, capabilities and limitations |
| `GET /v1/sources` | `[{id,name,lang,baseUrl,kind,engine}]` |
| `GET /v1/extensions` | Installed sources with package version/hash |
| `POST /v1/extensions/install` with `{url}` | Install/update an original ZIP; return installed source |
| `POST /v1/repositories` with `{url}` | Fetch registry metadata and entries; does not auto-install packages |
| `GET /v1/repositories` | Saved registry documents with entries |
| `GET /v1/sources/:id/search?query=...&page=...` | Book array; optional next-page token in `X-Next-Page` |
| `GET /v1/sources/:id/detail?ref=...` | Book document |
| `GET /v1/sources/:id/chapters?ref=...` | `[{ref,title,index}]` |
| `GET /v1/sources/:id/chapter?ref=...` | `{kind:"novel",html,title?}` or `{kind:"manga",images:[{url,headers?}]}` |

Book documents contain `ref,title,author,description,coverUrl,sourceId,kind,engine`. `kind` is `novel` or `manga`; `engine` is `vbook`. IDs use manifest name and source URL, so version/hash updates keep the same library source identity. TOC pagination through `page.js` is supported. Novel output is sanitized and relative links are made absolute; comic output contains URLs and optional request headers. Image bytes are downloaded by the reader/download layer, not this metadata endpoint.

PowerShell examples after starting the runtime:

```powershell
Invoke-RestMethod http://127.0.0.1:4570/v1/health
$payload = @{ url = 'https://example.com/original/plugin.zip' } | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:4570/v1/extensions/install -Method Post -ContentType 'application/json' -Body $payload
Invoke-RestMethod http://127.0.0.1:4570/v1/sources
```

## Verification

Run `npm test` or `node --test test/*.test.mjs`. The default tests use synthetic packages and a local HTTP fixture server, exercise real script execution and do not access external sites. For opt-in live verification of original MangaDex and Syosetu packages and explicit rejection of encrypted Hako:

```powershell
$env:VBOOK_REAL_TEST = '1'
node --test test/real-packages.test.mjs
Remove-Item Env:VBOOK_REAL_TEST
```

Live fixtures are downloaded into TEMP and removed after the test. The MangaDex test requests metadata and image URL lists only; it does not download chapter images. The Syosetu test reads one chapter into memory and prints only stage diagnostics, not chapter text. Upstream access failures and obsolete extension selectors fail the live tests explicitly; they are not replaced with fabricated data. Passing companion tests proves behavior on this Node host. It does not prove native iPhone behavior, source availability in another region or universal vBook compatibility.

The unchanged original **Truyện Full v13** package was also tested successfully through search, details, TOC and one text chapter on this Windows companion. The checked package SHA-256 was `3005f60b3a320fb698a7247943b3b30977fbade5e7e2ae9cc174e8c8707b5a86`; the query `Dế Mèn` returned one metadata result, ten chapter references and 11,257 sanitized HTML characters from the first chapter. This supports that package and the checked flow, not every vBook extension. The original package and chapter text are not committed. Run its focused live check with:

```powershell
$env:VBOOK_REAL_TEST = '1'
node --test --test-name-pattern 'original TruyenFull' test/real-packages.test.mjs
Remove-Item Env:VBOOK_REAL_TEST
```

Original Tàng Thư Viện and iSach packages installed but their upstream requests failed on this host. The previously checked Syosetu package had obsolete chapter selectors; MangaDex upstream access timed out. Those failures remain explicit and their scripts are not rewritten by this companion.
