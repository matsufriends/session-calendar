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
 const label=rows=>runInNewContext(definition('anonymousTitle')+'\n'+definition('privacyLabel')+';privacyLabel()',{sessions:rows});
 assert.match(label([]),/同期データなし/);
 assert.match(label([{id:'fixture-1',tool:'Codex',title:'Codex セッション fixture-'}]),/匿名タイトル形式/);
 assert.match(label([{id:'fixture-1',tool:'Codex',title:'Fixture task'}]),/タイトルを含む/);
});
test('dot-task anonymous fallback is recognized as anonymous',()=>{
 const anonymous=definition('anonymousTitle')+'\n'+definition('privacyLabel')+';({anonymousTitle,privacyLabel})';
 const {anonymousTitle,privacyLabel}=runInNewContext(anonymous,{sessions:[{id:'fixture-task-1',source:'dot-task',tool:'ChatGPT',title:'ChatGPT タスク e-task-1'}]});
 const task={id:'fixture-task-1',source:'dot-task',tool:'ChatGPT',title:'ChatGPT タスク e-task-1'};
 assert.equal(anonymousTitle(task),true);
 assert.match(privacyLabel(),/匿名タイトル形式/);
});
test('dot task UI uses registration markers, snapshot freshness and a distinct task link',()=>{
 const helpers=definition('eventAt')+'\n'+definition('statusLabel')+';({eventAt,statusLabel})';
 const {eventAt,statusLabel}=runInNewContext(helpers,{});
 const task={source:'dot-task',task_registered_at:'2026-10-03T01:00:00Z',latest_turn_status:'completed'};
 assert.equal(eventAt(task),task.task_registered_at);
 assert.match(statusLabel(task),/直近の実行は終了/);
 assert.match(statusLabel(task),/タスク全体の完了ではありません/);
 assert.match(source,/登録日時から実行開始・終了・所要時間を推定していません/);
 assert.match(source,/snapshotのため、現在の状態と異なる可能性があります/);
 assert.match(source,/codex:\/\/threads\//);
 assert.match(source,/s\.source==='dot-task'\?'dot-task'/);
});
test('official inProgress label describes only the observed latest turn',()=>{
 const helpers=definition('statusLabel')+';statusLabel(task)';
 const label=runInNewContext(helpers,{task:{source:'dot-task',latest_turn_status:'inProgress'}});
 assert.equal(label,'直近turnが実行中');
 assert.doesNotMatch(label,/タスク全体の完了|所要時間|開始|終了/);
});
test('dot-task markers do not occupy CLI duration lanes',()=>{
 const layouts=runInNewContext(['instant','sessionEnd','sessionExtent','sessionSegment','eventAt','layoutSessionItems'].map(definition).join('\n')+'\n'+definition('eventLayouts')+';eventLayouts(items)',{Date,Intl,items:[
  {id:'cli-a',source:'cli',tool:'Codex',start:'2026-10-03T01:00:00Z'},
  {id:'task-a',source:'dot-task',task_registered_at:'2026-10-03T01:00:00Z'},
  {id:'cli-b',source:'cli',tool:'Codex',start:'2026-10-03T01:05:00Z'},
  {id:'task-b',source:'dot-task',task_registered_at:'2026-10-03T01:00:00Z'}
 ]});
 assert.equal(layouts.laneCount,2);
 assert.equal(layouts.layouts.get('Codex:cli-a'),0);
 assert.equal(layouts.layouts.get('Codex:cli-b'),1);
 assert.equal(layouts.layouts.get('task:task-a').task,true);
 assert.equal(layouts.layouts.get('task:task-a').lane,0);
 assert.equal(layouts.layouts.get('task:task-b').lane,1);
 const apply=runInNewContext(['instant','daykey','timePosition','eventAt','applyEventLayout'].map(definition).join('\n')+';applyEventLayout',{Date,Intl});
 const marker={style:{},classList:{add(value){this.value=value}}};
 apply(marker,{id:'task',source:'dot-task',task_registered_at:'2026-10-03T01:00:00Z'},{task:true,lane:0},2);
 assert.equal(marker.style.width,'12px');
 assert.equal(marker.style.height,'12px');
 assert.equal(marker.style.left,'8px');
 assert.equal(marker.classList.value,'task-marker');
 assert.match(source,/layouts\.set\(s\.tool\+':'\+s\.id,lane\)/);
 assert.match(source,/height:12px!important;min-height:12px!important;max-height:12px!important/);
});
test('dot-task list cards keep readable flow layout across mode changes',()=>{
 const apply=runInNewContext(['instant','daykey','timePosition','eventAt','applyEventLayout'].map(definition).join('\n')+';applyEventLayout',{Date,Intl});
 const task={id:'fixture-task-1234',source:'dot-task',task_registered_at:'2026-10-04T11:15:00Z'};
 const listCard={style:{},classList:{values:[],add(value){this.values.push(value)}}};
 apply(listCard,task,{task:true,lane:0},1,'list');
 assert.deepEqual(listCard.classList.values,['task-card']);
 assert.equal(listCard.style.width,undefined);
 assert.equal(listCard.style.height,undefined);
 assert.equal(listCard.style.top,undefined);
 const weekMarker={style:{},classList:{values:[],add(value){this.values.push(value)}}};
 apply(weekMarker,task,{task:true,lane:0},1,'week');
 assert.deepEqual(weekMarker.classList.values,['task-marker']);
 assert.equal(weekMarker.style.width,'12px');
 assert.equal(weekMarker.style.height,'12px');
 assert.match(source,/applyEventLayout\(e,s,[^;]+laneCount,list\?'list':mode\)/);
 assert.match(source,/\.list \.event\.dot-task\.task-card\{height:auto;min-height:0;max-height:none/);
});
test('overlapping layouts identify records by the source tool and id contract',()=>{
 const layout=runInNewContext(['instant','sessionEnd','sessionExtent','sessionSegment','layoutSessionItems'].map(definition).join('\n')+';layoutSessionItems(items)',{
  Date,
  items:[
   {id:'shared',tool:'Codex',start:'2026-10-04T01:00:00Z',source:'codex-cli'},
   {id:'shared',tool:'Claude',start:'2026-10-04T01:00:00Z',source:'claude-code'},
   {id:'codex-regular',tool:'Codex',start:'2026-10-04T01:00:00Z',source:'codex-cli'},
  ]
 });
 assert.equal(layout.laneCount,3);
 assert.equal(layout.layouts.get('Codex:shared'),0);
 assert.equal(layout.layouts.get('Claude:shared'),1);
 assert.equal(layout.layouts.get('Codex:codex-regular'),2);
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
test('headings show work names and tools stay in the existing small label',()=>{
 const title=row=>runInNewContext(definition('workTitle')+';workTitle(row)',{row});
 assert.equal(title({title:'検索を改善',tool:'Claude',id:'fixture-1'}),'検索を改善');
 assert.equal(title({title:'Claude セッション fixture-',tool:'Claude',id:'fixture-1'}),'作業名未受信');
 assert.equal(title({title:'作業名不明',tool:'Codex',id:'fixture-2'}),'作業名不明');
 assert.equal(title({title:' ',tool:'Codex',id:'fixture-2'}),'作業名未受信');
 assert.equal(title({title:'ChatGPT タスク e-task-1',source:'dot-task',tool:'ChatGPT',id:'fixture-task-1'}),'作業名未受信');
 assert.match(source,/label.append\(node\('strong',workTitle\(s\)\),node\('small',toolLabel\(s\)/);
 assert.match(source,/node\('h2',workTitle\(s\)\)/);
});

test('dot marker hit areas reserve lanes for seconds and equivalent offset timestamps',()=>{
 const tasks=[
  {id:'a',source:'dot-task',task_registered_at:'2026-10-04T10:00:00+09:00'},
  {id:'b',source:'dot-task',task_registered_at:'2026-10-04T10:00:30+09:00'},
  {id:'c',source:'dot-task',task_registered_at:'2026-10-04T01:00:00Z'},
  {id:'d',source:'dot-task',task_registered_at:'2026-10-04T10:11:15+09:00'}
 ];
 const helpers=['instant','daykey','timePosition','sessionEnd','sessionExtent','sessionSegment','eventAt','layoutSessionItems','eventLayouts','applyEventLayout'].map(definition).join('\n');
 const ui=runInNewContext(helpers+';({eventLayouts,applyEventLayout})',{Intl,Date});
 const layout=ui.eventLayouts(tasks);
 assert.equal(layout.laneCount,0);
 assert.equal(layout.layouts.get('task:a').lane,0);
 assert.equal(layout.layouts.get('task:c').lane,1);
 assert.equal(layout.layouts.get('task:b').lane,2);
 assert.equal(layout.layouts.get('task:d').lane,0);
 const markers=tasks.map(task=>{const e={style:{},classList:{add(){}}};ui.applyEventLayout(e,task,layout.layouts.get('task:'+task.id),0,'week');return e.style});
 assert.equal(markers[0].top,markers[2].top);
 assert.ok(Math.abs(parseFloat(markers[1].top)-parseFloat(markers[0].top)-64/120)<1e-9);
 for(let i=0;i<3;i++)for(let j=i+1;j<3;j++)assert.ok(Math.abs(parseFloat(markers[i].left)-parseFloat(markers[j].left))>=12);
 assert.ok(markers.every(e=>e.width==='12px'&&e.height==='12px'));
 assert.match(source,/task-marker strong\{pointer-events:none;/);
});

test('CLI detail retains temporary app-server notLoaded warning',()=>{
 assert.match(definition('detail'),/notLoadedは一時app-serverで未読込の状態で、完了を示しません/);
 assert.match(definition('detail'),/取得元/);
 assert.match(definition('detail'),/現在の状態/);
 assert.match(definition('detail'),/archive/);
});

test('dense task marker groups preserve all registered tasks without vertical offsets',()=>{
 const rows=Array.from({length:10},(_,i)=>({id:'task-'+i,source:'dot-task',task_registered_at:'2026-10-04T10:00:00+09:00'}));
 const groups=runInNewContext(['instant','eventAt','taskMarkerGroups'].map(definition).join('\n')+';taskMarkerGroups(rows,6)',{rows,Date});
 assert.equal(groups.size,10);
 assert.equal(groups.get('task-0').length,10);
 assert.equal(new Set(groups.get('task-0').map(t=>t.id)).size,10);
 assert.match(definition('taskGroupDetail'),/for\(const task of tasks\)/);
 assert.match(source,/taskGroups=list\?new Map\(\)/);
 assert.match(source,/group\?\{task:true,lane:0\}/);
});

test('one width observer coalesces marker resize renders and ignores height-only notifications',()=>{
 const code=source.match(/^let markerViewportWidth=.*\nconst markerResizeObserver=.*$/m)[0];
 const day={clientWidth:200},frames=[];let callback,observations=0,renders=0,observers=0;
 class ResizeObserver {constructor(fn){callback=fn;observers++}observe(value){assert.equal(value,day);observations++}}
 runInNewContext(code,{$:()=>day,ResizeObserver,requestAnimationFrame:fn=>{frames.push(fn);return frames.length},render:()=>{renders++}});
 callback();assert.equal(frames.length,0);
 day.clientWidth=107;callback();day.clientWidth=106;callback();assert.equal(frames.length,1);
 frames.shift()();assert.equal(renders,1);callback();assert.equal(frames.length,0);
 day.clientWidth=200;callback();frames.shift()();assert.equal(renders,2);
 assert.equal(observers,1);assert.equal(observations,1);
});

test('day navigation advances one JST date while week/list advance seven',()=>{
 const step=view=>runInNewContext(definition('navigationStep')+';navigationStep()',{$:()=>({value:view})});
 for(const view of ['day','day-time'])assert.equal(step(view),1);
 for(const view of ['week','list'])assert.equal(step(view),7);
 assert.match(source,/\$\('view'\)\.value='day'/);
});
test('mobile marker touch reservations group dense records without altering registration geometry',()=>{
 const rows=[0,30,1200].map((second,i)=>({id:'touch-'+i,source:'dot-task',task_registered_at:new Date(Date.parse('2026-10-04T01:00:00Z')+second*1000).toISOString()}));
 const helpers=['instant','eventAt','taskMarkerGroups','sessionEnd','sessionExtent','sessionSegment','layoutSessionItems','eventLayouts'].map(definition).join('\n');
 const {groups,layouts}=runInNewContext(helpers+';({groups:taskMarkerGroups(rows,1,44),layouts:eventLayouts(rows,undefined,44).layouts})',{rows,Date});
 assert.equal(groups.get('touch-0').length,3);
 assert.equal(layouts.get('task:touch-0').lane,0);
 assert.equal(layouts.get('task:touch-1').lane,1);
 assert.equal(layouts.get('task:touch-2').lane,2);
 assert.equal(layouts.get('task:touch-0').hitSize,44);
 assert.equal(rows[0].task_registered_at,'2026-10-04T01:00:00.000Z');
});

 test('display states distinguish observed intervals, start points, and task registration without inventing completion',()=>{
 const helpers=['instant','sessionEnd','sessionExtent','statusLabel','recordState','toolLabel'].map(definition).join('\n');
 const ui=runInNewContext(helpers+';({recordState,toolLabel})',{Date});
 assert.equal(ui.recordState({start:'2026-10-04T01:00:00Z'}),'終了不明 · 開始記録のみ');
 assert.equal(ui.recordState({start:'2026-10-04T01:00:00Z',last_activity:'2026-10-04T12:00:00Z'}),'終了不明 · 観測区間');
 assert.equal(ui.recordState({start:'2026-10-04T01:00:00Z',end:'2026-10-04T01:00:30Z'}),'終了日時あり');
 assert.equal(ui.recordState({source:'dot-task',latest_turn_status:'inProgress'}),'取込時点：直近の実行が進行中');
 assert.match(ui.recordState({source:'dot-task',latest_turn_status:'completed'}),/タスク全体の完了ではありません/);
 assert.equal(ui.toolLabel({tool:'Codex'}),'Codex · AI作業');
 assert.equal(ui.toolLabel({tool:'Claude'}),'Claude Code · AI作業');
 assert.equal(ui.toolLabel({source:'dot-task'}),'ChatGPT · タスク登録');
 assert.doesNotMatch(source,/dashed|dotted/);
 assert.match(source,/time-bar.observed\{opacity:\.35\}/);
 });
