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
export async function writerAuthorized(request, env) {
  if (typeof env.SYNC_TOKEN !== 'string' || env.SYNC_TOKEN.length < 32) return false;
  const supplied = request.headers.get('Authorization');
  if (!supplied?.startsWith('Bearer ') || supplied.length > 1024) return false;
  const hash = async value => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
  const [a,b] = await Promise.all([hash(supplied.slice(7)), hash(env.SYNC_TOKEN)]);
  let diff = 0; for (let i=0;i<a.length;i++) diff |= a[i]^b[i];
  return diff === 0;
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
  return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}
export default {
  async fetch(request, env) {
    const url=new URL(request.url);
    if(url.pathname==='/api/sync') {
      if(request.method!=='PUT')return reply({error:'method'},405);
      if(!await writerAuthorized(request,env))return reply({error:'unauthorized'},401);
      if(!env.SESSIONS)return reply({error:'storage unavailable'},503);
      if(!request.headers.get('Content-Type')?.startsWith('application/json'))return reply({error:'content type'},415);
      let data;try {data=await readLimited(request);}catch{return reply({error:'invalid or oversized payload'},400);}
      if(!validateSnapshot(data))return reply({error:'invalid metadata'},400);
      const snapshot={...data,warnings:[],synced_at:new Date().toISOString()};
      await env.SESSIONS.put('snapshot',JSON.stringify(snapshot));
      return reply({ok:true,count:data.sessions.length});
    }
    if(!await viewerAuthorized(request,env))return reply({error:'unauthorized'},401);
    if(request.method!=='GET')return reply({error:'method'},405);
    if(url.pathname==='/api/sessions') {
      if(!env.SESSIONS)return reply({error:'storage unavailable'},503);
      const data=await env.SESSIONS.get('snapshot','json');
      return reply(data || {sessions:[],warnings:['まだ同期されていません'],timezone:'Asia/Tokyo',synced_at:null});
    }
    if(url.pathname!=='/')return reply({error:'not found'},404);
    if(!env.ASSETS)return reply({error:'assets unavailable'},503);
    const asset=await env.ASSETS.fetch(request);const response=new Response(asset.body,asset);
    for(const [k,v] of Object.entries(headers))response.headers.set(k,v);
    return response;
  }
};
