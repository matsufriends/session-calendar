import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdirSync,mkdtempSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {webcrypto,createHash,randomBytes} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import {exportJWK,generateKeyPair,SignJWT} from 'jose';
import worker,{SyncStore} from '../cloud/worker.mjs';

const readText=url=>readFileSync(new URL(url,import.meta.url),'utf8');
const index=readText('../index.html');
const definition=name=>index.match(new RegExp('^function '+name+'\\(.*$','m'))[0];
const bytes=value=>new TextEncoder().encode(value);
const hex=value=>Buffer.from(value).toString('hex');

test('fixture snapshot traverses Native payload, Worker validation/storage, and Web task semantics',async()=>{
 const temporary=mkdtempSync(join(tmpdir(),'session-calendar-dot-pipeline-'));
 try {
  const payloadPath=join(temporary,'native-payload.json');
  const swiftCache=join(temporary,'swift-cache'); mkdirSync(swiftCache);
  const swift=spawnSync('swift',['test','--package-path','native','--filter','DotTaskPipelineTests/testNativeCollectorBuildsAnonymousWorkerPayloadAndRetainsProvenance'],{
   cwd:new URL('..',import.meta.url),encoding:'utf8',env:{...process.env,DOT_TASK_PIPELINE_OUTPUT:payloadPath,SWIFTPM_MODULECACHE_OVERRIDE:swiftCache,CLANG_MODULE_CACHE_PATH:swiftCache},maxBuffer:8*1024*1024,
  });
  assert.equal(swift.status,0,swift.stdout+'\n'+swift.stderr);
  const payload=JSON.parse(readFileSync(payloadPath,'utf8'));
  assert.equal(payload.sessions[0].source,'dot-task');

  const rows=new Map();
  const storage={transaction:fn=>fn({
   get:async key=>rows.get(key),put:async(key,value)=>rows.set(key,value),delete:async key=>rows.delete(key),
   list:async({prefix})=>new Map([...rows].filter(([key])=>key.startsWith(prefix))),
  })};
  const durableStore=new SyncStore({storage});
  const syncKey=await webcrypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const origin='https://fixture-sync.invalid',stamp=String(Math.floor(Date.now()/1000)),nonce=hex(randomBytes(32));
  const body=bytes(JSON.stringify(payload));
  const digest=createHash('sha256').update(body).digest('hex');
  const canonical=['SESSION-CALENDAR-V1','PUT',origin,'/api/sync',stamp,nonce,digest].join('\n');
  const signature=hex(await webcrypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},syncKey.privateKey,bytes(canonical)));
  const rawKey=new Uint8Array(await webcrypto.subtle.exportKey('raw',syncKey.publicKey));
  const viewerOrigin='https://fixture-viewer.invalid';
  const env={SYNC_ORIGIN:origin,SYNC_PUBLIC_KEY:hex(rawKey),VIEWER_ORIGIN:viewerOrigin,
   ACCESS_TEAM_DOMAIN:'fixture-pipeline.cloudflareaccess.com',ACCESS_AUD:'fixture-calendar',VIEWER_EMAIL:'fixture@example.invalid',
   ASSETS:{fetch:async()=>new Response(index,{headers:{'Content-Type':'text/html; charset=utf-8'}})},
   SYNC_STORE:{idFromName:()=> 'owner',get:()=>({fetch:(input,init)=>durableStore.fetch(new Request(input,init))})}};
  const response=await worker.fetch(new Request(origin+'/api/sync',{method:'PUT',headers:{
   'Content-Type':'application/json','X-Sync-Timestamp':stamp,'X-Sync-Nonce':nonce,'X-Sync-Signature':signature,
  },body}),env);
  assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{ok:true,count:1});

  const accessKeys=await generateKeyPair('RS256');
  const jwk=await exportJWK(accessKeys.publicKey); jwk.kid='fixture-pipeline-key'; jwk.alg='RS256'; jwk.use='sig';
  const accessToken=await new SignJWT({email:env.VIEWER_EMAIL,sub:'fixture-owner'})
   .setProtectedHeader({alg:'RS256',kid:jwk.kid}).setIssuer('https://'+env.ACCESS_TEAM_DOMAIN)
   .setAudience(env.ACCESS_AUD).setIssuedAt().setExpirationTime('5m').sign(accessKeys.privateKey);
  const originalFetch=globalThis.fetch;
  let readResponse,htmlResponse;
  globalThis.fetch=async input=> {
   assert.match(String(input),/fixture-pipeline\.cloudflareaccess\.com\/cdn-cgi\/access\/certs/);
   return Response.json({keys:[jwk]});
  };
  try {
   const headers={'Cf-Access-Jwt-Assertion':accessToken};
   readResponse=await worker.fetch(new Request(viewerOrigin+'/api/sessions',{headers}),env);
   htmlResponse=await worker.fetch(new Request(viewerOrigin+'/',{headers}),env);
  } finally { globalThis.fetch=originalFetch; }
  assert.equal(readResponse.status,200);
  assert.equal(htmlResponse.status,200);
  const readback=await readResponse.json();
  assert.match(await htmlResponse.text(),/snapshot観測日時/);
  const task=readback.sessions[0];
  assert.equal(task.source,'dot-task');
  assert.equal(task.task_registered_at,'2026-10-03T01:00:00Z');
  assert.equal(task.snapshot_observed_at,'2026-10-04T01:00:00Z');
  assert.equal(task.latest_turn_status,'completed');
  assert.equal(task.title,'ChatGPT タスク e-task-1');

  const helpers=definition('eventAt')+'\n'+definition('statusLabel')+'\n'+definition('anonymousTitle')+';({eventAt,statusLabel,anonymousTitle})';
  const ui=runInNewContext(helpers,{});
  assert.equal(ui.eventAt(task),task.task_registered_at);
  assert.match(ui.statusLabel(task),/直近の実行は終了（タスク全体の完了ではありません）/);
  assert.equal(ui.anonymousTitle(task),true);
  const makeNode=tag=>({tag,children:[],append(...items){this.children.push(...items)},replaceChildren(...items){this.children=items}});
  const panel=makeNode('aside'),document={createElement:makeNode};
  const detailCode=definition('dt')+'\n'+definition('statusLabel')+'\n'+definition('node')+'\n'+definition('detail')+';detail(task)';
  runInNewContext(detailCode,{task,document,$:()=>panel});
  const visibleText=node=>[node.textContent||'',...(node.children||[]).map(visibleText)].join(' ');
  assert.match(visibleText(panel),/タスク登録日時/);
  assert.match(visibleText(panel),/snapshot観測日時/);
  assert.match(visibleText(panel),/直近の実行は終了（タスク全体の完了ではありません）/);
  assert.match(visibleText(panel),/登録日時から実行開始・終了・所要時間を推定していません/);
  assert.equal(panel.children.find(node=>node.tag==='a').href,'codex://threads/fixture-task-1');
 } finally { rmSync(temporary,{recursive:true,force:true}); }
});
