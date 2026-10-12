import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { webcrypto, createHash } from 'node:crypto';
import { parseHtml, cleanHtml } from '../../../runtime/html.mjs';

const host = fs.readFileSync(new URL('../ios/Resources/host.js', import.meta.url), 'utf8');
const cryptoSource = fs.readFileSync(new URL('../ios/Resources/crypto-js.js', import.meta.url), 'utf8');

// This runs the actual bundled JavaScript shim. The SwiftSoup/URLSession bridge
// is replaced only at its JSON boundary; it is not an iOS runtime test.
function execute(scripts, script, args = [], { storage = {}, config = {}, manifest = {}, fetch = () => '' } = {}) {
  const handles = new Map(); let next = 1;
  const save = item => { const id = next++; handles.set(id, item); return id; };
  const bridge = operation => input => {
    try { return JSON.stringify({ value: operation(JSON.parse(input)) }); }
    catch (error) { return JSON.stringify({ error: { code: error.code || 'HOST_FAILED', message: error.message } }); }
  };
  const context = vm.createContext({
    crypto: webcrypto,
    __nativeHtml: bridge(({ op, args = [], handle }) => {
      if (op === 'parse') return save(parseHtml(args[0]));
      if (op === 'clean') return cleanHtml(args[0], args[1]);
      const item = handles.get(handle);
      assert.ok(item, 'valid native handle');
      if (['get','select','children','parent','next','prev'].includes(op)) return save(item[op](...args));
      const output = item[op](...args);
      return output === item || output === undefined ? null : output;
    }),
    __nativeFetch: bridge(request => {
      const body = fetch(request);
      return { status: 200, statusText: 'OK', ok: true, url: request.url,
        request: { url: request.url }, headers: {'content-type':'text/html; charset=utf-8'},
        charset: 'utf-8', base64Data: Buffer.from(body).toString('base64') };
    }),
    __nativeDecode: bridge(({ base64 }) => Buffer.from(base64, 'base64').toString('utf8')),
    __nativeSleep: bridge(() => null),
    __payload: { scripts, script, args, storage, config,
      manifest: {metadata:{name:'Fixture', source:'https://fixture.test'}, ...manifest} }
  });
  vm.runInContext(cryptoSource, context, { timeout: 1000 });
  vm.runInContext(host, context, { timeout: 1000 });
  return JSON.parse(vm.runInContext('__runVbook(__payload)', context, { timeout: 1000 }));
}

test('bundled host executes search/detail/TOC/chapter fixture scripts through synchronous JSON bridges', () => {
  const scripts = {
    'search.js': `function execute(query,page) { return Response.success(fetch('https://fixture.test/search',{queries:{q:query,page:page}}).html().select('.story').map(e=>({name:e.text(),link:e.attr('href')}))); }`,
    'detail.js': `function execute(url) { var doc=Http.get(url).headers({Referer:url}).html(); return Response.success({name:doc.select('h1').text(),description:doc.select('.intro').html()}); }`,
    'toc.js': `function execute(url) { var out=[]; for(var e of fetch(url).html().select('.chapter')) out.push({name:e.text(),url:e.attr('href')}); return Response.success(out); }`,
    'chap.js': `function execute(url) { var doc=fetch(url).html(); doc.select('script').remove(); return Response.success(doc.select('#content').html()); }`
  };
  const requests = [];
  const fetch = request => {
    requests.push(request);
    if(request.url.endsWith('/search'))return '<a class="story" href="/story">A story</a>';
    if(request.url.endsWith('/toc'))return '<a class="chapter" href="/one">Chapter one</a><a class="chapter" href="/two">Chapter two</a>';
    if(request.url.endsWith('/one'))return '<div id="content">Hello <b>reader</b><script>bad()</script></div>';
    return '<h1>A story</h1><div class="intro">A <i>description</i></div>';
  };
  assert.deepEqual(execute(scripts,'search.js',['story','2'],{fetch}).data,[{name:'A story',link:'/story'}]);
  assert.deepEqual(requests[0].options.queries,{q:'story',page:'2'});
  assert.deepEqual(execute(scripts,'detail.js',['https://fixture.test/story'],{fetch}).data,{name:'A story',description:'A <i>description</i>'});
  assert.deepEqual(execute(scripts,'toc.js',['https://fixture.test/toc'],{fetch}).data,[{name:'Chapter one',url:'/one'},{name:'Chapter two',url:'/two'}]);
  assert.equal(execute(scripts,'chap.js',['https://fixture.test/one'],{fetch}).data,'Hello <b>reader</b>');
});

test('HTML proxy supports numeric access, iteration, mutations, attributes and empty selections', () => {
  const result=execute({'a.js': `function execute() { var d=Html.parse('<main><p id="a">One <b>bold</b></p><p>Two</p></main>'); var a=d.select('p'); a[0].attr('data-test','yes'); a.last().text('Changed'); return Response.success({length:a.length,own:a.first().ownText(),attrs:a[0].attributes(),second:a[1].text(),empty:a.get(-1).isEmpty(),names:a.map(e=>e.tagName())}); }`},'a.js');
  assert.deepEqual(result.data,{length:2,own:'One',attrs:{id:'a','data-test':'yes'},second:'Changed',empty:true,names:['p','p']});
});

