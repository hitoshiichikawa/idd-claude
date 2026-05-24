#!/usr/bin/env bash
# merge-queue.sh — watcher の Merge Queue 制御プロセッサモジュール
#
# 用途:
#   issue-watcher.sh から切り出した approved PR のマージ順序制御・再チェックプロセッサを
#   集約する。
#   Phase A 本体（process_merge_queue）: approve 済み open PR の mergeability を能動検知し、
#     CONFLICTING には needs-rebase ラベル + 状況コメント、MERGEABLE かつ base が古い場合は
#     ローカル自動 rebase + force-with-lease push を行う。
#   Phase A Re-check（process_merge_queue_recheck）: needs-rebase 付き approved PR を別レーンで
#     再評価し、mergeable=MERGEABLE に戻った PR のラベルを自動除去する。
#   - mq_pr_has_label / mq_handle_conflict / mq_try_rebase_pr / process_merge_queue
#   - mqr_log / mqr_warn / mqr_error : merge-queue-recheck 専用ロガー
#     （core_utils.sh には無く本体由来のため本モジュールへ移す）
#   - process_merge_queue_recheck
#
# 配置先:
#   $HOME/bin/modules/merge-queue.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（mq_log / mq_warn / mq_error）は core_utils.sh にあるため再定義しない。
#     mqr_* は本体由来のため本モジュールに移す（core_utils.sh は変更しない）。
#   - グローバル変数（$MERGE_QUEUE_ENABLED / $MERGE_QUEUE_RECHECK_ENABLED /
#     $MERGE_QUEUE_GIT_TIMEOUT / $LABEL_NEEDS_REBASE / $MERGE_QUEUE_BASE_BRANCH 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh / git / jq。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）
