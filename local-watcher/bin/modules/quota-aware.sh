#!/usr/bin/env bash
# quota-aware.sh — watcher の Quota-Aware 待機制御プロセッサモジュール
#
# 用途:
#   issue-watcher.sh から切り出した quota 枯渇検出・待機制御プロセッサを集約する。
#   Claude Max の 5 時間ローリング quota 超過を Stage 実行中の claude CLI が出す
#   `rate_limit_event` / synthetic 429 で検知し、当該 Issue を `needs-quota-wait`
#   状態にして reset 予定時刻を repo slug 単位の $LOG_DIR 配下に永続化する。次サイクル
#   以降の Quota Resume Processor が reset+grace 経過した Issue からラベルを除去して
#   通常 pickup ループに戻す。
#   - qa_detect_rate_limit  : stream-json を fold して quota 枯渇イベントを検出
#   - qa_run_claude_stage   : Stage 実行 wrapper（tee + 検出 + exit 99 sentinel）
#   - qa_persist_reset_time : reset 時刻の永続化（Issue 番号 keyed JSON）
#   - qa_load_reset_time    : reset 時刻の読み出し（移行期は本文 marker フォールバック）
#   - qa_build_escalation_comment / build_partial_escalation_comment : 状況コメント生成
#   - qa_handle_quota_exceeded : quota 検出時のラベル付与・コメント投稿・永続化
#   - process_quota_resume  : Resume Processor（全 Processor 先頭で起動）
#
# 配置先:
#   $HOME/bin/modules/quota-aware.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（qa_log / qa_warn / qa_error / qa_format_iso8601）は core_utils.sh にあるため
#     本モジュールでは再定義しない。
#   - グローバル変数（$REPO / $QUOTA_AWARE_ENABLED / $LABEL_NEEDS_QUOTA_WAIT / reset 永続化先
#     パス等）は本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh / jq / date / claude。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）
#   設計参照: docs/specs/66-feat-watcher-claude-max-quota-rate-limit/design.md
