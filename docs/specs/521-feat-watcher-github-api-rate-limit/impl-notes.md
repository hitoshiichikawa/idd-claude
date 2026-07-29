# 実装ノート（#521 watcher の GitHub API 消費削減・rate limit 耐性強化）

## 実装した機能の要約

新規 module `local-watcher/bin/modules/api-rate-guard.sh`（prefix `grl_` / 関数定義のみ）に
5 機能を集約。全 gate 既定 OFF・不正値は安全側正規化。ロガー `grl_log/_warn/_error`
（prefix `gh-rate-limit:`）は `core_utils.sh`。env は `watcher-config.sh`。

| 機能 | 主関数 | env | 配線 / 差し替え | テスト |
|---|---|---|---|---|
| (1) snapshot 共有 | `grl_snapshot_init` / `_active` / `_prs` / `_issues` / `grl_pr_snapshot_or_live` / `grl_issue_snapshot_or_live` | `GH_API_SNAPSHOT_ENABLED` ほか 4 | `issue-watcher.sh:412`（quota-resume 直前）+ PR 9 / Issue 4 module | `api_rate_guard_snapshot_test.sh` / `_pr_equiv_test.sh` / `_review_equiv_test.sh` / `_issue_equiv_test.sh` |
| (2) バケット可視化 | `grl_buckets_refresh` / `grl_buckets_log` | `GH_API_BUCKET_LOG_ENABLED` | refresh=`:418` / log=`:905`（`echo 完了` 直前） | `api_rate_guard_degrade_test.sh` |
| (3) 縮退 | `grl_degrade_should_run` | `GH_API_DEGRADE_ENABLED` / `_GRAPHQL_THRESHOLD` | 非必須 7 call site を gate | `api_rate_guard_degrade_test.sh` |
| (4) 限定リトライ | `grl_retry_label_op` | `GH_API_STATE_RETRY_ENABLED` / `_MAX_ATTEMPTS` / `_SLEEP` | 再 pickup 復帰 3 箇所（impl-pipeline ×2 / slot-worker ×1） | `api_rate_guard_retry_test.sh` |
| (5) REST 逃がし | `grl_rest_prs_for_head` / `grl_gh_pr_list_head` | `GH_API_REST_OFFLOAD_ENABLED` | per-branch 存在確認 3 箇所（resume ×1 / stage-checkpoint ×2） | `api_rate_guard_rest_test.sh` |

## AC トレーサビリティ（1 要件群 1 行）

