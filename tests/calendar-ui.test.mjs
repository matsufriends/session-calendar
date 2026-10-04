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
