import syncFetch from 'sync-fetch';
import vm from 'node:vm';
import { parseHtml, cleanHtml } from './html.mjs';
import { limits, safePath } from './package.mjs';
import { RuntimeError, capabilityError } from './errors.mjs';

const ANDROID_UA = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';
const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
const IOS_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

export function httpUrl(value, base) {
  let url;
  try { url = new URL(String(value), base); }
  catch { throw new RuntimeError('INVALID_URL', 'Expected an HTTP(S) URL.', 400); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new RuntimeError('INVALID_URL', 'Only HTTP(S) URLs without credentials are supported.', 400);
  }
  return url;
}

function blobValue(data, type = '') {
  const base64 = String(data ?? '');
  return { _isBlob: true, _base64: base64, type: String(type),
    size: Buffer.from(base64, 'base64').length,
    base64: () => base64, toString: () => base64 };
}

export function createFetch(baseUrl) {
  let requestCount = 0;
  let downloadedBytes = 0;
  function fetch(url, options = {}) {
    if (++requestCount > 50) throw new RuntimeError('EXECUTION_LIMIT', 'Too many HTTP requests in one script.');
    fetch.requestCount = requestCount;
    options ??= {};
    const target = httpUrl(url, baseUrl);
    for (const [key, value] of Object.entries(options.queries ?? {})) target.searchParams.set(key, String(value));
    const method = String(options.method ?? 'GET').toUpperCase();
    const headers = { 'User-Agent': ANDROID_UA, 'Accept-Encoding': 'identity', ...(options.headers ?? {}) };
    let body = options.body;
    if (['GET', 'HEAD'].includes(method)) body = undefined;
    else if (body?._isBlob) {
      headers['Content-Type'] ??= body.type || 'application/octet-stream';
      body = Buffer.from(body._base64, 'base64');
    } else if (body && typeof body === 'object') {
      const fields = new URLSearchParams();
      for (const [key, value] of Object.entries(body)) {
        if (value && typeof value === 'object') throw new RuntimeError('INVALID_HTTP_BODY', 'Form body must contain flat values.');
        fields.set(key, String(value));
      }
      headers['Content-Type'] ??= 'application/x-www-form-urlencoded';
      body = fields.toString();
    }
    if (body !== undefined && Buffer.byteLength(body) > limits.responseBytes) {
      throw new RuntimeError('EXECUTION_LIMIT', 'Request body exceeds size limit.');
    }
    const requestedTimeout = Number(options.timeout) || 10000;
    const timeout = Math.max(1, Math.min(10000, Math.trunc(requestedTimeout)));
    let response;
    let bytes;
    let failure;
    try {
      response = syncFetch(target.href, { method, headers, body, timeout, size: limits.responseBytes, follow: 10 });
      bytes = Buffer.from(response.arrayBuffer());
      if (response.ok) fetch.successfulRequests++;
      else fetch.lastNetworkFailure = `HTTP ${response.status} from ${target.hostname}.`;
      downloadedBytes += bytes.length;
      if (downloadedBytes > 32 * 1024 * 1024) throw new RuntimeError('EXECUTION_LIMIT', 'Script response-byte limit exceeded.');
    } catch (error) {
      if (error instanceof RuntimeError) throw error;
      failure = error;
      fetch.lastNetworkFailure = `HTTP request to ${target.hostname} failed (${error.type || error.code || error.name}).`;
      response = null;
      bytes = Buffer.alloc(0);
    }
    const responseHeaders = response ? Object.fromEntries(response.headers.entries()) : {};
    const text = charset => {
      if (!bytes.length && failure) return undefined;
      const label = charset || /charset\s*=\s*["']?([^;"'\s]+)/i.exec(responseHeaders['content-type'] ?? '')?.[1] || 'utf-8';
      try { return new TextDecoder(label).decode(bytes); }
      catch { throw capabilityError(`text charset ${label}`); }
    };
    return {
      request: { url: target.href, headers }, headers: responseHeaders,
      header: key => responseHeaders[String(key).toLowerCase()] ?? '',
      status: response?.status ?? 504, statusText: response?.statusText ?? 'Network failure',
      ok: response?.ok ?? false, url: response?.url ?? '',
      text, json: () => JSON.parse(text()), html: charset => parseHtml(text(charset) ?? ''),
      base64: () => bytes.toString('base64'), blob: () => blobValue(bytes.toString('base64'), responseHeaders['content-type']),
    };
  }
  fetch.lastNetworkFailure = '';
  fetch.requestCount = 0;
  fetch.successfulRequests = 0;
  return fetch;
}

function storageApi(backing) {
  return {
    getItem: key => Object.hasOwn(backing, String(key)) ? backing[String(key)] : null,
    setItem: (key, value) => {
      const name = String(key);
      const text = String(value);
      if (Buffer.byteLength(name) + Buffer.byteLength(text) > 1024 * 1024) throw new RuntimeError('EXECUTION_LIMIT', 'Storage item exceeds size limit.');
      backing[name] = text;
      if (Buffer.byteLength(JSON.stringify(backing)) > 2 * 1024 * 1024) throw new RuntimeError('EXECUTION_LIMIT', 'Extension storage exceeds size limit.');
    },
    removeItem: key => { delete backing[String(key)]; },
    clear: () => { for (const key of Object.keys(backing)) delete backing[key]; },
  };
}

function unsupported(name) {
  const fail = () => { throw capabilityError(name); };
  return new Proxy(fail, { get: fail, apply: fail, construct: fail });
}

export function executeScript({ manifest, scripts, script, args = [], storage = {}, config = {} }, timeoutMs = 18000) {
  if (!Object.hasOwn(scripts, script)) throw new RuntimeError('SCRIPT_MISSING', `Script ${script} is absent.`);
  const persistent = Object.assign(Object.create(null), storage);
  const cache = Object.create(null);
  const logs = [];
  const logger = message => { if (logs.length < 200) logs.push(String(message).slice(0, 1000)); };
  const fetch = createFetch(manifest.metadata.source);
  const httpBuilder = (url, method) => {
    const options = { method };
    return {
      headers(data) { options.headers = data; return this; },
      params(data) { options.queries = data; return this; },
      queries(data) { options.queries = data; return this; },
      body(data) { options.body = data; return this; },
      binary(data, type) { options.body = blobValue(data, type); return this; },
      timeout(value) { options.timeout = value; return this; },
      string(charset) { return fetch(url, options).text(charset); },
      html(charset) { return fetch(url, options).html(charset); },
      blob() { return fetch(url, options).blob(); },
      url() { return url; },
    };
  };
  const context = vm.createContext({
    fetch,
    Response: { success: (data, data2) => JSON.stringify({ code: 0, data, data2 }),
      error: data => JSON.stringify({ code: 1, data }) },
    Html: { parse: parseHtml, clean: cleanHtml },
    Http: { get: url => httpBuilder(url, 'GET'), post: url => httpBuilder(url, 'POST') },
    UserAgent: { system: () => ANDROID_UA, android: () => ANDROID_UA, chrome: () => CHROME_UA, ios: () => IOS_UA },
    Console: { log: logger }, Log: { log: logger }, console: { log: logger },
    localStorage: storageApi(persistent), cacheStorage: storageApi(cache),
    Blob: { fromBase64: blobValue },
    Engine: unsupported('browser/WebView execution'), CryptoJS: unsupported('CryptoJS/native crypto'),
    localCookie: unsupported('persistent cookie APIs'), localConfig: unsupported('dynamic config APIs'),
    localDatabase: unsupported('localDatabase'), localBook: unsupported('localBook'),
    Graphics: unsupported('Graphics'), WebSocket: unsupported('WebSocket'),
    Qt: unsupported('Qt translation'), QT: unsupported('Qt translation'),
    Script: unsupported('nested Script.execute'),
    sleep: value => {
      const duration = Math.max(0, Math.min(5000, Number(value) || 0));
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, duration);
    },
  });
  let loadedBytes = 0;
  const activeLoads = new Set();
  context.load = filename => {
    filename = String(filename);
    safePath(filename);
    if (filename === 'crypto.js') throw capabilityError('built-in crypto.js');
    if (filename.includes('/') || !Object.hasOwn(scripts, filename)) throw new RuntimeError('SCRIPT_MISSING', `load() file missing: ${filename}.`);
    if (activeLoads.has(filename)) throw new RuntimeError('CIRCULAR_LOAD', `Circular load(): ${filename}.`);
    loadedBytes += Buffer.byteLength(scripts[filename]);
    if (loadedBytes > 32 * 1024 * 1024) throw new RuntimeError('EXECUTION_LIMIT', 'Loaded-script size limit exceeded.');
    activeLoads.add(filename);
    try { return vm.runInContext(scripts[filename], context, { filename, timeout: timeoutMs }); }
    finally { activeLoads.delete(filename); }
  };
  const constants = [];
  for (const [name, definition] of Object.entries(manifest.config ?? {})) {
    if (definition?.mode === 'database') continue;
    if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name)) throw new RuntimeError('INVALID_CONFIG', `Invalid static config identifier: ${name}.`);
    const value = Object.hasOwn(config, name) ? config[name] :
      definition && typeof definition === 'object' ? definition.default ?? '' : definition;
    constants.push(`const ${name} = ${JSON.stringify(String(value ?? ''))};`);
  }
  context.__arguments = args.map(value => String(value ?? ''));
  const source = `${constants.join('\n')}\n${scripts[script]}\n;execute(...__arguments);`;
  const raw = vm.runInContext(source, context, { filename: script, timeout: timeoutMs });
  if (fetch.requestCount > 0 && fetch.successfulRequests === 0) {
    throw new RuntimeError('UPSTREAM_UNAVAILABLE', fetch.lastNetworkFailure || 'All extension HTTP requests failed.', 502);
  }
  if (typeof raw !== 'string') throw new RuntimeError('INVALID_SCRIPT_RESPONSE',
    'execute() must return a Response JSON string.' + (fetch.lastNetworkFailure ? ` ${fetch.lastNetworkFailure}` : ''));
  if (Buffer.byteLength(raw) > 16 * 1024 * 1024) throw new RuntimeError('EXECUTION_LIMIT', 'Script result exceeds size limit.');
  let response;
  try { response = JSON.parse(raw); }
  catch { throw new RuntimeError('INVALID_SCRIPT_RESPONSE', 'execute() did not return valid Response JSON.'); }
  if (response?.code !== 0) throw new RuntimeError('SOURCE_ERROR', String(response?.data ?? 'Extension returned an error.'), 502);
  return { data: response.data, data2: response.data2, storage: persistent, logs };
}
