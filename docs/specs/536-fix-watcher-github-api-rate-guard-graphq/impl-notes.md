# 実装ノート（#536: GitHub API Rate Guard の graphql 残量取得経路是正）

## 変更点サマリ

対象: `local-watcher/bin/modules/api-rate-guard.sh` / `local-watcher/test/api_rate_guard_degrade_test.sh` / `README.md`

- `grl_buckets_refresh`: 単一 REST `gh api rate_limit` から全バケットを読む構造をやめ、
  **core / search は REST**（従来どおり非消費 / `.resources.core` / `.resources.search`）、
  **graphql は GraphQL クエリ**へ分離。REST 失敗時も early-return せず graphql 取得へ進む
  （degrade は graphql のみに依存するため / 判断委任）。
- `grl_graphql_bucket_refresh`（**新規**）: `gh api graphql -f query='{ rateLimit { limit used
  remaining resetAt } }'` の `.data.rateLimit.remaining` / `.limit` を取得（Req 1.1, 1.3, 1.4）。
  取得失敗を種別判定して新グローバル `GRL_BUCKET_GRAPHQL_STATUS` へ反映。
- `grl_degrade_should_run`: 判定基準を `GRL_BUCKET_STATUS`（全体）から `GRL_BUCKET_GRAPHQL_STATUS`
  へ変更。`rate_limited` は残量 0 とみなし skip（Req 4.1, 4.2）、`unavailable`/未取得/非整数は
  安全側で実行（Req 4.3）、`ok`+残量<閾値で skip（Req 2.1, 2.2）。
- `grl_buckets_log`: ロジック不変（`GRL_BUCKET_STATUS`=REST 状態で core/search 可視化可否を判定）。
  graphql 欄は GraphQL クエリ由来の値（rate_limited 時は `graphql=0/?`）。固定書式・prefix 不変（Req 3.3）。

### 追加したモジュールグローバル

- `GRL_BUCKET_GRAPHQL_STATUS`（`grl_`/`GRL_` namespace）: `ok` / `rate_limited` / `unavailable` /
  `disabled`。既存 env var 名・ログ prefix（`gh-rate-limit:`）・固定書式・exit code 意味は不変。

## refresh 2 回発火に対する方針

**キャッシュ集約しない**（要件 Open Questions で実装判断に委任 / NFR 1.1 は 2pt 以下を許容）。
両 gate on 時、cycle 冒頭（`issue-watcher.sh:418`）と cycle 終端（`grl_buckets_log` 内 :905）で
GraphQL クエリが最大 2 回発火 = 最大 2pt/cycle で NFR 1.1 充足。集約は「cycle 終端は最新値を出す」
既存挙動との整合・後方互換の追加リスクに見合わないと判断し見送り。core/search の REST 再取得は
従来から非消費で挙動不変。

## rate-limit 起因失敗の判定方法

GraphQL 応答（stdout+stderr を `2>&1` 結合で捕捉）に対し、既存 `grl_retry_label_op` と同一パターン
`grep -qiE 'rate.?limit|RATE_LIMITED|HTTP 429|HTTP 403|too many requests'` を適用。失敗検出自体は
(a) gh の非ゼロ rc、または (b) rc=0 でも body に `errors[]`（`jq -e '.errors and (.errors|length>0)'`）
を含む GraphQL エラー、の双方を見る。未信頼文言は grep へ stdin 経由で渡し引数注入を避ける（NFR 5.1）。
クエリ文字列は固定リテラル。`set -e` 対策として gh の非ゼロ rc は `|| rc=$?` で捕捉。

## AC Traceability（担保テスト）

`local-watcher/test/api_rate_guard_degrade_test.sh`（全 44 検証 PASS）。

