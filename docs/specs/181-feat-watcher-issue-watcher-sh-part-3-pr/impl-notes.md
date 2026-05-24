# 実装ノート（#181 Part 3: issue-watcher.sh モジュール化 Part 3）

## 概要

`local-watcher/bin/issue-watcher.sh` 本体に残っていた 4 つの processor 群（PR 反復ループ /
Path Overlap / Stage A Verify / Promote Pipeline）の **関数定義のみ** を専用モジュールへ
切り出した。シグネチャ・本文を 1 文字も変えない純粋な move（差分等価リファクタリング）で、
top-level orchestration 呼び出し配線は本体に据え置いた。

着手時点で `git log --oneline main..HEAD` は空（設計 PR merge 済みの main 先端と同一）で、
Part 3 実装の最初の commit を積む状態だった。`git reset` / `git rebase` / branch 切替は
行っていない。

## Feature Flag Protocol 判定

対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節は **存在しない**。よって opt-out
として解釈し、通常フロー（単一実装パス）で実装した。flag 裏実装は不要（`feature-flag.md` は
読み込まない）。

## 消化したタスク

| Task | 内容 | 状態 |
|------|------|------|
| 1.1 | `pp_*` / `po_*` / `process_promote_pipeline` を `modules/promote-pipeline.sh` へ移動 | 完了（commit `5b87375`） |
| 2.1 | `pi_*` / `build_recovery_hint` / `process_pr_iteration` を `modules/pr-iteration.sh` へ移動 | 完了（commit `44ef315`） |
| 3.1 | `sav_*` / `_sav_*` / `stage_a_verify_*` を新規 `modules/stage-a-verify.sh` へ移動 | 完了（commit `d4f1459`） |
| 4.1 | 全テスト緑・shellcheck・差分等価スモーク・README 追記 | 完了（commit `b6cf1c2`） |
| 4.2 | （deferrable `- [ ]*`）移動境界の最小回帰テスト追加 | 未実施（任意。下記「派生タスク」参照） |

各実装 commit に対応する `docs(tasks): mark N.M as done` の marker commit を分離して積んだ
（batch ではなく 1 タスク = 1 marker commit）。親タスク 1 / 2 / 3 も子タスク完了に伴い `- [x]` へ更新済み。

## 移動した関数群と移動先

### modules/promote-pipeline.sh（新規, 1321 行 / Task 1.1）
- **Promote Pipeline (`pp_*`)**: `pp_resolve_target_branch` / `pp_issue_has_label` /
  `pp_collect_merged_issues` / `pp_resolve_merge_sha` / `pp_get_st_state` /
  `pp_resolve_st_log_url` / `pp_do_revert` / `pp_handle_st_failure` / `pp_handle_st_success` /
  `pp_process_one_issue` / `pp_match_cron_field` / `pp_match_cron` / `pp_do_promote_if_eligible` /
  `pp_do_promote` / `pp_notify_promote_failure` / `pp_summary` / `process_promote_pipeline`
- **Path Overlap (`po_*`)**: `po_log` / `po_warn` / `po_parse_triage_edit_paths` /
  `po_persist_edit_paths` / `po_load_edit_paths` / `po_collect_inflight_issues` /
  `po_resolve_overlap_holders` / `po_format_holders_for_log` / `po_format_holders_table_md` /
  `po_compute_overlap` / `po_apply_awaiting_slot` / `po_clear_awaiting_slot` / `po_check_dispatch_gate`
- Path Overlap は独立せず同居（design.md decision 3）。

### modules/pr-iteration.sh（新規, 1541 行 / Task 2.1）
- `pi_pr_has_label` / `pi_fetch_candidate_prs` / `pi_resolve_max_rounds` / `pi_read_round_counter` /
  `pi_read_no_progress_streak` / `pi_read_last_run` / `pi_general_filter_self` /
  `pi_general_filter_resolved` / `pi_general_filter_event_style` / `pi_general_truncate` /
  `pi_collect_general_comments` / `pi_write_marker` / `pi_post_processing_comment` /
  `pi_post_processing_marker` / `pi_finalize_labels` / `pi_finalize_labels_design` /
  `pi_classify_pr_kind` / `pi_select_template` / `build_recovery_hint` / `pi_escalate_to_failed` /
  `pi_build_iteration_prompt` / `pi_detect_quota_soft_fail` / `pi_branch_is_claude_pr_head` /
  `pi_auto_commit_and_push` / `pi_run_iteration` / `process_pr_iteration`

