import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { RuntimeStore } from './store.mjs';
import { RuntimeError } from './errors.mjs';

export const health = Object.freeze({
  engine: 'vbook', version: '0.1.0', runtime: 'Node.js companion',
  capabilities: ['original-plaintext-zip', 'legacy-novel-comic', 'search-detail-toc-chapter',
    'synchronous-fetch-http', 'html-selectors', 'local-script-load', 'static-config', 'persistent-localStorage'],
  limitations: ['Trusted extensions only; child processes and node:vm are not a security sandbox.',
    'Requires a reachable computer/server; this is not an embedded iOS runtime.',
    'Encrypted scripts, browser/WebView, native crypto, graphics, WebSocket, dynamic config, cookies and newer native APIs are unsupported.',
    'HTML/selector support is a compatibility subset; extension/source versions can still fail.'],
});

function json(response, status, value, headers = {}) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', ...headers });
  response.end(JSON.stringify(value));
}

async function requestJson(request) {
  if (!String(request.headers['content-type'] ?? '').startsWith('application/json')) {
    throw new RuntimeError('INVALID_REQUEST', 'POST requests require application/json.', 400);
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 1024 * 1024) throw new RuntimeError('REQUEST_LIMIT', 'Request body exceeds limit.', 413);
    chunks.push(chunk);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error();
    return value;
  } catch { throw new RuntimeError('INVALID_REQUEST', 'Request body must be a JSON object.', 400); }
}

function loopbackOrigin(origin) {
  try { return ['localhost', '127.0.0.1', '[::1]'].includes(new URL(origin).hostname); }
  catch { return false; }
}

export function createServer(store, { apiToken = '', allowedOrigins = [], executionSlots = 4 } = {}) {
  let activeExecutions = 0;
  return http.createServer(async (request, response) => {
    const origin = request.headers.origin;
    if (origin) {
      if (!loopbackOrigin(origin) && !allowedOrigins.includes(origin)) return json(response, 403, { error: { code: 'ORIGIN_REJECTED', message: 'Browser origin is not allowed.' } });
      response.setHeader('Access-Control-Allow-Origin', origin);
      response.setHeader('Vary', 'Origin');
      response.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      response.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
      response.setHeader('Access-Control-Expose-Headers', 'X-Next-Page');
    }
    if (request.method === 'OPTIONS') { response.writeHead(204); return response.end(); }
    if (apiToken && request.headers.authorization !== `Bearer ${apiToken}`) return json(response, 401, { error: { code: 'UNAUTHORIZED', message: 'Runtime API token required.' } });
    let execution = false;
    try {
      const url = new URL(request.url, 'http://127.0.0.1');
      const route = url.pathname;
      if (request.method === 'GET' && route === '/v1/health') return json(response, 200, health);
      if (request.method === 'GET' && route === '/v1/sources') return json(response, 200, store.sources());
      if (request.method === 'GET' && route === '/v1/extensions') return json(response, 200, store.extensions());
      if (request.method === 'GET' && route === '/v1/repositories') return json(response, 200, store.index.repositories);
      if (request.method === 'POST' && ['/v1/extensions/install', '/v1/repositories'].includes(route)) {
        const body = await requestJson(request);
        if (typeof body.url !== 'string' || !body.url) throw new RuntimeError('INVALID_REQUEST', 'url must be a nonempty string.', 400);
        const result = route === '/v1/extensions/install' ? await store.installUrl(body.url) : await store.addRepository(body.url);
        return json(response, 201, result);
      }
      const sourceRoute = /^\/v1\/sources\/([^/]+)\/(search|detail|chapters|chapter)$/.exec(route);
      if (request.method !== 'GET' || !sourceRoute) throw new RuntimeError('NOT_FOUND', 'Route not found.', 404);
      if (activeExecutions >= executionSlots) throw new RuntimeError('RUNTIME_BUSY', 'Runtime execution slots are busy; retry shortly.', 429);
      const [, encodedId, action] = sourceRoute;
      const id = decodeURIComponent(encodedId);
      if (!['search'].includes(action) && !url.searchParams.get('ref')) throw new RuntimeError('INVALID_REQUEST', 'ref is required.', 400);
      execution = true;
      activeExecutions++;
      if (action === 'search') {
        const result = await store.search(id, url.searchParams.get('query') ?? '', url.searchParams.get('page') ?? '');
        return json(response, 200, result.items, result.nextPage ? { 'X-Next-Page': result.nextPage } : {});
      }
      const result = await store[action](id, url.searchParams.get('ref'));
      return json(response, 200, result);
    } catch (error) {
      json(response, error.status || 500, { error: { code: error.code || 'RUNTIME_ERROR', message: error.message } });
    } finally { if (execution) activeExecutions--; }
  });
}

export async function startServer({ host = process.env.HOST || '127.0.0.1', port = Number(process.env.PORT || 4570),
  directory = process.env.VBOOK_DATA_DIR || path.join(path.dirname(fileURLToPath(import.meta.url)), '.data'),
  apiToken = process.env.VBOOK_API_TOKEN || '', allowedOrigins = (process.env.ALLOWED_ORIGINS || '').split(',').filter(Boolean) } = {}) {
  const store = await new RuntimeStore(directory).init();
  const server = createServer(store, { apiToken, allowedOrigins });
  server.requestTimeout = 120000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
  return { server, store };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  startServer().then(({ server }) => {
    const address = server.address();
    console.log(`vBook companion listening on http://${address.address}:${address.port}`);
    console.log('Only install extensions you trust. Read runtime/README.md for supported APIs.');
  }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
