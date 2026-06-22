#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した Termination Layer（fr_terminate_max_attempts /
#       fr_terminate_no_progress）を gh / rs_set_result stub で検証するスモークテスト。
#
#       対象関数:
#         - fr_terminate_max_attempts  (Req 4.5, 4.6, NFR 4.2)
#         - fr_terminate_no_progress   (Req 5.3, 5.4, NFR 4.2)
#
#       検証する観点（tasks.md 7 の検証項目 a〜d）:
#         (a) max-attempts 経路で rs_set_result / gh issue/pr comment が 1 件発火し
#             claude-failed 除去**されない**こと
#         (b) no-progress 経路で同様
#         (c) コメント本文に通算回数 / 終端理由が含まれること
#         (d) fr_log 出力に `failed-recovery:` prefix + Issue/PR 番号が含まれること
#             （NFR 4.1）
#
#       fr_post_attempt_comment は task 6 で実装済み・shellcheck pass 済みのため、
#       本 test では当該関数も同 module から extract_function で抽出して使う（stub
#       しない）。gh / rs_set_result / fr_log / fr_warn / timeout を stub する。
#
# 配置先: local-watcher/test/fr_terminate_test.sh
# 依存:   bash 4+, awk, mktemp
# 実行:   bash local-watcher/test/fr_terminate_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（fr_attempt_test.sh / fr_invoke_test.sh / fr_state_test.sh）と同じ
# extract_function イディオム。関数本体を行単位で抽出して eval する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 抽出: termination layer の 2 関数 + 依存する fr_post_attempt_comment
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_post_attempt_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_terminate_max_attempts")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_terminate_no_progress")"

for fn in fr_post_attempt_comment fr_terminate_max_attempts fr_terminate_no_progress; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── グローバル env（遅延束縛で抽出関数本体から参照される） ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
FAILED_RECOVERY_GIT_TIMEOUT=60
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_ATTEMPTS=4

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

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  local actual_rc="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  pattern: $pattern"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "FAIL: $label"
    echo "  unexpected match for pattern: $pattern"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# count_pattern: grep -c の exit 1 を吸収して数値を返す helper
# （task 6 fr_attempt_test.sh の learning を踏襲）
count_pattern() {
  local pattern="$1"
  local file="$2"
  local n
  n=$(grep -cE -- "$pattern" "$file" 2>/dev/null || true)
  n="${n//[[:space:]]/}"
  if [ -z "$n" ]; then
    n="0"
  fi
  printf '%s' "$n"
}

assert_count() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  local expected="$4"
  local actual
  actual=$(count_pattern "$pattern" "$file")
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label (count=$actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  pattern : $pattern"
    echo "  expected: $expected"
    echo "  actual  : $actual"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ── stub state ──
GH_CALL_LOG=""
FR_WARN_TRACE=""
FR_LOG_TRACE=""
RS_TRACE=""

GH_RC=0

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  FR_WARN_TRACE="$(mktemp)"
  FR_LOG_TRACE="$(mktemp)"
  RS_TRACE="$(mktemp)"
  GH_RC=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$FR_WARN_TRACE" "$FR_LOG_TRACE" "$RS_TRACE" 2>/dev/null || true
}

# ── 内部関数 stub 群 ──

# fr_warn / fr_log を上書きして呼出を観測
# shellcheck disable=SC2317
fr_warn() {
  echo "fr_warn: $*" >> "$FR_WARN_TRACE"
}
# shellcheck disable=SC2317
fr_log() {
  # production の fr_log は `[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery: $*` を
  # 出力するが、test では prefix を再現して観点 d を検証可能にする。
  echo "[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery: $*" >> "$FR_LOG_TRACE"
}

# rs_set_result stub: RS_TRACE に引数を append（カウンタ目的）
# shellcheck disable=SC2317
rs_set_result() {
  echo "rs_set_result $*" >> "$RS_TRACE"
  return 0
}

