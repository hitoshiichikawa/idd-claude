# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-397-impl-fix-pr-iteration-no-progress-design-roun
- HEAD commit: cff361e730d40df2fb89da931d326033ece23252
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/modules/pr-iteration.sh`（+88 / -7 行）
  - `local-watcher/test/pi_classify_round_outcome_test.sh`（新規 +226 行 / 24 ケース）
  - `docs/specs/397-fix-pr-iteration-no-progress-design-roun/requirements.md`（新規）
  - `docs/specs/397-fix-pr-iteration-no-progress-design-roun/impl-notes.md`（新規）

CLAUDE.md に `## Feature Flag Protocol` 節の `**採否**:` 宣言は存在しないため、flag 観点の
追加判定は適用せず、通常の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）で判定した。

## Verified Requirements

- 1.1 — `pi_run_iteration` 内 `case "$outcome" in no-progress) ... return 1`（`pr-iteration.sh:1465-1471`）
  により `pi_finalize_labels_design` を呼ばずに復帰。Test:
  `pi_classify_round_outcome false 1 3 → no-progress`（`pi_classify_round_outcome_test.sh:68-79`）
- 1.2 — no-progress 分岐のログは `action=no-progress`（`pr-iteration.sh:1470`）。`action=success` を含まない
- 1.3 — `needs-iteration` ラベルが据え置かれるため `pi_fetch_candidate_prs` の
  `label:"$LABEL_NEEDS_ITERATION"` フィルタに次サイクルも合致（implicit / 削除コードなし）
- 2.1 — `pi_write_marker "$pr_number" "$next_round" "$new_streak"`（`pr-iteration.sh:1444`）が
  outcome 分類より前に実行されるため streak は永続化される（修正前の挙動を温存）
- 2.2 — `pi_classify_round_outcome false <streak<limit> <limit> → no-progress`（`return 1` 経路）。
  Test: 累積シナリオ round=1/2（`pi_classify_round_outcome_test.sh:117-129`）
- 2.3 — `escalate` 分岐で `pi_escalate_to_failed ... no-progress`（`pr-iteration.sh:1457-1463`）。
  Test: streak=3/4/10 with limit=3（`pi_classify_round_outcome_test.sh:97-107`）+ 境界値 limit=0/1
- 2.4 — escalate ログ `... no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT}
  reason=no-progress escalate`（`pr-iteration.sh:1461`、`limit=` 新規追加）
- 3.1 — `success) :` で kind dispatch ブロックにフォールスルー（`pr-iteration.sh:1473-1499`）。
  Test: commit_pushed=true は streak 値に依らず success（4 ケース）
- 3.2 — 既存ロジック温存（`if [ "$commit_pushed" = "true" ]; then new_streak=0`、`pr-iteration.sh:1430-1431`）
- 3.3 — 既存 `action=success (needs-iteration -> awaiting-design-review/ready-for-review)` ログを温存
  （`pr-iteration.sh:1489 / 1495`）
- 4.1 — `pi_classify_round_outcome` は kind を引数に取らない純粋関数。Test:
  「同入力で同 outcome」検証（`pi_classify_round_outcome_test.sh:215-220`）
- 4.2 — no-progress 分岐は `return 1` で kind dispatch に到達しないため `pi_finalize_labels` も呼ばれない
- 4.3 — 既存 `impl)` case ブロックは outcome=success のときのみ到達するため挙動不変
- 5.1 — `pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak}
  limit=${PR_ITERATION_NO_PROGRESS_LIMIT}"`（`pr-iteration.sh:1440`、design/impl 両 kind で出力）
- 5.2 — no-progress 分岐ログは `action=no-progress`（`pr-iteration.sh:1470`）で `action=success` を含まない
- 5.3 — escalate ログに `reason=no-progress` + `no-progress-streak=` + `limit=` を含む（`pr-iteration.sh:1461`）
- NFR 1.1 — `PR_ITERATION_NO_PROGRESS_LIMIT` / `PR_ITERATION_DESIGN_ENABLED` 等の env var の
  宣言・既定値は無変更
- NFR 1.2 — ラベル定数（`LABEL_NEEDS_ITERATION` / `LABEL_AWAITING_DESIGN` / `LABEL_READY` /
  `LABEL_FAILED`）の名称・付与責務は無変更
- NFR 1.3 — commit 有り round の挙動（finalize 経路・success ログ・return 0）を温存
- NFR 2.1 — `pi_classify_round_outcome` の不正値（空文字列 / 非数値 / typo）は安全側で
  `no-progress` に倒れる。Test 6 ケース（`pi_classify_round_outcome_test.sh:163-194`）
- NFR 2.2 — 既存 `pi_write_marker` 失敗時の `pi_error + return 1`（`pr-iteration.sh:1444-1447`）を温存

## Findings

なし

## Summary

`pi_classify_round_outcome` 純粋関数の新規追加と `pi_run_iteration` 末尾の 3-way 分岐
（success / no-progress / escalate）により、no-progress design round の silent deadlock を
解消する変更。全 numeric AC（1.1-1.3 / 2.1-2.4 / 3.1-3.3 / 4.1-4.3 / 5.1-5.3 / NFR 1.1-1.3 /
NFR 2.1-2.2）が実装または既存挙動温存でカバーされており、新規 24 テストケースが該当ヘルパーを
網羅検証。boundary は対象モジュール（`local-watcher/bin/modules/pr-iteration.sh`）と
近接テスト（`local-watcher/test/`）に限定されており、`repo-template/` 配布物・env var 名・
ラベル名・既存 return code 意味への破壊的変更なし。`shellcheck` / `bash -n` クリーン、新規
テスト 24 PASS / 0 FAIL を再現確認。

RESULT: approve