### modules/stage-a-verify.sh（新規, 510 行 / Task 3.1）
- `sav_log` / `sav_warn` / `sav_error` / `_sav_cmd_starts_with_keyword` /
  `stage_a_verify_extract_command` / `stage_a_verify_resolve_command` /
  `stage_a_verify_round_path` / `stage_a_verify_read_round` / `stage_a_verify_bump_round` /
  `stage_a_verify_reset_round` / `_sav_handle_failure` / `stage_a_verify_run`
- 元コードの 2 非連続領域（Region 1: logger〜reset_round / Region 2: `_sav_handle_failure` /
  `stage_a_verify_run`）を 1 ファイルへ統合。`source` は全関数を実行前に読み込むため定義順序は
  ランタイム挙動へ影響しない（design.md decision 2 / Architecture 節）。

### 本体に残置した orchestration 呼び出し配線（移動していない）
- `process_promote_pipeline || pp_warn ...`（Phase A 直後）
- `process_pr_iteration || pi_warn ...`（Phase A 直後）
- `po_check_dispatch_gate "$issue_number" "$labels_json"`（dispatcher 内）
- `stage_a_verify_run || _sav_rc=$?`（`run_impl_pipeline` 内）

### REQUIRED_MODULES マニフェスト
現状の 4 要素（`core_utils.sh` / `quota-aware.sh` / `merge-queue.sh` / `auto-rebase.sh`）に
3 要素を **`.sh` 付き** で追加し、計 7 要素にした:
`( "core_utils.sh" "quota-aware.sh" "merge-queue.sh" "auto-rebase.sh" "promote-pipeline.sh" "pr-iteration.sh" "stage-a-verify.sh" )`

## repoint したテスト

設計 (design.md) の「pp_log / pi_log / sav_log を repoint」想定と **実態が異なっていた** ため、
実態のテストファイルを正確に読んだうえで以下のとおり repoint した（詳細は「確認事項」参照）:

| テスト | repoint 内容 |
|--------|-------------|
| `local-watcher/test/pi_max_rounds_kind_test.sh` | `PR_ITERATION_SH` 変数を追加し、`pi_resolve_max_rounds` / `pi_read_no_progress_streak` / `pi_read_round_counter` / `pi_read_last_run` の抽出元を本体から `modules/pr-iteration.sh` へ repoint |
| `local-watcher/test/pi_detect_quota_soft_fail_test.sh` | `PR_ITERATION_SH` 変数を追加し、`pi_detect_quota_soft_fail` / `pi_branch_is_claude_pr_head` の抽出元を repoint |
| `tests/local-watcher/stage-a-verify/extract-driver.sh` | 抽出元を `_WATCHER_SH`（本体）から `_STAGE_A_VERIFY_SH`（`modules/stage-a-verify.sh`）へ repoint |
| `local-watcher/test/repo_prefix_log_test.sh` | **変更不要**（下記「確認事項」参照） |

## 検証結果

### shellcheck
- `shellcheck -S warning local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` → **exit 0（全緑）**
- 移動先 3 モジュール単体（`-S warning`）も全て exit 0
- **default-severity（`-S style` 相当）では本体に SC2317（info, 10 件）、pr-iteration.sh に
  SC2012（info, 1 件）が残る**が、これらはいずれも **info レベル**で **baseline（main 先端の
  分割前状態）でも同一の info 群が存在**していた（`git stash` で確認済み）。本切り出しで
  **新規に増えた warning は無く**、warning 以上の severity では完全に緑。Req 7.1 / 7.2 は
  「警告ゼロ」を満たす（CLAUDE.md「警告ゼロを目指す」基準に対し warning severity で達成、
  info は移動元コードの既存特性で増減なし）。
- 移動により本体内で参照箇所が消えたグローバル（`LABEL_ST_FAILED` / `LABEL_AWAITING_SLOT` /
  `LABEL_NEEDS_REBASE` / `PR_ITERATION_MAX_ROUNDS_LEGACY_SET`）に **局所的な
  `# shellcheck disable=SC2034`** を付与（消費は module 側で維持される旨のコメント付き）。
  先回りの一律 disable はせず、移動で実際に出た warning のみを最小限に解消した
  （design.md「shellcheck 方針」準拠）。

### テスト
- `local-watcher/test/*.sh`（13 件）+ `tests/local-watcher/*/*.sh`（3 件）= **全 16 件 exit 0**
- 移動前の baseline でも 16 件全 pass を確認済み（リグレッションなし）

### 差分等価スモーク
- 注意: `$HOME/bin/issue-watcher.sh` は **install 済みの旧コピー**（modules/ も 4 本のみ）で
  あり、worktree の変更を反映しない。よってスモークは **worktree 版スクリプトを直接実行** して
  実施した。