# timeout は引数を捨ててコマンドをそのまま実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: 呼び出しを GH_CALL_LOG に記録、no-op で 0 を返す
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  if [ "$GH_RC" != "0" ]; then
    return "$GH_RC"
  fi
  return 0
}

# ============================================================
# Section 1: fr_terminate_max_attempts の Issue 経路（観点 a / c / d）
# ============================================================
echo "--- Section 1: fr_terminate_max_attempts (Issue 経路) ---"

reset_stub_state
trap 'cleanup_stub_state' EXIT

set +e
fr_terminate_max_attempts "issue" "42" "4"
rc=$?
set -e

# 戻り値 0（fail-continue / 正常終端）
assert_rc "Req 4.6: fr_terminate_max_attempts Issue → rc=0" "0" "$rc"

# 観点 a-1: gh issue comment が 1 件発火（着手 + 結果のような 2 件投稿ではない）
assert_count "観点 a: gh issue comment 42 が 1 件発火" "gh issue comment 42" "$GH_CALL_LOG" "1"

# 観点 a-2: --remove-label claude-failed が呼ばれない（Req 4.5 据え置き）
assert_not_grep "観点 a: --remove-label claude-failed が呼ばれない（Req 4.5 据え置き）" "--remove-label claude-failed" "$GH_CALL_LOG"

# 観点 a-3: rs_set_result claude-failed が 1 件発火（NFR 4.2 / 多重発火しない）
assert_count "観点 a: rs_set_result claude-failed が 1 件発火（NFR 4.2）" "^rs_set_result claude-failed$" "$RS_TRACE" "1"

# 観点 c: コメント本文に通算 4 / 上限 4 / max-attempts が含まれる（Req 4.6）
assert_grep "観点 c: コメント本文に '通算 4' を含む" "通算 4" "$GH_CALL_LOG"
assert_grep "観点 c: コメント本文に '上限 4' を含む" "上限 4" "$GH_CALL_LOG"
assert_grep "観点 c: コメント本文に 'max-attempts' を含む" "max-attempts" "$GH_CALL_LOG"

# 観点 d: fr_log 出力に `failed-recovery:` prefix + issue=#42 を含む（NFR 4.1）
assert_grep "観点 d: fr_log に 'failed-recovery:' prefix を含む" "failed-recovery:" "$FR_LOG_TRACE"
assert_grep "観点 d: fr_log に 'issue=#42' を含む（Issue 番号で抽出可能）" "issue=#42" "$FR_LOG_TRACE"
assert_grep "観点 d: fr_log に 'reason=max-attempts' を含む" "reason=max-attempts" "$FR_LOG_TRACE"
assert_grep "観点 d: fr_log に 'total=4' を含む" "total=4" "$FR_LOG_TRACE"
assert_grep "観点 d: fr_log に 'max=4' を含む（上限値も記録）" "max=4" "$FR_LOG_TRACE"

cleanup_stub_state

# ============================================================
# Section 2: fr_terminate_max_attempts の PR 経路（観点 a / c / d）
# ============================================================
echo ""
echo "--- Section 2: fr_terminate_max_attempts (PR 経路) ---"

reset_stub_state

set +e
fr_terminate_max_attempts "pr" "200" "4"
rc=$?
set -e

assert_rc "Req 4.6: fr_terminate_max_attempts PR → rc=0" "0" "$rc"

# 観点 a: gh pr comment が 1 件発火 + --remove-label 呼ばれない
assert_count "観点 a: gh pr comment 200 が 1 件発火" "gh pr comment 200" "$GH_CALL_LOG" "1"
assert_not_grep "観点 a: PR 経路でも --remove-label claude-failed が呼ばれない" "--remove-label claude-failed" "$GH_CALL_LOG"

# 観点 a: rs_set_result 1 件
assert_count "観点 a: PR 経路でも rs_set_result が 1 件発火" "^rs_set_result claude-failed$" "$RS_TRACE" "1"

