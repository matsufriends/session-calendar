#!/usr/bin/env python3
"""Metadata dry-run only. Sending is handled by the signed Mac app."""
import argparse, json, sys
from datetime import datetime
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
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--send',action='store_true');parser.add_argument('--include-titles',action='store_true');parser.add_argument('--watch',action='store_true');args=parser.parse_args()
    if args.watch and not args.send:parser.error('--watch requires --send')
    if args.send:parser.error('Sending is supported only by the signed Mac app; Python supports dry-run only')
    try:
        source=app.collect()
        if source['warnings']:raise ValueError('source read failure')
        data=snapshot(source,args.include_titles);body=json.dumps(data,ensure_ascii=False,separators=(',',':')).encode()
        if len(body)>2*1024*1024:raise ValueError('snapshot exceeds limit')
        print(f"Dry run: {len(data['sessions'])} sessions, {len(body)} bytes, titles {'included' if args.include_titles else 'omitted'}")
        return 0
    except (OSError,ValueError):
        print('Dry run failed; no details logged',file=sys.stderr)
        return 1
if __name__=='__main__':sys.exit(main())