| 要件 | 担保テスト / 検証 |
|---|---|
| 1.1–1.3（opt-in / 既定 no-op / 不正値正規化 / NFR1.1） | snapshot/degrade/retry/rest 各 test の gate off / typo ケース + Task10 config 正規化 smoke + gate-off no-op smoke（gh 非呼び出し確認） |
| 1.4–1.6（既存 env/ラベル/exit code 不変・新規ラベル無） | 新規 `GH_API_*` 名のみ追加。既存識別子・ラベル非変更（コードレビュー / 108 test suite 回帰） |
| 2.1, 2.2（サイクル冒頭 1 回取得 / NFR3.1） | `api_rate_guard_snapshot_test.sh`（PR/Issue list 各 1 回） |
| 2.3（個別取得と等価判定） | `_pr_equiv` / `_review_equiv` / `_issue_equiv`（client jq が server search を再現） |
| 2.4（鮮度クリティカルは個別） | `_pr_equiv`（Dispatcher 非参加をソース走査で確認） |
| 2.5, 2.6（取得失敗 fallback + warn / NFR2.1） | `api_rate_guard_snapshot_test.sh`（PR/Issue fetch fail → active=off + warn） |
| 3.1–3.4（終端 1 行ログ / 非消費 / 固定書式 / 失敗継続） | `api_rate_guard_degrade_test.sh`（gh api rate_limit parse / 書式 / 取得失敗継続） |
| 4.1–4.6（閾値 WARN / 非必須 skip / essential 不 skip / 閾値 env / skip ログ / 無効時不 skip） | `api_rate_guard_degrade_test.sh`（閾値割れ skip / gate off run / 安全側 fallback）+ 分類表 |
| 5.1–5.6（rate-limit 限定リトライ / 有限 / 孤児化しない / 安全側 / 試行ログ） | `api_rate_guard_retry_test.sh`（N 回試行 / 非 rate-limit 1 回 / 上限打ち切り / gate off 単発） |
| 6.1–6.4（REST 逃がし / 等価判定 / 失敗 fallback / 無効時 GraphQL） | `api_rate_guard_rest_test.sh`（REST→JSON 正規化 MERGED 変換 / 失敗 fallback / gate off 従来経路） |
| 7.1–7.3（README opt-in 手順 / env 表 / ログ読み方・縮退優先順） | README「GitHub API Rate Guard (#521)」節 |
| NFR5.1（未信頼入力） | jq は `--arg` / `--argjson`、REST は `-f` で query param、branch はクォート維持 |
| NFR6.1, 6.2（shellcheck 0 / fixture テスト） | Task10 verify（shellcheck + bash -n PASS）/ 全 test は gh stub で live API なし |

## design との差異・着手時に判明したドリフト（確認事項）

1. **Issue 超集合 union に `updatedAt` を追加**: design の Issue union は
   `number,title,body,url,labels,author` だが、参加 processor の stale-pickup-reaper
   （Inventory #13）は `updatedAt` を必須参照する。真の超集合にするため
   `grl_snapshot_issue_fields` に `updatedAt` を追加した（design union の抜けを補完）。
2. **Issue consumer 3 件は wrapper ではなく branch パターンで実装**: design は Issue 参加
   4 module を `grl_issue_snapshot_or_live` 経由と規定するが、quota-aware / dependency-resolver /
   path-overlap の現行コマンドは `--label` / `is:open`-in-search 形で、wrapper の統一形
   （`--state open --search`）と **byte 一致しない**。かつ既存テスト（#346 の `--label auto-dev`
   アサート、#518 の labels 欠落 fixture）が旧コマンド形/挙動を前提とする。NFR 1.1（gate off
   byte 等価）を最優先し、`grl_snapshot_active` 分岐で **active 時のみ snapshot+client 絞り込み /
   gate off は原コマンドを逐語温存** する branch パターンを採用した。stale-pickup-reaper は
   コマンド形が wrapper と一致するため wrapper 経由（`grl_issue_snapshot_or_live` は reaper が使用）。
3. **REST offload 対象は 3 箇所（design 記載の 4 箇所ではない）**: design は
   `slot-worker-resume.sh:318,1017` の 2 箇所を挙げるが、`:318` は design-PR probe（`--search
   ... in:head` の prefix 検索）で単一 branch の `--head <branch> --state all` ではないため
   REST `pulls?head=owner:branch`（厳密 branch 指定）へ逃がせない。差し替えは resume:1017 /
   stage-checkpoint:192 / :694 の 3 箇所。gate off fallback は superset `--json` + `--limit 20`
   で結果等価（呼び出し側は自 field を jq 抽出し `.[0]`/state 選択のため存在判定は不変）。
4. **degrade skip ログは `grl_warn` 経由**: Req 4.1 が WARN を要求するため
   `gh-rate-limit: WARN: skip processor=... reason=degrade bucket=graphql remaining=... threshold=...`
   の 1 行で出力（design の literal は "WARN:" を省いていたが、grep 対象 token は全て含む）。

上記 1–4 はいずれも実装を正しくするための解釈であり、spec 本文の書き換えは行っていない。
Architect / reviewer の確認が必要な場合は本 PR で判断されたい。それ以外の確認事項: なし。

## 実行した検証コマンドとその結果

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/watcher-config.sh local-watcher/bin/modules/*.sh && bash -n local-watcher/bin/issue-watcher.sh` → PASS（新規警告 0）
- 全 test suite（`local-watcher/test/*_test.sh` 108 本）→ 108 passed / 0 failed
- config 正規化 smoke: 不正値（`TRUE` / `-5` / `abc` / `0` / `on`）→ すべて安全側既定へ正規化を確認
- module load + gate-off no-op smoke: 全 gate off で `grl_*` が gh を 1 度も呼ばず（NFR 1.1）、
  snapshot=inactive / buckets STATUS=disabled / degrade=常に run を確認
- 実エントリポイント dry-run: config parse + 全 module load 成功（`git pull origin` で停止 =
  live GitHub 不在のため想定内。新規 module の syntax/wiring クラッシュなし）
- 新規公開 IF 追加で失敗した既存テストは fixture 追従で全 green 化（Issue #410）:
  auto-merge* ×3 / dr_unblock_sweep / po_staged / sr_marker_state / sr_wiring /
  stage_a_verify_round1_defer

## 派生タスク候補（次 Issue）

- config 起動サマリ行（`base-branch=... full-auto=...`）へ `gh-api-guard=` 状態の追記（可観測性向上）
- graphql 以外（core / search）バケットの縮退閾値対応（現状は graphql 単一閾値 / design Non-Goal）

STATUS: complete
