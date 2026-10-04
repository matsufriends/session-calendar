"""Generate cloud HTML; required script transforms fail closed on source drift."""
from pathlib import Path


def replace_once(html, old, new, label):
    if html.count(old) != 1:
        raise ValueError(f'cloud build anchor mismatch: {label}')
    return html.replace(old, new, 1)


def build_cloud(html):
    html = html.replace('YOUR LOCAL WORKSPACE', 'YOUR PRIVATE WORKSPACE').replace('ローカルの履歴を読み込み中…', '同期済みの履歴を読み込み中…').replace('ローカル読取専用', '同期済み・読取専用').replace('サーバーの起動状態を確認してください。', '認証状態と同期状態を確認してください。')
    for anchor in ["let sessions=[],anchor=today(),warnings=[],sourceScope='',syncedAt=null;", "sourceScope=data.source_scope||'';syncedAt=data.synced_at||null;", "${sync}${warnings.length?", "sourceScope=data.source_scope||'';", "${warnings.length?' · '+warnings.join(' / '):''}"]:
        replace_once(html, anchor, anchor, 'shared snapshot/source scope')
    return html


def main():
    root = Path(__file__).resolve().parent.parent
    html = build_cloud((root/'index.html').read_text())
    (root/'cloud/public').mkdir(exist_ok=True)
    (root/'cloud/public/index.html').write_text(html)


if __name__ == '__main__':
    main()
