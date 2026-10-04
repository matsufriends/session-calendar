#!/usr/bin/env python3
"""Local, read-only session metadata calendar. Standard library only."""
import json, argparse, threading, time, re
from datetime import datetime, timedelta
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT=Path(__file__).parent
cache={'at':0,'data':None}
lock=threading.Lock()
def parse_instant(value):
    """Parse an ISO-8601 timestamp only when it identifies an absolute instant."""
    if not isinstance(value,str) or not value: return None
    try:
        match=re.fullmatch(r'(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::(\d{2})(\.(\d+))?)?(Z|[+-]\d{2}:?\d{2})',value,re.I)
        if not match: return None
        date,hour,minute,second,fraction,frac_digits,zone=match.groups()
        hour=int(hour); minute=int(minute); second=int(second or 0)
        if hour==24:
            if minute or second or (frac_digits and int(frac_digits) != 0): return None
            date=(datetime.fromisoformat(date)+timedelta(days=1)).date().isoformat()
            hour=0
            value=f'{date}T00:{match.group(3)}:{second:02d}{fraction or ""}{zone}'
        elif hour>23: return None
        if minute>59 or second>59: return None
        parsed=datetime.fromisoformat(value[:-1]+'+00:00' if value.endswith(('Z','z')) else value)
        return parsed if parsed.tzinfo is not None and parsed.utcoffset() is not None else None
    except (ValueError,OverflowError): return None
def collect(home=None):
    home=Path.home() if home is None else Path(home)
    sessions=[]; errors=[]; names={}
    index=home/'.codex/session_index.jsonl'
    try:
        if index.exists():
            for line in index.open():
                try:
                    r=json.loads(line); names[r.get('id')]=r
                except ValueError: pass
    except OSError: errors.append('Codexのタイトル索引を読み取れません')
    for tool,base in [('Codex',home/'.codex/sessions'),('Claude',home/'.claude/projects')]:
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
                            raw_start=p.get('timestamp') if isinstance(p.get('timestamp'),str) else r.get('timestamp'); parsed_start=parse_instant(raw_start)
                            start=(parsed_start,raw_start) if parsed_start else None
                            if raw_start and not parsed_start: errors.append('不正な日時の履歴を除外しました')
                            project=p.get('cwd','')
                            n=names.get(sid,{}); title=n.get('thread_name','')
                            raw_last=n.get('updated_at'); parsed_last=parse_instant(raw_last)
                            last=(parsed_last,raw_last) if parsed_last else None
                        else:
                            for line in stream:
                                try:r=json.loads(line)
                                except ValueError:continue
                                if r.get('isSidechain'):continue
                                sid=r.get('sessionId',sid); project=r.get('cwd') or project
                                ts=r.get('timestamp')
                                instant=parse_instant(ts)
                                if ts and r.get('type') in ('user','assistant') and not instant:
                                    errors.append('不正な日時の履歴を除外しました')
                                if instant and r.get('type') in ('user','assistant'):
                                    if not start or instant<start[0]: start=(instant,ts)
                                    if not last or instant>last[0]: last=(instant,ts)
                                if r.get('type')=='custom-title':title=r.get('customTitle','')
                    if start:
                        sessions.append({'id':sid,'tool':tool,'start':start[1],'last_activity':last[1] if last else None,'end':None,'project':Path(project).name if project else '不明','title':title or f'{tool} セッション {sid[:8]}'})
                except (OSError,ValueError,StopIteration):errors.append(f'{tool}の一部の履歴を読み取れません')
        except OSError:errors.append(f'{tool}の履歴フォルダにアクセスできません')
    unique={(s['tool'],s['id']):s for s in sessions}
    return {'sessions':sorted(unique.values(),key=lambda x:parse_instant(x['start']),reverse=True),'warnings':list(set(errors)),'timezone':'Asia/Tokyo'}
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
