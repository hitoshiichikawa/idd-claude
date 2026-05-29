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
#   - tool 解決と排他検証: pr_resolve_tool（出力: `codex` / `antigravity` /
#     `none` / `conflict`、戻り値 0 = ok / 1 = conflict / 2 = none）
#   - 健全性チェック (installed / authenticated) を task 3 で追加。
#     候補 PR 取得 / レビュー実行 / コメント投稿 / ラベル付与は後続タスク
#     （4〜6）で順次追加する。
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
# pr_resolve_tool: PR_REVIEWER_TOOL / *_CODEX_ENABLED / *_ANTIGRAVITY_ENABLED から
#   使用ツールを解決する（design.md Decision 1 の解決順序）
#
#   入力: 環境変数のみ
#     - PR_REVIEWER_TOOL: canonical な単一値（"codex" / "antigravity" / それ以外）
#     - PR_REVIEWER_CODEX_ENABLED: alias（"=true" 厳密一致のみ有効）
#     - PR_REVIEWER_ANTIGRAVITY_ENABLED: alias（"=true" 厳密一致のみ有効）
#   出力: stdout に "codex" / "antigravity" / "none" / "conflict" のいずれか 1 語
#   戻り値: 0 = ok（codex / antigravity）
#           1 = conflict（両方有効化、排他エラー）
#           2 = none（どちらも有効化されていない）
#   AC: 2.1, 2.2, 2.3, 2.5, NFR 3.1
#
#   解決順序（design.md Decision 1）:
#     1. PR_REVIEWER_TOOL が "codex" / "antigravity" に厳密一致 → 当該値を採用
#     2. PR_REVIEWER_TOOL が 上記 2 値以外で非空 → WARN + alias fallback
#     3. alias を独立評価:
#        - codex_on  = (PR_REVIEWER_CODEX_ENABLED == "true")
#        - agy_on    = (PR_REVIEWER_ANTIGRAVITY_ENABLED == "true")
#     4. 片方のみ true → 採用、両方 true → conflict、両方 false → none
# ─────────────────────────────────────────────────────────────────────────────
pr_resolve_tool() {
  local tool_canonical="${PR_REVIEWER_TOOL:-}"
  local codex_on="${PR_REVIEWER_CODEX_ENABLED:-false}"
  local agy_on="${PR_REVIEWER_ANTIGRAVITY_ENABLED:-false}"

  # Step 1: PR_REVIEWER_TOOL が canonical 2 値に厳密一致 → 即採用
  case "$tool_canonical" in
    codex)
      echo "codex"
      return 0
      ;;
    antigravity)
      echo "antigravity"
      return 0
      ;;
    "")
      # 未設定 → alias 評価へフォールスルー
      ;;
    *)
      # canonical 2 値以外の非空値 → WARN + alias 評価へフォールバック（Decision 1 step 6）
      # pr_warn は stderr に出すため stdout の "tool 名" 契約を汚さない
      pr_warn "PR_REVIEWER_TOOL='${tool_canonical}' は canonical 値 (codex|antigravity) ではありません。PR_REVIEWER_CODEX_ENABLED / PR_REVIEWER_ANTIGRAVITY_ENABLED で alias 解決します"
      ;;
  esac

  # Step 2: alias 独立評価（厳密 =true のみ有効。それ以外（"True" / "1" / typo）は false 扱い）
  if [ "$codex_on" = "true" ] && [ "$agy_on" = "true" ]; then
    # AC 2.3: 排他エラー
    pr_error "PR_REVIEWER_CODEX_ENABLED と PR_REVIEWER_ANTIGRAVITY_ENABLED の両方が有効化されています（排他エラー）"
    echo "conflict"
    return 1
  fi

  if [ "$codex_on" = "true" ]; then
    # AC 2.1
    echo "codex"
    return 0
  fi

  if [ "$agy_on" = "true" ]; then
    # AC 2.2
    echo "antigravity"
    return 0
  fi

  # AC 2.5: どちらも無効
  # stdout は "none" の単一 token のみを返す契約のため、観測ログは >&2 へ。
  # 呼び出し元 process_pr_reviewer は command substitution で stdout を捕捉する。
  pr_log "tool 未指定（PR_REVIEWER_TOOL 未設定 かつ PR_REVIEWER_{CODEX,ANTIGRAVITY}_ENABLED いずれも true ではない）。サイクルを skip します" >&2
  echo "none"
  return 2
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_installed: 指定ツールの実行ファイルが PATH 上に存在するか確認
#
#   入力: $1 = "codex" | "antigravity"
#         （Decision 2 / 3: antigravity の実バイナリ名は `agy`）
#   出力: なし（観測ログは pr_log のみ）
#   戻り値: 0 = ok (installed) / 1 = not-installed
#   AC: 3.1
#
#   - `command -v "$bin"` で PATH 上の実行ファイル存在を確認する pure check。
#     stdout は捨てて戻り値のみを契約とする（呼び出し元は rc で分岐）。
#   - "codex" / "antigravity" 以外の入力は内部矛盾（pr_resolve_tool が canonical
#     2 値以外を返すことは無い設計）。安全側に倒し、観測ログを残して
#     not-installed (rc=1) 相当を返す。
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_installed() {
  local tool="${1:-}"
  local bin=""

  case "$tool" in
    codex)
      bin="codex"
      ;;
    antigravity)
      bin="agy"
      ;;
    *)
      pr_error "pr_check_tool_installed: 未知の tool 名 '${tool}'（'codex' / 'antigravity' のいずれか）。not-installed として扱います"
      return 1
      ;;
  esac

  if command -v "$bin" >/dev/null 2>&1; then
    pr_log "tool installed check: tool=${tool} bin=${bin} result=ok"
    return 0
  fi

  pr_log "tool installed check: tool=${tool} bin=${bin} result=not-installed"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_authenticated: 指定ツールが認証済みか確認
