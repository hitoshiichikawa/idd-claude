# Implementation Plan

> リファクタリングの性質上、**各タスク完了時点で `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` と既存全テスト（`local-watcher/test/*.sh` + `tests/local-watcher/*/*.sh`）が緑**を保てる順序で構成している。本 Part は **Part 1（#177）merge 済み**（`modules/` ディレクトリ・モジュールローダ・マニフェスト・テスト互換ヘルパー `IDD_SOURCE_FILES` / `extract_function` / `idd_grep_sources`・install.sh の modules コピーが存在）を前提依存とする（design.md「Migration Strategy」）。移動するのは **4 群の関数定義のみ**で、本体の top-level orchestration 呼び出し配線（`process_promote_pipeline || pp_warn ...` / `process_pr_iteration || pi_warn ...`）は据え置く。ファイル名はハイフン規約（decision 1）。

- [ ] 1. Promote Pipeline + Path Overlap 群の移動（pp_* + po_* + process_promote_pipeline）
- [ ] 1.1 `pp_*` / `po_*` / `process_promote_pipeline` の関数定義を `modules/promote-pipeline.sh` へ移動する
  - 本体（行 2406〜2419 の `pp_log/warn/error`、行 2420〜2975 の `po_*` 群、行 2976〜3697 の `pp_resolve_*`〜`process_promote_pipeline`）から該当関数定義を削除し promote-pipeline.sh へ移設（シグネチャ・本文を 1 文字も変えない）
  - Path Overlap（`po_*`）は独立せず promote-pipeline.sh へ同居（decision 3）。`po_check_dispatch_gate` / `po_apply_awaiting_slot` / `po_clear_awaiting_slot` ほか全 `po_*` を含む
  - **top-level 呼び出し配線 `process_promote_pipeline || pp_warn ...`（行 3701〜3702）は本体 orchestration に残す**（移動しない）
  - `PROMOTE_PIPELINE_ENABLED` の gate 判定は移動先でも不変（Req 4.2）
  - 移動後に `shellcheck modules/promote-pipeline.sh` 警告ゼロ・全テスト緑を確認
  - _Requirements: 2.1, 2.2, 2.3, 4.1, 4.2, 4.3, 5.3, 5.4, 7.2, NFR 1.1_
  - _Boundary: promote-pipeline.sh, Entry Point_

- [ ] 2. PR Iteration 群の移動（pi_* + build_recovery_hint + process_pr_iteration）
- [ ] 2.1 `pi_*` / `build_recovery_hint` / `process_pr_iteration` の関数定義を `modules/pr-iteration.sh` へ移動する (P)
  - 本体（行 3715〜5238。`build_recovery_hint` は行 4325 に同居）から該当関数定義を削除し pr-iteration.sh へ移設（シグネチャ・本文を 1 文字も変えない）
  - **top-level 呼び出し配線 `process_pr_iteration || pi_warn ...`（行 5497）は本体 orchestration に残す**（移動しない）
  - 移動後に `pi_max_rounds_kind_test.sh` / `pi_detect_quota_soft_fail_test.sh` が `IDD_SOURCE_FILES` 集合走査経由で緑であることを確認
  - `shellcheck modules/pr-iteration.sh` 警告ゼロを確認
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 5.3, 5.4, 7.2, NFR 1.1_
  - _Boundary: pr-iteration.sh, Entry Point_

