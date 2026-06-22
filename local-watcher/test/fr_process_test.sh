#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した Orchestrator Entry（process_failed_recovery /
#       _fr_dispatch_candidate）を gh / claude / 内部関数 stub で検証するスモークテスト。
#
#       対象関数:
#         - process_failed_recovery   (Req 1.1, 1.4, 2.1, 2.3, NFR 1.1, NFR 1.3, NFR 2.1, NFR 5.2)
#         - _fr_dispatch_candidate    (Req 4.5, 5.2 の terminate 経路配線)
#
#       検証する観点（tasks.md 8 の検証項目 a〜d + terminate 配線 e, f）:
#         (a) gate off 時に副作用ゼロ: fr_is_enabled が rc=1 を返すとき、
#             fr_fetch_failed_issues / fr_fetch_failed_prs / fr_run_recovery_attempt が
#             いずれも呼ばれず、trace に gh / claude stub の呼び出しが現れないこと
#             （NFR 1.3 / safety-side fallback）
#         (b) gate on 時に Issue + PR 双方の候補列挙が走ること: Issue が 2 件、PR が 1 件
#             返されたとき、fr_run_recovery_attempt が "issue <n>" / "issue <n>" / "pr <n>"
#             の順で 3 回呼ばれる（Issue → PR の順序）
#         (c) 候補 0 件で no-op: fr_fetch_failed_* が `[]` を返したとき、
#             fr_run_recovery_attempt が一度も呼ばれない（rc=0 で完了）
#         (d) fail-continue（failure path）: 候補 N 件のうち 1 件で
#             fr_run_recovery_attempt stub が exit 1 を返しても、残りの候補が継続処理される
#         (e) terminate 経路の配線: fr_run_recovery_attempt stub が rc=2 を返すと
#             fr_terminate_max_attempts が呼ばれ、rc=3 を返すと fr_terminate_no_progress
#             が呼ばれる
#         (f) rc=99（quota）の扱い: fr_run_recovery_attempt stub が rc=99 を返したとき、
#             fr_terminate_* が呼ばれず（terminate 経路ではない）、残り候補も継続される
#
# 配置先: local-watcher/test/fr_process_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/fr_process_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（fr_attempt_test.sh / fr_terminate_test.sh）と同じ extract_function イディオム
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 抽出: orchestrator entry 2 関数（process_failed_recovery / _fr_dispatch_candidate）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "_fr_dispatch_candidate")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "process_failed_recovery")"

for fn in _fr_dispatch_candidate process_failed_recovery; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── グローバル env（遅延束縛で抽出関数本体から参照される） ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_ATTEMPTS=4
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_PRS=3

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

# ── stub state ──
FETCH_ISSUES_TRACE=""
FETCH_PRS_TRACE=""
RUN_ATTEMPT_TRACE=""
TERMINATE_MAX_TRACE=""
TERMINATE_NO_PROGRESS_TRACE=""
LOAD_STATE_TRACE=""
FR_WARN_TRACE=""
FR_LOG_TRACE=""
IS_ENABLED_TRACE=""

# fr_is_enabled の rc (0=enabled / 1=disabled)
IS_ENABLED_RC=0

# fr_fetch_failed_issues / fr_fetch_failed_prs の応答（JSON 配列文字列）
FETCH_ISSUES_RESPONSE='[]'
FETCH_PRS_RESPONSE='[]'

# fr_run_recovery_attempt の rc (順次消費するための配列)
RUN_ATTEMPT_RC_QUEUE=()
RUN_ATTEMPT_RC_INDEX=0

# fr_load_state の応答（terminate 経由で state 再読み込み）
LOAD_STATE_RESPONSE='{"issue":0,"total_attempts":4,"last_failure_signature":"abc123def456"}'