# 観点 d: fr_log に pr=#200
assert_grep "観点 d: fr_log に 'pr=#200' を含む（PR 番号で抽出可能）" "pr=#200" "$FR_LOG_TRACE"

cleanup_stub_state

# ============================================================
# Section 3: fr_terminate_no_progress の Issue 経路（観点 b / c / d）
# ============================================================
echo ""
echo "--- Section 3: fr_terminate_no_progress (Issue 経路) ---"

reset_stub_state

set +e
fr_terminate_no_progress "issue" "100" "2" "aaaaaaaa0000000000000000000000000000bbbb"
rc=$?
set -e

assert_rc "Req 5.3: fr_terminate_no_progress Issue → rc=0" "0" "$rc"

# 観点 b-1: gh issue comment が 1 件発火
assert_count "観点 b: gh issue comment 100 が 1 件発火" "gh issue comment 100" "$GH_CALL_LOG" "1"

# 観点 b-2: --remove-label claude-failed が呼ばれない（Req 5.3 据え置き）
assert_not_grep "観点 b: --remove-label claude-failed が呼ばれない（Req 5.3 据え置き）" "--remove-label claude-failed" "$GH_CALL_LOG"

# 観点 b-3: rs_set_result claude-failed が 1 件発火（Req 5.4）
assert_count "観点 b: rs_set_result claude-failed が 1 件発火（Req 5.4）" "^rs_set_result claude-failed$" "$RS_TRACE" "1"

# 観点 c: コメント本文に no-progress / 無進捗 / 通算 2 が含まれる（Req 5.3）
assert_grep "観点 c: コメント本文に 'no-progress' を含む" "no-progress" "$GH_CALL_LOG"
assert_grep "観点 c: コメント本文に '無進捗' を含む（日本語抽出キーワード）" "無進捗" "$GH_CALL_LOG"
assert_grep "観点 c: コメント本文に '通算 2' を含む" "通算 2" "$GH_CALL_LOG"

# 観点 d: fr_log に failed-recovery: prefix + issue=#100 + reason=no-progress
assert_grep "観点 d: fr_log に 'failed-recovery:' prefix を含む" "failed-recovery:" "$FR_LOG_TRACE"
assert_grep "観点 d: fr_log に 'issue=#100' を含む" "issue=#100" "$FR_LOG_TRACE"
assert_grep "観点 d: fr_log に 'reason=no-progress' を含む" "reason=no-progress" "$FR_LOG_TRACE"
assert_grep "観点 d: fr_log に 'total=2' を含む" "total=2" "$FR_LOG_TRACE"
# signature の先頭 8 桁が log に出る（参考表示）
assert_grep "観点 d: fr_log に signature 先頭 8 桁 'aaaaaaaa' を含む" "signature=aaaaaaaa" "$FR_LOG_TRACE"

# 観点 c の補足: signature の hex 値はコメント本文には含めない（運用者可読性優先）
assert_not_grep "観点 c: コメント本文に signature hex 全体が含まれない（可読性優先）" "aaaaaaaa0000000000000000000000000000bbbb" "$GH_CALL_LOG"

cleanup_stub_state

# ============================================================
# Section 4: fr_terminate_no_progress の PR 経路（観点 b / c / d）
# ============================================================
echo ""
echo "--- Section 4: fr_terminate_no_progress (PR 経路) ---"

reset_stub_state

set +e
fr_terminate_no_progress "pr" "100" "2" "bbbbbbbb1111111111111111111111111111cccc"
rc=$?
set -e

assert_rc "Req 5.3: fr_terminate_no_progress PR → rc=0" "0" "$rc"

# 観点 b: gh pr comment が 1 件発火 + --remove-label 呼ばれない
assert_count "観点 b: gh pr comment 100 が 1 件発火" "gh pr comment 100" "$GH_CALL_LOG" "1"
assert_not_grep "観点 b: PR 経路でも --remove-label claude-failed が呼ばれない" "--remove-label claude-failed" "$GH_CALL_LOG"

