#!/usr/bin/env bash
# auto-rebase.sh — watcher の Auto Rebase 制御プロセッサモジュール
#
# 用途:
#   issue-watcher.sh から切り出した、コンフリクトした approved PR の自動 Rebase
#   プロセッサ（Phase D / #17）を集約する。
#   `needs-rebase` + approved な open PR を Claude 経由で rebase し、変更ファイルが
#   MECHANICAL_PATHS allowlist に閉じている場合は approve を維持して auto-merge に到達
#   させる。allowlist 外の差分（= semantic 判断含む）が出た場合は approving review を
#   review dismissal API で剥がし、`ready-for-review` に戻して再レビューを誘導する。
#   `AUTO_REBASE_MODE=claude` を明示したリポジトリでのみ起動し、未設定 / off / 不正値の
#   リポジトリは導入前と完全に同一の挙動を維持する（opt-in）。
#   - ar_fetch_candidates / ar_build_prompt / ar_run_claude_rebase / ar_classify_diff
#   - ar_apply_mechanical / ar_dismiss_all_approvals / ar_apply_semantic
#   - ar_escalate_to_failed / ar_handle_pr / process_auto_rebase
#
# 配置先:
#   $HOME/bin/modules/auto-rebase.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（ar_log / ar_warn / ar_error）は core_utils.sh にあるため再定義しない。
#   - グローバル変数（$AUTO_REBASE_MODE / $AUTO_REBASE_GIT_TIMEOUT / allowlist 設定 /
#     $LABEL_NEEDS_REBASE / $LABEL_FAILED / $BASE_BRANCH 等）は本体冒頭の Config ブロックで
#     定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh / git / claude / jq。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）
