# Implementation Plan

各タスクは 1 commit 単位で独立完了可能。段階導入順は「snapshot 基盤 → 参加 processor 差し替え →
可視化 → 縮退 → リトライ → REST 逃がし → README → 全体検証」。全 gate 既定 off のため、各タスク
commit 時点で未設定環境の挙動は不変（NFR 1.1）。

- [x] 1. snapshot 基盤 module・config・cycle 配線
  - `local-watcher/bin/modules/api-rate-guard.sh` を新規作成（prefix `grl_` / 関数定義のみ・トップレベル副作用なし / ファイル冒頭ヘッダに用途・prefix・依存を明記）
  - `grl_snapshot_init` / `grl_snapshot_active` / `grl_snapshot_prs` / `grl_snapshot_issues` / `grl_pr_snapshot_or_live` / `grl_issue_snapshot_or_live` を実装（超集合フィールド union は design 参照。`mktemp`→`mv` の atomic 書込・`GRL_SNAPSHOT_STATUS` グローバルで active 管理）
  - 取得失敗時は `grl_warn` 出力 + active=off で fallback（Req 2.5, 2.6 / NFR 2.1）。gate off / 未設定 / 不正値は no-op（Req 1.1, 1.2, 1.3）
  - `core_utils.sh` に `grl_log` / `grl_warn` / `grl_error`（prefix `gh-rate-limit:` / 既存 `qa_log` と同形式）を追加
  - `watcher-config.sh` に `GH_API_SNAPSHOT_ENABLED` / `_PR_LIMIT` / `_ISSUE_LIMIT` / `_DIR` / `_GH_TIMEOUT` を定義・正規化（`true` 厳密一致・数値は非整数/≤0 を既定へ）。既存 env 名は非変更（Req 1.4, 1.5, 1.6）
  - `issue-watcher.sh` の `REQUIRED_MODULES` へ `"api-rate-guard.sh"`（`env-loader.sh` 直後）を追加し、repo 最新化直後・`process_quota_resume` 直前へ `grl_snapshot_init || grl_warn ...` を配線（Req 2.1, 2.2）
  - `local-watcher/test/api_rate_guard_snapshot_test.sh` を追加（`extract_function` + fixture。超集合取得・accessor・active 判定・取得失敗時 fallback・gate off no-op を live API なしで検証 / NFR 6.2）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 2.1, 2.2, 2.5, 2.6_

- [x] 2. PR snapshot 差し替え: merge / auto-merge 系 (P)
  - Inventory #1〜#6 の 5 module（`merge-queue.sh`（recheck 含む）/ `auto-rebase.sh` / `auto-merge.sh` / `auto-merge-design.sh` / `auto-merge-disarm.sh`）の `gh pr list` を `grl_pr_snapshot_or_live` 経由へ差し替え
  - snapshot 参照時、各 module の client jq を現行 `--search` 全条件で再現（design「等価性ルール」表。例: merge-queue へ `-label:needs-rebase` / `-label:failed` の `index==null` select 追加、auto-rebase の `label:needs-rebase` 包含）— gate off の live 経路は byte 等価に保つ（Req 2.3）
  - 鮮度クリティカル（Dispatcher 候補 / check_existing_impl_pr）は差し替えず個別取得を維持（Req 2.4）
  - 各 module の fixture テストに「snapshot 参照 client jq が server search と等価集合を返す」ケースを追加（merge-queue の label 除外・auto-rebase の `label:needs-rebase` 包含・Dispatcher 非参加を代表検証。live API なし）
  - _Requirements: 2.3, 2.4_
  - _Boundary: merge-queue, auto-rebase, auto-merge, auto-merge-design, auto-merge-disarm_
  - _Depends: 1_

- [x] 3. PR snapshot 差し替え: review 系 (P)
  - Inventory #7〜#10 の 4 module（`pr-iteration.sh` / `pr-reviewer.sh` / `pr-design-reviewer.sh` / `security-review.sh`）の `gh pr list` を `grl_pr_snapshot_or_live` 経由へ差し替え、client jq を現行 `--search` 全条件（`-draft:true` = `isDraft==false` 等）で再現（Req 2.3）
  - gate off の live 経路は byte 等価に保つ
  - 各 module の fixture テストに snapshot 参照時の等価集合ケースを追加（`-draft:true` 相当の client 絞り込み / live API なし）
  - _Requirements: 2.3_
  - _Boundary: pr-iteration, pr-reviewer, pr-design-reviewer, security-review_
  - _Depends: 1_

