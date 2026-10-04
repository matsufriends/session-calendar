import test from 'node:test';
import assert from 'node:assert/strict';
import worker,{validateSnapshot,writerAuthorized,viewerAuthorized} from '../cloud/worker.mjs';
const empty={sessions:[],timezone:'Asia/Tokyo'};
const record={id:'test-session',tool:'Claude',start:'2026-10-03T01:00:00Z',last_activity:null,end:null,project:'Example',title:'Example session'};
const req=(path,options={})=>new Request('https://example.test'+path,options);
test('snapshot allowlist rejects conversation, paths, invalid times, duplicates',()=>{
 assert.ok(validateSnapshot(empty));assert.ok(validateSnapshot({...empty,sessions:[record]}));
 for(const bad of [{...empty,body:'private'}, {...empty,sessions:[{...record,body:'private'}]}, {...empty,sessions:[{...record,project:'/Users/person/repo'}]}, {...empty,sessions:[{...record,start:'invalid'}]}, {...empty,sessions:[{...record,end:'2026-10-03T02:00:00Z'}]}, {...empty,sessions:[record,record]}]) assert.equal(validateSnapshot(bad),false);
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
