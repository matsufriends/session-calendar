#!/usr/bin/env python3
"""Local, read-only session metadata calendar. Standard library only."""
import json, argparse, threading, time, re
from pathlib import Path
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=Path(__file__).parent
cache={'at':0,'data':None}
lock=threading.Lock()
def valid_timestamp(value):
    return isinstance(value,str) and len(value)<=40 and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})',value) is not None and _timestamp_parses(value)
def _timestamp_parses(value):
    try: datetime.fromisoformat(value.replace('Z','+00:00')); return True
    except ValueError: return False
def _safe_text(value, maximum):
    return isinstance(value,str) and 0<len(value)<=maximum and not any(ord(c)<32 or ord(c)==127 for c in value)
def adapt_dot_snapshot(data, occupied_ids=()):
    """Keep only official, user-visible task metadata from an explicitly imported snapshot."""
    if not isinstance(data,dict) or not isinstance(data.get('tasks'),list) or len(data['tasks'])>20000:
        raise ValueError('snapshot must contain a tasks array')
    observed=data.get('snapshot_observed_at')
    if observed is not None and not valid_timestamp(observed): raise ValueError('invalid snapshot_observed_at')
    occupied=set(occupied_ids); seen=set(); result=[]
    for task in data['tasks']:
        if not isinstance(task,dict): raise ValueError('invalid task record')
        task_id=task.get('id'); attached=task.get('attachedAt'); latest=task.get('latestTurn')
        if not _safe_text(task_id,128) or not re.fullmatch(r'[A-Za-z0-9._-]+',task_id): raise ValueError('invalid task id')
        if task_id in seen: raise ValueError('duplicate task id')
        if task_id in occupied: raise ValueError('task id collides with an existing CLI session')
        if not valid_timestamp(attached): raise ValueError('invalid attachedAt')
        if not isinstance(latest,dict) or not _safe_text(latest.get('status'),40) or not re.fullmatch(r'[A-Za-z0-9_-]+',latest['status']): raise ValueError('missing or invalid latestTurn.status')
        title=task.get('title')
        if title is None: title=f'ChatGPT タスク {task_id[-8:]}'
        if not _safe_text(title,300): raise ValueError('invalid title')
        project=task.get('project')
        if project is None: project='不明'
        if not _safe_text(project,500): raise ValueError('invalid project')
        # A supplied project may be a path-like value; only its display name is retained.
        project=project.replace('\\','/').rstrip('/').rsplit('/',1)[-1][:200] or '不明'
        seen.add(task_id)
        result.append({'id':task_id,'source':'dot-task','tool':'ChatGPT','task_registered_at':attached,
          'latest_turn_status':latest['status'],'snapshot_observed_at':observed,'project':project,'title':title})
    return result
def load_dot_snapshot(path, occupied_ids=()):
    """Read only the explicit local file path supplied at server startup; no HTTP path access."""
    raw=Path(path).read_text(encoding='utf-8')
    return adapt_dot_snapshot(json.loads(raw),occupied_ids)
def collect(dot_snapshot_path=None):
    sessions=[]; errors=[]; names={}
    index=Path.home()/'.codex/session_index.jsonl'
    try:
        if index.exists():
            for line in index.open():
                try:
                    r=json.loads(line); names[r.get('id')]=r
                except ValueError: pass
    except OSError: errors.append('Codexのタイトル索引を読み取れません')
    for tool,base in [('Codex',Path.home()/'.codex/sessions'),('Claude',Path.home()/'.claude/projects')]:
        try:
            for file in base.glob('**/*.jsonl'):
                if 'subagents' in file.parts: continue
                try:
                    sid=file.stem; start=None; last=None; project=''; title=''
                    with file.open() as stream:
                        if tool=='Codex':
                            r=json.loads(next(stream)); p=r.get('payload',{})
                            if r.get('type')!='session_meta': continue
                            sid=p.get('id') or p.get('session_id') or sid
                            start=p.get('timestamp') or r.get('timestamp'); project=p.get('cwd','')
                            n=names.get(sid,{}); title=n.get('thread_name',''); last=n.get('updated_at')
                        else:
                            for line in stream:
                                try:r=json.loads(line)
                                except ValueError:continue
                                if r.get('isSidechain'):continue
                                sid=r.get('sessionId',sid); project=r.get('cwd') or project
                                ts=r.get('timestamp')
                                if ts and r.get('type') in ('user','assistant'):
                                    start=min(start,ts) if start else ts; last=max(last,ts) if last else ts
                                if r.get('type')=='custom-title':title=r.get('customTitle','')
                    if start:
                        sessions.append({'id':sid,'tool':tool,'start':start,'last_activity':last,'end':None,'project':Path(project).name if project else '不明','title':title or f'{tool} セッション {sid[:8]}'})
                except (OSError,ValueError,StopIteration):errors.append(f'{tool}の一部の履歴を読み取れません')
        except OSError:errors.append(f'{tool}の履歴フォルダにアクセスできません')
    unique={(s['tool'],s['id']):s for s in sessions}
    dot_tasks=[]
    if dot_snapshot_path:
        try: dot_tasks=load_dot_snapshot(dot_snapshot_path,{s['id'] for s in unique.values()})
        except (OSError,UnicodeError,ValueError,json.JSONDecodeError): errors.append('dot-task snapshotを読み取れません（JSON・必須項目・ID重複を確認してください）')
    rows=list(unique.values())+dot_tasks
    return {'sessions':sorted(rows,key=lambda x:x.get('start') or x.get('task_registered_at',''),reverse=True),'warnings':list(set(errors)),'timezone':'Asia/Tokyo'}
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get('Host','') not in (f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}'):
            self.send_error(403);return
        if self.path in ('/api/sessions','/api/sessions?refresh=1'):
            with lock:
                if cache['data'] is None or time.time()-cache['at']>60 or '?' in self.path:
                    cache.update(data=collect(),at=time.time())
                body=json.dumps(cache['data'],ensure_ascii=False).encode(); mime='application/json'
        elif self.path=='/':body=(ROOT/'index.html').read_bytes();mime='text/html; charset=utf-8'
        else:self.send_error(404);return
        self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Cache-Control','no-store')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'none'; frame-ancestors 'none'")
        self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=8765);p.add_argument('--dot-snapshot',type=Path,help='公式dot cloud task metadata JSONのローカルファイルを明示指定（HTTPからは読めません）');args=p.parse_args()
    print(f'http://127.0.0.1:{args.port}',flush=True)
    original_collect=collect
    collect=lambda:original_collect(args.dot_snapshot)
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