test('hosted XCTest HTML fixture also executes through the bundled JavaScript boundary', () => {
  const nativeTest = fs.readFileSync(new URL('../../../ios/RunnerTests/RunnerTests.swift', import.meta.url), 'utf8');
  const script = nativeTest.match(/testNativeVbookHTMLBridgeMutationAndContextIsolation[\s\S]*?let script = """\r?\n([\s\S]*?)\r?\n\s*"""/)?.[1];
  assert.ok(script, 'hosted XCTest fixture exists');
  const first = execute({'chap.js':script}, 'chap.js');
  assert.match(first.data.html, /<strong>reader<\/strong>/);
  assert.equal(first.data.own, 'Hello');
  assert.equal(first.data.parent, 'content');
  assert.equal(first.data.next, 'after');
  assert.equal(first.data.previous, 'strong');
  assert.equal(first.data.before, 'new');
  assert.equal(first.data.after, '');
  assert.equal(first.data.count, 2);
  assert.match(first.data.clean, /<b>B<\/b>/);
  assert.doesNotMatch(first.data.clean, /section|script|bad\(\)/);
  assert.deepEqual(first.storage, {counter:'1'});
  assert.deepEqual(execute({'chap.js':script}, 'chap.js').storage, {counter:'1'});
  assert.deepEqual(execute({'chap.js':script}, 'chap.js', [], {storage:first.storage}).storage, {counter:'2'});
});

test('local load, static config and localStorage are preserved without copying app core.js', () => {
  const scripts={'common.js':`function label(x){return 'label:'+x;}`,
    'a.js':`load('common.js'); function execute() {var count=Number(localStorage.getItem('counter')||0)+1;localStorage.setItem('counter',count);return Response.success(label(MODE)+':'+count);}`};
  const options={manifest:{config:{MODE:{default:'default'}}},storage:{counter:'2'}};
  const result=execute(scripts,'a.js',[],options);
  assert.equal(result.data,'label:default:3'); assert.deepEqual(result.storage,{counter:'3'});
  assert.equal(execute(scripts,'a.js',[],{...options,config:{MODE:'override'}}).data,'label:override:3');
});

test('unsupported native features and source errors fail explicitly', () => {
  assert.throws(()=>execute({'a.js':`function execute(){return Engine.get('x');}`},'a.js'),/not supported/);
  assert.throws(()=>execute({'a.js':`function execute(){return Response.error('source changed');}`},'a.js'),/source changed/);
  assert.throws(()=>execute({'a.js':`function execute(){return [];}`},'a.js'),/Response JSON/);
});

test('pinned built-in CryptoJS hashes and AES use upstream bytes; local crypto.js cannot override it', () => {
  const provenance = JSON.parse(fs.readFileSync(new URL('../ios/Resources/crypto-js.provenance.json', import.meta.url), 'utf8'));
  assert.equal(provenance.version, '4.2.0');
  assert.equal(createHash('sha256').update(cryptoSource).digest('hex'), provenance.files['crypto-js.js']);
  const result = execute({'crypto.js':`throw new Error('local override');`, 'a.js':`
    load('crypto.js');
    function execute() {
      var key=CryptoJS.enc.Hex.parse('2b7e151628aed2a6abf7158809cf4f3c');
      var iv=CryptoJS.enc.Hex.parse('000102030405060708090a0b0c0d0e0f');
      var plain=CryptoJS.enc.Hex.parse('6bc1bee22e409f96e93d7e117393172a');
      var encrypted=CryptoJS.AES.encrypt(plain,key,{iv:iv,mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.NoPadding});
      var decoded=CryptoJS.AES.decrypt(encrypted,key,{iv:iv,mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.NoPadding});
      return Response.success({sha:CryptoJS.SHA256('abc').toString(),cipher:encrypted.ciphertext.toString(),plain:decoded.toString(),randomBytes:CryptoJS.lib.WordArray.random(16).sigBytes});
    }`}, 'a.js');
  assert.equal(result.data.sha, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assert.equal(result.data.cipher, '7649abac8119b246cee98e9b12e9197d');
  assert.equal(result.data.plain, '6bc1bee22e409f96e93d7e117393172a');
  assert.equal(result.data.randomBytes, 16);
});

test('script load rejects path traversal, missing files and circular imports', () => {
  assert.throws(()=>execute({'a.js':`function execute(){load('../a.js');}`},'a.js'),/Missing local script/);
  assert.throws(()=>execute({'a.js':`load('b.js'); function execute(){return Response.success('x');}`,'b.js':`load('b.js');`},'a.js'),/Circular load/);
});

test('response json/text/base64/blob and Http builder pass bodies and headers to native HTTP', () => {
  const requests=[];
  const result=execute({'a.js':`function execute(){var text=Http.post('https://fixture.test/api').headers({'X-Test':'yes'}).params({id:'1'}).body({name:'value'}).timeout(900).string();var r=fetch('https://fixture.test/json');return Response.success({text:text,json:r.json(),base64:r.base64(),blob:r.blob().base64(),header:r.header('CONTENT-TYPE')});}`},'a.js',[],{fetch:request=>{requests.push(request);return request.url.endsWith('/json')?'[1,2]':'posted';}});
  assert.equal(result.data.text,'posted');assert.deepEqual(result.data.json,[1,2]);
  assert.equal(result.data.base64,Buffer.from('[1,2]').toString('base64')); assert.equal(result.data.blob,result.data.base64);
  assert.equal(requests[0].options.method,'POST'); assert.deepEqual(requests[0].options.body,{name:'value'});
  assert.deepEqual(requests[0].options.headers,{'X-Test':'yes'});assert.equal(requests[0].options.timeout,900);
});