reset_stub_state() {
  FETCH_ISSUES_TRACE="$(mktemp)"
  FETCH_PRS_TRACE="$(mktemp)"
  RUN_ATTEMPT_TRACE="$(mktemp)"
  TERMINATE_MAX_TRACE="$(mktemp)"
  TERMINATE_NO_PROGRESS_TRACE="$(mktemp)"
  LOAD_STATE_TRACE="$(mktemp)"
  FR_WARN_TRACE="$(mktemp)"
  FR_LOG_TRACE="$(mktemp)"
  IS_ENABLED_TRACE="$(mktemp)"
  IS_ENABLED_RC=0
  FETCH_ISSUES_RESPONSE='[]'
  FETCH_PRS_RESPONSE='[]'
  RUN_ATTEMPT_RC_QUEUE=()
  RUN_ATTEMPT_RC_INDEX=0
  LOAD_STATE_RESPONSE='{"issue":0,"total_attempts":4,"last_failure_signature":"abc123def456"}'
}

cleanup_stub_state() {
  rm -f "$FETCH_ISSUES_TRACE" "$FETCH_PRS_TRACE" "$RUN_ATTEMPT_TRACE" \
        "$TERMINATE_MAX_TRACE" "$TERMINATE_NO_PROGRESS_TRACE" "$LOAD_STATE_TRACE" \
        "$FR_WARN_TRACE" "$FR_LOG_TRACE" "$IS_ENABLED_TRACE" 2>/dev/null || true
}

trap 'cleanup_stub_state' EXIT

# ── 内部関数 stub 群 ──

# shellcheck disable=SC2317
fr_is_enabled() {
  echo "fr_is_enabled called" >> "$IS_ENABLED_TRACE"
  return "$IS_ENABLED_RC"
}

# shellcheck disable=SC2317
fr_fetch_failed_issues() {
  echo "fr_fetch_failed_issues called" >> "$FETCH_ISSUES_TRACE"
  printf '%s' "$FETCH_ISSUES_RESPONSE"
}

# shellcheck disable=SC2317
fr_fetch_failed_prs() {
  echo "fr_fetch_failed_prs called" >> "$FETCH_PRS_TRACE"
  printf '%s' "$FETCH_PRS_RESPONSE"
}

# fr_run_recovery_attempt stub: 引数を trace に記録し、RUN_ATTEMPT_RC_QUEUE から rc を返す
# shellcheck disable=SC2317
fr_run_recovery_attempt() {
  echo "fr_run_recovery_attempt $*" >> "$RUN_ATTEMPT_TRACE"
  local rc=0
  if [ "$RUN_ATTEMPT_RC_INDEX" -lt "${#RUN_ATTEMPT_RC_QUEUE[@]}" ]; then
    rc="${RUN_ATTEMPT_RC_QUEUE[$RUN_ATTEMPT_RC_INDEX]}"
    RUN_ATTEMPT_RC_INDEX=$((RUN_ATTEMPT_RC_INDEX + 1))
  fi
  return "$rc"
}

# shellcheck disable=SC2317
fr_terminate_max_attempts() {
  echo "fr_terminate_max_attempts $*" >> "$TERMINATE_MAX_TRACE"
  return 0
}

# shellcheck disable=SC2317
fr_terminate_no_progress() {
  echo "fr_terminate_no_progress $*" >> "$TERMINATE_NO_PROGRESS_TRACE"
  return 0
}

# shellcheck disable=SC2317
fr_load_state() {
  echo "fr_load_state $*" >> "$LOAD_STATE_TRACE"
  printf '%s' "$LOAD_STATE_RESPONSE"
}

# shellcheck disable=SC2317
fr_warn() {
  echo "$*" >> "$FR_WARN_TRACE"
}

# shellcheck disable=SC2317
fr_log() {
  echo "$*" >> "$FR_LOG_TRACE"
}

# ============================================================
# Section 1: gate off 時に副作用ゼロ（観点 a / NFR 1.3）
# ============================================================
echo "--- Section 1: gate off 時に副作用ゼロ（観点 a） ---"

reset_stub_state
IS_ENABLED_RC=1  # gate off
FETCH_ISSUES_RESPONSE='[{"number":1},{"number":2}]'  # gate off なら使われないはず
FETCH_PRS_RESPONSE='[{"number":10}]'

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "NFR 1.3: gate off → rc=0（副作用ゼロ）" "0" "$rc"

