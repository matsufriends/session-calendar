import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
test('generated cloud HTML assigns and displays the API sync timestamp',()=>{
 execFileSync('python3',['scripts/build_cloud.py'],{cwd:root,stdio:'pipe'});
 const html=readFileSync(resolve(root,'cloud/public/index.html'),'utf8');
 assert.match(html,/syncedAt=data\.synced_at;/);
 assert.match(html,/syncedAt\?' · 同期 '\+dt\(syncedAt\):''/);
 assert.match(html,/sessions=rows\.filter\(s=>instant\(s\.start\)!==null\)/);
 assert.match(html,/daykey\(s\.start\)===d/);
});
