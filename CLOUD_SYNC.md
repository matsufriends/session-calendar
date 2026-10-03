# Cloudflare同期（実装準備済み・未稼働）

ローカルアプリは従来通り `python3 app.py` で動作します。クラウド側は独立したWorkerと専用KVに同期済みメタデータを置く構成です。認証設定・リソース作成・実履歴送信・OS自動起動はまだ行っていません。

## 構成

- `cloud/worker.mjs`: `/` と `/api/sessions` はCloudflare Access JWTの署名、issuer、audience、期限、本人emailを検証。設定が欠けると拒否。
- `/api/sync`: PUTのみ、別の書込専用Bearer tokenが必要。閲覧JWTで書き込めず、同期tokenでは閲覧できません。2MiB・20,000件上限、未知フィールド・本文・絶対projectパス・重複ID・不明でない終了日時を拒否。
- `sync.py`: 既存ローカル抽出処理を再利用。送信するのはID、tool、開始・最後の記録、終了null、project basename、titleのみ。本文・cwd・警告詳細は送信しません。タイトルは既定でID表示に置換、`--include-titles`を指定した場合だけ明示タイトルを送ります。タイトルやproject名にも機密情報が含まれ得ます。
- 手動送信 `--send`、5分ごとの変更時送信 `--send --watch`。再起動後の最初の送信はフルsnapshot。リダイレクトは拒否。通信はHTTPSのみ。失敗時に内容・URL・秘密をログへ出しません。snapshotはローカルファイル保存しません。
- KVは専用namespaceの` snapshot `相当の固定1キー。最後のsnapshotを上書きし、Mac停止中も閲覧可能。KVは結果整合性のため更新反映に遅延があり得ます。画面に最終同期日時を表示します。
- `scripts/build_cloud.py`: 元のHTMLだけから公開用assetを生成。生成先はignore対象。履歴や画像をコピーしません。
- `wrangler.jsonc`: workers.devとpreview URLは初期状態で無効。秘密をvarsに置きません。KV自動作成も設定していません。

## ローカル検証

```sh
npm ci
npm test
npm run build
WRANGLER_SEND_METRICS=false WRANGLER_LOG_PATH=/tmp/session-calendar-wrangler.log npm run dry-run
python3 sync.py  # dry-run。送信しない・本文やタイトルを出力しない
```

テストは空データと人工fixtureだけを使います。実データ送信を伴いません。

## 稼働前に必要な設定

1. ユーザーが送信範囲（titleを含むか）、閲覧本人email、専用credential、継続同期の登録を確認。
2. Cloudflare Accessに対象hostnameのアプリを作成。閲覧は本人のみ。同期パスはブラウザー用Accessでブロックしない専用設定が必要（Workerの書込token認証は必須のまま）。既存Accessがない場合はチーム設定・ログイン方式も必要。
3. 専用KVを作成し `SESSIONS` bindingを追加。チームdomain、Access audience、本人emailをWorker varsへ設定。同期tokenは十分なランダム値を安全な入力経路でWorker secretへ保存し、同じ値をMacの保護された保存先へ置く。チャット、CLI引数、ソース、Git、ログへ書かない。
4. 保護されたhostnameで空状態をデプロイ。workers.dev/preview等の別入口も検査。未認証のUI/API拒否、誤ったtoken拒否、本人ログインと空fixtureで成功を確認。
5. その後、Macに `SESSION_SYNC_URL=https://<host>/api/sync` と `SESSION_SYNC_TOKEN` を安全に渡し、明示許可した範囲の初回送信。必要な場合だけLaunchAgentを登録。

このコードは認証設定やリソースを自動作成しません。同期を止めてもサーバーに最後のメタデータは残るため、廃止時は専用snapshotとcredentialを削除する必要があります。

## 公式資料

- [Access JWT検証](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)
- [Worker assets binding](https://developers.cloudflare.com/workers/static-assets/binding/)
- [Worker secrets](https://developers.cloudflare.com/workers/configuration/secrets/)
- [Workers / KV料金](https://developers.cloudflare.com/workers/platform/pricing/)
