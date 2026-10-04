import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
const source=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const definition=name=>source.match(new RegExp('^function '+name+'\\(.*$','m'))[0];
test('current-time marker uses JST midnight and late-day boundaries',()=>{
 const position=t=>runInNewContext(['instant','daykey','timePosition'].map(definition).join('\n')+';timePosition(value)',{Intl,Date,value:t});
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
 const layout=runInNewContext(['instant','sessionEnd','sessionExtent','sessionSegment','layoutSessionItems'].map(definition).join('\n')+';layoutSessionItems(items)',{
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

const geometry=(s,d='2026-10-04')=>runInNewContext(['instant','daykey','timePosition','sessionEnd','sessionExtent','sessionSegment'].map(definition).join('\n')+';({segment:sessionSegment(s,d),position:timePosition(s.start)})',{Intl,Date,s,d});
test('seconds and offsets preserve exact positions and short durations',()=>{
 const a=geometry({start:'2026-10-04T10:00:30+09:00',end:'2026-10-04T10:01:00+09:00'});
 assert.equal(a.position,64+(10+30/3600)*64);
 assert.equal((a.segment.end-a.segment.start)/3600000*64,64/120);
 assert.deepEqual(JSON.parse(JSON.stringify(a)),JSON.parse(JSON.stringify(geometry({start:'2026-10-04T01:00:30Z',end:'2026-10-04T01:01:00Z'}))));
});
test('cross-midnight intervals clip precisely, excluding the end-only day',()=>{
 const s={start:'2026-10-03T14:59:30Z',end:'2026-10-03T15:00:30Z'};
 assert.equal((geometry(s,'2026-10-03').segment.end-geometry(s,'2026-10-03').segment.start)/1000,30);
 assert.equal((geometry(s).segment.end-geometry(s).segment.start)/1000,30);
 assert.equal(geometry({...s,end:'2026-10-03T15:00:00Z'}).segment,null);
});
test('unknown, invalid, reversed ends show only an explicitly labelled observed interval',()=>{
 for(const end of [null,undefined,'bad','2026-10-04T00:00:00Z']){
  const a=geometry({start:'2026-10-04T01:00:00Z',end,last_activity:'2026-10-04T05:00:00Z'}).segment;
  assert.equal(a.end,Date.parse('2026-10-04T05:00:00Z'));assert.equal(a.known,true);
 }
 assert.equal(geometry({start:'bad',end:null}).segment,null);
 assert.equal(geometry({start:'2026-10-04T01:00:00Z',end:'2026-10-04T01:00:00Z'}).segment.known,true);
});
test('long overlaps remain separate after 45 minutes and labels do not inflate bars',()=>{
 const items=[{tool:'Codex',id:'a',start:'2026-10-04T01:00:00Z',end:'2026-10-04T03:00:00Z'},{tool:'Claude',id:'a',start:'2026-10-04T02:00:00Z',end:'2026-10-04T02:01:00Z'},{tool:'Codex',id:'b',start:'2026-10-04T03:00:00Z',end:null}];
 const a=runInNewContext(['instant','sessionEnd','sessionExtent','sessionSegment','layoutSessionItems'].map(definition).join('\n')+';layoutSessionItems(items,"2026-10-04")',{Date,items});
 assert.equal(a.layouts.get('Codex:a'),0);assert.equal(a.layouts.get('Claude:a'),1);assert.equal(a.layouts.get('Codex:b'),0);
 assert.doesNotMatch(source,/laneEnds\[lane\]=m\+45|laneCount>3/);
});

test('unknown last activity and reversed last activity remain start points',()=>{
 for(const last_activity of [null,'bad','2026-10-04T00:00:00Z']){
  const a=geometry({start:'2026-10-04T01:00:00Z',end:null,last_activity}).segment;
  assert.equal(a.start,a.end);assert.equal(a.known,false);
 }
});

test('clamped labels at the end of day reserve separate lanes',()=>{
 const items=[{tool:'Codex',id:'a',start:'2026-10-04T23:00:00+09:00'}, {tool:'Codex',id:'b',start:'2026-10-04T23:45:00+09:00'}];
 const a=runInNewContext(['instant','sessionEnd','sessionExtent','sessionSegment','layoutSessionItems'].map(definition).join('\n')+';layoutSessionItems(items,"2026-10-04")',{Date,items});
 assert.equal(a.laneCount,2);
});

test('eight dense lanes keep exact short bars and isolated start positions',()=>{
 const items=Array.from({length:8},(_,i)=>({tool:'Codex',id:'dense-'+i,start:'2026-10-04T01:00:30Z',last_activity:'2026-10-04T01:01:00Z'}));
 const a=runInNewContext(['instant','sessionEnd','sessionExtent','sessionSegment','layoutSessionItems'].map(definition).join('\n')+';layoutSessionItems(items,"2026-10-04")',{Date,items});
 assert.equal(a.laneCount,8);
 for(const s of items)assert.equal((geometry(s).segment.end-geometry(s).segment.start)/3600000*64,64/120);
 assert.equal(geometry({start:'2026-10-04T14:37:15+09:00'}).position,64+(14+37/60+15/3600)*64);
});
