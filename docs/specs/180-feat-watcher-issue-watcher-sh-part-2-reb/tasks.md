# Implementation Plan

- [x] 1. Module Loader 配線の確立
  - `issue-watcher.sh` の Config ブロック直後・最初の関数定義より前に Module Loader ブロックを追加する
  - `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` で cwd 非依存にディレクトリ解決する
  - manifest 配列 `( core_utils.sh quota-aware.sh merge-queue.sh auto-rebase.sh )` をループし、各
    `$SCRIPT_DIR/modules/<name>` の存在を確認して `source`（`.`）する
  - 欠落モジュールは名前を含む ERROR を `>&2` に出し `exit 1` で停止する（silent fail 禁止）
  - この時点では 3 モジュールファイルは空 stub（関数定義は後続タスクで移動）でも Loader 自体が
    起動・欠落検知できることを確認する。`# shellcheck disable=SC1090` を source 行に付与
  - _Requirements: 4.1, 4.2, 4.4, NFR 3.1_
  - _Boundary: Module Loader_

- [x] 2. Quota-Aware Processor の抽出
  - `quota-aware.sh` を新規作成し、冒頭コメント（用途/配置先/依存/セットアップ参照先）を core_utils.sh
    の体裁に揃える。`set` 宣言は持たない
  - `qa_detect_rate_limit` / `qa_run_claude_stage` / `qa_persist_reset_time` / `qa_load_reset_time` /
    `qa_build_escalation_comment` / `build_partial_escalation_comment` / `qa_handle_quota_exceeded` /
    `process_quota_resume`（本体 L605〜1108）を差分等価で移動する
  - `qa_log`/`qa_warn`/`qa_error`/`qa_format_iso8601` は core_utils.sh にあるため再定義しない
  - 本体側は当該関数定義を削除し、call site `process_quota_resume || qa_warn ...`（L1112）は従来位置に温存
  - exit code（quota 検出 sentinel = exit 99）・reset 永続化結果を変えないこと
  - _Requirements: 1.1, 1.2, 1.3, 1.4, NFR 1.7_
  - _Boundary: Quota-Aware Processor_
  - _Depends: 1_

- [x] 3. Merge-Queue Processor の抽出
  - `merge-queue.sh` を新規作成する
  - `mq_pr_has_label` / `mq_handle_conflict` / `mq_try_rebase_pr` / `process_merge_queue`（L1123〜1424）
    と `mqr_log` / `mqr_warn` / `mqr_error` / `process_merge_queue_recheck`（L2195〜2318）を差分等価で移動する
  - `mq_log`/`mq_warn`/`mq_error` は core_utils.sh にあるため再定義しない（`mqr_*` は本体由来のため本モジュールに移す）
  - 本体側は当該定義を削除し、call site `process_merge_queue_recheck`（L2321）/ `process_merge_queue`（L2324）は従来位置に温存
  - マージ順序判定・状態遷移（needs-rebase / force-with-lease push）を変えないこと
  - _Requirements: 2.1, 2.2, 2.3, NFR 1.7_
  - _Boundary: Merge-Queue Processor_
  - _Depends: 1_

- [x] 4. Auto-Rebase Processor の抽出
  - `auto-rebase.sh` を新規作成する
  - `ar_fetch_candidates` / `ar_build_prompt` / `ar_run_claude_rebase` / `ar_classify_diff` /
    `ar_apply_mechanical` / `ar_dismiss_all_approvals` / `ar_apply_semantic` / `ar_escalate_to_failed` /
    `ar_handle_pr` / `process_auto_rebase`（L1424〜2181）を差分等価で移動する
  - `ar_log`/`ar_warn`/`ar_error` は core_utils.sh にあるため再定義しない
  - 本体側は当該定義を削除し、call site `process_auto_rebase`（L2330）は従来位置に温存
  - allowlist パスベース判定・approve 解除・escalation（claude-failed 相当）を変えないこと
  - _Requirements: 3.1, 3.2, 3.3, 3.4, NFR 1.7_
  - _Boundary: Auto-Rebase Processor_
  - _Depends: 1_

- [x] 5. install.sh によるモジュール配置
  - ローカル配置ブロック（L1224 付近、本体 `*.sh` 配置の直後）に
    `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin/modules" "*.sh" "$HOME/bin/modules" --executable` を追加する
  - 既存 `copy_glob_to_homebin` 経由で冪等 SKIP・差分上書き保護・dry-run 列挙・実行権限付与・sudo 不要を担保すること（新規ロジックは書かない）
  - scratch repo で初回配置 / 2 回目 SKIP / `--dry-run` 未反映を確認する
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, NFR 2.1, NFR 3.1_
  - _Boundary: Module Installer_
  - _Depends: 2, 3, 4_

- [ ] 6. 既存テストの抽出元追従修正
  - `qa_run_claude_stage_test.sh`: `qa_log`/`qa_warn`/`qa_error` を core_utils.sh から、
    `qa_detect_rate_limit`/`qa_run_claude_stage` を quota-aware.sh から抽出するよう `extract_function` の参照先を変更する
  - `verify_pushed_or_retry_test.sh`: `qa_log`/`qa_warn`/`qa_error` を core_utils.sh から抽出、
    `verify_pushed_or_retry` と stage 識別子 grep は本体 issue-watcher.sh のまま
  - `repo_prefix_log_test.sh`: `pi_*`/`mq_*`/`drr_*`/`qa_*` ロガーを core_utils.sh から、`mqr_*` を
    merge-queue.sh から抽出するよう変更。Req3 の dirty event / `process_merge_queue` call site 順序 grep は本体のまま
  - 新規テスト追加より既存テストの追従修正を優先する。`local-watcher/test/` 全テストが PASS することを確認する
  - _Requirements: 6.1, 6.2, 6.3_
  - _Boundary: Test Harness_
  - _Depends: 2, 3_

- [ ] 7. 静的解析・スモーク検証と README 更新
  - `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh` 警告ゼロ
  - cron-like 最小 PATH で Loader がモジュールを解決して起動できること、dry run で `処理対象の Issue なし` 正常終了、
    モジュール欠落時に欠落名 stderr + exit 1 を確認する
  - README にディレクトリ構成（`modules/` 追加）と modules 配置 migration note を追記する
  - _Requirements: 4.3, NFR 1.1, NFR 1.4, NFR 3.1_
  - _Boundary: Module Loader, Module Installer_
  - _Depends: 5, 6_

- [ ]* 7.1 モジュール欠落 fail-fast の専用回帰テスト追加（deferrable）
  - `modules/quota-aware.sh` を退避して起動し、欠落名を含む stderr + exit 1 を機械検証する小テストを追加
  - 既存テスト追従（タスク 6）を優先し、本タスクは余力がある場合に実施
  - _Requirements: 4.4, NFR 3.1_
