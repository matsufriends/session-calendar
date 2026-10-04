import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';
import {tmpdir} from 'node:os';

// Artificial inputs exercise the generated-HTML VM harness even on non-macOS.
// This does not replace the CI pipeline using actual Native fixture output.
test('title pipeline loads integrated CLI detail helpers for title-on and anonymous rows',()=>{
 const root=new URL('..',import.meta.url);
 const cases=JSON.parse(readFileSync(new URL('./fixtures/session-titles.json',import.meta.url),'utf8')).cases;
 const normalize=value=>{let text='',size=0;for(const {segment} of new Intl.Segmenter('en',{granularity:'grapheme'}).segment(value.replace(/[\u0000-\u001f]/g,' '))){if(size+segment.length>300)break;text+=segment;size+=segment.length}return text||'無題'};
 const sessions=cases.map(c=>({id:c.id,tool:c.tool,start:'2026-10-04T01:00:00Z',last_activity:null,end:null,project:'fixture',title:normalize(c.expected)}));
 const dir=mkdtempSync(join(tmpdir(),'session-calendar-title-harness-'));
 try {
  const path=join(dir,'artificial-title-snapshot.json');
  writeFileSync(path,JSON.stringify({sessions,timezone:'Asia/Tokyo'}));
  writeFileSync(path+'.anonymous',JSON.stringify({sessions:sessions.map(s=>({...s,title:`${s.tool} セッション ${s.id.slice(0,8)}`})),timezone:'Asia/Tokyo'}));
  execFileSync('python3',['scripts/build_cloud.py'],{cwd:root});
  const output=execFileSync(process.execPath,['scripts/check_title_pipeline.mjs',path],{cwd:root,encoding:'utf8'});
  assert.match(output,/title-on fixture titles preserved/);
  assert.match(output,/anonymous fixture titles preserved/);
 } finally { rmSync(dir,{recursive:true,force:true}); }
});
