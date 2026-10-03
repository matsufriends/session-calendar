from pathlib import Path
root=Path(__file__).resolve().parent.parent
html=(root/'index.html').read_text()
html=html.replace('YOUR LOCAL WORKSPACE','YOUR PRIVATE WORKSPACE').replace('ローカルの履歴を読み込み中…','同期済みの履歴を読み込み中…').replace('ローカル読取専用','同期済み・読取専用').replace('サーバーの起動状態を確認してください。','認証状態と同期状態を確認してください。')
html=html.replace('let sessions=[],anchor=today(),warnings=[];',"let sessions=[],anchor=today(),warnings=[],syncedAt=null;")
html=html.replace('warnings=data.warnings;render()', 'warnings=data.warnings;syncedAt=data.synced_at;render()')
html=html.replace("${warnings.length?' · '+warnings.join(' / '):''}","${warnings.length?' · '+warnings.join(' / '):''}${syncedAt?' · 同期 '+dt(syncedAt):''}")
(root/'cloud/public').mkdir(exist_ok=True)
(root/'cloud/public/index.html').write_text(html)