# fr_is_enabled は呼ばれる（gate 判定のため）
assert_eq "観点 a: fr_is_enabled が 1 件呼ばれる" "1" "$(count_pattern "." "$IS_ENABLED_TRACE")"
# fr_fetch_* / fr_run_recovery_attempt / terminate / fr_log は呼ばれない
assert_eq "観点 a: fr_fetch_failed_issues が呼ばれない" "0" "$(count_pattern "." "$FETCH_ISSUES_TRACE")"
assert_eq "観点 a: fr_fetch_failed_prs が呼ばれない" "0" "$(count_pattern "." "$FETCH_PRS_TRACE")"
assert_eq "観点 a: fr_run_recovery_attempt が呼ばれない" "0" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"
assert_eq "観点 a: fr_terminate_max_attempts が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
assert_eq "観点 a: fr_terminate_no_progress が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_NO_PROGRESS_TRACE")"
assert_eq "観点 a: fr_log が呼ばれない（gate off は完全 silent）" "0" "$(count_pattern "." "$FR_LOG_TRACE")"

cleanup_stub_state

# ============================================================
# Section 2: gate on 時の Issue + PR 双方の候補列挙（観点 b）
# ============================================================
echo ""
echo "--- Section 2: gate on 時の Issue + PR 双方の候補列挙（観点 b） ---"

reset_stub_state
IS_ENABLED_RC=0  # gate on
FETCH_ISSUES_RESPONSE='[{"number":42},{"number":43}]'
FETCH_PRS_RESPONSE='[{"number":100}]'
# 全 candidate が success path（rc=0）
RUN_ATTEMPT_RC_QUEUE=(0 0 0)

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "観点 b: gate on で正常完了 → rc=0" "0" "$rc"

# fr_fetch_* は両方 1 件ずつ呼ばれる
assert_eq "観点 b: fr_fetch_failed_issues が 1 件呼ばれる" "1" "$(count_pattern "." "$FETCH_ISSUES_TRACE")"
assert_eq "観点 b: fr_fetch_failed_prs が 1 件呼ばれる" "1" "$(count_pattern "." "$FETCH_PRS_TRACE")"
# fr_run_recovery_attempt が 3 回呼ばれる (issue 42, issue 43, pr 100)
assert_eq "観点 b: fr_run_recovery_attempt が 3 回呼ばれる" "3" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"
# 順序: Issue → PR
assert_grep "観点 b: issue 42 が呼ばれる" "^fr_run_recovery_attempt issue 42$" "$RUN_ATTEMPT_TRACE"
assert_grep "観点 b: issue 43 が呼ばれる" "^fr_run_recovery_attempt issue 43$" "$RUN_ATTEMPT_TRACE"
assert_grep "観点 b: pr 100 が呼ばれる" "^fr_run_recovery_attempt pr 100$" "$RUN_ATTEMPT_TRACE"
# 順序: Issue → PR を line 順で検証
first_issue_line=$(grep -nE "fr_run_recovery_attempt issue " "$RUN_ATTEMPT_TRACE" | head -1 | cut -d: -f1)
first_pr_line=$(grep -nE "fr_run_recovery_attempt pr " "$RUN_ATTEMPT_TRACE" | head -1 | cut -d: -f1)
if [ -n "$first_issue_line" ] && [ -n "$first_pr_line" ] && [ "$first_issue_line" -lt "$first_pr_line" ]; then
  echo "PASS: 観点 b: Issue → PR の順で呼ばれる (issue_line=$first_issue_line < pr_line=$first_pr_line)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: 観点 b: Issue → PR の順序が崩れている (issue_line=$first_issue_line / pr_line=$first_pr_line)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# success path では terminate 関数は呼ばれない
assert_eq "観点 b: success path で fr_terminate_max_attempts が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
assert_eq "観点 b: success path で fr_terminate_no_progress が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_NO_PROGRESS_TRACE")"

cleanup_stub_state

