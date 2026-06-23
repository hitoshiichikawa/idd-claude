#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh 内の `full_auto_enabled()` 関数定義行と
#       全 caller の出現行を機械抽出し、「定義行 < すべての caller 行」が成り立つ
#       ことを検証する近接テスト。
#
#       Issue #375: bash は top-level コードを順次実行するため、関数定義が最初の
#       呼び出し位置より後ろにあると `command not found` (rc=127) となり、
#       `if ! full_auto_enabled; then return 0; fi` ガードが真と評価されて
#       auto-merge / auto-merge-design / dr_unblock_sweep / needs-decisions-auto /
#       dep-cycle-detect 等が無言で no-op に倒れる load-order bug を発生させる。
#       本テストは当該 bug の回帰を機械的に検出する。
#
#       検証する AC (docs/specs/375-fix-watcher-full-auto-enabled-auto-merge/requirements.md):
#         - Req 1.1: 定義位置が `process_auto_merge` の call site より前であること
#         - Req 1.2: 定義は 1 箇所のみ（重複定義なし）
#         - Req 1.6: すべての呼び出し位置が定義位置より後ろにあることを維持
#         - Req 3.1: 全 caller を機械抽出して「定義行 < caller 行」を assert
#         - Req 3.2: fail 時に定義行 / 最も早い caller 行 / caller シンボル名を出力
#         - Req 3.3: 既存テストランナ（local-watcher/test/ の bash イディオム）から起動可能
#         - NFR 3.2: 追加テストの bash スクリプトが bash -n / shellcheck クリーン
#
# 配置先: local-watcher/test/full_auto_enabled_load_order_test.sh
# 依存:   bash 4+, awk, grep, sed
# 実行:   bash local-watcher/test/full_auto_enabled_load_order_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

# ─── 1. 関数定義行の抽出 ───
# bash の関数定義は典型的に `<name>() {` で始まる。`full_auto_enabled()` の定義行を
# 抽出する（行頭が `full_auto_enabled() {` で始まる行のみ。コメント中の `full_auto_enabled`
# 言及は除外）。
DEF_LINES=$(grep -n '^full_auto_enabled() {' "$WATCHER_SH" | cut -d: -f1)
DEF_COUNT=$(echo -n "$DEF_LINES" | grep -c . || true)

# ─── 1a. 重複定義チェック（Req 1.2） ───
if [ "$DEF_COUNT" -eq 1 ]; then
  echo "PASS: Req 1.2: full_auto_enabled の定義は 1 箇所のみ"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.2: full_auto_enabled の定義が 1 箇所ではない（count=$DEF_COUNT）"
  echo "  定義行: $(echo "$DEF_LINES" | tr '\n' ' ')"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ "$DEF_COUNT" -eq 0 ]; then
  echo "ERROR: 定義が見つからないため後続テストを skip" >&2
  echo "==========================================="
  echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
  echo "==========================================="
  exit 1
fi

# 定義行は 1 つだけ採用（複数あった場合は最も早い位置を採用して比較）
DEF_LINE=$(echo "$DEF_LINES" | head -n1)

# ─── 2. 全 caller の抽出 ───
# `full_auto_enabled` を参照する行から以下を除外:
#   - 関数定義行自体（`^full_auto_enabled() {`）
#   - コメント行（行頭 `#` で始まる行 / インデント込みコメントも対象）
# 残った行が真の caller。awk で行番号 + 行内容を出力する。
ALL_REFS=$(grep -n 'full_auto_enabled' "$WATCHER_SH" || true)

