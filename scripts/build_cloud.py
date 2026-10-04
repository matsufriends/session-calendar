from pathlib import Path
root=Path(__file__).resolve().parent.parent
html=(root/'index.html').read_text()
def replace_once(source, anchor, replacement, label):
    count=source.count(anchor)
    if count != 1:
        raise RuntimeError(f'{label}: expected one anchor, found {count}')
    return source.replace(anchor, replacement, 1)
html=html.replace('YOUR LOCAL WORKSPACE','YOUR PRIVATE WORKSPACE').replace('ローカルの履歴を読み込み中…','同期済みの履歴を読み込み中…').replace('ローカル読取専用','同期済み・読取専用').replace('サーバーの起動状態を確認してください。','認証状態と同期状態を確認してください。')
if 'syncedAt=data.synced_at||null;' not in html or "${sync}${warnings.length?" not in html:
    raise RuntimeError('Cloud viewer requires the shared snapshot timestamp display')
(root/'cloud/public').mkdir(exist_ok=True)
(root/'cloud/public/index.html').write_text(html)