- [ ] 3. Stage A Verify 群の移動と独立モジュール新設（sav_* + stage_a_verify_*）
- [ ] 3.1 `sav_*` / `_sav_*` / `stage_a_verify_*` の関数定義を新規 `modules/stage-a-verify.sh` へ移動しマニフェストに登録する
  - 本体の 2 非連続領域（Region 1: 行 5527〜5845 = `sav_log/warn/error` / `_sav_cmd_starts_with_keyword` / `stage_a_verify_extract_command` / `_resolve_command` / `_round_path` / `_read_round` / `_bump_round` / `_reset_round`、Region 2: 行 9019〜9184 = `_sav_handle_failure` / `stage_a_verify_run`）を 1 ファイルへ統合移設（シグネチャ・本文を 1 文字も変えない。`source` は全関数を実行前に読み込むため 2 領域を 1 ファイルへ統合しても挙動等価）
  - Stage A Verify は `impl-gates.sh` に集約せず独立分離（decision 2）。`sc_*` / `tc_*` / `stage_checkpoint_*` は本体（または Part 1 の impl-gates.sh）に残し移動しない
  - `_sav_handle_failure → mark_issue_failed`（impl-pipeline）/ `stage_a_verify_run → _sav_handle_failure` の cross-module 呼び出しは、全モジュールが実行前に source されるため挙動不変
  - エントリポイントの `_IDD_MODULES` マニフェストに `stage-a-verify` を追加（Part 1 マニフェストに無いため。design.md decision 2）
  - 各モジュール冒頭にファイルコメント（用途 / 配置先 `~/bin/modules/stage-a-verify.sh` / 依存 / 設計参照先）を付与（CLAUDE.md bash 規約）
  - 移動後に `tests/local-watcher/stage-a-verify/extract-driver.sh` が `stage_a_verify_extract_command` を集合走査経由で抽出でき全 fixture が緑であることを確認
  - `shellcheck modules/stage-a-verify.sh` 警告ゼロを確認
  - _Requirements: 3.1, 3.2, 3.3, 5.3, 5.4, 6.1, 6.2, 6.3, 7.2, NFR 1.1_
  - _Boundary: stage-a-verify.sh, Entry Point_
  - _Depends: 1.1_

- [ ] 4. 全体結合・差分等価スモークと README 追記
- [ ] 4.1 全テスト緑・shellcheck 全緑・差分等価スモーク・README 追記を行う
  - 全テストスイート緑を確認: `local-watcher/test/*.sh`（12 件）+ `tests/local-watcher/*/*.sh`（3 件）が全て exit 0（Req 6.1 / 6.2）
  - `repo_prefix_log_test.sh` が `pp_log` / `pi_log` / `sav_log` の `[REPO]` prefix を移動先 3 module 横断で `idd_grep_sources` 解決して緑（Req 5.3 / 6.3）
  - top-level 呼び出し配線据置の確認: `process_promote_pipeline ||` / `process_pr_iteration ||` が entry point に残り module に含まれないことを grep 確認（Req 4.2 / 5.2）
  - 差分等価スモーク: `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` が `処理対象の Issue なし` で exit 0、`PROMOTE_PIPELINE_ENABLED` 未設定で promote が起動しないこと（Req 4.2 / 5.2 / NFR 1.1）
  - `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/promote-pipeline.sh local-watcher/bin/modules/pr-iteration.sh local-watcher/bin/modules/stage-a-verify.sh` 全緑（Req 7.1 / 7.2）
  - README に `stage-a-verify.sh` 増分を反映（ディレクトリ構成 / 手動コピー対象は `modules/*.sh` glob でカバー済みのため追記は構成記述のみ。互換破壊なしのため migration note 追記は不要、必要時のみ / Req 5.5）
  - _Requirements: 4.2, 5.2, 5.3, 5.5, 6.1, 6.2, 6.3, 7.1, 7.2, 8.2, NFR 1.1, NFR 1.2_
  - _Boundary: Entry Point, promote-pipeline.sh, pr-iteration.sh, stage-a-verify.sh_
  - _Depends: 1.1, 2.1, 3.1_

- [ ]* 4.2 移動境界の最小回帰テスト追加（任意）
  - 移動後に `declare -F process_promote_pipeline` / `process_pr_iteration` / `stage_a_verify_run` が本体単体 source では未定義・module source 後は定義済みになることを確認する軽量テスト（4 群が本体から除去され module へ移ったことの観測 / Req 8.2）
  - _Requirements: 8.2, 6.3_
