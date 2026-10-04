import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
const source=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const definition=name=>source.match(new RegExp('^function '+name+'\\(.*$','m'))[0];
test('current-time marker uses JST midnight and late-day boundaries',()=>{
 const position=t=>runInNewContext(definition('timePosition')+';timePosition(value)',{Intl,Date,value:t});
 assert.equal(position('2026-10-03T15:00:00Z'),64);
 assert.equal(position('2026-10-04T01:30:00Z'),736);
 assert.equal(position('2026-10-04T14:59:00Z'),64+(23+59/60)*64);
});
test('privacy badge distinguishes anonymous format, explicit titles and no received data',()=>{
 const label=rows=>runInNewContext(definition('privacyLabel')+';privacyLabel()',{sessions:rows});
 assert.match(label([]),/同期データなし/);
 assert.match(label([{id:'fixture-1',tool:'Codex',title:'Codex セッション fixture-'}]),/匿名タイトル形式/);
 assert.match(label([{id:'fixture-1',tool:'Codex',title:'Fixture task'}]),/タイトルを含む/);
});
test('overlapping layouts identify records by the source tool and id contract',()=>{
 const layout=runInNewContext(definition('layoutSessionItems')+';layoutSessionItems(items)',{
  Date,
  items:[
   {id:'shared',tool:'Codex',start:'2026-10-04T01:00:00Z',source:'codex-cli'},
   {id:'shared',tool:'Claude',start:'2026-10-04T01:00:00Z',source:'claude-code'},
   {id:'codex-regular',tool:'Codex',start:'2026-10-04T01:00:00Z',source:'codex-cli'},
   {id:'shared',tool:'ChatGPT',start:'2026-10-04T01:00:00Z',source:'dot-task'},
  ]
 });
 assert.equal(layout.laneCount,4);
 assert.equal(layout.layouts.get('Codex:shared'),0);
 assert.equal(layout.layouts.get('Claude:shared'),1);
 assert.equal(layout.layouts.get('Codex:codex-regular'),2);
 assert.equal(layout.layouts.get('ChatGPT:shared'),3);
});
test('date helpers treat offset timestamps as instants and leave invalid dates unknown',()=>{
 const run=(name,value)=>runInNewContext(definition('instant')+'\n'+definition(name)+`;${name}(value)`,{Intl,Date,value});
 assert.equal(run('daykey','2026-10-04T23:00:00+09:00'),'2026-10-04');
 assert.equal(run('daykey','2026-10-04T15:30:00Z'),'2026-10-05');
 assert.equal(run('daykey',new Date('2026-10-04T15:30:00Z')),'2026-10-05');
 assert.equal(run('daykey','not-a-datetime'),null);
 assert.equal(run('daykey','2026-10-04T15:30:00'),null);
 assert.equal(run('daykey','2026-02-30T15:00:00Z'),null);
 assert.equal(run('daykey','2026-10-04T24:00:00Z'),'2026-10-05');
 assert.equal(run('daykey','2026-10-04T24:00:01Z'),null);
 assert.equal(run('daykey','2026-10-04T24:01:00Z'),null);
 assert.equal(run('dt','not-a-datetime'),'不明');
 assert.match(runInNewContext(definition('instant')+'\n'+definition('daykey')+'\n'+definition('today')+';today()',{Intl,Date}),/^\d{4}-\d{2}-\d{2}$/);
});
test('headings show work names and tools stay in the existing small label',()=>{
 const title=row=>runInNewContext(definition('workTitle')+';workTitle(row)',{row});
 assert.equal(title({title:'検索を改善',tool:'Claude',id:'fixture-1'}),'検索を改善');
 assert.equal(title({title:'Claude セッション fixture-',tool:'Claude',id:'fixture-1'}),'作業名未受信');
 assert.equal(title({title:'作業名不明',tool:'Codex',id:'fixture-2'}),'作業名不明');
 assert.equal(title({title:' ',tool:'Codex',id:'fixture-2'}),'作業名未受信');
 assert.match(source,/node\('small',`\$\{dt\(s.start\).slice\(-5\)\} · \$\{s.tool\}`\),node\('strong',workTitle\(s\)\)/);
 assert.match(source,/node\('h2',workTitle\(s\)\)/);
});
