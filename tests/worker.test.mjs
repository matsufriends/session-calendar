import test from 'node:test';
import assert from 'node:assert/strict';
import worker,{SyncStore,validateSnapshot,writerAuthorized,viewerAuthorized} from '../cloud/worker.mjs';
import {readFile} from 'node:fs/promises';
const titleFixtures=JSON.parse(await readFile(new URL('../native/Tests/SessionCalendarTests/Fixtures/title-normalization.json',import.meta.url),'utf8'));
function fixtureString(value) { return typeof value==='string'?value:value.repeat.repeat(value.count)+(value.suffix||''); }
const empty={sessions:[],timezone:'Asia/Tokyo'};
const record={id:'test-session',tool:'Claude',start:'2026-10-03T01:00:00Z',last_activity:null,end:null,project:'Example',title:'Example session'};
const dotTask={id:'fixture-task-1',source:'dot-task',tool:'ChatGPT',task_registered_at:'2026-10-03T01:00:00Z',latest_turn_status:'completed',snapshot_observed_at:'2026-10-04T01:00:00Z',project:'FixtureProject',title:'Fixture task'};
const req=(path,options={})=>new Request('https://example.test'+path,options);
test('snapshot allowlist rejects conversation, paths, invalid times, duplicates',()=>{
 assert.ok(validateSnapshot(empty));assert.ok(validateSnapshot({...empty,sessions:[record]}));
 for(const bad of [{...empty,body:'private'}, {...empty,sessions:[{...record,body:'private'}]}, {...empty,sessions:[{...record,project:'/Users/person/repo'}]}, {...empty,sessions:[{...record,start:'invalid'}]}, {...empty,sessions:[{...record,end:'2026-10-03T02:00:00Z'}]}, {...empty,sessions:[record,record]}]) assert.equal(validateSnapshot(bad),false);
});
test('dot-task snapshot schema preserves source and rejects unknown fields or CLI ID collisions',()=>{
 assert.ok(validateSnapshot({...empty,sessions:[dotTask]}));
 assert.ok(validateSnapshot({...empty,sessions:[{...dotTask,latest_turn_status:'inProgress'}]}));
 assert.equal(validateSnapshot({...empty,sessions:[{...dotTask,latest_turn_status:'future_state'}]}),false);
 assert.ok(validateSnapshot({...empty,sessions:[{...dotTask,snapshot_observed_at:null}]}));
 assert.equal(validateSnapshot({...empty,sessions:[{...dotTask,conversation:'fixture secret'}]}),false);
 assert.equal(validateSnapshot({...empty,sessions:[{...dotTask,snapshot_observed_at:'invalid'}]}),false);
 assert.equal(validateSnapshot({...empty,sessions:[dotTask,{...record,id:dotTask.id}]}),false);
 assert.equal(validateSnapshot({...empty,sessions:[dotTask,{...dotTask}]}),false);
});
test('shared title fixtures satisfy the Worker snapshot schema',()=>{
 for(const fixture of titleFixtures) {
  const title=fixtureString(fixture.expected);
  assert.ok(title.length>0&&title.length<=300&&!/[\u0000-\u001f]/.test(title),fixture.name);
  assert.ok(validateSnapshot({...empty,sessions:[{...record,title}]}),fixture.name);
 }
 assert.equal(validateSnapshot({...empty,sessions:[{...record,title:'😀'.repeat(151)}]}),false);
 assert.equal(validateSnapshot({...empty,sessions:[{...record,title:'line\nbreak'}]}),false);
});
test('viewer fails closed on missing configuration, forged token, invalid team domain',async()=>{
 assert.equal(await viewerAuthorized(req('/'),{}),false);
 assert.equal(await viewerAuthorized(req('/',{headers:{'Cf-Access-Jwt-Assertion':'forged'}}),{ACCESS_TEAM_DOMAIN:'test.cloudflareaccess.com',ACCESS_AUD:'fixture',VIEWER_EMAIL:'fixture@example.invalid'}),false);
 assert.equal(await viewerAuthorized(req('/'),{ACCESS_TEAM_DOMAIN:'evil.example',ACCESS_AUD:'fixture',VIEWER_EMAIL:'fixture@example.invalid'}),false);
});
test('all read routes reject unauthenticated requests before assets or KV',async()=>{
 const env={ASSETS:{fetch(){throw Error('must not access assets')}},SESSIONS:{get(){throw Error('must not access KV')}}};
 for(const path of ['/','/api/sessions','/index.html','/unknown'])assert.equal((await worker.fetch(req(path),env)).status,401);
});
test('real JWT verifier accepts only correct issuer, audience, expiry and owner email',async()=>{
 const {generateKeyPair,SignJWT}=await import('jose');
 // Ephemeral in-memory fixture key; no deployment credential is created or saved.
 const {publicKey,privateKey}=await generateKeyPair('RS256');
 const env={ACCESS_TEAM_DOMAIN:'fixture.cloudflareaccess.com',ACCESS_AUD:'calendar-fixture',VIEWER_EMAIL:'owner@example.invalid'};
 const sign=async(overrides={})=>new SignJWT({email:'owner@example.invalid',sub:'fixture-user',...overrides}).setProtectedHeader({alg:'RS256'}).setIssuer('https://fixture.cloudflareaccess.com').setAudience('calendar-fixture').setIssuedAt().setExpirationTime('5m').sign(privateKey);
 const check=async(token,settings=env)=>viewerAuthorized(req('/',{headers:{'Cf-Access-Jwt-Assertion':token}}),settings,publicKey);
 assert.equal(await check(await sign()),true);
 assert.equal(await check(await sign({email:'other@example.invalid'})),false);
 assert.equal(await check(await sign(),{...env,ACCESS_AUD:'wrong'}),false);
 assert.equal(await check(await sign(),{...env,ACCESS_TEAM_DOMAIN:'other.cloudflareaccess.com'}),false);
 const expired=await new SignJWT({email:env.VIEWER_EMAIL,sub:'fixture-user'}).setProtectedHeader({alg:'RS256'}).setIssuer('https://fixture.cloudflareaccess.com').setAudience(env.ACCESS_AUD).setIssuedAt(1).setExpirationTime(2).sign(privateKey);
 assert.equal(await check(expired),false);
 const fake=await sign();assert.equal(await check(fake.slice(0,-5)+'aaaaa'),false);
});

