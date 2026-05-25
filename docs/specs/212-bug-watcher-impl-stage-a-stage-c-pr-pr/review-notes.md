# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-25T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-212-impl-bug-watcher-impl-stage-a-stage-c-pr-pr
- HEAD commit: 88b2f5b
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh`（新規 `stage_c_existing_pr_guard` + Stage C call site）/
  `local-watcher/test/stage_c_existing_pr_guard_test.sh`（新規）/ `README.md`（1 段落追記）/
  spec 配下 docs

## Feature Flag Protocol 採否確認

- `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しない → opt-out として解釈。
  flag 観点（boundary 逸脱細目）は適用せず、通常の 3 カテゴリ判定のみを実施した。

## Verified Requirements

- 1.1 — gate=true 時に Stage C 直前で `stage_checkpoint_find_impl_pr` を呼んで観測。call site は
  `run_impl_pipeline` の `--- Stage C 実行 ---` 直後（issue-watcher.sh:4908）。テスト OPEN/MERGED/CLOSED 各ケースで観測・ログ出力を assert
- 1.2 — `STAGE_CHECKPOINT_ENABLED` が `true` 以外で即 `return 1`、副作用ゼロ（issue-watcher.sh:1242-1244）。
  test「gate=false / gate=任意値」で return 1・gh 未呼出・ログ無を assert
- 1.3 — OPEN/MERGED/CLOSED を `case "$pr_state"` で区別判定（issue-watcher.sh:1269-1306）
- 1.4 — サイクル開始時の `resolve_resume_point` とは別に Stage C 直前で再観測（call site 追加 issue-watcher.sh:4902-4911）。
  test の sanity grep で配線存在を確認
- 2.1/2.2 — OPEN 検出時に新規作成へ進まず return 0（test「OPEN: return 0」）
- 2.3 — OPEN 時に PR 番号・state を `sc_log` で出力（`state=OPEN` / `210,OPEN` を assert）
- 2.4 — OPEN 時 gh 未呼出 = Issue コメントなし（test「OPEN: gh 未呼出」）
- 3.1/3.2 — MERGED 検出時 return 0 停止（test「MERGED: return 0」）
- 3.3 — MERGED 時に PR 番号・state をログ出力（`state=MERGED` / `208,MERGED`）
- 3.4 — MERGED 時 gh 未呼出 = コメントなし
- 4.1/4.5 — CLOSED 検出時に新規作成抑止 + return 0（test「CLOSED: return 0」）
- 4.2 — CLOSED 時に `gh issue edit --add-label needs-decisions`（`--add-label needs-decisions` を assert）
- 4.3 — CLOSED 時に PR 番号 + 人間判断要旨のコメント 1 件（gh 呼出 2 回 / `issue comment 212` を assert）
- 4.4 — `mark_issue_failed` 不使用 = `claude-failed` 不付与（`claude-failed` を含まないことを assert）
- 5.1/5.2 — none(rc=1) で return 1 → 従来の PR 作成経路へ。gh 未呼出・ログ無で user-observable 挙動不変
- 6.1 — gh API エラー(rc=2) で `sc_warn`（`WARN:` を assert）
- 6.2 — API エラー時に作成方向へ return 1 フォールバック（既存 `resolve_resume_point` の fallback と同方針）
- 6.3 — API エラー時に「二重 PR の可能性」警告ログ（`二重 PR` を assert）
- NFR 1.1 — none ケースで return 1 → 従来作成経路、PR 1 本不変
- NFR 1.2 — gate!=true で差分ゼロ（return 1 / gh 未呼出 / ログ無を assert）
- NFR 1.3 — 新 env var 追加なし。`STAGE_CHECKPOINT_ENABLED` 既定 true を流用、意味・既定値不変
- NFR 1.4 — CLOSED は既存 `LABEL_NEEDS_DECISIONS` のみ付与、`claude-failed` 不付与
- NFR 1.5 — OPEN/MERGED/CLOSED は既存 TERMINAL_OK と同一 return 0、none/API/想定外は従来経路。exit code 意味不変
- NFR 1.6 — `sc_log` / `sc_warn`（`stage-checkpoint:` prefix）と TERMINAL_OK の `✅` / `tee -a "$LOG"` 表示を踏襲。
  既存 line 1111 の `sc_warn ... >> "$LOG"` と同一書式
- NFR 2.1/2.2 — gate=true + OPEN/MERGED/CLOSED で作成抑止（return 0）= 同一 head に 2 回到達しても 1 本超えない
- NFR 3.1 — 抑止理由 `reason=reuse-open-pr|already-merged|human-closed` を grep 可能粒度で出力
- NFR 3.2 — `existing-impl-pr=unknown reason=gh-api-error fallback=create` を grep 可能粒度で出力

## Findings

なし

## Boundary / Out of Scope 確認

- diff hunk は 2 箇所のみ（`@@ -1206 ... stage_checkpoint_resolve_resume_point` 直後への新関数追加 /
  `@@ -4794 ... run_impl_pipeline` への 10 行 call site 追加）。既存ロジックの書き換えは無し
- `stage_checkpoint_resolve_resume_point` 本体（サイクル開始時観測）は未変更（Out of Scope 遵守）
- 重複 PR の自動 close / 削除なし（CLOSED 時もラベル付与とコメントのみ、PR には触れない）
- Stage A 越境防止・PR 本文補正・gh 以外の検出手段は導入していない
- call site は `_assert_base_branch_resolved`（#96 Req 1.5）より前に置かれるが、guard が return 0 で
  停止する場合は PR 作成に到達せず BASE_BRANCH 不要。return 1 時は既存の BASE_BRANCH 検証順序が保持される
- 後方互換: env var 名 / ラベル遷移契約 / exit code 意味 / ログ書式いずれも不変

## 検証コマンド結果

- `bash local-watcher/test/stage_c_existing_pr_guard_test.sh` → PASS 26 / FAIL 0
- `bash -n local-watcher/bin/issue-watcher.sh` → 構文 OK
- `shellcheck local-watcher/bin/issue-watcher.sh` → SC2317 info のみ（main baseline と同一件数、新規警告ゼロ）
- 既存テスト 15 ファイル全 PASS（回帰なし。`stagec_pr_verify_test.sh` 含む）

## Summary

全 Requirement（1〜6）・NFR（1〜3）の numeric AC が実装とテストで観測可能にカバーされ、26 アサーション
全 pass・既存 15 テスト回帰なし。Out of Scope 越境・後方互換破壊は検出されず。

RESULT: approve
