#!/usr/bin/env bash
# shellcheck shell=bash
# pr-reviewer.sh — watcher の PR Reviewer Processor モジュール (#261)
#
# 用途:
#   issue-watcher.sh から分離した PR Reviewer Processor (#261) の関数定義を集約する。
#   `PR_REVIEWER_ENABLED=true` のとき外部 AI レビューツール（`codex` または
#   `antigravity` (バイナリ名 `agy`)）を呼び出し、open PR に対するレビュー結果を
#   PR コメントとして投稿し、修正要求の VERDICT を検出した場合に `needs-iteration`
#   ラベルを付与して既存 PR Iteration Processor (#26) のループへ接続する。
#   - 入口: process_pr_reviewer（dispatcher から呼ばれる）
#   - tool 解決: pr_resolve_tool（`codex` / `antigravity` / `none` / `conflict`）
#   - 後続の健全性チェック / 候補 PR 取得 / レビュー実行 / コメント投稿 /
#     ラベル付与は後続タスク（3〜6）で順次追加する。
#
# 配置先:
#   $HOME/bin/modules/pr-reviewer.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pr_log / pr_warn / pr_error は core_utils.sh に定義済み（#261 task 1 で追加）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PR_REVIEWER_ENABLED /
#     $PR_REVIEWER_TOOL / $PR_REVIEWER_CODEX_ENABLED / $PR_REVIEWER_ANTIGRAVITY_ENABLED /
#     $PR_REVIEWER_MAX_PRS / $PR_REVIEWER_EXEC_TIMEOUT 等）は本体冒頭の Config ブロックで
#     定義される予定（task 7 で配線）。bash の遅延束縛により呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_pr_reviewer || pr_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ）。
#   - 外部 CLI: gh / git / jq / codex / agy（健全性チェック・レビュー実行は後続 task）。
#
# セットアップ参照先:
#   - 設計: docs/specs/261-feat-pr-codex-antigravity/design.md
#   - README「PR Reviewer Processor (#261)」節（task 8 で追加予定）

# ─────────────────────────────────────────────────────────────────────────────
# pr_resolve_tool: tool 選択 env を解決し排他検証する（task 2.2 で実装）
# ─────────────────────────────────────────────────────────────────────────────
# 後続 task 2.2 で本実装を追加する。task 2.1 時点では skeleton としてのプレース
# ホルダを置くと未定義参照のリスクが残るため、本ファイル内では task 2.1 の
# process_pr_reviewer が pr_resolve_tool を呼ばない skeleton に留める。task 2.2 の
# commit で pr_resolve_tool を実装し、process_pr_reviewer もサマリログに tool 名
# を含めるよう書き換える。

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_reviewer: dispatcher から呼ばれるエントリ関数
#   入力: なし（env var 群を読む）
#   出力: なし（log のみ）
#   戻り値: 0 固定（後続 processor を阻害しないため）
#   AC 1.1, 1.2, 1.3, NFR 1.1, NFR 3.1
#
# Skeleton（task 2.1）: opt-in gate（早期 return）と 1 行サマリログのみを実装。
#   - PR_REVIEWER_ENABLED が `true` と完全一致しない場合は何もせず return 0
#     （AC 1.1 / NFR 1.1: 未設定 / 空 / `True` / `1` / typo はすべて OFF）
#   - 上記以外（=true 厳密一致）はサマリログ 1 行を pr_log で出力して return 0
#     （task 2.2 以降で tool 解決・候補 PR 取得・レビュー実行を追加）
# ─────────────────────────────────────────────────────────────────────────────
process_pr_reviewer() {
  # AC 1.1: opt-in gate（=true 厳密一致のみ有効。それ以外は全て OFF）
  if [ "${PR_REVIEWER_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # AC 1.2 / NFR 3.1: サイクル開始の 1 行サマリログ（tool 解決は task 2.2 で追加）
  pr_log "cycle start (skeleton): max_prs=${PR_REVIEWER_MAX_PRS:-unset} exec_timeout=${PR_REVIEWER_EXEC_TIMEOUT:-unset}"

  return 0
}