class MemoryStorage {
 constructor(){this.values=new Map();}
 async transaction(operation){return operation({
  get:async key=>this.values.get(key),
  put:async(key,value)=>this.values.set(key,value),
  delete:async key=>this.values.delete(key),
  list:async({prefix})=>new Map([...this.values].filter(([key])=>key.startsWith(prefix))),
 });}
}
const saved={sessions:[{...record,id:'existing'}],timezone:'Asia/Tokyo',warnings:[],synced_at:'2026-10-03T01:00:00.000Z'};
function seed(storage,snapshot=saved){const serialized=JSON.stringify(snapshot),count=Math.ceil(serialized.length/32768);for(let i=0;i<count;i++)storage.values.set('snapshot:'+i,serialized.slice(i*32768,(i+1)*32768));storage.values.set('snapshot-chunks',count);}
async function writerFixture(){
 const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const publicHex=Buffer.from(await crypto.subtle.exportKey('raw',pair.publicKey)).toString('hex');
 const storage=new MemoryStorage(),store=new SyncStore({storage});seed(storage);
 const env={SYNC_ORIGIN:'https://example.test',SYNC_PUBLIC_KEY:publicHex,SYNC_STORE:{idFromName:()=> 'owner',get:()=>({fetch:(input,init)=>store.fetch(input instanceof Request?input:new Request(input,init))})}};
 const sign=async(path,body,stamp=Math.floor(Date.now()/1000),nonce=Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('hex'))=>{
  const bytes=new TextEncoder().encode(body),hash=Buffer.from(await crypto.subtle.digest('SHA-256',bytes)).toString('hex');
  const canonical=['SESSION-CALENDAR-V1','PUT',env.SYNC_ORIGIN,path,String(stamp),nonce,hash].join('\n');
  const signature=Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(canonical))).toString('hex');
  return new Request(env.SYNC_ORIGIN+path,{method:'PUT',headers:{'Content-Type':'application/json','X-Sync-Timestamp':String(stamp),'X-Sync-Nonce':nonce,'X-Sync-Signature':signature},body});
 };
 return {env,storage,sign};
}
async function readStoredSnapshot(store){const response=await store.fetch(new Request('https://store.internal/'));return response.json();}
test('signed connection check preserves an existing snapshot and consumes a replay nonce',async()=>{
 const {env,storage,sign}=await writerFixture(),store=env.SYNC_STORE.get();
 const check=await sign('/api/sync/check','{"check":true}'),replay=check.clone();
 const first=await worker.fetch(check,env);assert.equal(first.status,200);assert.deepEqual(await first.json(),{ok:true,check:true});
 assert.equal((await readStoredSnapshot(store)).sessions.length,1);
 assert.deepEqual([...storage.values.keys()].filter(key=>key.startsWith('snapshot:')||key==='snapshot-chunks'),['snapshot:0','snapshot-chunks']);
 assert.equal((await worker.fetch(replay,env)).status,409);
 assert.equal((await readStoredSnapshot(store)).sessions[0].id,'existing');
});
test('unsigned and expired checks are rejected without changing existing data',async()=>{
 const {env,storage,sign}=await writerFixture();
 const unsigned=new Request(env.SYNC_ORIGIN+'/api/sync/check',{method:'PUT',headers:{'Content-Type':'application/json'},body:'{"check":true}'});
 assert.equal((await worker.fetch(unsigned,env)).status,401);
 assert.equal((await worker.fetch(await sign('/api/sync/check','{"check":true}',Math.floor(Date.now()/1000)-301),env)).status,401);
 assert.equal((await readStoredSnapshot(env.SYNC_STORE.get())).sessions[0].id,'existing');
 assert.equal([...storage.values.keys()].filter(key=>key.startsWith('nonce:')).length,0);
});
test('normal signed data sync still replaces the snapshot',async()=>{
 const {env,sign}=await writerFixture();
 const response=await worker.fetch(await sign('/api/sync',JSON.stringify({...empty,sessions:[record]})),env);
 assert.equal(response.status,200);assert.deepEqual(await response.json(),{ok:true,count:1});
 assert.equal((await readStoredSnapshot(env.SYNC_STORE.get())).sessions[0].id,record.id);
});