# ============================================================
# Section 3: 候補 0 件で no-op（観点 c）
# ============================================================
echo ""
echo "--- Section 3: 候補 0 件で no-op（観点 c） ---"

reset_stub_state
IS_ENABLED_RC=0  # gate on
FETCH_ISSUES_RESPONSE='[]'
FETCH_PRS_RESPONSE='[]'

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "観点 c: 候補 0 件 → rc=0" "0" "$rc"
# fetch は両方呼ばれる（候補確認のため）
assert_eq "観点 c: fr_fetch_failed_issues が 1 件呼ばれる" "1" "$(count_pattern "." "$FETCH_ISSUES_TRACE")"
assert_eq "観点 c: fr_fetch_failed_prs が 1 件呼ばれる" "1" "$(count_pattern "." "$FETCH_PRS_TRACE")"
# fr_run_recovery_attempt は一度も呼ばれない
assert_eq "観点 c: fr_run_recovery_attempt が 0 回（候補なし）" "0" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"
# terminate も呼ばれない
assert_eq "観点 c: terminate_max が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
assert_eq "観点 c: terminate_no_progress が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_NO_PROGRESS_TRACE")"

cleanup_stub_state

# ============================================================
# Section 4: fail-continue（failure path / 観点 d / NFR 5.2）
# ============================================================
echo ""
echo "--- Section 4: fail-continue（観点 d） ---"

reset_stub_state
IS_ENABLED_RC=0
FETCH_ISSUES_RESPONSE='[{"number":50},{"number":51},{"number":52}]'
FETCH_PRS_RESPONSE='[{"number":150}]'
# 2 件目 (issue 51) で failure (rc=1)、残りは success
RUN_ATTEMPT_RC_QUEUE=(0 1 0 0)

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "観点 d: 一部 failure でも process_failed_recovery は rc=0（fail-continue）" "0" "$rc"

# 4 件すべて fr_run_recovery_attempt まで到達する（残候補が継続処理される）
assert_eq "観点 d: 全 4 件で fr_run_recovery_attempt が呼ばれる" "4" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"
assert_grep "観点 d: issue 50 が呼ばれる" "^fr_run_recovery_attempt issue 50$" "$RUN_ATTEMPT_TRACE"
assert_grep "観点 d: issue 51 が呼ばれる (failure)" "^fr_run_recovery_attempt issue 51$" "$RUN_ATTEMPT_TRACE"
assert_grep "観点 d: issue 52 が呼ばれる (failure 後も継続)" "^fr_run_recovery_attempt issue 52$" "$RUN_ATTEMPT_TRACE"
assert_grep "観点 d: pr 150 が呼ばれる (Issue 失敗後も PR まで継続)" "^fr_run_recovery_attempt pr 150$" "$RUN_ATTEMPT_TRACE"

cleanup_stub_state

# ============================================================
# Section 5: terminate 経路の配線（観点 e / Req 4.5 / 5.2）
# ============================================================
echo ""
echo "--- Section 5: terminate 経路の配線（観点 e） ---"

# 5-A: rc=2 (max-attempts) → fr_terminate_max_attempts が呼ばれる
reset_stub_state
IS_ENABLED_RC=0
FETCH_ISSUES_RESPONSE='[{"number":200}]'
FETCH_PRS_RESPONSE='[]'
RUN_ATTEMPT_RC_QUEUE=(2)
LOAD_STATE_RESPONSE='{"issue":200,"total_attempts":4,"last_failure_signature":"sig200"}'

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "観点 e: rc=2 を受けて process は rc=0（fail-continue）" "0" "$rc"
assert_grep "観点 e: rc=2 → fr_terminate_max_attempts が issue 200 で呼ばれる" "^fr_terminate_max_attempts issue 200 4$" "$TERMINATE_MAX_TRACE"
assert_eq "観点 e: rc=2 で fr_terminate_no_progress は呼ばれない" "0" "$(count_pattern "." "$TERMINATE_NO_PROGRESS_TRACE")"
# state 再読み込みも行われる
assert_grep "観点 e: rc=2 経路で fr_load_state が呼ばれる" "^fr_load_state 200$" "$LOAD_STATE_TRACE"
cleanup_stub_state

