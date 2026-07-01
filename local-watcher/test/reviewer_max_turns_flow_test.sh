#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の `run_reviewer_stage`（単発経路）に Issue #442 で
#       追加した turn 切れ拡張リトライ制御フローを、claude 実行を stub して検証する。
#       検証する分岐（Req 1.1, 1.2, 1.3, 2.1, 3.1, 4.6）:
#         - turn 切れ → 拡張 turn 予算で 1 回再実行 → verdict 取得（approve）= return 0
#           かつ 1 回目は base、2 回目は EXTENDED の max-turns で起動される
#         - 拡張リトライ後もなお turn 切れ = 区別された return code 6
#         - turn 切れ以外の非ゼロ exit（claude crash）= 拡張リトライせず即 return 2
#         - 通常 approve（turn 切れなし）= 1 回実行で return 0（外形不変 / NFR 1.1）
#
# 配置先: local-watcher/test/reviewer_max_turns_flow_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/reviewer_max_turns_flow_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 検証対象本体を抽出
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "run_reviewer_stage")"
if ! declare -F run_reviewer_stage >/dev/null; then
  echo "ERROR: run_reviewer_stage not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label (=$actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: '$expected' / actual: '$actual'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─── 共通 stub / グローバル ───
# run_reviewer_stage は eval で動的 source されるため、shellcheck は本体側からの
# 以下グローバル参照を静的に追えない。各行で SC2034 を抑止する
# （shellcheck の disable ディレクティブは直後の単一行にのみ作用するため）。
# shellcheck disable=SC2034
REVIEWER_MODEL="stub-model"
# shellcheck disable=SC2034
REVIEWER_MAX_TURNS=50
# shellcheck disable=SC2034
REVIEWER_MAX_TURNS_EXTENDED=100
# shellcheck disable=SC2034
NUMBER=999
# shellcheck disable=SC2034
REPO="owner/repo"
# shellcheck disable=SC2034
REPO_SLUG="owner-repo"
# shellcheck disable=SC2034
SPEC_DIR_REL="docs/specs/999-x"
# shellcheck disable=SC2034
REPO_DIR="/tmp/nonexistent-repo-dir"
# shellcheck disable=SC2034
CLAUDE_HOOK_ARGS=()

# ログは捨てる
LOG="$(mktemp)"

# stub: 副作用系を no-op 化
build_reviewer_prompt() { echo "stub-prompt"; }
extract_review_result_token() { return 1; }
qa_handle_quota_exceeded() { :; }
rs_record_reviewer() { :; }
tu_mark_log_offset() { echo 0; }

# CALL_LOG にどの max-turns で claude が起動されたかを記録する。
# qa_run_claude_stage は本体で `qa_run_claude_stage <label> <reset_file> -- claude ... --max-turns <N> ...`
# の形で呼ばれる。引数列から --max-turns の次の値を拾って記録する。
CALL_LOG=""
qa_run_claude_stage() {
  local label="$1"; shift
  local reset_file="$1"; shift
  # 残り引数（-- 以降）から --max-turns を探す
  local prev="" mt=""
  for a in "$@"; do
    if [ "$prev" = "--max-turns" ]; then mt="$a"; fi
    prev="$a"
  done
  CALL_LOG="${CALL_LOG}${mt} "
  # reset_file を作っておく（本体が rm -f する）
  : > "$reset_file" 2>/dev/null || true
  return "${STUB_CLAUDE_RC:-0}"
}

