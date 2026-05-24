# Implementation Plan

- [x] 1. core_utils.sh を新規作成し低レベル共通ユーティリティを移動する
  - `local-watcher/bin/modules/core_utils.sh` を新規作成（ファイル冒頭に用途 / 配置先 / 依存 / セットアップ参照先コメント、`set -euo pipefail` は本体側で宣言済みのためモジュールでは関数定義のみ）
  - 低レベルロガー（`qa_log` / `qa_warn` / `qa_error`、`mq_log` 系、`ar_log` 系、`pp_log` 系、`pi_log` 系、`drr_log` 系）を issue-watcher.sh から **移動のみ（cut & paste）** で集約
  - 日付フォーマット `qa_format_iso8601` を移動
  - worktree 系（`_worktree_path` / `_worktree_is_registered` / `_worktree_ensure` / `_worktree_reset`）を移動（モジュール内依存を閉じる）
  - slot 系（`_slot_lock_path` / `_slot_acquire` / `_slot_release`）と hook（`_hook_invoke`）を移動
  - issue-watcher.sh 側からは移動した関数定義を削除する。`dispatcher_log` / `dispatcher_warn` は本体に残す（前方参照）
  - 関数本体・シグネチャ・戻り値・副作用・グローバル変数参照を一切変えない（差分等価）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9_
  - _Boundary: CoreUtils.Loggers, CoreUtils.DateFormat, CoreUtils.Worktree, CoreUtils.Slot, CoreUtils.Hook_

- [ ] 2. issue-watcher.sh にモジュール動的ロード基盤を追加する
  - 冒頭（PATH prepend 直後）に `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` を追加（cwd 非依存解決）
  - `REQUIRED_MODULES=( "core_utils.sh" )` マニフェストを定義し、`SCRIPT_DIR/modules/` 基準で source ループを実装
  - 必須モジュール欠落時にモジュール名を含む stderr メッセージを出し `exit 1`
  - ロード成否を運用者がログから判別可能な形で記録（成功時も観測可能な 1 行）
  - 既存メインフロー（`_dispatcher_run` 即時実行）の前にロードを完了させる。env var / exit code / ログ出力先 / ラベル遷移契約 / cron 起動文字列は変えない
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, NFR 1.1, NFR 1.2, NFR 1.3, NFR 1.4, NFR 1.5, NFR 1.6, NFR 3.1_
  - _Boundary: ModuleLoader_
  - _Depends: 1_

- [ ] 3. install.sh に modules 再帰配置を追加する
  - `copy_modules_recursive <src_dir> <dest_dir>` ヘルパーを新規追加（`find` ベースで相対パス階層を保持、既存 `classify_action` / `log_action` / `ensure_dir` を再利用、新規分類ロジックを作らない）
  - `*.sh` は実行ビットを保持して配置。`.bak` once-only 退避・`--force` 上書きを既存テンプレート配置と整合する規律で行う
  - modules 0 件 / ディレクトリ不在は SKIP ログを出して install 継続（エラー停止しない）
  - `$INSTALL_LOCAL` ブロック（`copy_glob_to_homebin` 呼び出し直後）で `local-watcher/bin/modules/` → `$HOME/bin/modules/` を配置
  - `--dry-run` で `[DRY-RUN]` 分類列挙・FS 無変更、再実行で冪等、sudo 不要を維持
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, NFR 2.1, NFR 2.2, NFR 3.1_
  - _Boundary: InstallModuleCopier_

- [ ] 4. 既存スモークテストの抽出元を core_utils.sh に拡張する
  - `repo_prefix_log_test.sh` / `verify_pushed_or_retry_test.sh` / `qa_run_claude_stage_test.sh` の 3 テストのみが移動対象関数（`qa_log` 系 / `mq_log` 系 / `pi_log` 系 / `drr_log` 系）を抽出するため、抽出元に `modules/core_utils.sh` を追加する
  - 移動対象関数は core_utils.sh から、本体に残る関数（`mqr_log` 系等）は issue-watcher.sh から抽出するよう各テストの `extract_function` 呼び出し元ファイルを修正
  - `repo_prefix_log_test.sh` の source-level grep（dirty working tree イベント）は本体メインフロー対象のため変更不要であることを確認
  - 共通抽出ヘルパー（`local-watcher/test/lib/extract.sh`）は新設しない（投機的抽象化の回避、影響 3 テストのみ）
  - 残り 9 本の `local-watcher/test/*.sh` と `tests/local-watcher/**` が無修正で通過することを確認
  - _Requirements: 4.1, 4.2, 4.3_
  - _Boundary: TestCompat_
  - _Depends: 1_

- [ ] 5. 差分等価とモジュールロードのスモークテストを実施する
  - `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/core_utils.sh install.sh` を警告ゼロで通す
  - 全 `local-watcher/test/*.sh` と `tests/local-watcher/**` を実行し全件 PASS を確認（Req 4.1）
  - `install.sh --local --dry-run` で modules 配置が `[DRY-RUN]` 分類列挙され FS 無変更、`--local` 2 回実行で 2 回目 SKIP 中心の冪等出力を確認
  - cron-like 最小 PATH 起動（`env -i HOME=$HOME PATH=/usr/bin:/bin ...`）で SCRIPT_DIR 基準ロード成功、対象 Issue なしで正常終了、`core_utils.sh` 一時退避時にモジュール名付き stderr + exit 1 を確認
  - ラベル遷移契約（`auto-dev` → `claude-claimed` 等）が分割前と同一であることを E2E（test issue）で確認
  - _Requirements: 1.3, 1.4, 2.2, 2.3, 2.4, 4.1, NFR 1.4, NFR 1.6, NFR 2.1, NFR 3.1_
  - _Boundary: ModuleLoader, InstallModuleCopier, TestCompat_
  - _Depends: 2, 3, 4_

- [ ] 6. README を更新する
  - `local-watcher/bin/modules/` を含むディレクトリ構成図を追記
  - modules 化の migration note（既稼働ユーザーは次回 `install.sh --local` でモジュールを受け取る、cron 起動行は変更不要、`$HOME/bin/modules/core_utils.sh` が必須である旨）
  - 挙動変更（ファイル構成）を同一 PR で README へ反映（CLAUDE.md 必須事項）
  - _Requirements: 2.5, NFR 1.5_
  - _Depends: 2, 3_