# 5-B: rc=3 (no-progress) → fr_terminate_no_progress が呼ばれる
reset_stub_state
IS_ENABLED_RC=0
FETCH_ISSUES_RESPONSE='[{"number":201}]'
FETCH_PRS_RESPONSE='[]'
RUN_ATTEMPT_RC_QUEUE=(3)
LOAD_STATE_RESPONSE='{"issue":201,"total_attempts":2,"last_failure_signature":"abc12345deadbeef"}'

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "観点 e: rc=3 を受けて process は rc=0" "0" "$rc"
assert_grep "観点 e: rc=3 → fr_terminate_no_progress が issue 201 で呼ばれる" "^fr_terminate_no_progress issue 201 2 abc12345deadbeef$" "$TERMINATE_NO_PROGRESS_TRACE"
assert_eq "観点 e: rc=3 で fr_terminate_max_attempts は呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
cleanup_stub_state

# 5-C: PR 経路でも terminate が動く
reset_stub_state
IS_ENABLED_RC=0
FETCH_ISSUES_RESPONSE='[]'
FETCH_PRS_RESPONSE='[{"number":300}]'
RUN_ATTEMPT_RC_QUEUE=(2)
LOAD_STATE_RESPONSE='{"issue":300,"total_attempts":4,"last_failure_signature":"sig300"}'

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "観点 e: PR 経路 rc=2 でも process は rc=0" "0" "$rc"
assert_grep "観点 e: rc=2 → fr_terminate_max_attempts が pr 300 で呼ばれる" "^fr_terminate_max_attempts pr 300 4$" "$TERMINATE_MAX_TRACE"
cleanup_stub_state

# ============================================================
# Section 6: rc=99 (quota) は terminate 経路ではない（観点 f / Req 3.x quota sentinel）
# ============================================================
echo ""
echo "--- Section 6: rc=99 (quota) の扱い（観点 f） ---"

reset_stub_state
IS_ENABLED_RC=0
FETCH_ISSUES_RESPONSE='[{"number":400},{"number":401}]'
FETCH_PRS_RESPONSE='[]'
# 1 件目 quota (rc=99)、2 件目 success (rc=0)
RUN_ATTEMPT_RC_QUEUE=(99 0)

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "観点 f: rc=99 でも process は rc=0（quota は次サイクル待ち / fail-continue）" "0" "$rc"

# 2 件目（issue 401）も走る（quota は当該候補のみの中断、次候補は継続）
assert_eq "観点 f: 全 2 件で fr_run_recovery_attempt が呼ばれる（quota 後も継続）" "2" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"
assert_grep "観点 f: issue 400 (quota) が呼ばれる" "^fr_run_recovery_attempt issue 400$" "$RUN_ATTEMPT_TRACE"
assert_grep "観点 f: issue 401 (quota 後の継続) が呼ばれる" "^fr_run_recovery_attempt issue 401$" "$RUN_ATTEMPT_TRACE"

# quota は terminate ではないので terminate 関数は呼ばれない
assert_eq "観点 f: rc=99 で fr_terminate_max_attempts が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
assert_eq "観点 f: rc=99 で fr_terminate_no_progress が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_NO_PROGRESS_TRACE")"

cleanup_stub_state

# ============================================================
# Section 7: 未知の rc は警告 + 継続（fail-continue / NFR 5.2）
# ============================================================
echo ""
echo "--- Section 7: 未知の rc 警告 + 継続（NFR 5.2） ---"

reset_stub_state
IS_ENABLED_RC=0
FETCH_ISSUES_RESPONSE='[{"number":500},{"number":501}]'
FETCH_PRS_RESPONSE='[]'
# 1 件目で未知 rc=42、2 件目で success
RUN_ATTEMPT_RC_QUEUE=(42 0)

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "NFR 5.2: 未知 rc でも process は rc=0" "0" "$rc"
# 未知 rc の警告が trace に出ている
assert_grep "NFR 5.2: 未知 rc=42 の警告が fr_warn に出る" "未知の rc=42" "$FR_WARN_TRACE"
# 2 件目も継続処理されている
assert_eq "NFR 5.2: 未知 rc 後も全 2 件で fr_run_recovery_attempt が呼ばれる" "2" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"

