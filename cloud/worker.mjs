import { createRemoteJWKSet, jwtVerify } from 'jose';
const MAX_BYTES = 2 * 1024 * 1024;
const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
  'Content-Security-Policy': "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'none'; frame-ancestors 'none'" };
const reply = (body, status = 200) => Response.json(body, { status, headers });
const jwksCache = new Map();
export async function viewerAuthorized(request, env, verificationKey = null) {
  if (!env.ACCESS_TEAM_DOMAIN || !env.ACCESS_AUD || !env.VIEWER_EMAIL) return false;
  if (!/^[a-z0-9-]+\.cloudflareaccess\.com$/.test(env.ACCESS_TEAM_DOMAIN)) return false;
  const token = request.headers.get('Cf-Access-Jwt-Assertion');
  if (!token) return false;
  try {
    const issuer = `https://${env.ACCESS_TEAM_DOMAIN}`;
    if (!jwksCache.has(issuer)) jwksCache.set(issuer, createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`)));
    const { payload } = await jwtVerify(token, verificationKey || jwksCache.get(issuer), {
      issuer, audience: env.ACCESS_AUD, algorithms: ['RS256'], requiredClaims: ['exp', 'iat', 'email', 'sub'],
    });
    return typeof payload.email === 'string' && payload.email.toLowerCase() === env.VIEWER_EMAIL.toLowerCase();
  } catch { return false; }
}
const encoder = new TextEncoder();
const hex = bytes => [...new Uint8Array(bytes)].map(b=>b.toString(16).padStart(2,'0')).join('');
export async function writerAuthorized(request, env, bytes, now = Date.now()) {
  try {
    const url=new URL(request.url);
    if (request.method !== 'PUT' || url.pathname !== '/api/sync' || url.search || url.protocol!=='https:' || !env.SYNC_ORIGIN || url.origin !== env.SYNC_ORIGIN) return null;
    if (request.headers.has('Authorization')) return null;
    const stamp=request.headers.get('X-Sync-Timestamp'), nonce=request.headers.get('X-Sync-Nonce'), signature=request.headers.get('X-Sync-Signature');
    if (!/^\d{10}$/.test(stamp || '') || Math.abs(now/1000-Number(stamp))>300 || !/^[a-f0-9]{64}$/.test(nonce || '') || !/^[a-f0-9]{128}$/.test(signature || '')) return null;
    const raw=Uint8Array.from((env.SYNC_PUBLIC_KEY || '').match(/.{2}/g) || [], x=>parseInt(x,16));
    if (!/^[a-f0-9]{130}$/.test(env.SYNC_PUBLIC_KEY || '') || raw[0]!==4) return null;
    const key=await crypto.subtle.importKey('raw',raw,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
    const bodyHash=hex(await crypto.subtle.digest('SHA-256',bytes));
    const canonical=['SESSION-CALENDAR-V1','PUT',env.SYNC_ORIGIN,'/api/sync',stamp,nonce,bodyHash].join('\n');
    const sig=Uint8Array.from(signature.match(/.{2}/g),x=>parseInt(x,16));
    return await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,sig,encoder.encode(canonical)) ? {nonce,expires:Number(stamp)+300} : null;
  } catch { return null; }
}
// A single Durable Object atomically consumes nonces and stores the snapshot.
// KV eventual consistency is not used for replay protection.
export class SyncStore {
  constructor(state) { this.state=state; }
  async fetch(request) {
    if (request.method==='GET') return this.state.storage.transaction(async tx=> {
      const count=await tx.get('snapshot-chunks');
      if(!count)return reply({sessions:[],warnings:['まだ同期されていません'],timezone:'Asia/Tokyo',synced_at:null});
      const parts=[];for(let i=0;i<count;i++)parts.push(await tx.get('snapshot:'+i));
      return reply(JSON.parse(parts.join('')));
    });
    if (request.method!=='PUT') return reply({error:'method'},405);
    const {snapshot,nonce,expires}=await request.json();
    return this.state.storage.transaction(async tx=> {
      const now=Math.floor(Date.now()/1000);
      const used=await tx.list({prefix:'nonce:'});
      for(const [key,expiry] of used) if(expiry<now) await tx.delete(key);
      if (expires<now || await tx.get('nonce:'+nonce)) return reply({error:'replay'},409);
      if ([...used.values()].filter(expiry=>expiry>=now).length>=256) return reply({error:'rate limit'},429);
      await tx.put('nonce:'+nonce,expires);
      const serialized=JSON.stringify(snapshot),count=Math.ceil(serialized.length/32768);
      const oldCount=await tx.get('snapshot-chunks') || 0;
      for(let i=0;i<count;i++)await tx.put('snapshot:'+i,serialized.slice(i*32768,(i+1)*32768));
      for(let i=count;i<oldCount;i++)await tx.delete('snapshot:'+i);
      await tx.put('snapshot-chunks',count);
      return reply({ok:true,count:snapshot.sessions.length});
    });
  }
}
function plainObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function exact(value, keys) { return plainObject(value) && Object.keys(value).length === keys.length && keys.every(k=>Object.hasOwn(value,k)); }
function text(value, max) { return typeof value === 'string' && value.length > 0 && value.length <= max && !/[\u0000-\u001f]/.test(value); }
function timestamp(value) { return text(value,40) && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(value) && Number.isFinite(Date.parse(value)); }
export function validateSnapshot(data) {
  if (!exact(data,['sessions','timezone']) || data.timezone !== 'Asia/Tokyo' || !Array.isArray(data.sessions) || data.sessions.length > 20000) return false;
  const seen = new Set();
  return data.sessions.every(s=> {
    if (!exact(s,['id','tool','start','last_activity','end','project','title'])) return false;
    if (!text(s.id,100) || !['Codex','Claude'].includes(s.tool) || !timestamp(s.start) || !(s.last_activity===null || timestamp(s.last_activity)) || s.end!==null || !text(s.project,200) || /[\\/]/.test(s.project) || !text(s.title,300)) return false;
    const key=s.tool+':'+s.id;if(seen.has(key))return false;seen.add(key);return true;
  });
}
async function readLimited(request) {
  const reader=request.body?.getReader(); if(!reader)throw Error('empty');
  const chunks=[];let size=0;
  try { while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>MAX_BYTES)throw Error('large');chunks.push(value);} }
  finally { await reader.cancel(); }
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  return bytes;
}
export default {
  async fetch(request, env) {
    const url=new URL(request.url);
    if(url.pathname==='/api/sync') {
      if(request.method!=='PUT')return reply({error:'method'},405);
      if(!request.headers.get('Content-Type')?.startsWith('application/json'))return reply({error:'content type'},415);
      let bytes;try {bytes=await readLimited(request);}catch{return reply({error:'invalid or oversized payload'},400);}
      const auth=await writerAuthorized(request,env,bytes);if(!auth)return reply({error:'unauthorized'},401);
      let data;try {data=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{return reply({error:'invalid metadata'},400);}
      if(!validateSnapshot(data))return reply({error:'invalid metadata'},400);
      if(!env.SYNC_STORE)return reply({error:'storage unavailable'},503);
      const snapshot={...data,warnings:[],synced_at:new Date().toISOString()};
      return env.SYNC_STORE.get(env.SYNC_STORE.idFromName('owner')).fetch('https://store.internal/',{method:'PUT',body:JSON.stringify({snapshot,...auth})});
    }
    if(url.origin!==env.VIEWER_ORIGIN)return reply({error:'unauthorized'},401);
    if(!await viewerAuthorized(request,env))return reply({error:'unauthorized'},401);
    if(request.method!=='GET')return reply({error:'method'},405);
    if(url.pathname==='/api/sessions') {
      if(!env.SYNC_STORE)return reply({error:'storage unavailable'},503);
      return env.SYNC_STORE.get(env.SYNC_STORE.idFromName('owner')).fetch('https://store.internal/');
    }
    if(url.pathname!=='/')return reply({error:'not found'},404);
    if(!env.ASSETS)return reply({error:'assets unavailable'},503);
    const asset=await env.ASSETS.fetch(request);const response=new Response(asset.body,asset);
    for(const [k,v] of Object.entries(headers))response.headers.set(k,v);
    return response;
  }
};
