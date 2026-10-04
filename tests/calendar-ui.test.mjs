import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';

const source=readFileSync(new URL('../index.html',import.meta.url),'utf8');
const helpers=source.match(/^const HOUR=.*$/m)[0]+'\n'+['instant','dayKey','midnight','addDays','lastOf','endOf','workTitle','segments','layout'].map(name=>source.match(new RegExp('^function '+name+'\\(.*$','m'))[0]).join('\n');
const ui=runInNewContext(helpers+';({dayKey,addDays,endOf,workTitle,segments,layout})',{Intl,Date,document:{getElementById:()=>null}});
const at=t=>Date.parse(t);
const row=(id,start,last,extra={})=>({id,tool:'Codex',title:id,project:'p',start,last_activity:last,end:null,...extra});

test('days are JST dates and step across month ends',()=>{
 assert.equal(ui.dayKey(at('2026-10-04T15:30:00Z')),'2026-10-05');
 assert.equal(ui.addDays('2026-09-30',1),'2026-10-01');
 assert.equal(ui.addDays('2026-10-01',-7),'2026-09-24');
});

test('sessions without an end are shown up to the last record, capped at two hours',()=>{
 assert.equal(ui.endOf(row('a','2026-10-04T10:00:00+09:00','2026-10-04T10:30:00+09:00')),at('2026-10-04T10:30:00+09:00'));
 assert.equal(ui.endOf(row('b','2026-10-04T10:00:00+09:00','2026-10-06T10:00:00+09:00')),at('2026-10-04T12:00:00+09:00'));
 assert.equal(ui.endOf(row('c','2026-10-04T10:00:00+09:00',null)),at('2026-10-04T10:00:00+09:00'));
});

test('segments clip at midnight and keep a minimum visible height',()=>{
 const late=row('late','2026-10-04T23:30:00+09:00','2026-10-05T00:30:00+09:00');
 const [first]=ui.segments([late],'2026-10-04'),[second]=ui.segments([late],'2026-10-05');
 assert.equal(first.bottom,at('2026-10-05T00:00:00+09:00'));
 assert.equal(second.top,at('2026-10-05T00:00:00+09:00'));
 const [point]=ui.segments([row('p','2026-10-04T09:00:00+09:00',null)],'2026-10-04');
 assert.equal(point.bottom-point.top,20*60000);
 assert.equal(ui.segments([late],'2026-10-06').length,0);
});

test('overlapping sessions split the column and separate groups reset',()=>{
 const segs=ui.layout(ui.segments([
  row('a','2026-10-04T09:00:00+09:00','2026-10-04T10:00:00+09:00'),
  row('b','2026-10-04T09:30:00+09:00','2026-10-04T10:30:00+09:00'),
  row('c','2026-10-04T10:15:00+09:00','2026-10-04T10:45:00+09:00'),
  row('d','2026-10-04T12:00:00+09:00','2026-10-04T13:00:00+09:00'),
 ],'2026-10-04'));
 const by=Object.fromEntries(segs.map(g=>[g.s.id,g]));
 assert.deepEqual([by.a.col,by.b.col,by.c.col],[0,1,0]);
 assert.equal(by.a.cols,2);
 assert.deepEqual([by.d.col,by.d.cols],[0,1]);
});

test('anonymous or empty titles get a neutral heading',()=>{
 assert.equal(ui.workTitle({tool:'Codex',id:'abcdefgh1234',title:'Codex セッション abcdefgh'}),'作業名なし');
 assert.equal(ui.workTitle({tool:'Codex',id:'x',title:' '}),'作業名なし');
 assert.equal(ui.workTitle({tool:'Codex',id:'x',title:'実装'}),'実装');
});
