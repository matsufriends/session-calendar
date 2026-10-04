# Cloudflare同期

閲覧: https://session-calendar.matsufriends.com/ 。本人メールだけを許可するCloudflare Accessの後段で、WorkerもJWT署名・issuer・audience・期限・emailを検証します。未設定時は拒否します。

同期: https://session-calendar-sync.matsufriends.com/api/sync 。PUT専用です。このホストの閲覧ルートはJWTや署名を付けても拒否します。同期署名は閲覧権限を与えません。

## 署名プロトコル

Mac KeychainのP-256秘密鍵でSHA-256/ECDSA署名を作ります。秘密鍵をサーバーへ送る工程はありません。Workerへ登録する`SYNC_PUBLIC_KEY`は130文字の小文字hex（非圧縮X9.63公開鍵）です。

署名対象は次の7行を改行で結合したUTF-8です。末尾改行はありません。

```
SESSION-CALENDAR-V1
PUT
<HTTPS origin>
/api/sync
<Unix秒>
<32 random bytesの小文字hex>
<body bytesのSHA-256小文字hex>
```

ヘッダーは`X-Sync-Timestamp`、`X-Sync-Nonce`、`X-Sync-Signature`（P1363 raw 64-byte署名の小文字hex）。サーバーは時刻差300秒以内、正確な送信先origin/path、本文hash、登録公開鍵を検証します。Authorization/Bearerは受け付けません。

単一のSQLite Durable Object `SyncStore`が、nonce消費とsnapshot保存を1トランザクションで行います。再使用nonceは409。期限切れnonceを除去し、有効nonceが256個ある場合は429。KVの結果整合性をリプレイ防止には使いません。保存は最新snapshotのみです。

## 送信データ

2MiB・20,000件上限。未知フィールド、本文、絶対projectパス、重複ID、終了日時（null以外）を拒否します。ID・tool・開始/最後の記録・終了null・project basename・titleだけを送り、明示タイトルは初期状態で匿名化します。タイトル送信を有効にした場合も、C0制御文字を空白に置き換え、UTF-16で300単位以内に書記素境界で切り詰めます。空文字になる場合は「無題」にします。

Macメニューバーアプリは初回同期無効、5分ごとの変更時送信、HTTPSのみ、redirect拒否。「停止」で継続同期を止めます。Python `sync.py`はdry-run専用にし、`--send`を拒否します。旧Bearer経路はありません。

## 検証と運用

`npm test`と`swift test --package-path native`は人工fixtureのみ。`--self-test`は履歴/Keychain/通信なし。`--provision-key`は公開鍵だけを出力。`--probe-empty-sync`は実履歴を読まず空データの送信・リプレイ拒否・閲覧拒否・偽署名拒否を検査します。Keychain UIは許可せず、検査全体に15秒期限を設けます。

workers.devとpreview URLを無効化し、assetsはWorkerを先に通します。本人ログインと保護確認が完了するまで実履歴を送らないでください。同期を停止しても最後のsnapshotは残ります。廃止時は専用Durable Objectのsnapshot/nonceとMac専用鍵を削除します。

## 公式資料

- [Access JWT検証](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)
- [Durable Object transaction](https://developers.cloudflare.com/durable-objects/api/legacy-kv-storage-api/)
- [Worker custom domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)