- `REPO=owner/test REPO_DIR=/tmp/nonexistent bash local-watcher/bin/issue-watcher.sh`:
  module loader（7 モジュール source）→ config → `base-branch=...` 起動ログまで到達し、
  **モジュール未検出 / syntax / unbound variable エラーは一切出ない**。その後 `cd $REPO_DIR`
  が（存在しない repo dir のため）失敗して exit 1 — これは想定どおりの環境起因の失敗で、
  loader と config 解決が正常であることを示す。
- 実 git temp repo（remote 未設定）に対しても `git fetch origin` 到達まで正常進行し、
  **`PROMOTE_PIPELINE_ENABLED` 未設定で promote-pipeline のサイクル開始ログは出力されない**
  ことを確認（Req 4.2）。
- E2E（実 gh / 実 Issue）は cron / launchd 環境での dogfooding に委ねる（NFR 1.2）。なお
  install 済みコピーを更新するには PR merge 後に `install.sh --local` 再実行が必要
  （install.sh の `modules/*.sh` glob が新 3 モジュールを自動コピーする）。

### 本体行数（Req 8）
- 切り出し前: 9969 行 → 切り出し後: **6747 行**（約 3222 行を 3 モジュールへ移動）
- **Req 8.2 充足**: Part 3 が切り出す 4 processor 群の関数定義を本体から完全に除去
  （`grep` で本体内の `pp_*` / `po_*` / `pi_*` / `sav_*` / `stage_a_verify_*` 関数定義 = 0 件）。
- **Req 8.1（1,000 行以下）は未達**: 本体は依然 6747 行。requirements.md / design.md が
  明記するとおり、1,000 行以下の達成は Part 1 / Part 2 完了を前提依存とする（実態の Part 1/2
  は `core_utils` / `quota-aware` / `merge-queue` / `auto-rebase` の切り出しに留まっており、
  本体には dispatcher / impl-pipeline / impl-gates(sc_/tc_) / design-review-release 等の
  未切り出し群が残存）。これらは本 Issue の Out of Scope。Req 8.1 は別 Part / 別 Issue の
  領分であり、本 Part 単独では達成できない（Req 8.2 がこの前提依存を明文化している）。

## 受入基準とテストの対応

| Req | 担保方法 |
|-----|---------|
| 1.1〜1.4（PR 反復ループ差分等価） | `pi_max_rounds_kind_test.sh`（`pi_resolve_max_rounds` / `pi_read_no_progress_streak` / `pi_read_round_counter` / `pi_read_last_run`）/ `pi_detect_quota_soft_fail_test.sh`（`pi_detect_quota_soft_fail` / `pi_branch_is_claude_pr_head`）が移動先から抽出して従来どおり pass。純粋 move による差分等価 |
| 2.1〜2.3（Path Overlap 差分等価） | 純粋 move。`po_check_dispatch_gate` 呼び出し配線を本体に残置。`bash -n` + スモークで load 確認 |
| 3.1〜3.3（Stage A Verify 差分等価） | `tests/local-watcher/stage-a-verify/extract-driver.sh` を移動先へ repoint し全 fixture pass。純粋 move |
| 4.1〜4.3（Promote Pipeline 差分等価） | 純粋 move。スモークで `PROMOTE_PIPELINE_ENABLED` 未設定時に起動しないこと（Req 4.2）を確認。gate 判定（`process_promote_pipeline` 冒頭）据置 |
| 5.1〜5.4（差分等価・後方互換） | env var 定義・logger・ラベル定数・exit code・orchestration 配線を一切変更せず。`repo_prefix_log_test.sh` で `[REPO]` prefix 維持を確認。5.5（migration note）は互換破壊なしのため不要 |
| 6.1〜6.4（既存テスト不破壊） | 全 16 テスト pass。`extract_function` は抽出失敗時に空出力→関数未定義→exit 非0 となり Req 6.4 を満たす（repoint 漏れがあれば失敗で観測可能） |
| 7.1〜7.2（shellcheck） | warning severity で本体・全モジュール exit 0。新規 warning ゼロ |
| 8.1〜8.2（サイズ集約） | 8.2 充足（4 群除去）。8.1（1000 行以下）は Part 1/2 前提依存で本 Part 単独では未達（requirements.md 明記） |
| NFR 1.1〜1.2 | 純粋 move による外部観測差分等価。dogfooding 次サイクルで完走確認は cron 環境に委ねる |
| NFR 2.1〜2.2 | module loader（`BASH_SOURCE` 基準 `IDD_MODULE_DIR` 解決）は Part 1 所有。本 Part はマニフェスト要素追加のみ |

