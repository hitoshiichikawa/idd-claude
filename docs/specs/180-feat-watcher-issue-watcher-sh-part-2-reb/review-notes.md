# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-180-impl-feat-watcher-issue-watcher-sh-part-2-reb
- HEAD commit: 359042b（chore(watcher): issue-watcher.sh の実行ビット (100755) を復元）
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out
  扱い。通常の 3 カテゴリ判定のみを実施（flag 観点の確認は行わない）。

## Verified Requirements

- 1.1 — `quota-aware.sh` に quota 待機制御 8 関数を集約。`qa_detect_rate_limit` /
  `qa_run_claude_stage` / `qa_persist_reset_time` / `qa_load_reset_time` /
  `qa_build_escalation_comment` / `build_partial_escalation_comment` /
  `qa_handle_quota_exceeded` / `process_quota_resume` が定義済み（本体からは削除済み・重複 0 件）
- 1.2 — call site `process_quota_resume`（issue-watcher.sh:590）は本体に温存。
  全 Processor 先頭順序を維持し、Loader source 後に遅延束縛で解決される
- 1.3 — `process_quota_resume` が main と byte-identical（差分等価移動）
- 1.4 — `qa_run_claude_stage`（exit 99 sentinel）/ `qa_persist_reset_time` が byte-identical。
  reset 永続化ロジック不変。`qa_run_claude_stage_test.sh` PASS
- 2.1 — `merge-queue.sh` に `mq_*` / `process_merge_queue` / `mqr_*` /
  `process_merge_queue_recheck` を集約（mqr_* は本体由来で core_utils.sh には無いため
  本モジュールへ。core_utils.sh は無変更）
- 2.2 — `process_merge_queue` が main と byte-identical、call site issue-watcher.sh:618 温存
- 2.3 — `process_merge_queue_recheck` が main と byte-identical、call site issue-watcher.sh:615 温存
- 3.1 — `auto-rebase.sh` に自動 Rebase 10 関数を集約（`ar_*` / `process_auto_rebase`）
- 3.2 — `ar_classify_diff` / `ar_fetch_candidates` が byte-identical（allowlist パスベース判定不変）
- 3.3 — `ar_dismiss_all_approvals` が byte-identical（approve 解除条件不変）
- 3.4 — `ar_escalate_to_failed` が byte-identical（escalation 挙動不変）、call site
  issue-watcher.sh:624 温存
- 4.1 — 既存 Module Loader（issue-watcher.sh:484-）が `IDD_MODULE_DIR`（BASH_SOURCE 基準）で
  解決。`REQUIRED_MODULES` 配列に 3 モジュールを追加
- 4.2 — `module_loader_missing_test.sh` Case 1 が別 cwd 起動で cwd 非依存解決を検証（PASS）
- 4.3 — 全モジュール source 後に 3 プロセッサ全関数が解決（本体に重複定義 0 件 / impl-notes
  dry-run スモークで未定義参照 0 件）。`module_loader_missing_test.sh` Case 3 PASS
- 4.4 — `module_loader_missing_test.sh` Case 1/2 が欠落モジュール名を含む stderr +
  exit 1 を検証（PASS）。本体の欠落チェック分岐は main から不変
- 5.1〜5.5 — install.sh のモジュール配置ブロック（L1227-1233）は Part 1 で既配線（本 PR diff なし）。
  `copy_glob_to_homebin ".../bin/modules" "*.sh" "$HOME/bin/modules" --executable` が
  冪等 SKIP・差分上書き・dry-run 列挙・chmod +x・HOME スコープ完結を担保（impl-notes でスモーク検証）
- 6.1 — `local-watcher/test/` 全 13 本を reviewer 自身で再実行し PASS=13 / FAIL=0 を確認
- 6.2 — `qa_run_claude_stage_test.sh` / `repo_prefix_log_test.sh` /
  `qa_detect_rate_limit_test.sh` の `extract_function` が新モジュールを抽出元に追加
- 6.3 — 移動済みロガー/関数を参照する該当テストが移動先を解決して通過（再実行で確認）
- NFR 1.1〜1.7 — 移動 26 関数すべてが main と byte-identical（独自スクリプトで機械検証）。
  call site の順序・内容も main と一致。core_utils.sh は無変更。
  env 名・exit code・ログ書式・ラベル遷移・cron 登録文字列は不変
- NFR 2.1 — install.sh は既存 `copy_glob_to_homebin`→`classify_action` 経由で再実行 SKIP（冪等）
- NFR 3.1 — モジュール欠落時 stderr エラー + exit 1（silent fail なし）。
  shellcheck -S warning は変更全ファイルで rc=0

## 機械検証の要点（差分等価リファクタの裏取り）

- main:issue-watcher.sh から抽出した 26 プロセッサ関数定義と、各モジュールへ移動した定義を
  awk 抽出 + 文字列比較し、全 26 関数が IDENTICAL であることを確認（ロジック改変の混入なし）
- 当該 26 関数定義は本体から完全に削除され、本体に重複定義は 0 件
- core_utils.sh のロガー（`qa_log` / `mq_log` / `ar_log` / `qa_format_iso8601`）は 3 新規
  モジュールで再定義されていない（design.md Non-Goal 準拠）
- 3 新規モジュールに top-level `set` 宣言なし（規約準拠）
- `local-watcher/test/` 全 13 本を再実行し PASS=13 / FAIL=0、shellcheck -S warning rc=0

## Findings

なし（reject の根拠となる AC 未カバー / missing test / boundary 逸脱はいずれも検出されず）

参考（reject 対象外・informational）:
- HEAD の chore commit（359042b）で `issue-watcher.sh` の実行ビットが 100755 に復元されている。
  観測挙動は不変（cron はデプロイ済みコピーを呼び、install.sh が `--executable` で chmod +x、
  launchd は bash 経由起動、テストも bash 経由）。NFR 1.6 の cron/launchd 登録文字列も不変。
- impl-notes #1（Part 1 基盤は main HEAD で既配線済み）/ #3（Req 5.3 の上書き保護ヘルパ解釈）
  は人間レビュー判断事項として記録済み。成果物（差分等価な module 分割）は AC を満たしており、
  Reviewer の 3 カテゴリ判定では reject 事由にならない。

## Summary

3 プロセッサ（quota-aware / merge-queue / auto-rebase）の抽出は全 26 関数 byte-identical で
差分等価が機械検証でき、call site の順序・内容も main と一致。全 numeric AC（1.1〜6.3 /
NFR 1.1〜3.1）に対応する実装・テストを確認。テスト 13 本全 PASS、shellcheck warning ゼロ、
core_utils.sh 無変更。boundary 逸脱・AC 未カバー・missing test のいずれも検出されず。

RESULT: approve