- [x] 4. Issue snapshot 参加 processor の差し替え (P)
  - Inventory #11〜#14 の 4 module（`dependency-resolver.sh` / `path-overlap.sh` / `stale-pickup-reaper.sh` / `quota-aware.sh`）の `gh issue list` を `grl_issue_snapshot_or_live` 経由へ差し替え、client jq を現行 `--search` で再現（Req 2.3）
  - 参加条件「対象集合 ⊆ (open ∧ auto-dev)」を各 module のコメントに明記。gate off 時は live 経路で byte 等価
  - 各 module の fixture テストに snapshot 参照時の等価集合ケースを追加（reaper の `label:claude-picked-up` 絞り込み等 / live API なし）
  - _Requirements: 2.3_
  - _Boundary: dependency-resolver, path-overlap, stale-pickup-reaper, quota-aware_
  - _Depends: 1_

- [ ] 5. バケット別残量の可視化
  - `api-rate-guard.sh` に `grl_buckets_refresh`（`gh api rate_limit` → core/graphql/search の remaining/limit をグローバルへ / 非消費経路 / 失敗は warn + 継続）と `grl_buckets_log`（cycle 終端に固定書式 1 行 `gh-rate-limit: core=<r>/<l> graphql=<r>/<l> search=<r>/<l>` を `LOG_DIR` へ）を実装（Req 3.1, 3.2, 3.3, 3.4）
  - `watcher-config.sh` に `GH_API_BUCKET_LOG_ENABLED`（既定 false / `true` のみ ON）を追加
  - `issue-watcher.sh` の cycle 終端（`echo 完了` 直前）へ `grl_buckets_log || true` を、repo 最新化直後へ `grl_buckets_refresh || true`（degrade 用 / 後続 task 6 が参照）を配線
  - `local-watcher/test/api_rate_guard_degrade_test.sh` に bucket parse・固定書式・取得失敗継続（Req 3.4）を fixture 検証（`gh` stub / live API なし）
  - _Requirements: 3.1, 3.2, 3.3, 3.4_
  - _Depends: 1_

- [ ] 6. 残量閾値割れ時の WARN と縮退
  - `api-rate-guard.sh` に `grl_degrade_should_run <processor名>` を実装（`GH_API_DEGRADE_ENABLED=true` かつ graphql 残量 < `GH_API_DEGRADE_GRAPHQL_THRESHOLD` で WARN + 非必須は rc=1 skip・essential 名は常に rc=0。gate off は常に rc=0 = 従来挙動 / Req 4.6）
  - skip 時に `gh-rate-limit: skip processor=<name> reason=degrade bucket=graphql remaining=<r> threshold=<t>` を出力（Req 4.5 / WARN に bucket・残量・閾値含む）
  - `watcher-config.sh` に `GH_API_DEGRADE_ENABLED`（既定 false）と `GH_API_DEGRADE_GRAPHQL_THRESHOLD`（既定 500 / 保守的 / 非整数・<0 を既定へ）を追加（Req 4.4）
  - `issue-watcher.sh` の非必須 7 call site（pr-reviewer / claude-review-catchup / claude-review-merge-gate-visibility / pr-design-reviewer / security-review / pr-iteration / failed-recovery）を `grl_degrade_should_run "<name>" && { process_X || xxx_warn ...; }` で gate。essential（dispatch / merge / 状態遷移 / reaper / release）は gate せず常時実行（Req 4.3 / NFR 2.2）
  - `api_rate_guard_degrade_test.sh` に「閾値割れで非必須 skip / essential 名は run / gate off で全 run」を fixture 検証
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6_
  - _Depends: 1, 5_

