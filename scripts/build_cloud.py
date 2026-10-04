from pathlib import Path
root=Path(__file__).resolve().parent.parent
html=(root/'index.html').read_text()
def replace_once(source, anchor, replacement, label):
    count=source.count(anchor)
    if count != 1:
        raise RuntimeError(f'{label}: expected one anchor, found {count}')
    return source.replace(anchor, replacement, 1)
html=html.replace('YOUR LOCAL WORKSPACE','YOUR PRIVATE WORKSPACE').replace('ローカルの履歴を読み込み中…','同期済みの履歴を読み込み中…').replace('ローカル読取専用','同期済み・読取専用').replace('サーバーの起動状態を確認してください。','認証状態と同期状態を確認してください。')
html=replace_once(html,'let sessions=[],anchor=today(),warnings=[];',"let sessions=[],anchor=today(),warnings=[],syncedAt=null;",'session state')
html=replace_once(html,'warnings=Array.isArray(data.warnings)?data.warnings:[];', 'warnings=Array.isArray(data.warnings)?data.warnings:[];syncedAt=data.synced_at;', 'sync timestamp assignment')
html=replace_once(html,"${warnings.length?' · '+warnings.join(' / '):''}","${warnings.length?' · '+warnings.join(' / '):''}${syncedAt?' · 同期 '+dt(syncedAt):''}",'sync timestamp display')
(root/'cloud/public').mkdir(exist_ok=True)
(root/'cloud/public/index.html').write_text(html)
