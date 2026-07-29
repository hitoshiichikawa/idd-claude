# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-07-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-521-impl-feat-watcher-github-api-rate-limit
- HEAD commit: 097ab7b90d15300c63e34a12fcaa70a63603cc62
- Compared to: main..HEAD

Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節（`**採否**:` 行）が存在しない
ため opt-out 扱いとし、通常の 3 カテゴリ判定（AC 未カバー / missing test / boundary 逸脱）のみを
適用した。全 108 テスト green / `shellcheck`（issue-watcher.sh + watcher-config.sh + modules/*.sh）
新規警告 0 / `bash -n` OK を reviewer 自身で再実行確認済み。

## Verified Requirements

- 1.1 — 各 grl_* 関数が `GH_API_*_ENABLED != "true"` で早期 no-op。`api_rate_guard_snapshot_test.sh`
  ケース1（gate off で gh 非呼び出し / active=off）、degrade/retry/rest 各 test の gate off ケース
- 1.2 — `watcher-config.sh` 新規 12 env の既定を全て false / 安全側数値に固定
- 1.3 — config `case` 正規化 + `api_rate_guard_snapshot_test.sh` ケース2（`TRUE` typo → inactive）
- 1.4 — 追加は `GH_API_*` 名のみ。既存 env 名（REPO/REPO_DIR/LOG_DIR 等）非変更（diff 確認）
- 1.5 — 既存ラベル / exit code / cron 文字列 / LOG_DIR 出力先の変更なし（diff 確認）
- 1.6 — 新規ラベル導入なし（idd-claude-labels.sh は diff 対象外）
- 2.1 — `issue-watcher.sh:409` に `grl_snapshot_init` 配線 + `api_rate_guard_snapshot_test.sh`
  「PR/Issue list 各 1 回」アサート
- 2.2 — `grl_pr/issue_snapshot_or_live` が active 時に file を返し再取得しない（snapshot_test ケース6）
- 2.3 — `api_rate_guard_pr_equiv_test.sh` / `_review_equiv_test.sh` / `_issue_equiv_test.sh`
  （client jq が server `--search` を等価再現。live 経路は byte 等価）
- 2.4 — Dispatcher 候補クエリ（issue-watcher.sh:715/724）/ `check_existing_impl_pr`（gh api graphql）/
  design-PR probe（slot-worker-resume.sh:318 の `--search ... in:head`）は差し替えず個別取得を維持。
  `api_rate_guard_pr_equiv_test.sh` ケース5 で Dispatcher 非参加を検証
- 2.5 — `grl_snapshot_init` 取得失敗で active=off へ fallback（snapshot_test ケース4/5）
- 2.6 — fallback 時に `grl_warn` 出力（snapshot_test ケース4 で `gh-rate-limit: WARN` 確認）
- 3.1 — `grl_buckets_log` を cycle 終端（issue-watcher.sh:902）へ配線 + `api_rate_guard_degrade_test.sh`
- 3.2 — `gh api rate_limit`（非消費経路）で取得。degrade_test が経路を assert
- 3.3 — 固定書式 `gh-rate-limit: core=r/l graphql=r/l search=r/l`（degrade_test ケース2）
- 3.4 — 取得失敗は warn + 継続（degrade_test ケース3）
- 4.1 — `grl_degrade_should_run` が閾値割れで WARN（degrade_test ケース4）
- 4.2 — 非必須 7 call site を `grl_degrade_should_run && { ... }` で gate（issue-watcher.sh diff）
- 4.3 — essential（dispatch / merge / 状態遷移 / reaper / release / Dispatcher）は gate せず常時実行（diff 確認）
- 4.4 — `GH_API_DEGRADE_GRAPHQL_THRESHOLD` 既定 500（保守的）/ env 調整可
- 4.5 — skip ログに processor 名・bucket・残量・閾値（degrade_test が 4 トークン assert）
- 4.6 — gate off は常に rc=0（degrade_test「gate off: 残量僅少でも skip しない」）
- 5.1 — resumable-return 3 箇所（impl-pipeline.sh ×2 / slot-worker.sh ×1）を `grl_retry_label_op` 経由へ差替
- 5.2 — rate-limit 文言検出時のみ再試行 / 非 rate-limit は 1 回（`api_rate_guard_retry_test.sh` ケース3/4）
- 5.3 — `GH_API_STATE_RETRY_MAX_ATTEMPTS` 既定 3（有限）/ retry_test で上限 3 回打ち切り
- 5.4 — 上限到達でも label 残置 + rc 非0 で次 tick 再評価（retry_test ケース3）
- 5.5 — wrapper は既存 gh 引数の rc を変えず回数のみ増やす。差替先は PICKED/CLAIMED 除去のみで FAILED 非付与（diff 確認）
- 5.6 — 再試行ログに issue/op/attempt（retry_test が `retry issue=#42 op=-claude-picked-up attempt=1/3` を assert）
- 6.1 — `grl_rest_prs_for_head` が offload on で `gh api repos/.../pulls?head=` 経由（`api_rate_guard_rest_test.sh` ケース2）
- 6.2 — open→OPEN / closed+merged_at→MERGED / closed→CLOSED 正規化（rest_test ケース2）
- 6.3 — REST 失敗時 `gh pr list --head` へ fallback + warn（rest_test ケース3）
- 6.4 — gate off は従来 GraphQL 経路（rest_test ケース1）
- 7.1 — README「GitHub API Rate Guard (#521)」節に opt-in 手順・既定安全側方針を追記
- 7.2 — README に新規 env 12 個の一覧と既定値表を追記（design env 表と一致）
- 7.3 — README にバケット可視化ログの読み方 + essential/non-essential 縮退優先順表 + 用語分離を追記

## Findings

なし

## Summary

Req 1〜7 の全 numeric AC について、観測可能な実装と live-API 非依存の fixture テストが差分内に
確認できた。全 gate 既定 OFF で新規 API 呼び出しゼロ・live 経路 byte 等価を保つ後方互換設計で、
`_Boundary:_` 逸脱なし（変更ファイルは全て design File Structure Plan / 各 task boundary 内）。
108 テスト green・shellcheck 新規警告 0・bash -n OK を再実行確認済み。

（設計レベルの補足 / 当該 impl PR の reject 理由には含めない）: REST offload の差替は 3 箇所で、
design File Structure Plan が挙げた slot-worker-resume.sh:318 は per-branch の `--head` 呼び出し
ではなく prefix `--search ... in:head` probe のため対象外とした旨が impl-notes に記録されている。
これは Req 6.1 の適用対象（per-branch exact head の存在確認）を正しく満たしており AC 未カバーに
該当しない。design.md の該当記述と実装の食い違いは設計 iteration / 別 Issue で還流すべき軽微な
ドリフトであり、本 impl PR の reject 事由ではない。

RESULT: approve