## 確認事項（人間レビュア / Architect 向け）

design.md / tasks.md は書き換えていない（人間レビュー済みのため）。以下は実装中に気づいた
design.md と実態の差異であり、PR 本文の「確認事項」へ反映を推奨する。

1. **`pp_log` / `pi_log` は既に core_utils.sh へ集約済みだった**: design.md の File Structure
   Plan / Testing Strategy は「`pp_*` の `pp_log/warn/error` を promote-pipeline.sh へ移動」
   「`pi_log` を pr-iteration.sh へ移動」と記述していたが、**実態では `pp_log` / `pp_warn` /
   `pp_error` / `pi_log` / `pi_warn` / `pi_error` は #180 Part 2 で既に `modules/core_utils.sh`
   へ移動済み**だった。よって本 Part ではこれらロガーを **再定義せず**、core_utils.sh の
   定義をそのまま使う形にした（重複定義を避けるため）。`sav_log` / `sav_warn` / `sav_error` /
   `po_log` / `po_warn` は本体由来だったため移動先モジュールへ移した。

2. **`repo_prefix_log_test.sh` の repoint は不要だった**: design.md / tasks.md（Task 4.1）は
   「`repo_prefix_log_test.sh` の `pp_log` / `pi_log` / `sav_log` 抽出元を移動先 3 module へ
   repoint」と記述していたが、**実態の `repo_prefix_log_test.sh` は `pp_log` / `sav_log` を
   抽出対象に含めていない**（`LOGGER_FUNCS` は `pi_/mq_/mqr_/drr_/qa_` のみ）。さらに同テストの
   `extract_function` は既に `$WATCHER_SH $CORE_UTILS_SH $MERGE_QUEUE_SH` の 3 ソースを走査し、
   `pi_log` は core_utils.sh から解決される。したがって本テストは **変更不要**で、現状のまま
   全 pass する。design.md の当該記述は想定と実態のズレ（上記 1 と同根）。

3. **shellcheck の severity と「警告ゼロ」基準**: 本体・全モジュールは **`-S warning` で exit 0**
   だが、default-severity では **info レベル**の SC2317（10 件, 本体）/ SC2012（1 件,
   pr-iteration.sh）が残る。これらは baseline（分割前）でも同一に存在した info 群で、本切り出し
   による新規増加はない。Req 7.1/7.2 を「warning 以上ゼロ」と解釈して満たしたと判断したが、
   「info を含め完全ゼロ」を要求する場合は別途 info 抑止（`find` 化 / `# shellcheck disable`）の
   要否を Architect / 人間が判断されたい（移動元コードの既存特性であり本 Part のスコープ外と
   判断して触っていない）。

4. **Req 8.1（1,000 行以下）は本 Part 単独では未達**: 本体は 6747 行。requirements.md 8.1 が
   「Part 1〜3 すべて完了時」を前提とし 8.2 が前提依存を明文化しているとおり、実態の Part 1/2 は
   想定より切り出し範囲が狭く（dispatcher / impl-pipeline / impl-gates / design-review-release
   等が未切り出し）、本 Part 完了時点でも 1,000 行には届かない。これは設計どおりの想定挙動で
   あり、追加の切り出しは別 Issue の領分。

5. **install 済みコピーへの反映**: 本 PR merge 後、cron / launchd が実行する
   `$HOME/bin/issue-watcher.sh` / `$HOME/bin/modules/` を更新するには `install.sh --local` の
   再実行が必要（既存 migration 手順どおり / README 記載済み）。install.sh の `modules/*.sh`
   glob が新 3 モジュールを自動コピーするため、install.sh 自体の変更は不要。

## 派生タスク（次 Issue 候補）

- **Task 4.2（deferrable）の最小回帰テスト**: 移動後に `declare -F process_promote_pipeline` /
  `process_pr_iteration` / `stage_a_verify_run` が本体単体 source では未定義・module source 後は
  定義済みになることを確認する軽量テスト。本サイクルでは未実施（deferrable `- [ ]*`）。実装の
  正しさは既存 16 テスト + スモークで担保済みだが、移動境界の明示的観測テストとして将来追加して
  もよい。
- **Req 8.1 達成のための追加切り出し**: 本体に残る dispatcher / impl-pipeline / impl-gates
  (`sc_*` / `tc_*` / `stage_checkpoint_*`) / design-review-release 群のモジュール化（別 Part /
  別 Issue）。

STATUS: complete
