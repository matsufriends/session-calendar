#!/usr/bin/env python3
"""Local, read-only session metadata calendar. Standard library only."""
import json, argparse, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from codex_source import collect_codex, merge_codex, SourceError, SCOPE
ROOT=Path(__file__).parent
cache={'at':0,'data':None}
lock=threading.Lock()
def collect():
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
    try:
        sessions=merge_codex(sessions,collect_codex())
        codex_scope=SCOPE
    except SourceError as error:
        errors.append(f'Codex app-server取得失敗（{error}）。JSONLにfallback')
        codex_scope='Codex: JSONL先頭metadataとタイトル索引のみ（archive対象外）'
    unique={(s['tool'],s['id']):s for s in sessions}
    return {'sessions':sorted(unique.values(),key=lambda x:x['start'],reverse=True),'warnings':list(set(errors)),'timezone':'Asia/Tokyo','source_scope':codex_scope}
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
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=8765);args=p.parse_args()
    print(f'http://127.0.0.1:{args.port}',flush=True)
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
