#!/usr/bin/env python3
"""Opt-in metadata sync. Default is dry-run; no body or credential is logged."""
import argparse, json, os, time, hashlib, sys
from datetime import datetime
from pathlib import Path
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.parse import urlparse
from urllib.error import URLError
import app
KEYS=('id','tool','start','last_activity','end','project','title')
def snapshot(source, include_titles=False):
    rows=[]
    for s in source['sessions']:
        r={k:s.get(k) for k in KEYS}
        r['project']=str(r['project'] or '不明').replace('\\','/').rstrip('/').split('/')[-1][:200] or '不明'
        r['title']=str(r['title'])[:300] if include_titles else f"{r['tool']} セッション {str(r['id'])[:8]}"
        for k in ('start','last_activity'):
            if r[k]:r[k]=datetime.fromisoformat(r[k].replace('Z','+00:00')).isoformat()
        r['end']=None;rows.append(r)
    return {'sessions':rows,'timezone':'Asia/Tokyo'}
class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--send',action='store_true');parser.add_argument('--include-titles',action='store_true');parser.add_argument('--watch',action='store_true');args=parser.parse_args()
    if args.watch and not args.send:parser.error('--watch requires --send')
    endpoint=os.environ.get('SESSION_SYNC_URL','');token=os.environ.get('SESSION_SYNC_TOKEN','')
    if args.send:
        url=urlparse(endpoint)
        if url.scheme!='https' or not url.netloc or url.username or url.password or url.path!='/api/sync' or url.query or url.fragment or len(token)<32:parser.error('Set a HTTPS /api/sync URL and token of at least 32 characters through the environment')
    previous=None;opener=build_opener(NoRedirect)
    while True:
        try:
            source=app.collect()
            if source['warnings']:raise ValueError('source read failure')
            data=snapshot(source,args.include_titles);body=json.dumps(data,ensure_ascii=False,separators=(',',':')).encode()
            if len(body)>2*1024*1024:raise ValueError('snapshot exceeds limit')
            digest=hashlib.sha256(body).digest()
            if not args.send:print(f"Dry run: {len(data['sessions'])} sessions, {len(body)} bytes, titles {'included' if args.include_titles else 'omitted'}");return 0
            if digest!=previous:
                request=Request(endpoint,body,{'Authorization':'Bearer '+token,'Content-Type':'application/json'},method='PUT')
                with opener.open(request,timeout=30) as response:
                    result=json.load(response)
                    if result.get('ok') is not True:raise ValueError('sync rejected')
                previous=digest;print(f"Synced {len(data['sessions'])} sessions",flush=True)
            if not args.watch:return 0
        except (OSError,ValueError,URLError):
            print('Sync failed; no details or credentials logged',file=sys.stderr,flush=True)
            if not args.watch:return 1
        time.sleep(300)
if __name__=='__main__':sys.exit(main())
