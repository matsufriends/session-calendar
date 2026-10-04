import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
test('generated cloud HTML preserves task markers, dates and sync timestamp',()=>{
 execFileSync('python3',['scripts/build_cloud.py'],{cwd:root,stdio:'pipe'});
 const html=readFileSync(resolve(root,'cloud/public/index.html'),'utf8');
 assert.match(html,/syncedAt=data\.synced_at\|\|null;/);
 assert.match(html,/const sync=syncedAt\?' · 同期観測 '\+dt\(syncedAt\):''/);
 assert.match(html,/sessions=rows\.filter\(s=>instant\(eventAt\(s\)\)!==null\)/);
 assert.match(html,/daykey\(eventAt\(s\)\)===d/);
 assert.match(html,/task_registered_at/);
 assert.match(html,/codex:\/\/threads\//);
});