# ─── ケース 1: turn 切れ → 拡張リトライ → approve(return 0) ───
# 1 回目は error_max_turns(rc=1) を返し、2 回目は成功(rc=0) を返す。
# reviewer_is_error_max_turns は 1 回目のみ true を返すよう stub。
case1() {
  CALL_LOG=""
  local _n=0
  qa_run_claude_stage() {
    local label="$1"; shift; local reset_file="$1"; shift
    local prev="" mt=""
    for a in "$@"; do [ "$prev" = "--max-turns" ] && mt="$a"; prev="$a"; done
    CALL_LOG="${CALL_LOG}${mt} "
    : > "$reset_file" 2>/dev/null || true
    _n=$((_n + 1))
    if [ "$_n" -eq 1 ]; then return 1; fi  # 1 回目: turn 切れ起因の非ゼロ exit
    return 0                                # 2 回目: 成功
  }
  # 1 回目の直後のみ turn 切れ判定 true、それ以降 false
  reviewer_is_error_max_turns() { [ "$_n" -eq 1 ]; }
  # 成功後の parse は approve を返す
  parse_review_result() { printf 'approve\t\t1.1\n'; }
  local rc=0
  run_reviewer_stage 1 >/dev/null 2>&1 || rc=$?
  assert_eq "ケース1: turn 切れ→拡張リトライ→approve = return 0" "0" "$rc"
  assert_eq "ケース1: 1 回目 base / 2 回目 EXTENDED で起動" "50 100" "$(echo "$CALL_LOG" | xargs)"
}

# ─── ケース 2: 拡張リトライ後もなお turn 切れ → return 6 ───
case2() {
  CALL_LOG=""
  qa_run_claude_stage() {
    local label="$1"; shift; local reset_file="$1"; shift
    local prev="" mt=""
    for a in "$@"; do [ "$prev" = "--max-turns" ] && mt="$a"; prev="$a"; done
    CALL_LOG="${CALL_LOG}${mt} "
    : > "$reset_file" 2>/dev/null || true
    return 1  # 毎回 turn 切れ起因の非ゼロ exit
  }
  reviewer_is_error_max_turns() { return 0; }  # 毎回 turn 切れ判定
  parse_review_result() { return 3; }
  local rc=0
  run_reviewer_stage 1 >/dev/null 2>&1 || rc=$?
  assert_eq "ケース2: 拡張リトライ後もなお turn 切れ = return 6" "6" "$rc"
  assert_eq "ケース2: base→EXTENDED の 2 回のみ起動（リトライ 1 回限定）" "50 100" "$(echo "$CALL_LOG" | xargs)"
}

# ─── ケース 3: turn 切れ以外の非ゼロ exit（claude crash）→ 即 return 2 ───
case3() {
  CALL_LOG=""
  qa_run_claude_stage() {
    local label="$1"; shift; local reset_file="$1"; shift
    local prev="" mt=""
    for a in "$@"; do [ "$prev" = "--max-turns" ] && mt="$a"; prev="$a"; done
    CALL_LOG="${CALL_LOG}${mt} "
    : > "$reset_file" 2>/dev/null || true
    return 1  # 非ゼロ exit
  }
  reviewer_is_error_max_turns() { return 1; }  # turn 切れではない
  parse_review_result() { return 3; }
  local rc=0
  run_reviewer_stage 1 >/dev/null 2>&1 || rc=$?
  assert_eq "ケース3: claude crash（turn 切れ以外）= 即 return 2（拡張リトライなし）" "2" "$rc"
  assert_eq "ケース3: base で 1 回のみ起動（拡張リトライ起動せず）" "50" "$(echo "$CALL_LOG" | xargs)"
}

# ─── ケース 4: 通常 approve（turn 切れなし）→ 1 回実行で return 0（NFR 1.1 外形不変）───
case4() {
  CALL_LOG=""
  qa_run_claude_stage() {
    local label="$1"; shift; local reset_file="$1"; shift
    local prev="" mt=""
    for a in "$@"; do [ "$prev" = "--max-turns" ] && mt="$a"; prev="$a"; done
    CALL_LOG="${CALL_LOG}${mt} "
    : > "$reset_file" 2>/dev/null || true
    return 0  # 成功
  }
  reviewer_is_error_max_turns() { return 1; }
  parse_review_result() { printf 'approve\t\t1.1\n'; }
  local rc=0
  run_reviewer_stage 1 >/dev/null 2>&1 || rc=$?
  assert_eq "ケース4: 通常 approve = return 0" "0" "$rc"
  assert_eq "ケース4: base で 1 回のみ起動（外形不変）" "50" "$(echo "$CALL_LOG" | xargs)"
}

case1
case2
case3
case4

rm -f "$LOG"

echo ""
echo "================================"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
