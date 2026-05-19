# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-20T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-118-impl-bug-watcher-pr-iteration-round-five-hour
- HEAD commit: 589a0d4643ad5a8884e7f80fb649c01ad7120c1e
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/issue-watcher.sh`（+275/-6）
  - `local-watcher/test/pi_detect_quota_soft_fail_test.sh`（新規 +160）
  - `local-watcher/test/fixtures/pi_detect_quota_soft_fail/*.jsonl`（新規 6 件）
  - `docs/specs/118-bug-watcher-pr-iteration-round-five-hour/{requirements.md,impl-notes.md}`
- 注: 本 spec には `tasks.md` / `design.md` が存在しない（PM のみフロー）。`_Boundary:_` の
  明示は無いが、requirements.md の Out of Scope で `pr-iteration` Processor 限定が明記されており、
  実装は `pi_run_iteration` / `process_pr_iteration` の 2 関数のみに収束しているため、
  境界逸脱は検出されない。

## Verified Requirements

- **1.1** — `pi_detect_quota_soft_fail` jq folder（issue-watcher.sh L1885〜）が
  `type==rate_limit_event` かつ `status==allowed_warning`（top-level / `rate_limit_info` ネスト
  両対応）かつ `surpassedThreshold>=0.9` で検出。`pi_run_iteration` 内で claude stdout を tee
  経由で `pi_soft_fail_file` に書き出し、`soft_fail_observed` フラグで参照。テスト 6 ケース
  （top-level / nested / 境界値 0.85 不検出 / rejected 不検出 / 通常成功 / malformed 行混入）。
- **1.2** — `pi_run_iteration` subshell L2131〜で `has_dirty=true && soft_fail_observed=true`
  分岐 → `pi_auto_commit_and_push` で `git add -A && git commit && git push origin <branch>`。
- **1.3** — `pi_auto_commit_and_push` が `Co-Authored-By: Claude <noreply@anthropic.com>` を
  常時付与。soft-fail commit message は `docs(specs): partial round-${next_round} output before
  quota cutoff (auto-recovered)` 形式（要件と完全一致）。
- **1.4** — 親側 case で `soft-fail-commit:ok` を受けた場合は `pi_finalize_labels*` を呼ばず
  `return 1` を返すため、`needs-iteration` は外れず `ready-for-review` への昇格も行われない。
- **1.5** — `soft-fail-commit:fail` 分岐で `pi_warn` 出力 + `return 1`（needs-iteration 残置）。
- **1.6** — 新規 hunk に `needs-quota-wait` / `qa_handle_quota_exceeded` の追加呼び出しなし
  （grep 確認: 0 matches）。
- **2.1** — round 終了直後に `git status --porcelain` で has_dirty を判定（L2120〜）。
- **2.2** — `has_dirty=true && soft_fail_observed=false` で `post-round-commit` 経路。
- **2.3** — commit message `docs(specs): recover uncommitted round-${next_round} output (auto)`
  + Co-Authored-By 付与（要件と完全一致）。
- **2.4** — `post-round-commit:fail` 分岐で `pi_warn` + `return 1`。
- **2.5** — `if soft_fail_observed=true` が先に評価され、`else (post-round)` に落ちる制御
  フローで優先順位を構造的に保証。
- **3.1** — `process_pr_iteration` 冒頭の dirty 検出時に
  `pi_log "pre-cycle dirty 検出 issue=#... branch=... paths=..."` を出力（一致 / 不一致
  双方の経路で出力）。
- **3.2** — `pi_branch_is_claude_pr_head` 一致時に `pi_auto_commit_and_push` 実行 → 成功で
  BASE_BRANCH に戻して本処理継続。テスト 2 ケース（`claude/issue-118-impl-foo` /
  `claude/issue-42-design-bar`）で正規表現マッチ確認。
- **3.3** — commit message `docs(specs): recover pre-cycle dirty state on ${_pi_pre_branch}
  (auto)` + Co-Authored-By（要件と完全一致）。
- **3.4** — `pi_branch_is_claude_pr_head` 不一致時に `pi_error` + `return 0`（skip）。テスト
  4 ケース（main / develop / hitoshi/manual-work / `claude/no-issue-prefix` / 空文字列）。
- **3.5** — `pi_auto_commit_and_push` 失敗時に `pi_error "pre-cycle-recover ... action=fail"`
  + `return 0`。
- **4.1** — `pi_log "PR #${pr_number}: kind=${kind} round=${next_round} quota-soft-fail
  utilization=${soft_fail_summary} action=auto-commit+keep-label"` 1 行出力（grep 集計可能）。
- **4.2** — `pi_log "...post-round-recover branch=... action=success"` および
  `pi_log "pre-cycle-recover issue=#... branch=... action=success"` の 1 行ログ出力。
- **4.3** — `pi_warn` / `pi_error` は既存定義のまま `>&2` 出力（NFR 1.2）。
- **5.1** — `pi_detect_quota_soft_fail` は `QUOTA_AWARE_ENABLED` を参照せず、tee pipe で常時
  起動（QUOTA_AWARE_ENABLED の有無にかかわらず動作）。
- **5.2** — `process_pr_iteration` 冒頭の dirty 自動回復ロジックも QUOTA_AWARE_ENABLED 非依存。
- **5.3** — 新規 hunk に dispatcher 連携（`needs-quota-wait` / `qa_handle_quota_exceeded`）の
  追加なし（grep 0 matches）。
- **NFR 1.1** — `recover_status="none:"` の original path で従来の `pi_finalize_labels*`
  呼び出しがそのまま通過する制御フロー。既存ラベル遷移は保持。
- **NFR 1.2** — `pi_log` / `pi_warn` / `pi_error` の関数定義は無変更。新規ログも同 prefix。
- **NFR 1.3** — `PR_ITERATION_*` / `QUOTA_AWARE_ENABLED` ほか既存 env var の意味と既定値変更なし。
- **NFR 2.1** — fixture ベースの独立テスト（6 検出ケース + 7 branch ガードケース）で 4 分岐
  検証可能。
- **NFR 2.2** — `shellcheck -S warning local-watcher/bin/issue-watcher.sh` rc=0 / 191 テスト
  ケース全 PASS（impl-notes 記載、reviewer 側でも `pi_detect_quota_soft_fail_test.sh` を
  再実行し 13/13 PASS を確認）。
- **NFR 3.1** — `pi_log` の既存タイムスタンプ形式維持。
- **NFR 3.2** — `quota-soft-fail` 行は PR 番号付き 1 行で grep 集計可能。

## Findings

なし

## Summary

requirements.md の全 numeric ID（1.1〜5.3 / NFR 1.1〜3.2）について実装またはテストが対応。
shellcheck warning ゼロ、新規 13 ケース PASS、既存 178 ケース PASS（impl-notes 記載、reviewer
側で `pi_detect_quota_soft_fail_test.sh` を再実行し PASS=13 確認）。本 spec は PM のみフロー
で `tasks.md` / `design.md` が無いが、Out of Scope 節で `pr-iteration` Processor 限定が
明記されており、実装は `pi_run_iteration` / `process_pr_iteration` の 2 関数のみに収束、
`needs-quota-wait` / `qa_handle_quota_exceeded` の追加呼び出しもなく境界逸脱は検出されない。

RESULT: approve
