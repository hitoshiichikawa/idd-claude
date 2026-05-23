# Implementation Plan

> リファクタリングの性質上、**各タスク完了時点で `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` と既存全テスト（`local-watcher/test/*.sh` + `tests/local-watcher/*/*.sh`）が緑**を保てる順序で構成している。一括移動で全テストが赤になる事故を避けるため、**テスト互換ヘルパー（design.md「既存テスト互換戦略」案 (b)）を関数移動より前に導入**する。ヘルパーはエントリポイント + modules/*.sh を 1 つの仮想ソース集合（`IDD_SOURCE_FILES`）として走査するため、関数が本体に残っていても module へ移った後でも同じく解決でき、各移動タスクが緑のまま遷移できる。

- [ ] 1. モジュールローダとマニフェスト・空モジュール雛形の導入
- [ ] 1.1 `issue-watcher.sh` に `SCRIPT_DIR` 解決 + モジュールマニフェスト配列 + 動的 source ループを追加する
  - `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` で配置位置を cwd / symlink 非依存に解決（NFR 3.2）
  - 9 モジュール名の固定順マニフェスト（design.md File Structure Plan 順）をエントリポイントに明示列挙
  - 各 module を source 前に `[ -r "$f" ]` で検証し、不在/読込不能なら欠落パスを `>&2` 出力して `exit 1`（Req 1.3）
  - ローダはツールチェックより前・副作用（flock / git）より前に配置（Req 1.1 / NFR 3.1）
  - `# shellcheck source=/dev/null` directive で SC1090 を抑止（Req 5.1）
  - `local-watcher/bin/modules/` に 9 個の空モジュール雛形を作成（shebang `#!/usr/bin/env bash` + `# shellcheck shell=bash` + ファイル冒頭コメント: 用途/配置先 `~/bin/modules/<name>.sh`/依存/セットアップ参照先）。この段では関数は本体に残し、雛形のみ追加する（重複定義は作らない）
  - _Requirements: 1.1, 1.2, 1.3, 5.1, 5.2, NFR 3.1, NFR 3.2_
  - _Boundary: Module Loader, Entry Point_

- [ ] 2. テスト互換ヘルパー (b) の先行導入
- [ ] 2.1 `local-watcher/test/lib/extract.sh` を新設し、全テストの抽出/grep を仮想ソース集合経由に切り替える
  - `IDD_SOURCE_FILES`（エントリポイント + `modules/*.sh` の絶対パス配列）を `SCRIPT_DIR` 基準で定義
  - `extract_function "<fn>"`（全 SOURCE 横断 awk 抽出。1 件も解決できなければ非0 exit / Req 4.4）と `idd_grep_sources "<pattern>"`（全 SOURCE 横断 grep）を提供
  - 既存 12 テスト（`local-watcher/test/*.sh`）の各ローカル `extract_function` 定義と `WATCHER_SH` 直接参照を `lib/extract.sh` source + 共通関数呼び出しに置換（アサーション期待値・ケースは変更しない）
  - `tests/local-watcher/stage-a-verify/extract-driver.sh` / `tasks-count/extract-driver.sh` の抽出も SOURCE 集合走査に揃える
  - この段では関数はまだ本体に残るが、ヘルパーは本体も走査するため全テストが緑のまま遷移する（以降の移動タスクで赤化させないための足場）
  - _Requirements: 4.1, 4.2, 4.3, 4.4_
  - _Boundary: Test Compatibility Layer_
  - _Depends: 1.1_

- [ ] 3. Processor 系モジュール群 A の移動（quota-aware / merge-queue / auto-rebase）
- [ ] 3.1 `qa_*` / `build_partial_escalation_comment` / `process_quota_resume` を `modules/quota-aware.sh` へ移動 (P)
  - 本体から該当関数定義を削除し quota-aware.sh へ移設（シグネチャ・本文を 1 文字も変えない）
  - 移動後に `shellcheck modules/quota-aware.sh` 警告ゼロ・`qa_detect_rate_limit_test.sh` 緑を確認
  - _Requirements: 1.4, 3.3, 5.2, NFR 1.1_
  - _Boundary: quota-aware.sh_
  - _Depends: 2.1_
- [ ] 3.2 `mq_*` / `process_merge_queue` / `mqr_*` / `process_merge_queue_recheck` を `modules/merge-queue.sh` へ移動 (P)
  - _Requirements: 1.4, 3.3, 5.2, NFR 1.1_
  - _Boundary: merge-queue.sh_
  - _Depends: 2.1_
- [ ] 3.3 `ar_*` / `process_auto_rebase` を `modules/auto-rebase.sh` へ移動 (P)
  - _Requirements: 1.4, 3.3, 5.2, NFR 1.1_
  - _Boundary: auto-rebase.sh_
  - _Depends: 2.1_

- [ ] 4. Processor 系モジュール群 B の移動（promote-pipeline / pr-iteration / design-review-release）
- [ ] 4.1 `pp_*` + `po_*` + `process_promote_pipeline` を `modules/promote-pipeline.sh` へ移動 (P)
  - Path Overlap（`po_*`）と Promote（`pp_*`）を同一モジュールに consolidate（design.md 根拠）
  - `po_check_dispatch_gate` は dispatcher から呼ばれるが定義はここに置く（呼び出し配線は本体/dispatcher 側で不変）
  - _Requirements: 1.4, 3.3, 5.2, NFR 1.1_
  - _Boundary: promote-pipeline.sh_
  - _Depends: 2.1_
- [ ] 4.2 `pi_*` / `build_recovery_hint` / `process_pr_iteration` を `modules/pr-iteration.sh` へ移動 (P)
  - 移動後に `pi_max_rounds_kind_test.sh` / `pi_detect_quota_soft_fail_test.sh` が SOURCE 集合経由で緑であることを確認
  - _Requirements: 1.4, 3.3, 5.2, NFR 1.1_
  - _Boundary: pr-iteration.sh_
  - _Depends: 2.1_
- [ ] 4.3 `drr_*` / `process_design_review_release` を `modules/design-review-release.sh` へ移動 (P)
  - _Requirements: 1.4, 3.3, 5.2, NFR 1.1_
  - _Boundary: design-review-release.sh_
  - _Depends: 2.1_

- [ ] 5. impl-gates モジュールの移動とゲート系テストの解決確認
- [ ] 5.1 `sav_*` / `_sav_*` / `stage_a_verify_*` / `sc_*` / `stage_checkpoint_*` / `tc_*` / `_normalize_slug` / `_slug_mismatch_escalate` / `_stage_checkpoint_assert_slug_match` を `modules/impl-gates.sh` へ移動
  - 移動後に `normalize_slug_test.sh` / `slug_match_guard_test.sh` / `stage-a-verify/extract-driver.sh` / `tasks-count/extract-driver.sh` が SOURCE 集合経由で緑であることを確認
  - `shellcheck modules/impl-gates.sh` 警告ゼロを確認
  - _Requirements: 1.4, 3.3, 4.1, 4.2, 4.3, 5.2, NFR 1.1_
  - _Boundary: impl-gates.sh_
  - _Depends: 2.1_

- [ ] 6. impl-pipeline と dispatcher の移動・配線維持とテスト全緑化
- [ ] 6.1 impl-pipeline 系関数を `modules/impl-pipeline.sh` へ移動する
  - `rv_*` / `pt_*` / per-task（`build_per_task_*` / `run_per_task_*`）/ debugger 系 / `build_dev_prompt_*` / `build_reviewer_prompt` / `extract_review_result_token` / `parse_review_result` / `run_reviewer_stage` / `verify_pushed_or_retry` / `verify_stagec_pr_or_retry` / `mark_issue_*` / `handle_partial_status` / `_sav_handle_failure` / `stage_a_verify_run` / `run_impl_pipeline` / `_assert_base_branch_resolved` を移設
  - `parse_review_result_test.sh` / `verify_pushed_or_retry_test.sh` / `stagec_pr_verify_*_test.sh` が、定義・呼び出し配線・`gh pr view`/`gh api` 文字列を `idd_grep_sources` 横断で解決して緑になることを確認
  - _Requirements: 1.4, 3.3, 4.1, 4.3, 5.2, NFR 1.1_
  - _Boundary: impl-pipeline.sh_
  - _Depends: 5.1_
- [ ] 6.2 dispatcher 系関数を `modules/dispatcher.sh` へ移動する（定義のみ。orchestration はエントリポイント据置）
  - `dispatcher_*` / `pclp_*` / `check_existing_impl_pr` / `_parallel_validate_slots` / `_worktree_*` / `_slot_*` / `slot_*` / `_resume_*` / `_resume_branch_assert_slug_match` / `dr_*` / `_dispatcher_on_signal` / `_dispatcher_reap_finished_slots` / `_dispatcher_find_free_slot` / `_slot_run_issue` / `_dispatcher_run` を移設
  - `declare -A _DISPATCHER_SLOT_PIDS` / `trap` 登録 / `_dispatcher_run` の**呼び出し** / `exit` はエントリポイントに残す（dispatcher.sh は関数定義のみ）
  - dispatcher.sh はマニフェスト最後に source される（impl-pipeline / 各 processor を呼ぶため）。source 順序制約を満たすことを確認
  - `repo_prefix_log_test.sh`（dirty-tree 文字列はエントリポイント残置 / logger は各 module 横断）含む全テストが緑、`shellcheck` 全緑を確認
  - _Requirements: 1.4, 3.1, 3.2, 3.3, 4.1, 4.3, 5.1, 5.2, NFR 1.1_
  - _Boundary: dispatcher.sh, Entry Point_
  - _Depends: 6.1_

- [ ] 7. install.sh による modules 配置の追加
- [ ] 7.1 local watcher インストール節に modules/ コピーを追加する
  - 既存 `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.sh" ...` の直後に `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin/modules" "*.sh" "$HOME/bin/modules" --executable` を追加
  - 既存ヘルパー（`ensure_dir` / `copy_template_file` / `log_action` / DRY_RUN / `.bak` once-only）を再利用し新規ロジックは追加しない（Req 2.2/2.3/2.4 / NFR 2.1/2.2）
  - スモーク: `/tmp` scratch repo へ `./install.sh --repo /tmp/scratch --local` を 2 回実行し冪等性、`--dry-run` で実コピーなし `[DRY-RUN]` 列挙のみを確認
  - `shellcheck install.sh` 警告ゼロを確認
  - _Requirements: 2.1, 2.2, 2.3, 2.4, NFR 2.1, NFR 2.2_
  - _Boundary: Installer Module Copy_
  - _Depends: 6.2_

- [ ] 8. README 更新と最終差分等価スモーク検証
- [ ] 8.1 README にディレクトリ構成・手動コピー手順・modules 化 migration note を追記し、最終スモークを実施する
  - ディレクトリ構成（`local-watcher/bin/` 配下）に `modules/` を追記
  - 手動コピー手順に `cp -r .../local-watcher/bin/modules ~/bin/` 相当を追記
  - 「modules 化の構成変更」migration note を 1 節追加（cron/launchd 登録文字列・env var・exit code は不変。既存運用者は `install.sh --local` 再実行が必要な旨 / Req 3.4）
  - 最終スモーク: 最小 PATH 起動で modules 解決（NFR 3.1/3.2）、対象 Issue なしで `処理対象の Issue なし` exit 0（NFR 1.1）、modules 欠落時に非0 exit + 欠落パス stderr（Req 1.3）、`shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` 全緑（Req 5.1/5.2）
  - _Requirements: 3.4, 1.3, 5.1, 5.2, NFR 1.1, NFR 1.2, NFR 3.1, NFR 3.2_
  - _Boundary: Entry Point, Module Loader_
  - _Depends: 7.1_
