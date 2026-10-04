# Codexローカルmetadata adapter

Python版 `app.py` は `codex_source.py` の一時stdio app-serverを使います。native Mac版のcollector・常駐プロセス・Keychain・同期設定はこの変更に含みません。

CLI 0.139.0の `codex app-server --help` と `generate-json-schema --out <temporary-dir>` で確認したstable schemaに対応しています。protocolは変更され得るため、未知の応答形式ではJSONLへfallbackします。schema生成物は同梱しません。公式資料: [app-server](https://learn.chatgpt.com/docs/app-server)、[commands](https://learn.chatgpt.com/docs/reference/commands)。app-serverは開発・デバッグ向けでもあり、安定した永続履歴APIの保証ではありません。

## 取得範囲

- `initialize` → `initialized` → `thread/list`。終了はstdin EOF、2秒待ってterminate、さらに2秒後killしてreap。shutdown RPCはschemaにありません。
- sourceKindsは確認済み10種を明示。省略/空配列はinteractiveのみになるため使用しません。全provider、active/archiveを別々にcursor paginationで取得します。
- `useStateDbOnly: true` によりrollout scan/repairを避けます。ただしapp-server自身の起動時state runtime初期化にはDB書込みが必要です。ファイル読取専用のprocessとは異なり、このsandboxでは起動できません。権限変更・daemon登録・login・token抽出は行いません。
- 保持・表示する値はid、明示name、createdAt、updatedAt、cwd basename、sourceの既知分類、現在のstatus.type、archive filter値だけです。既存calendarのtool/end/fallback titleを付加します。subagentの親IDや任意custom source文字列は保持しません。
- `thread/list` は先頭user本文のpreviewを応答に含み、protocol上省略できません。通信バッファ/JSON解析の一時メモリに到着しますが、一覧応答の全rowから直ちに除外し、保存・ログ・表示・検索・API返却を行いません。その他の応答fieldもallowlist投影後に捨てます。
- `thread/read` / turns / items / resumeを呼びません。hidden analysis、turn本文、system prompt、credential、file内容、作業要点全文は要求しません。
- runtime statusは別の一時app-serverの観測値です。通常のnotLoadedは完了/停止を示しません。updatedAtも終了日時ではありません。
- このMacのstate DBにある履歴だけです。dot/cloud tasks、他ホスト、未記録の履歴を網羅する保証はありません。

## 統合と失敗

JSONL collectorを維持し、同じCodex IDにはstate DBの投影値を優先します。JSONLにだけあるIDも残します。app-server失敗時は部分一覧を捨て、従来のJSONL結果にfallbackします。UIはscopeと固定エラー種別を表示し、生のserver error/stdout/stderrを出しません。タイトル索引・先頭metadataのみのfallbackではarchiveとstatusは不明です。通常の同期serializerは既存allowlistのままで、この追加fieldを送信しません。

取得全体20秒、stdout framing buffer 8MiB、各archive区分1000ページを上限とします。CLIが無い場合もfallbackします。キャッシュ更新ごとに一時processを起動し、常駐daemonには接続しません。

## 検証

`python3 -m unittest discover -s tests` はpreview除外、allowlist、source mapping、cursor/重複、分割JSONL/notification、malformed応答、timeoutとprocess reap、EOF終了、JSONL fallbackを人工fixtureで検査します。実dataをtestsやログへ保存しません。

この実行環境では空の一時CODEX_HOMEで公式CLIのinitialize→一覧（active/archive）→EOF終了を確認しました。実ホームでの起動はread-only state DBエラーです。実metadata mappingはDBをmode=roで開き許可fieldだけを投影して件数を確認しましたが、statusはschema fixtureを与えたため、実runtime statusの検証ではありません。運用ホームでのapp-server全一覧とnative連携は未検証です。

## 最新mainとの統合

main `0be60ba230f8c6f8d907725f483887104b3e007d` の日時契約（offset付き日時の実時間比較、不正開始日時の除外）と `tool:id` のカード配置を保持します。nativeのUTF-16 300単位・C0除去・文字cluster境界のタイトル契約、およびsnapshot非更新の署名付きcheckはmain実装のままです。`collect(home=...)` は人工JSONL fixture用で実CLIを起動しません。adapterの統合fixtureには明示的にreaderを注入できます。

引継ぎ済みの公式CLI 0.139.0実ホーム検証では、active/archiveの各1ページはともに0件でprotocolは成功しました。これは履歴coverageの確認ではなく、dot/cloud task全件取得を主張しません。本cloneのread-only sandbox起動拒否、空の一時ホームの成功、従来JSONL件数確認とは別の検証結果です。Native adapter連携は未実装でこのPRの範囲外です。