# 観点 b: rs_set_result 1 件
assert_count "観点 b: PR 経路でも rs_set_result が 1 件発火" "^rs_set_result claude-failed$" "$RS_TRACE" "1"

# 観点 d: fr_log に pr=#100
assert_grep "観点 d: fr_log に 'pr=#100' を含む" "pr=#100" "$FR_LOG_TRACE"

cleanup_stub_state

# ============================================================
# Section 5: 不正値ガード（NFR 3.1）
# ============================================================
echo ""
echo "--- Section 5: 不正値ガード（NFR 3.1） ---"

# 5-A: fr_terminate_max_attempts kind="foo" → rc=1 + fr_warn
reset_stub_state
set +e
fr_terminate_max_attempts "foo" "42" "4"
rc=$?
set -e
assert_rc "NFR 3.1: max_attempts 不正な kind=foo → rc=1" "1" "$rc"
assert_count "NFR 3.1: max_attempts 不正 kind で fr_warn が 1 件" "fr_warn:" "$FR_WARN_TRACE" "1"
# 不正値ガード時は副作用ゼロ
assert_count "NFR 3.1: 不正 kind 時に gh が呼ばれない" "." "$GH_CALL_LOG" "0"
assert_count "NFR 3.1: 不正 kind 時に rs_set_result が呼ばれない" "." "$RS_TRACE" "0"
assert_count "NFR 3.1: 不正 kind 時に fr_log が呼ばれない" "." "$FR_LOG_TRACE" "0"
cleanup_stub_state

# 5-B: fr_terminate_max_attempts number="abc" → rc=1 + fr_warn
reset_stub_state
set +e
fr_terminate_max_attempts "issue" "abc" "4"
rc=$?
set -e
assert_rc "NFR 3.1: max_attempts 非数値 number → rc=1" "1" "$rc"
assert_count "NFR 3.1: max_attempts 非数値 number で fr_warn が 1 件" "fr_warn:" "$FR_WARN_TRACE" "1"
assert_count "NFR 3.1: 非数値 number 時に gh が呼ばれない" "." "$GH_CALL_LOG" "0"
assert_count "NFR 3.1: 非数値 number 時に rs_set_result が呼ばれない" "." "$RS_TRACE" "0"
cleanup_stub_state

# 5-C: fr_terminate_no_progress kind="foo" → rc=1 + fr_warn
reset_stub_state
set +e
fr_terminate_no_progress "foo" "100" "2" "sig"
rc=$?
set -e
assert_rc "NFR 3.1: no_progress 不正な kind=foo → rc=1" "1" "$rc"
assert_count "NFR 3.1: no_progress 不正 kind で fr_warn が 1 件" "fr_warn:" "$FR_WARN_TRACE" "1"
cleanup_stub_state

# 5-D: fr_terminate_no_progress number="abc" → rc=1 + fr_warn
reset_stub_state
set +e
fr_terminate_no_progress "pr" "abc" "2" "sig"
rc=$?
set -e
assert_rc "NFR 3.1: no_progress 非数値 number → rc=1" "1" "$rc"
assert_count "NFR 3.1: no_progress 非数値 number で fr_warn が 1 件" "fr_warn:" "$FR_WARN_TRACE" "1"
cleanup_stub_state

# 5-E: fr_terminate_max_attempts number に command injection（; 含む）→ rc=1
reset_stub_state
set +e
fr_terminate_max_attempts "issue" "42; rm -rf /tmp/x" "4"
rc=$?
set -e
assert_rc "NFR 3.1: command injection を含む number → rc=1" "1" "$rc"
assert_count "NFR 3.1: command injection 時に gh が呼ばれない" "." "$GH_CALL_LOG" "0"
cleanup_stub_state

