# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-354-impl-feat-watcher-pr-auto-merge-awaiting-desi
- HEAD commit: cb6575f4073386a11b6280c83916c7684912153f
- Compared to: main..HEAD（実 merge-base は `fe56aeb`。`git diff main..HEAD` には base 側
  の前進分（#356 / #357 由来の `pt_post_marker_classify_test.sh` 削除、`developer.md` 編集等）
  が含まれていたため、本レビューは `git diff fe56aeb..HEAD` を用いて当該ブランチで
  追加された差分のみを評価対象とした）
- 検証コマンド（reviewer 側で再実行）:
  - `bash -n local-watcher/bin/modules/auto-merge-design.sh local-watcher/bin/issue-watcher.sh` → OK
  - `shellcheck local-watcher/bin/modules/auto-merge-design.sh local-watcher/bin/issue-watcher.sh` → OK（警告ゼロ）
  - `bash local-watcher/test/auto-merge-design_test.sh` → PASS=61 FAIL=0
  - `bash local-watcher/test/pr_publish_commit_status_test.sh` → PASS=74 FAIL=0
  - `bash local-watcher/test/auto-merge_test.sh` → PASS=56 FAIL=0（既存挙動回帰なし）
  - `bash local-watcher/test/full_auto_enabled_test.sh` → PASS=28 FAIL=0（既存挙動回帰なし）

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh` Config に `AUTO_MERGE_DESIGN_ENABLED="${AUTO_MERGE_DESIGN_ENABLED:-false}"` を追加（既定 false）
- 1.2 — `process_auto_merge_design` 先頭で `full_auto_enabled || return 0` と `amd_resolve_gate_enabled` の AND 評価
- 1.3 — `amd_resolve_gate_enabled` が `case "${AUTO_MERGE_DESIGN_ENABLED:-false}" in true) ... ;; *) ... ;; esac` で `=true` 厳密一致以外を OFF に正規化（test Section 1 で `true` / `false` / `0` / `True` / `TRUE` / `1` / `on` / `yes` / `enable` / `tRue` / `"  true  "` / `trues` / 空文字 / 未設定 を網羅検証）
- 1.4 — `process_auto_merge_design` の `full_auto_enabled || return 0`（test Case B で検証）
- 1.5 — gate OFF 時は早期 return で gh API 呼び出しゼロ（test Case A / B / C で gh 呼び出し 0 を assert）
- 2.1 — `amd_should_enable_for_pr` が `AUTO_MERGE_DESIGN_HEAD_PATTERN`（既定 `^claude/issue-.*-design`）で head ref を検証 + server-side `--search` で head pattern を絞る
- 2.2 — `isDraft` チェック（test PR_DRAFT / Case F）
- 2.3 — `mergeable=MERGEABLE` のみ通過（test PR_OK / Case D）
- 2.4 — `mergeable=CONFLICTING` skip（test PR_CONFLICT / Case E）
- 2.5 — `mergeable=UNKNOWN` skip（test PR_UNKNOWN）
- 2.6 — head pattern による client-side filter で impl PR (`-impl`) は不一致除外（test PR_IMPL / Case I）
- 3.1 — `amd_enable_auto_merge_for_pr` が `gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number"` を呼ぶ（test で `--auto` / `--squash` / `--delete-branch` / `-- 100` 全フラグの exactly-once 呼び出しを assert）
- 3.2 — `gh pr merge --auto` のみ。`git merge` / `git push` への直接 base 変更なし（grep 確認）
- 3.3 — 単一 API 呼び出しのみで polling / sleep / バックグラウンド処理なし
- 3.4 — `--delete-branch` フラグを含む（test で flag assert）
- 4.1 — `pr_publish_commit_status_test.sh` Section 5 Case 5.A / 5.B で design head sha への `codex-review` publish と state success / failure を検証（既存 #349 経路の流用確認 / コード変更なし）
- 4.2 — Section 5 Case 5.E / 5.F で design head sha への `claude-review` publish を検証
- 4.3 — Case 5.A / 5.E で approve → state=success
- 4.4 — Case 5.B / 5.F で needs-iteration / reject → state=failure
- 4.5 — Case 5.E で target_url に DESIGN_SHA が含まれることを assert（latest-wins 補強）
- 4.6 — Case 5.C で `PR_REVIEWER_STATUS_CHECK_ENABLED` 未設定時 gh 呼び出しゼロ + suppression ログ 1 行、Case 5.D で `FULL_AUTO_ENABLED` 未設定時 gh 呼び出しゼロ
- 5.1 — `amd_*` 関数群に `--add-label` / `--remove-label` / `gh issue edit` 呼び出しなし（grep 確認）
- 5.2 — `process_auto_merge_design` は `process_design_review_release` を呼ばない（main loop の独立配線）
- 5.3 — Design Review Release Processor (#40) のコード変更なし（既存挙動温存）
- 5.4 — `DESIGN_REVIEW_RELEASE_ENABLED` 関連の env / 関数変更なし
- 6.1 — `needs-rebase` ラベル操作なし（grep 確認）
- 6.2 — `claude-failed` ラベルを `amd_should_enable_for_pr` で除外 + server-side `-label:"$LABEL_FAILED"` で除外
- 6.3 — `needs-decisions` 同上
- 6.4 — `needs-iteration` 同上（test PR_NEEDS_ITER / Case G）
- 6.5 — review dismiss コマンド呼び出しなし
- 6.6 — `autoMergeRequest` 既存時に rc=2 を返し冪等 skip（test PR_ALREADY / Case J で `auto-merge already enabled` ログを assert）
- 6.7 — `modules/auto-merge.sh` (#352) のコード変更なし。head pattern 排他で非干渉（test Case I）
- 7.1 — stderr 内容から `api-error` カテゴリで WARN log（test 422 fixture）
- 7.2 — `transport-error` カテゴリ（test "could not resolve host" fixture）
- 7.3 — `process_auto_merge_design` は失敗時も rc=0（test Case K の `assert_rc 0 process_auto_merge_design`）
- 7.4 — 失敗時必ず `amd_warn` 出力（test で WARN log line count を assert）
- 7.5 — `repo-config-rejected` カテゴリ（test "Auto merge is not allowed" fixture）
- 8.1 — gate OFF 時 gh ゼロ呼び出し（test Case A / B / C）
- 8.2 — gate OFF 時に他 processor の env を変えず副作用ゼロ（コード目視確認）
- 8.3 — head pattern 不一致時 client-side filter で skip（Case H で手書き branch を skip）
- 8.4 — 既存 processor のコード変更は call site への 1 行追加と `REQUIRED_MODULES` 配列への 1 要素追加、Config への env 追加のみ（既存挙動温存 / 既存 env / ラベル / cron 文字列いずれも変更なし）
- 9.1 — `amd_log "PR #${pr_number}: auto-merge enabled (squash, delete-branch) head=${head_ref} sha=${head_sha} url=${pr_url}"`（test で PR 番号 / head / sha を含むことを assert）
- 9.2 — `amd_log "suppressed by AUTO_MERGE_DESIGN_ENABLED gate (no-op)"` を 1 行出力（test Case C で count=1 を assert）
- 9.3 — `full_auto_enabled` OFF 経路では log を出さない（test Case B で suppression ログ count=0 を assert）
- 9.4 — cycle startup ログに `auto-merge-design=${AUTO_MERGE_DESIGN_ENABLED}` を `auto-merge=` と `full-auto=` の間に追加（impl-notes.md Task 8 で dry-run smoke 観測ログ記録あり）
- NFR 1.1 — jq に `--arg` で値展開（`amd_should_enable_for_pr` の label 判定、`process_auto_merge_design` の filter）
- NFR 1.2 — `gh pr merge` 呼び出しで `--` 打ち切り（test で `-- 100` 形式を assert）
- NFR 1.3 — `amd_enable_auto_merge_for_pr` / `process_auto_merge_design` 双方で PR 番号を `grep -qE '^[0-9]+$'` 検証
- NFR 1.4 — head ref を `grep -qE -- "$AUTO_MERGE_DESIGN_HEAD_PATTERN"` で検証
- NFR 2.1 — 既定値 `false` で gate OFF、未設定環境では gh API 呼び出しゼロ（既存挙動温存）
- NFR 2.2 — 既存 env 名（`FULL_AUTO_ENABLED` / `AUTO_MERGE_ENABLED` / `DESIGN_REVIEW_RELEASE_ENABLED` / `PR_REVIEWER_STATUS_CHECK_ENABLED` 等）変更なし、ラベル名変更なし
- NFR 2.3 — `auto-merge.sh` / `pr-reviewer.sh` / Design Review Release Processor 等の既存関数 signature 変更なし
- NFR 3.1 — `amd_enable_auto_merge_for_pr` は 1 PR 1 回の `gh pr merge` のみ
- NFR 3.2 — polling / sleep / バックグラウンド処理なし
- NFR 4.1 — README オプション機能一覧表に `AUTO_MERGE_DESIGN_ENABLED` 行追加
- NFR 4.2 — README に Allow auto-merge / Required status checks（`codex-review` / `claude-review` + CI）の設定手順を追記
- NFR 4.3 — README に `DESIGN_REVIEW_RELEASE_ENABLED` (#40) との共存節を追加
- NFR 4.4 — `.claude/agents` / `.claude/rules` / workflow / labels 等の dual-management 対象には変更なし（diff stat で確認）
- NFR 5.1 — `shellcheck` + `bash -n` クリーン（reviewer 側で再実行確認）
- NFR 5.2 — `auto-merge-design_test.sh` で全 10 検証ケース（gate 値正規化 / head pattern / draft / mergeable / 既 enabled / `gh pr merge` exactly once / 失敗 3 分類 / 両 gate OFF / FULL_AUTO OFF / 失敗時 rc=0）を網羅、PASS=61
- NFR 5.3 — `pr_publish_commit_status_test.sh` Section 5 で design PR head fixture 経路 6 ケース追加、PASS=74（baseline 53 → +21 assertion）
- NFR 6.1 — `install.sh` の既存 module 配布 glob により自動配置（コード変更不要）
- NFR 6.2 — `REQUIRED_MODULES` 配列に `"auto-merge-design.sh"` を `"auto-merge.sh"` 直後に追加

## Findings

なし

## Summary

#354 の 8 タスクは tasks.md 通りに完遂されており、全 numeric requirement ID（Req 1.1〜9.4 / NFR 1.1〜6.2）が実装またはテストで観測可能にカバーされている。`_Boundary:_` で許可された範囲（`modules/auto-merge-design.sh` 新規 / `issue-watcher.sh` Config・Loader・MainLoop / `test/auto-merge-design_test.sh` 新規 / `test/pr_publish_commit_status_test.sh` 追加 / `README.md`）を逸脱する変更はなく、既存 `modules/auto-merge.sh` (#352) / `modules/pr-reviewer.sh` (#349) / Design Review Release Processor (#40) のコード変更はゼロ。reviewer 側で再実行した `shellcheck` / `bash -n` / 全 4 テストファイル（新規 + 既存回帰）はすべて green（PASS 合計 219 / FAIL 0）。

RESULT: approve