| Req | 担保 |
|---|---|
| 1.1/1.3 graphql は GraphQL クエリ由来 | test 2「graphql remaining=4800（GraphQL 由来）」+ 呼び出しログに `gh api graphql -f query=` |
| 1.2 core/search は REST 由来 | test 2「core=4990/search limit=30（REST 由来）」+ `gh api rate_limit` |
| 1.4 仮案 B 不採用 | 応答ヘッダ流用コードを持たず GraphQL rateLimit クエリで取得（実装 + test 2） |
| 2.1/2.2 閾値割れ skip+WARN | test 6「残量<閾値 rc=1」+ skip ログに processor/reason/bucket/remaining/threshold |
| 2.3 閾値以上は実行 | test 6「残量>=閾値 rc=0」 |
| 2.4 縮退無効は skip しない | test 6「gate off rc=0」 |
| 3.1/3.2 可視化 graphql=GraphQL・core/search=REST | test 2 固定書式 + test 4「graphql=0/」 |
| 3.3 固定書式/prefix 不変 | test 2「gh-rate-limit: core=.. graphql=.. search=..」 |
| 4.1/4.2 rate limit 起因失敗→残量0で skip+WARN | test 4/4b + test 6「rate_limited rc=1」+ reason=degrade-graphql-fetch-rate-limited |
| 4.3/4.4 rate limit 以外失敗→全実行+WARN | test 5 + test 6「unavailable rc=0」 |
| 4.5 失敗でもサイクル中断しない | 全 refresh 呼び出しが rc=0（各 test で継続） |
| 5.1 両 gate off で新規 API 呼び出しゼロ | test 1「GraphQL クエリも REST も呼ばない」 |
| 5.2/5.3 env/prefix/書式・実行順不変 | env var 追加なし・ロジック外形不変（実装 diff） |
| 6.1〜6.4 テスト追随 | test 2/4/5/7（live API なし stub） |
| NFR 1.1 2pt 以下 | 上記「refresh 2 回発火」方針（最大 2 回/cycle） |
| NFR 2 後方互換 | 既存 env var/ラベル/exit code/ログ出力先 不変・新規ラベルなし |
| NFR 3 観測可能性 | WARN に失敗種別（rate limit 起因 / 以外）を記録（test 4/5） |
| NFR 4 shellcheck クリーン | 下記検証結果 |

## 検証結果

- `bash -n`: api-rate-guard.sh / degrade_test.sh とも OK
- `shellcheck`: api-rate-guard.sh / degrade_test.sh とも新規警告 0（root `.shellcheckrc` baseline 準拠）
- 関連テスト群（全 green）:
  - api_rate_guard_degrade: PASS 44 / api_rate_guard_snapshot: 26 / api_rate_guard_retry: 13
  - api_rate_guard_rest: 15 / api_rate_guard_pr_equiv: 14 / api_rate_guard_issue_equiv: 16
  - api_rate_guard_review_equiv: 12 / sr_wiring: 61
- 二重管理: `diff -r .claude/agents|rules repo-template/...` とも差分なし。api-rate-guard.sh は
  local-watcher 専用（repo-template に非配布）のため同期不要。

## README 更新箇所

`README.md` 「GitHub API Rate Guard (#521)」節:
- 「バケット可視化ログの読み方」: graphql=GraphQL クエリ由来 / core・search=REST の取得経路（#536）、
  1〜2pt 消費の migration note（#521 Req 3.2 緩和）、失敗種別分岐（判断 2）を追記。
- 「縮退の優先順位」: graphql 実残量が GraphQL 由来である旨、rate limit 起因失敗時の
  `reason=degrade-graphql-fetch-rate-limited` skip を追記。
- 「fail-safe / 後方互換」: graphql 取得失敗の分岐（rate limit 起因は残量 0 で縮退 / 以外は全実行）を反映。

## 確認事項

- **degrade の判定基準を全体 status から graphql status へ移した点**: 従来 `grl_degrade_should_run` は
  `GRL_BUCKET_STATUS != ok`（core/search 含む全体）で安全側実行していた。#536 の degrade は graphql
  バケット固有（要件 Req 2/4 は全て graphql 参照）のため、判定を `GRL_BUCKET_GRAPHQL_STATUS` へ移した。
  結果、「core/search の REST 取得が失敗しても graphql 実残量が低ければ縮退が発火し得る」挙動になる
  （従来は全 bucket 未取得＝全実行）。要件（graphql 低下時の縮退）と整合し、設計ヒントの「REST 取得
  失敗の従来フォールバック（＝graphql も未取得なら全実行）は変えない」も unavailable 経路で維持している
  と解釈した。この解釈拡張が意図と異なる場合は Architect/PM に差し戻し可能。

STATUS: complete
