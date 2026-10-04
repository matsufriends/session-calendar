# MornSessionCalendar

Claude Code / Codex CLI のローカル履歴を、週カレンダー（日本時間）で表示する Mac メニューバーアプリです。データはすべて手元で完結し、外部へは送信しません。

## インストール

```sh
brew install --cask tsukumistudio/tap/morn-session-calendar
```

起動中は http://127.0.0.1:18765 でカレンダーを見られます。メニューバーの「カレンダーを開く」からも開けます。履歴は 5 分ごとに読み直します。更新はダッシュボード下段の「更新を確認」から行います（内部で `brew upgrade --cask` を実行します）。

## 別サイトで見る（任意）

`~/.config/morn-session-calendar/push.json` に `{"url": "https://<host>/api/sessions/push", "token": "<送信用トークン>"}` を置くと、読み込みのたびに（変化があったときだけ）その URL へ履歴を `PUT` します。受け側は `index.html` を配信し、`GET /api/sessions` で同じ形式の JSON を返せば表示できます。

## 読み取るデータ

- `~/.codex/sessions/**/*.jsonl` の先頭 session_meta と `~/.codex/session_index.jsonl`
- `~/.claude/projects/**/*.jsonl`（subagents / isSidechain は除外）

取り出すのは ID・開始/最後の記録日時・cwd の末尾名・明示タイトルだけで、会話本文やツール出力は読み取りません。タイトルは Codex の thread_name、Claude の custom-title → ai-title → summary の順で使います。終了時刻は記録されないため、開始から最後の記録まで（最大 2 時間）をブロックとして表示します。

## 開発

```sh
node --test tests/*.test.mjs
swift test --package-path native
zsh build-mac.sh
dist/MornSessionCalendar.app/Contents/MacOS/MornSessionCalendar --self-test
```

`git config core.hooksPath .githooks` で同じ検査をコミット前に実行します。

## リリース

`vX.Y.Z` タグを push すると、GitHub Actions がビルド → MornNotary で署名・公証 → Release 作成 → `TsukumiStudio/homebrew-tap` の cask 更新まで行います。バージョンはタグから決まります。release 環境に `MORN_NOTARY_TOKEN` と `HOMEBREW_TAP_TOKEN` が必要です。
