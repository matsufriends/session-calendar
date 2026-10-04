# Session Calendar

Claude Code / Codex CLI のローカル履歴を、Asia/Tokyo の週カレンダーで表示します。会話本文やツール出力は読み取り・保存・送信しません。

- Mac メニューバーアプリ: ローカルカレンダーを表示し、任意で自分の Cloudflare Worker へメタデータを同期します
- Web カレンダー: 自分で deploy した Worker 上で、Cloudflare Access の本人認証を通して閲覧します
- Python 版: ローカル表示だけを行います（外部送信なし）

## Mac アプリのインストール

```sh
brew install --cask tsukumistudio/tap/session-calendar
```

更新はダッシュボード下段の「更新を確認」から行います（内部で `brew upgrade --cask` を実行します）。

## 読み取るデータ

- `~/.codex/sessions/**/*.jsonl` の先頭 session_meta と `~/.codex/session_index.jsonl`
- `~/.claude/projects/**/*.jsonl`（subagents / isSidechain は除外）

取り出すのは ID・開始/最後の記録日時・cwd の末尾名・明示タイトルだけです。タイトルは Codex の thread_name、Claude の custom-title → ai-title → summary の順で使い、ない場合は「作業名不明」です。終了日時は記録されないため、カレンダーは開始〜最後の記録を「終了不明」の観測区間として表示します。

## Web 同期（各自で deploy）

同期サーバーは利用者ごとに自分の Cloudflare アカウントへ deploy します。プロトコルと保護の詳細は [CLOUD_SYNC.md](CLOUD_SYNC.md) を参照してください。

1. 閲覧用と同期用の 2 つのホスト名を用意し、閲覧用ホストに自分のメールだけを許可する Cloudflare Access アプリケーションを作成します
2. 署名鍵を作成し、公開鍵を控えます（秘密鍵は Mac の Keychain にだけ保存されます）
   ```sh
   /Applications/SessionCalendar.app/Contents/MacOS/SessionCalendar --provision-key
   ```
3. `wrangler.example.jsonc` を `wrangler.jsonc` にコピーし、`<...>` を自分の値に置き換えて deploy します
   ```sh
   cp wrangler.example.jsonc wrangler.jsonc
   npm ci
   npm run deploy
   ```
4. アプリの「…」→「接続設定」で同期先（`https://<同期用ホスト>/api/sync`）と閲覧 URL（`https://<閲覧用ホスト>/`）を保存し、「同期を開始」を押します

同期は 5 分ごと、変更があったときだけ送信します。

## Python 版（ローカル表示のみ）

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python app.py
```

http://127.0.0.1:8765 を開きます。別ポートは `--port 8766`。Codex は一時起動した app-server の state DB metadata も読みます（[Codex adapter](docs/codex-source.md)）。

## 開発

```sh
PATH="$PWD/.venv/bin:$PATH" npm test
swift test --package-path native
zsh build-mac.sh
dist/SessionCalendar.app/Contents/MacOS/SessionCalendar --self-test
```

`.githooks/pre-commit` で同じ検査をコミット前に実行できます（`git config core.hooksPath .githooks`）。

## リリース

`vX.Y.Z` タグを push すると、GitHub Actions がビルド → MornNotary で署名・公証 → Release 作成 → `TsukumiStudio/homebrew-tap` の cask 更新まで行います。バージョンはタグから決まります。release 環境に `MORN_NOTARY_TOKEN` と `HOMEBREW_TAP_TOKEN` が必要です。
