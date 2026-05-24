# 実装ノート（#177 Part 1）

## Implementation Notes

### Task 1: core_utils.sh 新規作成と低レベル共通ユーティリティの移動

- **採用方針**: `local-watcher/bin/modules/core_utils.sh` を新規作成し、移動対象関数を本体から
  「cut & paste（移動のみ）」で集約。issue-watcher.sh 側は当該関数定義のみを削除し、call site・
  他コードは一切変更しない（bash の遅延評価により呼び出しは task 2 の loader による source 完了後に解決される）。

- **重要な判断**:
  - 移動したロガーは `qa_` / `mq_`(merge-queue) / `ar_` / `pp_` / `pi_` / `drr_` の各系（`_log` /
    `_warn` / `_error`）。`mqr_`(merge-queue-recheck) 系は Part 1 移動対象外のため **本体に残置**
    （design.md TestCompat 節の注意書きに従う）。`dispatcher_log` / `dispatcher_warn` も **本体に残置**
    （worktree ユーティリティからの前方参照）。
  - worktree 系（`_worktree_path` / `_worktree_is_registered` / `_worktree_ensure` / `_worktree_reset`）と
    slot 系（`_slot_lock_path` / `_slot_acquire` / `_slot_release`）は、`_worktree_ensure`→`_worktree_path`/
    `_worktree_is_registered`、`_slot_acquire`→`_slot_lock_path` の **モジュール内依存をすべて core_utils.sh
    内で閉じた**。外向き依存は `dispatcher_log` / `dispatcher_warn`（前方参照）とグローバル変数のみ。
  - 関数直前のドキュメントコメント・セクション罫線（Phase C: Worktree/Slot/Hook 等）も関数と一体で移動し、
    本体・シグネチャ・コメントを文字単位で保持（差分等価）。
  - core_utils.sh には `set -euo pipefail` を書かず（本体側で宣言済み・source される側）、shebang は
    `#!/usr/bin/env bash` を付与（既存スクリプト慣習に合わせた）。ファイル冒頭に用途／配置先／依存／
    セットアップ参照先コメントを記載。

- **検証結果**:
  - `bash -n` 両ファイル OK。`shellcheck local-watcher/bin/modules/core_utils.sh` 警告ゼロ。
  - issue-watcher.sh は 358 行の純削除（追加行 0）。削除された全非空行が core_utils.sh に文字単位で
    一致して存在することを機械検証済み（cut & paste の取りこぼし・改変ゼロ）。
  - issue-watcher.sh の shellcheck 警告コード種別は main と同一（SC2317 / SC2012）で新規警告ゼロ。
    SC2317 件数は 41→37 に減少（移動した関数本体の到達不能コード警告が core_utils.sh 側へ移動したため）。

- **残存課題（後続 task へ引き継ぐ事項）**:
  - **task 2**: issue-watcher.sh に ModuleLoader を追加し、`REQUIRED_MODULES=( "core_utils.sh" )` を
    `SCRIPT_DIR/modules/` 基準で source する必要がある。task 1 完了時点では本体は「関数が削除されたが
    source 機構がまだ無い」中間状態（設計上の想定どおり）。
  - **task 3**: install.sh に `local-watcher/bin/modules/` を `$HOME/bin/modules/` へ配置する
    `copy_modules_recursive` を追加する必要がある。
  - **task 4**: 移動対象関数を抽出する 3 テスト（`repo_prefix_log_test.sh` / `verify_pushed_or_retry_test.sh` /
    `qa_run_claude_stage_test.sh`）の抽出元に `modules/core_utils.sh` を追加する必要がある。task 1 単独では
    これら 3 テストは failing になる想定（task 4 で修正）。
  - **task 6**: README にディレクトリ構成図・modules 化 migration note を追記する必要がある。

- **確認事項**: なし。design.md の移動対象・残置対象の区別（特に `mqr_` 残置・`dispatcher_*` 残置）は
  明確で、要件・設計との矛盾は検出されなかった。

## 受入基準カバレッジ（task 1 分）

task 1 は差分等価リファクタリングであり、本リポジトリは unit test フレームワークを持たない（CLAUDE.md
「テスト・検証」節）。requirement 3.1〜3.9 は移動した関数が分割前と文字単位で同一であること（上記
機械検証 = 削除全行が core_utils.sh に一致）で差分等価を担保。関数の到達可能性・eval 抽出の検証は
TestCompat（task 4）および統合スモークテスト（task 5）の責務であり、task 1 単独ではテストスイート全体の
PASS は要求されない（移動対象を抽出する 3 テストは task 4 修正まで failing 想定）。

| Requirement | 担保方法（task 1 分） |
|---|---|
| 3.1 ロガー集約 | `qa`/`mq`/`ar`/`pp`/`pi`/`drr` の log/warn/error を core_utils.sh に移動（mqr は残置） |
| 3.2 ロガー書式不変 | 削除全行が core_utils.sh に文字単位一致（機械検証）→ 出力先・prefix・書式同一 |
| 3.3 日付フォーマット | `qa_format_iso8601` を本体と同一定義で移動 |
| 3.4 `_worktree_ensure` | 同一定義で移動、モジュール内依存（`_worktree_path`/`_worktree_is_registered`）を閉じた |
| 3.5 `_worktree_reset` | 同一定義で移動 |
| 3.6 `_slot_acquire` | 同一定義で移動、`_slot_lock_path` 依存を閉じた、fd 210+N 規約保持 |
| 3.7 `_slot_release` | 同一定義で移動 |
| 3.8 `_hook_invoke` | 同一定義で移動、直接 exec / stderr 同期捕捉 / no-op 既定を保持 |
| 3.9 同一シグネチャ・戻り値・副作用で公開 | cut & paste により全関数を改変なしで公開（差分等価検証済み） |

STATUS: complete
