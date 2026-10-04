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
