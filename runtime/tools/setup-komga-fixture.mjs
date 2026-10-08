import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {randomBytes,createHash} from 'node:crypto';
import {deflateSync} from 'node:zlib';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {zipSync,strToU8} from 'fflate';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../runtime-data/komga');
const libraryRoot=path.join(root,'fixture-library');
const fixtureSeries=path.join(libraryRoot,'Tachi Books Runtime Fixture');
await mkdir(fixtureSeries,{recursive:true});
// Self-authored test pages: no downloaded artwork or publisher content.
function crc32(b){let c=0xffffffff;for(const v of b){c^=v;for(let k=0;k<8;k++)c=(c>>>1)^(0xedb88320&-(c&1));}return(c^0xffffffff)>>>0;}
function chunk(type,data){const tag=Buffer.from(type),size=Buffer.alloc(4),crc=Buffer.alloc(4);size.writeUInt32BE(data.length);crc.writeUInt32BE(crc32(Buffer.concat([tag,data])));return Buffer.concat([size,tag,data,crc]);}
function page(color){const width=320,height=480,head=Buffer.alloc(13);head.writeUInt32BE(width);head.writeUInt32BE(height,4);head[8]=8;head[9]=2;const raw=Buffer.alloc(height*(1+width*3));for(let y=0;y<height;y++){const offset=y*(1+width*3);for(let x=0;x<width;x++){const v=(x%80<3||y%120<3)?[20,30,40]:color;for(let c=0;c<3;c++)raw[offset+1+x*3+c]=v[c];}}return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',head),chunk('IDAT',deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);}
const cbz=zipSync({'001.png':page([180,215,235]),'002.png':page([235,200,150]),'ComicInfo.xml':strToU8('<?xml version="1.0"?><ComicInfo><Title>Original fixture chapter</Title><Series>Tachi Books Runtime Fixture</Series><Number>1</Number><Writer>Tachi Books test fixture</Writer><Summary>Self-authored test graphics used solely to verify original extension runtime.</Summary><PageCount>2</PageCount></ComicInfo>')});
await writeFile(path.join(fixtureSeries,'chapter-001.cbz'),cbz);
const endpoint=process.env.KOMGA_TEST_URL || 'http://127.0.0.1:25600';
let account;try{account=JSON.parse(await readFile(path.join(root,'test-account.json'),'utf8'));}catch{account={email:'fixture@tachi-books.test',password:randomBytes(24).toString('hex')};await writeFile(path.join(root,'test-account.json'),JSON.stringify(account));}
async function request(url,options={}){const response=await fetch(url,{...options,signal:AbortSignal.timeout(30000)});if(!response.ok)throw Error(`${response.status} ${new URL(url).pathname}`);const text=await response.text();return text?JSON.parse(text):null;}
const claim=await request(endpoint+'/api/v1/claim');
if(!claim.isClaimed)await request(endpoint+'/api/v1/claim',{method:'POST',headers:{'X-Komga-Email':account.email,'X-Komga-Password':account.password}});
const authorization='Basic '+Buffer.from(account.email+':'+account.password).toString('base64');
const headers={Authorization:authorization,'Content-Type':'application/json'};
const libraries=await request(endpoint+'/api/v1/libraries',{headers});
let library=libraries.find(i=>i.name==='Runtime fixture');
if(!library)library=await request(endpoint+'/api/v1/libraries',{method:'POST',headers,body:JSON.stringify({name:'Runtime fixture',root:libraryRoot,scanOnStartup:true})});
await request(endpoint+`/api/v1/libraries/${library.id}/scan`,{method:'POST',headers});
const source=process.env.KOMGA_TEST_SOURCE || '4508733312114627536',suwayomi=process.env.SUWAYOMI_TEST_URL || 'http://127.0.0.1:4567';
for(const [position,value]of [[1,endpoint],[2,account.email],[3,account.password]]){
 await request(suwayomi+`/api/v1/source/${source}/preferences`);
 await request(suwayomi+`/api/v1/source/${source}/preferences`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({position,value})});
}
console.log(JSON.stringify({stage:'fixture-ready',komgaVersion:'1.28.1',fixtureSha256:createHash('sha256').update(cbz).digest('hex'),source,libraryId:library.id,fixturePages:2}));