#
#   入力: $1 = "codex" | "antigravity"
#   出力: なし（観測ログは pr_log のみ。auth コマンドの stdout/stderr は破棄）
#   戻り値: 0 = ok (authenticated)
#           1 = not-authenticated
#           2 = check 機構が無効（env 未設定 / 空文字 = 既定 skip）
#   AC: 3.2
#
#   - `PR_REVIEWER_<TOOL>_AUTH_CMD` env を解決し、空文字なら skip (rc=2)。
#     既定値は task 7 で issue-watcher.sh 本体側に焼き込まれる:
#       - codex: `codex login status`
#       - agy:   `""`（既定 skip。Decision 3）
#     本 task 範囲では env 未設定 = 空文字扱い = skip で OK。
#   - 非空なら `bash -c "$auth_cmd"` を `>/dev/null 2>&1` で stdout/stderr を完全
#     破棄して実行（Security Considerations: auth token / 認証 URL 等の流出防止）。
#   - 終了コード 0 → ok (rc=0)、非ゼロ → not-authenticated (rc=1)。
#   - `eval` は使わない（Decision 9）。`bash -c` で subshell に閉じ込める。
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_authenticated() {
  local tool="${1:-}"
  local auth_cmd=""

  case "$tool" in
    codex)
      auth_cmd="${PR_REVIEWER_CODEX_AUTH_CMD:-}"
      ;;
    antigravity)
      auth_cmd="${PR_REVIEWER_ANTIGRAVITY_AUTH_CMD:-}"
      ;;
    *)
      pr_error "pr_check_tool_authenticated: 未知の tool 名 '${tool}'（'codex' / 'antigravity' のいずれか）。skip として扱います"
      return 2
      ;;
  esac

  if [ -z "$auth_cmd" ]; then
    # AC 3.2 既定: 空文字 = check 機構が無効（skip）
    pr_log "tool authenticated check: tool=${tool} result=skipped (auth cmd unset)"
    return 2
  fi

  # auth コマンド実行: stdout / stderr を完全破棄（Security Considerations）
  if bash -c "$auth_cmd" >/dev/null 2>&1; then
    pr_log "tool authenticated check: tool=${tool} result=ok"
    return 0
  fi

  pr_log "tool authenticated check: tool=${tool} result=not-authenticated"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_reviewer: dispatcher から呼ばれるエントリ関数
#   入力: なし（env var 群を読む）
#   出力: なし（log のみ）
#   戻り値: 0 固定（後続 processor を阻害しないため）
#   AC 1.1, 1.2, 1.3, NFR 1.1, NFR 3.1
#
#   - PR_REVIEWER_ENABLED が `true` と完全一致しない場合は何もせず return 0
#     （AC 1.1 / NFR 1.1: 未設定 / 空 / `True` / `1` / typo はすべて OFF）
#   - 上記以外（=true 厳密一致）は tool 解決と排他検証を行い、サマリログ 1 行を
#     pr_log で出力する。conflict / none の場合も dispatcher fail-continue 契約に
#     従い return 0（後続 task 3 以降で kind=conflict-tool の PR コメント投稿を追加）。
# ─────────────────────────────────────────────────────────────────────────────
process_pr_reviewer() {
  # AC 1.1: opt-in gate（=true 厳密一致のみ有効。それ以外は全て OFF）
  if [ "${PR_REVIEWER_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # AC 2.x: tool 解決（pr_resolve_tool は stdout に tool 名 / 戻り値で状態を返す）
  local resolved_tool
  local resolve_rc=0
  resolved_tool=$(pr_resolve_tool) || resolve_rc=$?

  # AC 1.2 / NFR 3.1: サイクル開始の 1 行サマリログ（tool / max_prs / exec_timeout）
  pr_log "cycle start: tool=${resolved_tool} max_prs=${PR_REVIEWER_MAX_PRS:-unset} exec_timeout=${PR_REVIEWER_EXEC_TIMEOUT:-unset}"

  # AC 2.3 / 2.5: conflict / none は本サイクルでレビュー実行に進まない。
  # （conflict 時の PR コメント投稿 (kind=conflict-tool) は後続 task 3 / 5 で追加）
  if [ "$resolve_rc" -ne 0 ]; then
    return 0
  fi

  # task 3 以降で健全性チェック / 候補 PR 取得 / レビュー実行を追加する。
  return 0
}