- [ ] 7. 状態遷移系ラベル操作の限定リトライ
  - `api-rate-guard.sh` に `grl_retry_label_op <issue番号> <gh issue edit 引数...>` を実装（`GH_API_STATE_RETRY_ENABLED=true` 時のみ、rate-limit 文言検出時に `GH_API_STATE_RETRY_MAX_ATTEMPTS` まで `GH_API_STATE_RETRY_SLEEP` 秒 backoff 再試行。非 rate-limit 失敗は再試行せず即返す。gate off は 1 回実行 = 従来挙動）
  - 試行ごとに `gh-rate-limit: retry issue=#<N> op=<label操作> attempt=<i>/<max>` を出力（Req 5.6）。上限到達でも `claude-picked-up` を残置し次 tick 再評価（孤児化しない / holder ラベル誤除去を発生させない / Req 5.4, 5.5）
  - `watcher-config.sh` に `GH_API_STATE_RETRY_ENABLED`（既定 false）/ `GH_API_STATE_RETRY_MAX_ATTEMPTS`（既定 3 / 有限）/ `GH_API_STATE_RETRY_SLEEP`（既定 2）を追加
  - resumable-return の `claude-picked-up` 除去箇所（`impl-pipeline.sh:273-281` の per-task hold・同ファイル resumable hold・`slot-worker.sh:386-387`）を `grl_retry_label_op` 経由へ差し替え（対象は「LABEL_PICKED を除去し LABEL_FAILED を付けない」= 再 pickup 復帰系のみ）
  - `local-watcher/test/api_rate_guard_retry_test.sh` に rate-limit fixture での N 回試行・非 rate-limit 1 回・上限打ち切り・gate off 単発を検証（`gh` stub / live API なし）
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_
  - _Depends: 1_

- [ ] 8. GraphQL から REST への負荷分散
  - `api-rate-guard.sh` に `grl_rest_prs_for_head <branch> <state>` を実装（`GH_API_REST_OFFLOAD_ENABLED=true` 時に `gh api "repos/$REPO/pulls" -f head="$owner:$branch" -f state="$state"` で REST core 経由取得し、`gh pr list --head` 互換 JSON へ正規化: `state` は open→OPEN / closed+merged_at→MERGED / closed→CLOSED、`headRefName`=head.ref、`url`=html_url。失敗・gate off は `gh pr list --head` へ fallback / Req 6.1, 6.2, 6.3, 6.4）
  - `watcher-config.sh` に `GH_API_REST_OFFLOAD_ENABLED`（既定 false）を追加
  - per-branch PR 存在確認（`slot-worker-resume.sh:318,1017` / `stage-checkpoint.sh:192,694`）を `grl_rest_prs_for_head` 経由へ差し替え（呼び出し側が参照する number/state/headRefName/url フィールドの互換を保つ）
  - `local-watcher/test/api_rate_guard_rest_test.sh` に REST→JSON 正規化（MERGED 変換）・失敗時 `gh pr list` fallback・gate off で従来経路を fixture 検証（`gh` stub / live API なし）
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
  - _Depends: 1_

- [ ] 9. README 整合
  - README「オプション機能一覧」へ 5 機能の opt-in 手順・有効化時の挙動・既定安全側方針を追記（Req 7.1）
  - 新規 env 12 個の一覧と既定値の表を追記（Req 7.2 / design env 表と一致）
  - バケット可視化ログ（`gh-rate-limit:` 書式）の読み方と縮退の優先順位（essential vs non-essential 分類）を追記（Req 7.3）。GitHub API rate limit と Claude Max quota の用語分離を明記
  - _Requirements: 7.1, 7.2, 7.3_
  - _Depends: 1, 5, 6, 7, 8_

- [ ] 10. 全体整合の検証（統合・no-op 回帰）
  - gate 全 off（既定）で main loop の一覧取得回数・プロセッサ実行順・ログ出力が導入前と一致することを統合テストで確認（Req 1.1 no-op / NFR 1.1）
  - `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/watcher-config.sh local-watcher/bin/modules/*.sh` 新規警告 0・`bash -n` OK を確認（NFR 6.1）
  - dry-run（対象なし・全 gate off）で `処理対象の Issue なし` 正常終了、`GH_API_BUCKET_LOG_ENABLED=true` で終端 1 行ログ出力を smoke 確認
  - スコープは統合 / smoke / no-op 回帰に限定（各 unit テストは task 1〜8 に同梱済み）
  - _Requirements: 1.1_
  - _Depends: 1, 2, 3, 4, 5, 6, 7, 8_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを宣言する。
対象パスは tasks.md commit 時点で存在するもののみ（新規 test ファイルは各 task 内で Developer が実行）。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/watcher-config.sh local-watcher/bin/modules/*.sh && bash -n local-watcher/bin/issue-watcher.sh
```