# caller 行抽出: 関数定義行とコメント行を除外
CALLER_LINES=$(echo "$ALL_REFS" | awk -F: '
  {
    # $1 = lineno, $2.. = line content (rejoin)
    lineno = $1
    sub(/^[0-9]+:/, "", $0)
    content = $0
    # trim leading whitespace for comment detection
    trimmed = content
    sub(/^[[:space:]]+/, "", trimmed)
    # skip comment lines
    if (trimmed ~ /^#/) next
    # skip the function definition line itself
    if (trimmed ~ /^full_auto_enabled\(\)[[:space:]]*\{/) next
    # それ以外は caller として採用
    print lineno ":" content
  }
')

CALLER_COUNT=$(echo -n "$CALLER_LINES" | grep -c . || true)

echo ""
echo "--- load-order 検査 (Req 1.1 / 1.6 / 3.1) ---"
echo "  定義行: $DEF_LINE"
echo "  caller 数: $CALLER_COUNT"

if [ "$CALLER_COUNT" -eq 0 ]; then
  # caller がない = 関数が dead code。回帰防止対象外だが warning として PASS 扱い
  echo "PASS: Req 3.1: caller 行数=0 のため load-order 検査は trivially 成立"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  # ─── 3. 各 caller について「定義行 < caller 行」を検証（Req 1.1 / 1.6 / 3.1） ───
  EARLIEST_CALLER_LINE=""
  EARLIEST_CALLER_SYMBOL=""
  VIOLATIONS=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    caller_lineno=$(echo "$line" | cut -d: -f1)
    caller_content=$(echo "$line" | cut -d: -f2-)

    if [ -z "$EARLIEST_CALLER_LINE" ] || [ "$caller_lineno" -lt "$EARLIEST_CALLER_LINE" ]; then
      EARLIEST_CALLER_LINE="$caller_lineno"
    fi

    if [ "$caller_lineno" -le "$DEF_LINE" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      # この caller を含む関数名を遡って取得（直近の `<name>() {` を `awk` で検出）
      enclosing_symbol=$(awk -v target="$caller_lineno" '
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { last = $1; last_line = NR }
        NR == target { print last " (defined at line " last_line ")"; exit }
      ' "$WATCHER_SH")
      echo "FAIL: Req 1.1 / 1.6: 前方参照を検出"
      echo "  定義行       : $DEF_LINE"
      echo "  caller 行    : $caller_lineno"
      echo "  caller 内容  : $caller_content"
      echo "  caller シンボル: ${enclosing_symbol:-(top-level)}"
      if [ -z "$EARLIEST_CALLER_SYMBOL" ]; then
        EARLIEST_CALLER_SYMBOL="$enclosing_symbol"
      fi
    fi
  done <<EOF
$CALLER_LINES
EOF

  if [ "$VIOLATIONS" -eq 0 ]; then
    echo "PASS: Req 1.1 / 1.6 / 3.1: 全 $CALLER_COUNT 件の caller が定義位置より後ろにある"
    echo "  最も早い caller: 行 $EARLIEST_CALLER_LINE （定義行 $DEF_LINE より $((EARLIEST_CALLER_LINE - DEF_LINE)) 行後）"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: Req 1.1 / 1.6 / 3.1: 前方参照 caller が $VIOLATIONS 件存在"
    echo "  原因: bash は top-level を順次実行するため、定義行 ($DEF_LINE) より前の caller"
    echo "        ($EARLIEST_CALLER_LINE) から呼ぶと 'command not found' で no-op に倒れる"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ─── 4. Req 1.1 補完: 定義位置が Config ブロック内（最も早い caller である process_auto_merge の
#       call site）より前にあることを明示的に assert する。process_auto_merge の top-level
#       call site が動いた場合に追従できるよう、`^process_auto_merge ||` パターンで検索する。
PAM_LINES=$(grep -n '^process_auto_merge ||' "$WATCHER_SH" | cut -d: -f1 || true)
PAM_FIRST=$(echo "$PAM_LINES" | head -n1)

if [ -n "$PAM_FIRST" ]; then
  if [ "$DEF_LINE" -lt "$PAM_FIRST" ]; then
    echo "PASS: Req 1.1: 定義行 ($DEF_LINE) は process_auto_merge call site ($PAM_FIRST) より前"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: Req 1.1: 定義行 ($DEF_LINE) が process_auto_merge call site ($PAM_FIRST) 以後"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "PASS: Req 1.1: process_auto_merge call site が見つからないため trivially 成立（process_auto_merge が消えた可能性あり）"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
