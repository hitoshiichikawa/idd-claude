#!/usr/bin/env bash
# shellcheck disable=SC2034  # LOG / REPO / NUMBER / TOKEN_REPORT_ENABLED は抽出した
#                            # 関数本体が bash の遅延束縛で参照する（直接参照に見えない）
#
# 用途: local-watcher/bin/modules/token-usage.sh（#325 Token Usage Report）の
#       抽出・整形・集計関数を fixture で検証するスモークテスト。
#
#       対象関数:
#         - tu_enabled（TOKEN_REPORT_ENABLED の正規化判定）
#         - tu_extract_last_result_json（offset 以降から最後の有効 result 行を抽出）
#         - tu_format_usage_kv（result JSON → k=v 列の純粋関数）
#         - tu_report_stage_usage（stage 行の echo / silent skip）
#         - tu_emit_issue_summary（stage 行の集計サマリ）
#
# 配置先: local-watcher/test/tu_token_usage_test.sh
# 依存:   bash 4+, awk, grep, jq
# 実行:   bash local-watcher/test/tu_token_usage_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/token-usage.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find token-usage.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する（本モジュールは関数定義のみだが
# 他テストとの一貫性のため同じ方式を採る）。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

for fn in tu_enabled tu_mark_log_offset tu_extract_last_result_json tu_format_usage_kv tu_report_stage_usage tu_emit_issue_summary; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODULE_SH" "$fn")"
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  needle: $(printf '%q' "$needle")"
      echo "  in    : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ─── fixture: stream-json の result イベント行 ───
RESULT_A='{"type":"result","subtype":"success","is_error":false,"num_turns":12,"total_cost_usd":1.2345,"usage":{"input_tokens":1000,"cache_read_input_tokens":50000,"cache_creation_input_tokens":2000,"output_tokens":3000},"modelUsage":{"claude-opus-4-7":{"inputTokens":1000}}}'
RESULT_B='{"type":"result","subtype":"success","is_error":false,"num_turns":5,"total_cost_usd":0.5,"usage":{"input_tokens":200,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300,"output_tokens":400},"modelUsage":{"claude-sonnet-4-6":{"inputTokens":200}}}'
RESULT_MINIMAL='{"type":"result"}'

echo "--- tu_enabled cases ---"

TOKEN_REPORT_ENABLED="" ; tu_enabled && r=on || r=off
assert_eq "未設定(空文字)は有効" "on" "$r"
TOKEN_REPORT_ENABLED="false" ; tu_enabled && r=on || r=off
assert_eq "false は無効" "off" "$r"
TOKEN_REPORT_ENABLED="0" ; tu_enabled && r=on || r=off
assert_eq "0 は無効" "off" "$r"
TOKEN_REPORT_ENABLED="off" ; tu_enabled && r=on || r=off
assert_eq "off は無効" "off" "$r"
TOKEN_REPORT_ENABLED="False" ; tu_enabled && r=on || r=off
assert_eq "False(大文字 typo)は有効側に倒れる" "on" "$r"
unset TOKEN_REPORT_ENABLED

echo "--- tu_format_usage_kv cases ---"

assert_eq "全フィールドありの整形" \
  "in=1000 cache_read=50000 cache_write=2000 out=3000 turns=12 cost_usd=1.2345 models=claude-opus-4-7" \
  "$(tu_format_usage_kv "$RESULT_A")"

assert_eq "欠落フィールドは 0 / models は - に補完" \
  "in=0 cache_read=0 cache_write=0 out=0 turns=0 cost_usd=0 models=-" \
  "$(tu_format_usage_kv "$RESULT_MINIMAL")"

assert_eq "不正 JSON は空出力" "" "$(tu_format_usage_kv 'not-json')"
assert_eq "空入力は空出力" "" "$(tu_format_usage_kv '')"

echo "--- tu_extract_last_result_json cases ---"

