#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh 内の `parse_review_result()` 関数定義行と、
#       `process_claude_review_status_catchup` の **top-level call site** の行番号を
#       機械抽出し、「定義行 < 呼び出し行」が成り立つことを検証する近接テスト。
#       併せて `parse_review_result` の依存関数 `extract_review_result_token()` も
#       同じ load-order 制約を満たすことを検証する。
#
#       Issue #385: bash は top-level コードを順次実行するため、関数定義が最初の
#       top-level 呼び出しより後ろにあると `declare -F parse_review_result` が false を返し、
#       catch-up 経路（`process_claude_review_status_catchup` / pr-reviewer.sh）が
#       `reason=parse-helper-missing` の WARN を残して safe-skip する。結果として
#       AND 二重 opt-in（`PR_REVIEWER_STATUS_CHECK_ENABLED=true` AND
#       `FULL_AUTO_ENABLED=true`）環境で `claude-review` commit status が永久に publish
#       されない silent load-order bug が発生する。本テストは当該 bug の回帰を機械的に
#       検出する。
#
#       本 bug は #376 で修正した `full_auto_enabled` 前方参照と同種の load-order 系
#       回帰であり、`full_auto_enabled_load_order_test.sh` と並列の役割を持つ。
#
#       検証する AC (docs/specs/385-fix-pr-reviewer-claude-review-catch-up-p/requirements.md):
#         - Req 1.1: 定義位置が `process_claude_review_status_catchup` の call site より前
#         - Req 1.2: 定義は 1 箇所のみ（重複定義なし）
#         - Req 1.5: 全 caller の行番号が定義行番号より大きいことを維持
#         - Req 5.1: 定義行 < 呼び出し行 を機械検証する近接テストを提供
#         - Req 5.2: 回帰時に定義行番号と呼び出し行番号を 1 件以上特定可能に出力
#         - Req 5.3: 既存テストランナ（local-watcher/test/ の bash イディオム）から起動可能
#         - NFR 3.3: fail 出力に定義行番号 / catch-up 呼び出し行番号を含め grep 1 回で原因特定
#
# 配置先: local-watcher/test/pr_reviewer_parse_review_result_load_order_test.sh
# 依存:   bash 4+, awk, grep, sed, cut
# 実行:   bash local-watcher/test/pr_reviewer_parse_review_result_load_order_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

# ─── 共通: top-level call site の行番号抽出 ───
# `process_claude_review_status_catchup` の top-level 呼び出し（行頭が
# `process_claude_review_status_catchup ||` で始まる行）を抽出する。本体内 function
# 定義経由の参照（コメント / 関数本体内呼び出し）は除外し、top-level 順次実行で
# 評価される行のみを対象にする。
CATCHUP_CALL_LINE=$(grep -nE '^process_claude_review_status_catchup[[:space:]]*\|\|' "$WATCHER_SH" | head -n1 | cut -d: -f1 || true)

