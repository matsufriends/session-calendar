#!/usr/bin/env python3
"""Local, read-only session metadata calendar."""
import json, argparse, threading, time, re
from datetime import datetime, timedelta, timezone
from title_normalization import normalized_title
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from codex_source import collect_codex, merge_codex, SourceError, SCOPE
ROOT=Path(__file__).parent
DOT_TASK_STATUSES={'queued','running','in_progress','cancelling','cancelled','canceled','completed','failed','incomplete','requires_action','expired','waiting','inProgress'}
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
            value=f'{date}T00:{match.group(3)}:{second:02d}{fraction or ""}{zone}'
        elif hour>23: return None
        if minute>59 or second>59: return None
        parsed=datetime.fromisoformat(value[:-1]+'+00:00' if value.endswith(('Z','z')) else value)
        return parsed if parsed.tzinfo is not None and parsed.utcoffset() is not None else None
    except (ValueError,OverflowError): return None
def title_value(value):
    # Only explicit title metadata: never derive a heading from message content.
    if not isinstance(value,str) or not value.strip(): return ''
    try: return normalized_title(value)
    except UnicodeError: return ''  # Native JSONLines rejects invalid Unicode strings too.
def valid_timestamp(value):
    return isinstance(value,str) and len(value)<=40 and parse_instant(value) is not None
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
        if not isinstance(latest,dict) or not _safe_text(latest.get('status'),40) or latest['status'] not in DOT_TASK_STATUSES: raise ValueError('missing or invalid latestTurn.status')
        title=task.get('title')
        if title is None: title=f'ChatGPT タスク {task_id[-8:]}'
        if not _safe_text(title,300): raise ValueError('invalid title')
        project=task.get('project')
        if project is None: project='不明'
        if not _safe_text(project,500): raise ValueError('invalid project')
        project=project.replace('\\','/').rstrip('/').rsplit('/',1)[-1][:200] or '不明'
        result.append({'id':task_id,'source':'dot-task','tool':'ChatGPT','task_registered_at':attached,
          'latest_turn_status':latest['status'],'snapshot_observed_at':observed,'project':project,'title':title})
        seen.add(task_id)
    return result
def load_dot_snapshot(path, occupied_ids=()):
    """Read only the explicit local file path supplied at server startup; no HTTP path access."""
    raw=Path(path).read_text(encoding='utf-8')
    return adapt_dot_snapshot(json.loads(raw),occupied_ids)
def collect(home=None,dot_snapshot_path=None,codex_reader=None):
    fixture_home=home is not None
    home=Path.home() if home is None else Path(home)
    sessions=[]; errors=[]; names={}
    index=home/'.codex/session_index.jsonl'
    try:
        if index.exists():
            with index.open() as stream:
                for line in stream:
                    try:
                        r=json.loads(line); names[r.get('id')]=r
                    except ValueError: pass
    except OSError: errors.append('Codexのタイトル索引を読み取れません')
    for tool,base in [('Codex',home/'.codex/sessions'),('Claude',home/'.claude/projects')]:
        try:
            for file in base.glob('**/*.jsonl'):
                if 'subagents' in file.parts: continue
                try:
                    sid=file.stem; start=None; last=None; project=''; title=''; ai_title=''; summary=''
                    with file.open() as stream:
                        if tool=='Codex':
                            r=json.loads(next(stream)); p=r.get('payload',{})
                            if r.get('type')!='session_meta': continue
                            sid=p.get('id') or p.get('session_id') or sid
                            raw_start=p.get('timestamp') or r.get('timestamp'); parsed_start=parse_instant(raw_start)
                            start=(parsed_start,raw_start) if parsed_start else None
                            if raw_start and not parsed_start: errors.append('不正な日時の履歴を除外しました')
                            project=p.get('cwd','')
                            n=names.get(sid,{}); title=title_value(n.get('thread_name'))
                            raw_last=n.get('updated_at'); parsed_last=parse_instant(raw_last)
                            last=(parsed_last,raw_last) if parsed_last else None
                        else:
                            for line in stream:
                                try:r=json.loads(line)
                                except ValueError:continue
                                if r.get('isSidechain'):continue
                                sid=r.get('sessionId',sid); project=r.get('cwd') or project
                                ts=r.get('timestamp'); instant=parse_instant(ts)
                                if ts and r.get('type') in ('user','assistant') and not instant: errors.append('不正な日時の履歴を除外しました')
                                if instant and r.get('type') in ('user','assistant'):
                                    if not start or instant<start[0]: start=(instant,ts)
                                    if not last or instant>last[0]: last=(instant,ts)
                                if r.get('type')=='custom-title':title=title_value(r.get('customTitle')) or title
                                if r.get('type')=='ai-title':ai_title=title_value(r.get('aiTitle')) or ai_title
                                if r.get('type')=='summary':summary=title_value(r.get('summary')) or summary
                    if start:
                        sessions.append({'id':sid,'tool':tool,'start':start[1],'last_activity':last[1] if last else None,'end':None,'project':Path(project).name if project else '不明','title':title or ai_title or summary or '作業名不明'})
                except (OSError,ValueError,StopIteration):errors.append(f'{tool}の一部の履歴を読み取れません')
        except OSError:errors.append(f'{tool}の履歴フォルダにアクセスできません')
    try:
        reader=codex_reader if codex_reader is not None else ((lambda: []) if fixture_home else collect_codex)
        metadata=reader()
        sessions=merge_codex(sessions,metadata)
        codex_scope='Codex: fixture JSONL metadataのみ' if fixture_home and codex_reader is None else f'{SCOPE} · app-server {len(metadata)}件'
    except SourceError as error:
        errors.append(f'Codex app-server取得失敗（{error}）。JSONLにfallback')
        codex_scope='Codex: JSONL先頭metadataとタイトル索引のみ（archive対象外）'
    unique={(s['tool'],s['id']):s for s in sessions}
    dot_tasks=[]
    if dot_snapshot_path:
        try: dot_tasks=load_dot_snapshot(dot_snapshot_path,{s['id'] for s in unique.values()})
        except (OSError,UnicodeError,ValueError,json.JSONDecodeError): errors.append('dot-task snapshotを読み取れません（JSON・必須項目・ID重複を確認してください）')
    rows=list(unique.values())+dot_tasks
    floor=datetime.min.replace(tzinfo=timezone.utc)
    return {'sessions':sorted(rows,key=lambda x:parse_instant(x.get('start') or x.get('task_registered_at')) or floor,reverse=True),'warnings':list(set(errors)),'timezone':'Asia/Tokyo','source_scope':codex_scope}
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
    def configured_collect(home=None): return original_collect(home,args.dot_snapshot)
    collect=configured_collect
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
