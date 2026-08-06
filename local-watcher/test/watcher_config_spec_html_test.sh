#!/usr/bin/env bash
# =============================================================================
# watcher_config_spec_html_test.sh — Spec HTML 並行生成の config 正規化回帰テスト
#   (#526 / Task 1)
#
# 対象: local-watcher/bin/watcher-config.sh の SPEC_HTML_* 定義・正規化ブロック。
#   watcher-config.sh はトップレベル副作用（env-loader source / REPO 派生等）を持ち
#   単体 source できないため、awk で SPEC_HTML_* の代入・正規化ブロックのみを
#   抽出し、env を差し替えた bash -c 内で eval して source 後の値を検証する
#   （config の実コードを実行するため、正規化ロジックの再実装ではない）。
#
# 検証内容:
#   - SPEC_HTML_ENABLED: `true` 厳密一致のみ ON。未設定 / 空 / `True` / `1` /
#     `false` / typo はすべて `false`（安全側 / Req 1.1, 1.3 / NFR 1.1）
#   - SPEC_HTML_TIMEOUT: 非整数 / 負値 / 0 は既定 60 に正規化、正の整数はそのまま
#   - 補助 env（RENDER_BIN / RENDER_CMD / TARGETS）の既定値
#
# 配置先: local-watcher/test/watcher_config_spec_html_test.sh
# 実行:   bash local-watcher/test/watcher_config_spec_html_test.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"

CONFIG="$SCRIPT_DIR/../bin/watcher-config.sh"

PASS_COUNT=0
FAIL_COUNT=0

if [ ! -f "$CONFIG" ]; then
  echo "FATAL: watcher-config.sh not found at $CONFIG" >&2
  exit 1
fi

# SPEC_HTML_ENABLED の代入行から SPEC_HTML_TARGETS の代入行までを抽出。
# 代入・case 正規化を含み、先頭のコメントブロックは含めない（eval 対象は実コードのみ）。
SPEC_HTML_BLOCK="$(awk '
  /^SPEC_HTML_ENABLED=/ { f = 1 }
  f { print }
  /^SPEC_HTML_TARGETS=/ { f = 0 }
' "$CONFIG")"

if [ -z "$SPEC_HTML_BLOCK" ]; then
  echo "FATAL: SPEC_HTML_* 正規化ブロックを watcher-config.sh から抽出できませんでした" >&2
  exit 1
fi

# normalized <var> [ENV=VAL ...]
#   指定 env のもとで SPEC_HTML_* ブロックを eval し、<var> の正規化後の値を stdout に返す。
#   env 未指定の変数は親環境から継承しない（テスト冒頭で unset 済み）ため「未設定」検証になる。
normalized() {
  local var="$1"
  shift
  env "$@" bash -c "set -uo pipefail; $SPEC_HTML_BLOCK
printf '%s' \"\${$var}\""
}

# 親環境に残留していると「未設定」ケースが誤判定になるため明示的に除去する。
unset SPEC_HTML_ENABLED SPEC_HTML_RENDER_BIN SPEC_HTML_RENDER_CMD SPEC_HTML_TIMEOUT SPEC_HTML_TARGETS

echo "=== SPEC_HTML_ENABLED 正規化（true 厳密一致のみ ON / Req 1.1, 1.3）==="
assert_eq "ENABLED: true → true (ON)"        "true"  "$(normalized SPEC_HTML_ENABLED SPEC_HTML_ENABLED=true)"
assert_eq "ENABLED: 未設定 → false (OFF)"     "false" "$(normalized SPEC_HTML_ENABLED)"
assert_eq "ENABLED: 空文字 → false (OFF)"     "false" "$(normalized SPEC_HTML_ENABLED SPEC_HTML_ENABLED=)"
assert_eq "ENABLED: True → false (OFF)"       "false" "$(normalized SPEC_HTML_ENABLED SPEC_HTML_ENABLED=True)"
assert_eq "ENABLED: 1 → false (OFF)"          "false" "$(normalized SPEC_HTML_ENABLED SPEC_HTML_ENABLED=1)"
assert_eq "ENABLED: false → false (OFF)"      "false" "$(normalized SPEC_HTML_ENABLED SPEC_HTML_ENABLED=false)"
assert_eq "ENABLED: typo(yes) → false (OFF)"  "false" "$(normalized SPEC_HTML_ENABLED SPEC_HTML_ENABLED=yes)"
assert_eq "ENABLED: TRUE → false (OFF)"       "false" "$(normalized SPEC_HTML_ENABLED SPEC_HTML_ENABLED=TRUE)"

echo "=== SPEC_HTML_TIMEOUT 正規化（非整数 / ≤0 は既定 60 / Req 1.3）==="
assert_eq "TIMEOUT: 未設定 → 60"       "60" "$(normalized SPEC_HTML_TIMEOUT)"
assert_eq "TIMEOUT: 非整数 abc → 60"   "60" "$(normalized SPEC_HTML_TIMEOUT SPEC_HTML_TIMEOUT=abc)"
assert_eq "TIMEOUT: 負値 -5 → 60"      "60" "$(normalized SPEC_HTML_TIMEOUT SPEC_HTML_TIMEOUT=-5)"
assert_eq "TIMEOUT: 0 → 60"            "60" "$(normalized SPEC_HTML_TIMEOUT SPEC_HTML_TIMEOUT=0)"
assert_eq "TIMEOUT: 空文字 → 60"       "60" "$(normalized SPEC_HTML_TIMEOUT SPEC_HTML_TIMEOUT=)"
assert_eq "TIMEOUT: 30 → 30 (据え置き)" "30" "$(normalized SPEC_HTML_TIMEOUT SPEC_HTML_TIMEOUT=30)"
assert_eq "TIMEOUT: 120 → 120 (据え置き)" "120" "$(normalized SPEC_HTML_TIMEOUT SPEC_HTML_TIMEOUT=120)"

echo "=== 補助 env の既定値（design env 表と一致）==="
assert_eq "RENDER_BIN 既定" "pandoc" "$(normalized SPEC_HTML_RENDER_BIN)"
assert_eq "RENDER_CMD 既定" "pandoc -f gfm -t html5 -s -o {OUT} {IN}" "$(normalized SPEC_HTML_RENDER_CMD)"
assert_eq "TARGETS 既定" "requirements.md design.md tasks.md impl-notes.md review-notes.md" "$(normalized SPEC_HTML_TARGETS)"

echo "=== override 可能性（既定を明示値で上書きできる）==="
assert_eq "RENDER_BIN override" "markdown" "$(normalized SPEC_HTML_RENDER_BIN SPEC_HTML_RENDER_BIN=markdown)"
assert_eq "TARGETS override" "design.md" "$(normalized SPEC_HTML_TARGETS SPEC_HTML_TARGETS=design.md)"

echo ""
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