# ============================================================
# Section 6: gh comment 失敗時の fail-continue（rs_set_result / fr_log は呼ばれる）
# ============================================================
echo ""
echo "--- Section 6: gh comment 失敗時の fail-continue ---"

# 6-A: gh comment が失敗（GH_RC=1）でも rs_set_result / fr_log は呼ばれる
reset_stub_state
GH_RC=1
set +e
fr_terminate_max_attempts "issue" "500" "4"
rc=$?
set -e
assert_rc "NFR 4.2: gh comment 失敗でも fr_terminate_max_attempts は rc=0（fail-continue）" "0" "$rc"
# rs_set_result は gh 失敗に関係なく呼ばれる（run-summary 連携が優先 / NFR 4.2）
assert_count "NFR 4.2: gh 失敗でも rs_set_result が 1 件発火" "^rs_set_result claude-failed$" "$RS_TRACE" "1"
# fr_log も呼ばれる
assert_grep "NFR 4.1: gh 失敗でも fr_log が呼ばれる" "issue=#500" "$FR_LOG_TRACE"
# fr_post_attempt_comment が内部で fr_warn を呼んでいる（gh 失敗を観測）
assert_grep "fr_warn: gh comment 失敗を観測" "fr_post_attempt_comment: gh issue comment 失敗" "$FR_WARN_TRACE"
cleanup_stub_state

# 6-B: 同様に no_progress でも fail-continue
reset_stub_state
GH_RC=1
set +e
fr_terminate_no_progress "pr" "501" "3" "sig123"
rc=$?
set -e
assert_rc "NFR 4.2: gh comment 失敗でも fr_terminate_no_progress は rc=0（fail-continue）" "0" "$rc"
assert_count "NFR 4.2: gh 失敗でも rs_set_result が 1 件発火" "^rs_set_result claude-failed$" "$RS_TRACE" "1"
assert_grep "NFR 4.1: gh 失敗でも fr_log が呼ばれる" "pr=#501" "$FR_LOG_TRACE"
cleanup_stub_state

# ============================================================
# Section 7: rs_set_result が 1 度だけ呼ばれる（NFR 4.2 / 多重発火しない）
# ============================================================
echo ""
echo "--- Section 7: rs_set_result の単発契約（NFR 4.2） ---"

# 7-A: max_attempts は rs_set_result を 1 度だけ呼ぶ
reset_stub_state
set +e
fr_terminate_max_attempts "issue" "600" "4"
set -e
# rs_set_result 全体の発火回数を厳密に検査（正規表現は最初の引数まで）
assert_count "NFR 4.2: max_attempts で rs_set_result 全体が 1 件のみ" "^rs_set_result " "$RS_TRACE" "1"
cleanup_stub_state

# 7-B: no_progress も同様
reset_stub_state
set +e
fr_terminate_no_progress "pr" "601" "3" "sig"
set -e
assert_count "NFR 4.2: no_progress で rs_set_result 全体が 1 件のみ" "^rs_set_result " "$RS_TRACE" "1"
cleanup_stub_state

# ============================================================
# Section 8: signature 省略時（4th 引数なし）の no_progress 動作
# ============================================================
echo ""
echo "--- Section 8: no_progress signature 省略時の動作 ---"

reset_stub_state
set +e
fr_terminate_no_progress "issue" "700" "1"
rc=$?
set -e
assert_rc "Req 5.3: signature 省略時も rc=0（fail-continue）" "0" "$rc"
# signature が空なので fr_log には signature= が出ない
assert_not_grep "観点 d: signature 空時に fr_log に 'signature=' が出ない" "signature=" "$FR_LOG_TRACE"
# それ以外（reason / total / issue=#N）は出る
assert_grep "観点 d: signature 省略時も reason=no-progress を含む" "reason=no-progress" "$FR_LOG_TRACE"
assert_grep "観点 d: signature 省略時も issue=#700 を含む" "issue=#700" "$FR_LOG_TRACE"
cleanup_stub_state

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