cleanup_stub_state

# ============================================================
# Section 8: fetch 失敗（空文字応答）でも安全に進む（fail-continue）
# ============================================================
echo ""
echo "--- Section 8: fetch 空文字応答の正規化（NFR 5.2） ---"

reset_stub_state
IS_ENABLED_RC=0
FETCH_ISSUES_RESPONSE=''  # 空文字（fr_fetch_failed_issues が空を返すケース）
FETCH_PRS_RESPONSE=''

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "NFR 5.2: fetch 空文字でも process は rc=0" "0" "$rc"
assert_eq "NFR 5.2: 空文字 → fr_run_recovery_attempt が呼ばれない" "0" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"

cleanup_stub_state

# ============================================================
# Section 9: 不正な number は skip し残候補は継続（NFR 3.1）
# ============================================================
echo ""
echo "--- Section 9: 不正 number の skip（NFR 3.1） ---"

reset_stub_state
IS_ENABLED_RC=0
# 1 件目に非数値 number、2 件目に正常 number
FETCH_ISSUES_RESPONSE='[{"number":"abc"},{"number":600}]'
FETCH_PRS_RESPONSE='[]'
RUN_ATTEMPT_RC_QUEUE=(0)

set +e
process_failed_recovery
rc=$?
set -e
assert_rc "NFR 3.1: 不正 number 存在でも process は rc=0" "0" "$rc"
# 不正 number は skip され、正常な issue 600 のみ呼ばれる
assert_eq "NFR 3.1: 不正 number は skip され 1 件のみ呼ばれる" "1" "$(count_pattern "." "$RUN_ATTEMPT_TRACE")"
assert_grep "NFR 3.1: issue 600 が呼ばれる" "^fr_run_recovery_attempt issue 600$" "$RUN_ATTEMPT_TRACE"
# 警告が出る
assert_grep "NFR 3.1: 不正 issue number の警告が fr_warn に出る" "不正な issue number" "$FR_WARN_TRACE"

cleanup_stub_state

# ============================================================
# Section 10: 単独 _fr_dispatch_candidate の terminate 配線（unit-ish）
# ============================================================
echo ""
echo "--- Section 10: _fr_dispatch_candidate の terminate 配線 ---"

# 10-A: rc=0 → terminate 関数を呼ばない
reset_stub_state
RUN_ATTEMPT_RC_QUEUE=(0)
set +e
_fr_dispatch_candidate "issue" "700"
rc=$?
set -e
assert_rc "rc=0 → dispatch は rc=0" "0" "$rc"
assert_eq "rc=0 で terminate_max が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
assert_eq "rc=0 で terminate_no_progress が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_NO_PROGRESS_TRACE")"
cleanup_stub_state

# 10-B: rc=1 → terminate 関数を呼ばない（失敗は次サイクル再試行）
reset_stub_state
RUN_ATTEMPT_RC_QUEUE=(1)
set +e
_fr_dispatch_candidate "issue" "701"
rc=$?
set -e
assert_rc "rc=1 → dispatch は rc=0" "0" "$rc"
assert_eq "rc=1 で terminate_max が呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
cleanup_stub_state

# 10-C: rc=99 → terminate 関数を呼ばない（quota 待ち）
reset_stub_state
RUN_ATTEMPT_RC_QUEUE=(99)
set +e
_fr_dispatch_candidate "pr" "702"
rc=$?
set -e
assert_rc "rc=99 → dispatch は rc=0" "0" "$rc"
assert_eq "rc=99 で terminate 関数が一切呼ばれない" "0" "$(count_pattern "." "$TERMINATE_MAX_TRACE")"
assert_eq "rc=99 で terminate_no_progress も呼ばれない" "0" "$(count_pattern "." "$TERMINATE_NO_PROGRESS_TRACE")"
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