LOG_FIXTURE="$TMP_DIR/issue-log.log"
{
  echo '{"type":"system","subtype":"init"}'
  echo "$RESULT_A"
  echo 'plain text line mentioning "type":"result" but not JSON {'
  echo '{"type":"assistant","message":{}}'
  echo "$RESULT_B"
} > "$LOG_FIXTURE"

assert_eq "offset=0 で最後の有効 result 行(B)を抽出" \
  "$(printf '%s' "$RESULT_B" | jq -c .)" \
  "$(tu_extract_last_result_json "$LOG_FIXTURE" 0)"

# offset=2 → 1〜2 行目(RESULT_A まで)をスキップ → B のみが対象
assert_eq "offset 指定で範囲前の result 行(A)を無視する" \
  "$(printf '%s' "$RESULT_B" | jq -c .)" \
  "$(tu_extract_last_result_json "$LOG_FIXTURE" 2)"

# offset がファイル末尾以降 → 空
assert_eq "offset が末尾以降のとき空出力" "" "$(tu_extract_last_result_json "$LOG_FIXTURE" 99)"
assert_eq "不在ファイルは空出力" "" "$(tu_extract_last_result_json "$TMP_DIR/nope.log" 0)"
assert_eq "不正 offset は 0 として扱う" \
  "$(printf '%s' "$RESULT_B" | jq -c .)" \
  "$(tu_extract_last_result_json "$LOG_FIXTURE" 'abc')"

echo "--- tu_report_stage_usage cases ---"

LOG="$LOG_FIXTURE"
REPO="owner/repo"
TOKEN_REPORT_ENABLED="true"
out=$(tu_report_stage_usage "StageA" 0)
assert_contains "stage 行に固定 prefix と repo を含む" "[owner/repo] token-usage: stage=StageA " "$out"
assert_contains "stage 行に usage k=v を含む" "in=200 cache_read=1000 cache_write=300 out=400 turns=5 cost_usd=0.5 models=claude-sonnet-4-6" "$out"

EMPTY_LOG="$TMP_DIR/empty.log"
: > "$EMPTY_LOG"
LOG="$EMPTY_LOG"
assert_eq "result 行不在なら何も出力しない(Req 1.3)" "" "$(tu_report_stage_usage "Triage" 0)"

LOG="$LOG_FIXTURE"
TOKEN_REPORT_ENABLED="false"
assert_eq "無効化時は stage 行を出力しない(Req 3.1)" "" "$(tu_report_stage_usage "StageA" 0)"
TOKEN_REPORT_ENABLED="true"

echo "--- tu_emit_issue_summary cases ---"

SUMMARY_LOG="$TMP_DIR/summary.log"
{
  echo '[2026-06-12 00:00:00] [owner/repo] token-usage: stage=StageA in=1000 cache_read=50000 cache_write=2000 out=3000 turns=12 cost_usd=1.2345 models=claude-opus-4-7'
  echo 'unrelated line'
  echo '[2026-06-12 00:10:00] [owner/repo] token-usage: stage=StageC in=200 cache_read=1000 cache_write=300 out=400 turns=5 cost_usd=0.5 models=claude-sonnet-4-6'
} > "$SUMMARY_LOG"

LOG="$SUMMARY_LOG"
NUMBER="325"
out=$(tu_emit_issue_summary)
assert_contains "サマリ行に issue 番号を含む" "token-usage: issue=#325 total " "$out"
assert_contains "サマリ行の合計値が正しい" "in=1200 cache_read=51000 cache_write=2300 out=3400 turns=17 cost_usd=1.7345 stages=2" "$out"

LOG="$EMPTY_LOG"
assert_eq "stage 行ゼロならサマリを出力しない(Req 2.2)" "" "$(tu_emit_issue_summary)"

LOG="$SUMMARY_LOG"
TOKEN_REPORT_ENABLED="no"
assert_eq "無効化時はサマリを出力しない(Req 3.1)" "" "$(tu_emit_issue_summary)"
TOKEN_REPORT_ENABLED="true"

echo ""
echo "================================"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
