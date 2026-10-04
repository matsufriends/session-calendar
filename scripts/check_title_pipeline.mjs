// Run after SessionTitleTests exports TITLE_FIXTURE_SNAPSHOT (synthetic data only).
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import worker,{SyncStore,validateSnapshot} from '../cloud/worker.mjs';
const path=process.argv[2];
if(!path)throw Error('Usage: node scripts/check_title_pipeline.mjs /absolute/native-title-snapshot.json');
const cases=JSON.parse(await readFile(new URL('../tests/fixtures/session-titles.json',import.meta.url))).cases;
const html=await readFile(new URL('../cloud/public/index.html',import.meta.url),'utf8');
const definitions=['workTitle','node','detail'].map(name=>html.match(new RegExp('^function '+name+'\\(.*$','m'))[0]).join('\n');
class Element {
 constructor(tag){this.tag=tag;this.children=[];}
 append(...nodes){this.children.push(...nodes);}
 replaceChildren(...nodes){this.children=nodes;}
}
for(const anonymous of [false,true]) {
 const snapshot=JSON.parse(await readFile(path+(anonymous?'.anonymous':''),'utf8'));
 assert.ok(validateSnapshot(snapshot));
 const values=new Map(),storage={transaction:async fn=>fn({get:async key=>values.get(key),put:async(key,value)=>values.set(key,value),delete:async key=>values.delete(key),list:async({prefix})=>new Map([...values].filter(([key])=>key.startsWith(prefix)))})};
 const store=new SyncStore({storage});
 const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
 const origin='https://fixture.invalid',body=JSON.stringify(snapshot),stamp=String(Math.floor(Date.now()/1000)),nonce=Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('hex');
 const hash=Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(body))).toString('hex');
 const canonical=['SESSION-CALENDAR-V1','PUT',origin,'/api/sync',stamp,nonce,hash].join('\n');
 const signature=Buffer.from(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},pair.privateKey,new TextEncoder().encode(canonical))).toString('hex');
 const env={SYNC_ORIGIN:origin,SYNC_PUBLIC_KEY:Buffer.from(await crypto.subtle.exportKey('raw',pair.publicKey)).toString('hex'),SYNC_STORE:{idFromName:()=> 'fixture',get:()=>({fetch:(input,init)=>store.fetch(new Request(input,init))})}};
 const response=await worker.fetch(new Request(origin+'/api/sync',{method:'PUT',headers:{'Content-Type':'application/json','X-Sync-Timestamp':stamp,'X-Sync-Nonce':nonce,'X-Sync-Signature':signature},body}),env);
 assert.equal(response.status,200);
 const received=await (await store.fetch(new Request('https://store.internal/'))).json();
 assert.deepEqual(received.sessions,snapshot.sessions);
 for(const row of received.sessions) {
  const item=cases.find(c=>c.id===row.id);
  assert.equal(row.title,anonymous?`${row.tool} セッション ${row.id.slice(0,8)}`:item.expected.replace(/[\u0000-\u001f]/g,' '));
  const heading=anonymous?'作業名未受信':row.title,detail=new Element('aside');
  const context={document:{createElement:tag=>new Element(tag)},$:()=>detail,dt:()=> 'fixture time',row};
  runInNewContext(definitions+';detail(row)',context);
  assert.equal(detail.children[0].tag,'h2');assert.equal(detail.children[0].textContent,heading);
  assert.equal(runInNewContext(definitions+';node("strong",workTitle(row)).textContent',context),heading);
 }
 assert.ok(!JSON.stringify(received).includes('Body must remain local'));
 await writeFile(path+(anonymous?'.anonymous.worker':'.worker'),JSON.stringify(received,null,2)+'\n');
 console.log(`Native → signed Worker → generated HTML: ${received.sessions.length} ${anonymous?'anonymous':'title-on'} fixture titles preserved; no message body`);
}