# ─── load-order 検証ヘルパ ───
# 引数: $1=関数名 / $2=Req 番号タグ（メッセージ用）
verify_load_order() {
  local fn_name="$1"
  local req_tag="$2"

  # 関数定義行の抽出。bash の関数定義は典型的に `<name>() {` 形式。
  local def_lines
  def_lines=$(grep -n "^${fn_name}() {" "$WATCHER_SH" | cut -d: -f1)
  local def_count
  def_count=$(echo -n "$def_lines" | grep -c . || true)

  # ─── 1. 重複定義チェック ───
  if [ "$def_count" -eq 1 ]; then
    echo "PASS: ${req_tag}: ${fn_name} の定義は 1 箇所のみ"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: ${req_tag}: ${fn_name} の定義が 1 箇所ではない（count=${def_count}）"
    echo "  定義行: $(echo "$def_lines" | tr '\n' ' ')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  if [ "$def_count" -eq 0 ]; then
    echo "ERROR: ${fn_name} の定義が見つからないため後続テストを skip" >&2
    return
  fi

  local def_line
  def_line=$(echo "$def_lines" | head -n1)

  # ─── 2. 全 caller の抽出（コメント行・定義行は除外） ───
  local all_refs caller_lines caller_count
  all_refs=$(grep -n "${fn_name}" "$WATCHER_SH" || true)
  caller_lines=$(echo "$all_refs" | awk -v fn_def="${fn_name}() {" -F: '
    {
      lineno = $1
      sub(/^[0-9]+:/, "", $0)
      content = $0
      trimmed = content
      sub(/^[[:space:]]+/, "", trimmed)
      # skip comment lines
      if (trimmed ~ /^#/) next
      # skip the function definition line itself
      if (trimmed == fn_def) next
      print lineno ":" content
    }
  ')
  caller_count=$(echo -n "$caller_lines" | grep -c . || true)

  echo ""
  echo "--- ${fn_name} load-order 検査 ---"
  echo "  定義行: $def_line"
  echo "  caller 数: $caller_count"

  # ─── 3. 各 caller について「定義行 < caller 行」を検証 ───
  if [ "$caller_count" -eq 0 ]; then
    echo "PASS: ${req_tag}: caller 行数=0 のため load-order 検査は trivially 成立"
    PASS_COUNT=$((PASS_COUNT + 1))
    return
  fi

  local earliest_caller_line=""
  local violations=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local caller_lineno caller_content
    caller_lineno=$(echo "$line" | cut -d: -f1)
    caller_content=$(echo "$line" | cut -d: -f2-)

    if [ -z "$earliest_caller_line" ] || [ "$caller_lineno" -lt "$earliest_caller_line" ]; then
      earliest_caller_line="$caller_lineno"
    fi

    if [ "$caller_lineno" -le "$def_line" ]; then
      violations=$((violations + 1))
      local enclosing_symbol
      enclosing_symbol=$(awk -v target="$caller_lineno" '
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { last = $1; last_line = NR }
        NR == target { print last " (defined at line " last_line ")"; exit }
      ' "$WATCHER_SH")
      echo "FAIL: ${req_tag}: 前方参照を検出"
      echo "  定義行          : $def_line"
      echo "  caller 行       : $caller_lineno"
      echo "  caller 内容     : $caller_content"
      echo "  caller シンボル : ${enclosing_symbol:-(top-level)}"
    fi
  done <<EOF
$caller_lines
EOF

  if [ "$violations" -eq 0 ]; then
    echo "PASS: ${req_tag}: 全 ${caller_count} 件の caller が定義位置より後ろにある"
    echo "  最も早い caller: 行 $earliest_caller_line （定義行 $def_line より $((earliest_caller_line - def_line)) 行後）"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: ${req_tag}: 前方参照 caller が $violations 件存在"
    echo "  原因: bash は top-level を順次実行するため、定義行 ($def_line) より前の caller"
    echo "        から呼ぶと catch-up の declare -F が false 評価となり parse-helper-missing で skip"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─── 1. parse_review_result の load-order 検証 ───
verify_load_order "parse_review_result" "Req 1.1 / 1.2 / 1.5 / 5.1"

# ─── 2. extract_review_result_token の load-order 検証 ───
# parse_review_result の依存関数。同じ load-order 制約を満たす必要がある。
verify_load_order "extract_review_result_token" "Req 1.1 / 1.5 (依存関数)"

# ─── 3. Req 1.1 補完: parse_review_result 定義が process_claude_review_status_catchup の
#       top-level call site（catch-up 経路の発火点）より前にあることを明示的に assert する。
#       Issue #385 の core: catch-up 経路が parse_review_result を `declare -F` で参照する。
echo ""
echo "--- Req 1.1: parse_review_result vs process_claude_review_status_catchup call site ---"

if [ -z "$CATCHUP_CALL_LINE" ]; then
  echo "PASS: Req 1.1: process_claude_review_status_catchup の top-level call site が見つからないため trivially 成立"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  PARSE_DEF_LINE=$(grep -n '^parse_review_result() {' "$WATCHER_SH" | head -n1 | cut -d: -f1 || true)
  if [ -z "$PARSE_DEF_LINE" ]; then
    echo "FAIL: Req 1.1: parse_review_result の定義行が見つからない"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  elif [ "$PARSE_DEF_LINE" -lt "$CATCHUP_CALL_LINE" ]; then
    echo "PASS: Req 1.1: parse_review_result 定義行 ($PARSE_DEF_LINE) は process_claude_review_status_catchup call site ($CATCHUP_CALL_LINE) より前"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: Req 1.1: parse_review_result 定義行 ($PARSE_DEF_LINE) が process_claude_review_status_catchup call site ($CATCHUP_CALL_LINE) 以後"
    echo "  原因: catch-up 経路が parse_review_result を declare -F で参照するため"
    echo "        定義行 < call site 行 を満たさないと parse-helper-missing で永続 skip する"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ─── 4. Req 4.1 補完: caller 棚卸し（参考表示）───
# 同種 bug の再発防止のため、本 PR 修正後の parse_review_result 全 caller を一覧表示する。
# 失敗時の調査効率向上目的の参考出力（PASS/FAIL カウントには加算しない）。
echo ""
echo "--- Req 4.1: parse_review_result caller 棚卸し（参考） ---"
grep -n 'parse_review_result' "$WATCHER_SH" | awk -F: '
  {
    lineno = $1
    sub(/^[0-9]+:/, "", $0)
    trimmed = $0
    sub(/^[[:space:]]+/, "", trimmed)
    if (trimmed ~ /^#/) next
    if (trimmed ~ /^parse_review_result\(\)[[:space:]]*\{/) next
    print "  line " lineno ": " trimmed
  }
'

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
