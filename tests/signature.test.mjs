import test from 'node:test';
import assert from 'node:assert/strict';
import worker,{writerAuthorized,SyncStore} from '../cloud/worker.mjs';
const hex=b=>Buffer.from(b).toString('hex');
const empty={sessions:[],timezone:'Asia/Tokyo'};
async function fixture() {
 const key=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const env={SYNC_ORIGIN:'https://sync.example.test',SYNC_PUBLIC_KEY:hex(await crypto.subtle.exportKey('raw',key.publicKey))};
 const values=new Map();const storage={async get(k){return values.get(k)},async put(k,v){values.set(k,v)},async delete(k){values.delete(k)},async list({prefix}){return new Map([...values].filter(([k])=>k.startsWith(prefix)))},async transaction(fn){return fn(storage)}};
 const store=new SyncStore({storage});env.SYNC_STORE={idFromName(){return 'owner'},get(){return {fetch(url,opts){return store.fetch(new Request(url,opts))}}}};
 async function signed(data=empty,overrides={}) {
  const body=JSON.stringify(data),stamp=String(Math.floor(Date.now()/1000)),nonce=hex(crypto.getRandomValues(new Uint8Array(32)));
  const fields={stamp,nonce,origin:env.SYNC_ORIGIN,path:'/api/sync',...overrides};
  const canonical=['SESSION-CALENDAR-V1','PUT',fields.origin,fields.path,fields.stamp,fields.nonce,hex(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(body)))].join('\n');
  const signature=hex(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key.privateKey,new TextEncoder().encode(canonical)));
  return new Request(env.SYNC_ORIGIN+'/api/sync',{method:'PUT',headers:{'Content-Type':'application/json','X-Sync-Timestamp':fields.stamp,'X-Sync-Nonce':fields.nonce,'X-Sync-Signature':signature},body});
 }
 return {env,signed,values};
}
test('P256 signature accepts raw signature; rejects stale, future, wrong origin/path/body/key and bearer',async()=>{
 const {env,signed}=await fixture();let r=await signed();assert.ok(await writerAuthorized(r,env,new TextEncoder().encode(JSON.stringify(empty))));
 for(const overrides of [{stamp:String(Math.floor(Date.now()/1000)-301)},{stamp:String(Math.floor(Date.now()/1000)+301)},{origin:'https://other.test'},{path:'/api/sessions'}]) {
  r=await signed(empty,overrides);assert.equal(await writerAuthorized(r,env,new TextEncoder().encode(JSON.stringify(empty))),null);
 }
 r=await signed();assert.equal(await writerAuthorized(r,env,new TextEncoder().encode('tampered')),null);
 assert.equal(await writerAuthorized(r,{...env,SYNC_PUBLIC_KEY:'00'},new TextEncoder().encode(JSON.stringify(empty))),null);
 r=await signed();r.headers.set('Authorization','Bearer old');assert.equal(await writerAuthorized(r,env,new TextEncoder().encode(JSON.stringify(empty))),null);
});
test('valid write consumes nonce atomically and replay fails; writer cannot read history',async()=>{
 const {env,signed,values}=await fixture();const r=await signed();
 assert.equal((await worker.fetch(r.clone(),env)).status,200);
 assert.deepEqual(JSON.parse(values.get('snapshot:0')).sessions,[]);
 assert.equal((await worker.fetch(r.clone(),env)).status,409);
 for(const path of ['/','/api/sessions','/index.html','/api/sync']) {
  const read=new Request(env.SYNC_ORIGIN+path,{headers:r.headers});assert.notEqual((await worker.fetch(read,env)).status,200);
 }
});
test('schema/size failures and forged signatures cannot modify snapshot',async()=>{
 const {env,signed,values}=await fixture();
 for(const data of [{...empty,body:'private'},{...empty,sessions:Array(20001).fill({})}]) assert.equal((await worker.fetch(await signed(data),env)).status,400);
 assert.equal((await worker.fetch(new Request(env.SYNC_ORIGIN+'/api/sync',{method:'PUT',headers:{'Content-Type':'application/json'},body:' '.repeat(2*1024*1024+1)}),env)).status,400);
 const r=await signed();r.headers.set('X-Sync-Signature','0'.repeat(128));assert.equal((await worker.fetch(r,env)).status,401);
 assert.equal(values.size,0);
});
test('expired nonces are pruned; live nonce saturation rejects further writes',async()=>{
 const {env,signed,values}=await fixture();values.set('nonce:expired',1);
 assert.equal((await worker.fetch(await signed(),env)).status,200);assert.equal(values.has('nonce:expired'),false);
 for(let i=0;i<256;i++)values.set('nonce:'+i,Math.floor(Date.now()/1000)+300);
 assert.equal((await worker.fetch(await signed(),env)).status,429);
});

test('large allowed snapshot is stored in bounded chunks and read atomically',async()=>{
 const {env,signed,values}=await fixture();
 const sessions=Array.from({length:2000},(_,i)=>({id:'fixture-'+i,tool:'Codex',start:'2026-10-03T01:00:00Z',last_activity:null,end:null,project:'Fixture',title:'人工'.repeat(100)}));
 assert.equal((await worker.fetch(await signed({...empty,sessions}),env)).status,200);
 assert.ok(values.get('snapshot-chunks')>1);
 for(const [k,v] of values)if(k.startsWith('snapshot:'))assert.ok(new TextEncoder().encode(v).length<128*1024);
 const store=env.SYNC_STORE.get('owner');const res=await store.fetch('https://store.internal/');assert.equal((await res.json()).sessions.length,2000);
 assert.equal((await worker.fetch(await signed(),env)).status,200);assert.equal(values.has('snapshot:1'),false);
});
