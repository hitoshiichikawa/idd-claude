#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #411（即時失敗除外）で
#       追加した即時失敗除外 / 専用ログ / worktree 起動 / 独立エスカレーション を
#       関数単体 / 統合 stub で検証するスモークテスト。
#
#       対象関数（#411 で新規追加 / 拡張）:
#         - fr_resolve_dedicated_log_path        (Req 2.1〜2.5 / NFR 2.2)
#         - fr_prepare_repo_worktree              (Req 3.1〜3.6)
#         - fr_terminate_immediate_failure_streak (Req 4.1〜4.6 / NFR 4.1)
#         - fr_run_recovery_attempt 内の rc=98 ハンドリング（Req 1.1 / 1.4 / 1.5 / 1.7）
#         - fr_save_state の immediate_failure_streak 6 番目引数（Req 1.4）
#
#       検証する AC（docs/specs/411-fix-failed-recovery-claude-rc-1-2s-attem/requirements.md）:
#         - Req 1.1: rc=98 時に attempt budget からロールバック
#         - Req 1.4: immediate_failure_streak の state 永続化
#         - Req 1.5: streak 上限到達時に rc=4 を caller に返す
#         - Req 1.7: tool_use 観測時 / 通常失敗時に streak=0 リセット
#         - Req 2.1〜2.3: ログ名に `failed-recovery` / kind / number / timestamp を含む
#         - Req 2.4: LOG 未設定でも /dev/null fallback せず自前で保存先を確定
#         - Req 3.5: REPO_DIR を作業ツリー起点に採用
#         - Req 4.1: 終端理由識別子 `immediate-failure-streak` を使用
#         - Req 4.2: 一次運用ログ `terminated reason=immediate-failure-streak` で grep 抽出可能
#         - Req 4.4: claude-failed ラベルは据え置き（除去しない）
#         - Req 4.5: rs_set_result claude-failed が 1 回だけ呼ばれる
#
# 配置先: local-watcher/test/fr_immediate_fail_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/fr_immediate_fail_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テストと同じ extract_function イディオム
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 抽出: #411 で追加 / 既存利用の関数
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_resolve_dedicated_log_path")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_prepare_repo_worktree")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_terminate_immediate_failure_streak")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_post_attempt_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_run_recovery_attempt")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_should_recover")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_finalize_success")"

for fn in fr_resolve_dedicated_log_path fr_prepare_repo_worktree \
          fr_terminate_immediate_failure_streak fr_post_attempt_comment \
          fr_run_recovery_attempt fr_should_recover fr_finalize_success; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── グローバル env ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
REPO_SLUG="owner-test-repo"
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
FAILED_RECOVERY_GIT_TIMEOUT=60
# shellcheck disable=SC2034
FAILED_RECOVERY_DEV_MODEL="claude-opus-4-7"
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_TURNS=20
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_ATTEMPTS=4
# shellcheck disable=SC2034
FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=10
# shellcheck disable=SC2034
FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3
# shellcheck disable=SC2034
LOG_DIR="/tmp/fr-imm-test-logs"
# shellcheck disable=SC2034
BASE_BRANCH="main"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
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
  local label="$1" expected_rc="$2" actual_rc="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label expected_rc=$expected_rc actual_rc=$actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}
assert_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label pattern=$pattern"
    [ -f "$file" ] && { echo "--- $file ---"; cat "$file"; echo "--- /$file ---"; }
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}
assert_not_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "FAIL: $label unexpected pattern=$pattern"
    [ -f "$file" ] && { echo "--- $file ---"; cat "$file"; echo "--- /$file ---"; }
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ── stub state ──
GH_CALL_LOG=""
FR_WARN_TRACE=""
FR_LOG_TRACE=""
SAVE_STATE_TRACE=""
LOAD_STATE_TRACE=""
INVOKE_CLAUDE_TRACE=""
PREPARE_WORKTREE_TRACE=""
SN_NOTIFY_TRACE=""
RS_SET_RESULT_TRACE=""

LOAD_STATE_RESPONSE='{}'
INVOKE_CLAUDE_RC=0
DETECT_NO_PROGRESS_RC=1
COLLECT_ISSUE_CONTEXT_RESPONSE="dummy issue context"
COLLECT_PR_CI_CONTEXT_RESPONSE="dummy pr ci context"
GH_PR_VIEW_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
GH_PR_VIEW_HEAD_REF="claude/issue-42-impl-test"
GH_RC=0
PREPARE_WORKTREE_RC=0
PREPARE_WORKTREE_OUTPUT="claude/issue-42-impl-test"

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  FR_WARN_TRACE="$(mktemp)"
  FR_LOG_TRACE="$(mktemp)"
  SAVE_STATE_TRACE="$(mktemp)"
  LOAD_STATE_TRACE="$(mktemp)"
  INVOKE_CLAUDE_TRACE="$(mktemp)"
  PREPARE_WORKTREE_TRACE="$(mktemp)"
  SN_NOTIFY_TRACE="$(mktemp)"
  RS_SET_RESULT_TRACE="$(mktemp)"
  LOAD_STATE_RESPONSE='{}'
  INVOKE_CLAUDE_RC=0
  DETECT_NO_PROGRESS_RC=1
  COLLECT_ISSUE_CONTEXT_RESPONSE="dummy issue context"
  COLLECT_PR_CI_CONTEXT_RESPONSE="dummy pr ci context"
  GH_PR_VIEW_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
  GH_PR_VIEW_HEAD_REF="claude/issue-42-impl-test"
  GH_RC=0
  PREPARE_WORKTREE_RC=0
  PREPARE_WORKTREE_OUTPUT="claude/issue-42-impl-test"
  FR_PROCESSED_THIS_CYCLE=""
  export FR_PROCESSED_THIS_CYCLE
  # shellcheck disable=SC2034  # REPO_DIR は遅延束縛で fr_run_recovery_attempt から参照される
  REPO_DIR="/tmp/fr-imm-test-stub-repo"
}
cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$FR_WARN_TRACE" "$FR_LOG_TRACE" "$SAVE_STATE_TRACE" \
        "$LOAD_STATE_TRACE" "$INVOKE_CLAUDE_TRACE" "$PREPARE_WORKTREE_TRACE" \
        "$SN_NOTIFY_TRACE" "$RS_SET_RESULT_TRACE" 2>/dev/null || true
}

# ── 内部関数 stub 群 ──
# shellcheck disable=SC2317
fr_warn() { echo "$*" >> "$FR_WARN_TRACE"; }
# shellcheck disable=SC2317
fr_log() { echo "$*" >> "$FR_LOG_TRACE"; }
# shellcheck disable=SC2317
fr_error() { echo "$*" >> "$FR_WARN_TRACE"; }
# shellcheck disable=SC2317
timeout() { shift; "$@"; }
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  case "${1:-}" in
    pr)
      case "${2:-}" in
        view)
          # 引数の `--json` を見て応答を切り替え
          local args=("$@")
          local i
          for ((i=0; i<${#args[@]}; i++)); do
            if [ "${args[i]:-}" = "--json" ] && [ "${args[i+1]:-}" = "headRefOid" ]; then
              printf '%s' "$GH_PR_VIEW_HEAD_SHA"
              return "$GH_RC"
            fi
            if [ "${args[i]:-}" = "--json" ] && [ "${args[i+1]:-}" = "headRefName" ]; then
              printf '%s' "$GH_PR_VIEW_HEAD_REF"
              return "$GH_RC"
            fi
          done
          return "$GH_RC"
          ;;
      esac
      ;;
  esac
  return "$GH_RC"
}
# shellcheck disable=SC2317
fr_load_state() {
  echo "fr_load_state $*" >> "$LOAD_STATE_TRACE"
  printf '%s' "$LOAD_STATE_RESPONSE"
}
# shellcheck disable=SC2317
fr_save_state() {
  echo "fr_save_state $*" >> "$SAVE_STATE_TRACE"
  return 0
}
# shellcheck disable=SC2317
fr_compute_failure_signature() {
  cat >/dev/null
  printf '%s' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
# shellcheck disable=SC2317
fr_detect_no_progress() { return "$DETECT_NO_PROGRESS_RC"; }
# shellcheck disable=SC2317
fr_collect_issue_context() { printf '%s' "$COLLECT_ISSUE_CONTEXT_RESPONSE"; }
# shellcheck disable=SC2317
fr_collect_pr_ci_context() { printf '%s' "$COLLECT_PR_CI_CONTEXT_RESPONSE"; }
# shellcheck disable=SC2317
fr_invoke_claude() {
  echo "fr_invoke_claude prompt_len=${#1} stage=$2 ded_log=$3" >> "$INVOKE_CLAUDE_TRACE"
  return "$INVOKE_CLAUDE_RC"
}
# shellcheck disable=SC2317
fr_prepare_repo_worktree() {
  echo "fr_prepare_repo_worktree kind=$1 number=$2 pr_head=$3" >> "$PREPARE_WORKTREE_TRACE"
  if [ "$PREPARE_WORKTREE_RC" != "0" ]; then
    return "$PREPARE_WORKTREE_RC"
  fi
  printf '%s' "$PREPARE_WORKTREE_OUTPUT"
  return 0
}
# shellcheck disable=SC2317
fr_resolve_dedicated_log_path() {
  printf '/tmp/fr-imm-test-dedicated-%s-%s.log' "$1" "$2"
  return 0
}
# shellcheck disable=SC2317
sn_notify() { echo "sn_notify $*" >> "$SN_NOTIFY_TRACE"; return 0; }
# shellcheck disable=SC2317
rs_set_result() { echo "rs_set_result $*" >> "$RS_SET_RESULT_TRACE"; return 0; }

# ============================================================
# Section A: fr_resolve_dedicated_log_path（Req 2.1〜2.4 / NFR 2.2 / NFR 3.1）
# ============================================================
echo "--- Section A: fr_resolve_dedicated_log_path ---"

reset_stub_state
trap 'cleanup_stub_state' EXIT

# 正常 path: kind=issue + number=42 → `failed-recovery` / `issue` / `42` を含む
unset -f fr_resolve_dedicated_log_path  # stub を外して本物を呼ぶ
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_resolve_dedicated_log_path")"
out=$(fr_resolve_dedicated_log_path "issue" "42")
rc=$?
assert_rc "Req 2.1: 正常 path → rc=0" "0" "$rc"
case "$out" in
  *"failed-recovery"*) echo "PASS: Req 2.3: 識別語 failed-recovery を含む"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *) echo "FAIL: Req 2.3: 識別語 failed-recovery を含む actual=$out"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
esac
case "$out" in
  *"issue"*) echo "PASS: Req 2.2: kind=issue を含む"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *) echo "FAIL: Req 2.2: kind=issue を含む actual=$out"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
esac
case "$out" in
  *"42"*) echo "PASS: Req 2.2: number=42 を含む"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *) echo "FAIL: Req 2.2: number=42 を含む actual=$out"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
esac
case "$out" in
  *"$LOG_DIR"*) echo "PASS: Req 2.2: $LOG_DIR 配下"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *) echo "FAIL: Req 2.2: $LOG_DIR 配下 actual=$out"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
esac

# kind=pr
out=$(fr_resolve_dedicated_log_path "pr" "100")
case "$out" in
  *"-pr-100-"*) echo "PASS: Req 2.2: kind=pr / number=100 が含まれる"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *) echo "FAIL: Req 2.2: kind=pr / number=100 actual=$out"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
esac

# 不正な kind → rc=1
set +e
out=$(fr_resolve_dedicated_log_path "design" "42"); rc=$?
set -e
assert_rc "NFR 3.1: 不正な kind=design → rc=1" "1" "$rc"

# 不正な number → rc=1
set +e
out=$(fr_resolve_dedicated_log_path "issue" "abc"); rc=$?
set -e
assert_rc "NFR 3.1: 非数値 number → rc=1" "1" "$rc"

# Req 2.4: LOG_DIR 未設定でも自前で fallback パスを生成（/dev/null fallback ではない）
saved_log_dir="$LOG_DIR"
unset LOG_DIR
out=$(fr_resolve_dedicated_log_path "issue" "42")
case "$out" in
  *"/.issue-watcher/logs/"*"failed-recovery-issue-42-"*)
    echo "PASS: Req 2.4: LOG_DIR 未設定でも \$HOME/.issue-watcher/logs にフォールバック"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: Req 2.4: LOG_DIR 未設定 fallback actual=$out"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
case "$out" in
  */dev/null*) echo "FAIL: Req 2.4: /dev/null に倒さない"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
  *) echo "PASS: Req 2.4: /dev/null fallback ではない"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
esac
LOG_DIR="$saved_log_dir"

# stub を戻す
# shellcheck disable=SC2317
fr_resolve_dedicated_log_path() {
  printf '/tmp/fr-imm-test-dedicated-%s-%s.log' "$1" "$2"
  return 0
}
cleanup_stub_state

# ============================================================
# Section B: fr_terminate_immediate_failure_streak（Req 4.1〜4.6 / NFR 4.1 / 4.2）
# ============================================================
echo ""
echo "--- Section B: fr_terminate_immediate_failure_streak ---"

reset_stub_state

set +e
fr_terminate_immediate_failure_streak "issue" "411" "3"
rc=$?
set -e
assert_rc "Req 4.1〜4.5: 正常 path → rc=0" "0" "$rc"

# Req 4.1 / 4.3: 終端理由コメントに識別子と連続回数が含まれる
assert_grep "Req 4.1: コメントに identifier immediate-failure-streak が含まれる" "immediate-failure-streak" "$GH_CALL_LOG"
assert_grep "Req 4.3: コメントに streak 回数 3 が含まれる" "連続 3 回" "$GH_CALL_LOG"

# Req 4.2: 一次運用ログに terminated reason=immediate-failure-streak が記録される
assert_grep "Req 4.2: fr_log に terminated reason=immediate-failure-streak" "terminated reason=immediate-failure-streak" "$FR_LOG_TRACE"
assert_grep "Req 4.2: fr_log に issue=#411" "issue=#411" "$FR_LOG_TRACE"

# Req 4.4: claude-failed ラベルを除去しない
assert_not_grep "Req 4.4: --remove-label claude-failed が呼ばれない" "--remove-label" "$GH_CALL_LOG"

# Req 4.5: rs_set_result claude-failed が 1 回だけ呼ばれる
rs_count=$(wc -l < "$RS_SET_RESULT_TRACE" 2>/dev/null || echo "0")
rs_count="${rs_count//[[:space:]]/}"
assert_eq "Req 4.5: rs_set_result が 1 回だけ呼ばれる" "1" "$rs_count"
assert_grep "Req 4.5: rs_set_result claude-failed" "claude-failed" "$RS_SET_RESULT_TRACE"

# Req 4.6: Slack 通知に identifier と streak が含まれ、signature 等の機微値を含めない
assert_grep "Req 4.6: sn_notify に immediate-failure-streak" "immediate-failure-streak" "$SN_NOTIFY_TRACE"
assert_grep "Req 4.6: sn_notify に streak=3" "streak=3" "$SN_NOTIFY_TRACE"
assert_not_grep "NFR 3.2: signature 値が sn_notify に含まれない" "aaaaaaaaaaaaaaaa" "$SN_NOTIFY_TRACE"

# NFR 3.1: 不正な kind / number → rc=1
set +e
fr_terminate_immediate_failure_streak "design" "411" "3"; rc=$?
set -e
assert_rc "NFR 3.1: 不正な kind → rc=1" "1" "$rc"

set +e
fr_terminate_immediate_failure_streak "issue" "abc" "3"; rc=$?
set -e
assert_rc "NFR 3.1: 非数値 number → rc=1" "1" "$rc"

cleanup_stub_state

# ============================================================
# Section C: fr_run_recovery_attempt 内 rc=98 → attempt ロールバック + streak ++
# （Req 1.1 / 1.4）
# ============================================================
echo ""
echo "--- Section C: rc=98 → attempt rollback + streak ++ ---"

reset_stub_state

# prev_total=1, prev_streak=0、claude が rc=98 を返す
LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":0,"history":[]}'
INVOKE_CLAUDE_RC=98

set +e
fr_run_recovery_attempt "issue" "42"
rc=$?
set -e

# 上限未到達なので caller には rc=1（次サイクル再試行）を返す
assert_rc "Req 1.1: 上限未到達の即時失敗 → caller には rc=1" "1" "$rc"

# fr_save_state は計 2 回呼ばれる:
#   1) 開始時 in-progress save (total=2, streak=0)  ← prev_total + 1
#   2) 即時失敗 rollback save (total=1, streak=1)
save_count=$(wc -l < "$SAVE_STATE_TRACE" 2>/dev/null || echo "0")
save_count="${save_count//[[:space:]]/}"
assert_eq "Req 1.1 / 1.4: fr_save_state が 2 回呼ばれる" "2" "$save_count"

# Req 1.1: rollback save が total=1（prev_total に戻す）+ streak=1
assert_grep "Req 1.1: rollback save total=1（巻き戻し）+ streak=1" "^fr_save_state 42 1 in-progress .* 1$" "$SAVE_STATE_TRACE"

# 上限未到達なので rc != 4
if [ "$rc" = "4" ]; then
  echo "FAIL: Req 1.5: streak=1 < max=3 で rc=4 は出してはならない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: Req 1.5: streak=1 < max=3 で rc=4 を返さない"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

cleanup_stub_state

# ============================================================
# Section D: rc=98 + streak が上限到達 → rc=4 を caller に返す（Req 1.5）
# ============================================================
echo ""
echo "--- Section D: rc=98 + streak 上限到達 → rc=4 ---"

reset_stub_state

# prev_streak=2、claude が rc=98 → new_streak=3 == max=3
LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":2,"history":[]}'
INVOKE_CLAUDE_RC=98

set +e
fr_run_recovery_attempt "issue" "42"
rc=$?
set -e
assert_rc "Req 1.5: streak max 到達 → rc=4（terminate へ委譲）" "4" "$rc"

# 即時失敗 rollback save: total=1, streak=3
assert_grep "Req 1.4: rollback save streak=3" "^fr_save_state 42 1 in-progress .* 3$" "$SAVE_STATE_TRACE"

cleanup_stub_state

# ============================================================
# Section E: rc=98 + prev_streak が既に上限 → 事前判定で rc=4（attempt 加算なし）
# （Req 1.5 / 1.6）
# ============================================================
echo ""
echo "--- Section E: 事前判定で prev_streak が上限 → rc=4 ---"

reset_stub_state

LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":3,"history":[]}'
INVOKE_CLAUDE_RC=0  # ここまで来ないはず

set +e
fr_run_recovery_attempt "issue" "42"
rc=$?
set -e
assert_rc "Req 1.5: prev_streak >= max → 事前判定で rc=4" "4" "$rc"

# attempt 加算もしない / claude も起動しない
invoke_count=$(wc -l < "$INVOKE_CLAUDE_TRACE" 2>/dev/null || echo "0")
invoke_count="${invoke_count//[[:space:]]/}"
assert_eq "Req 1.5: 事前判定では fr_invoke_claude が呼ばれない" "0" "$invoke_count"

save_count=$(wc -l < "$SAVE_STATE_TRACE" 2>/dev/null || echo "0")
save_count="${save_count//[[:space:]]/}"
assert_eq "Req 1.5: 事前判定では fr_save_state も呼ばれない" "0" "$save_count"

cleanup_stub_state

# ============================================================
# Section F: 通常失敗（rc!=0,98,99）→ streak=0 リセット（Req 1.7）
# ============================================================
echo ""
echo "--- Section F: 通常失敗で streak=0 リセット ---"

reset_stub_state

# prev_streak=2、claude が rc=7（通常失敗）→ new_streak リセット
LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":2,"history":[]}'
INVOKE_CLAUDE_RC=7

set +e
fr_run_recovery_attempt "issue" "42"
rc=$?
set -e
assert_rc "Req 1.7: 通常失敗 → caller には rc=1（次サイクル再試行）" "1" "$rc"

# 開始時 in-progress save: total=2, streak=2 (継承)
# 通常失敗時 in-progress save: total=2, streak=0 (リセット)
assert_grep "Req 1.7: 通常失敗時の save で streak=0 にリセット" "^fr_save_state 42 2 in-progress .* 0$" "$SAVE_STATE_TRACE"

cleanup_stub_state

# ============================================================
# Section G: success path で streak=0 リセット（Req 1.7）
# ============================================================
echo ""
echo "--- Section G: success path で streak=0 リセット ---"

reset_stub_state

LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":2,"history":[]}'
INVOKE_CLAUDE_RC=0

set +e
fr_run_recovery_attempt "issue" "42"
rc=$?
set -e
assert_rc "Req 1.7: success path → rc=0" "0" "$rc"

# success 経由の追加 save で streak=0 にリセット
assert_grep "Req 1.7: success 経由の save で streak=0 にリセット" "^fr_save_state 42 2 in-progress .* 0$" "$SAVE_STATE_TRACE"

cleanup_stub_state

# ============================================================
# Section H: 作業ツリー checkout 失敗 → 即時失敗扱い（Req 3.4）
# ============================================================
echo ""
echo "--- Section H: 作業ツリー checkout 失敗 → 即時失敗扱い ---"

reset_stub_state

LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":0,"history":[]}'
PREPARE_WORKTREE_RC=1
INVOKE_CLAUDE_RC=0  # ここに来ないはず

set +e
fr_run_recovery_attempt "issue" "42"
rc=$?
set -e
assert_rc "Req 3.4: 作業ツリー失敗 → 即時失敗扱い → 上限未到達なら rc=1" "1" "$rc"

# claude は起動しない
invoke_count=$(wc -l < "$INVOKE_CLAUDE_TRACE" 2>/dev/null || echo "0")
invoke_count="${invoke_count//[[:space:]]/}"
assert_eq "Req 3.4: 作業ツリー失敗時に fr_invoke_claude が呼ばれない" "0" "$invoke_count"

# rollback save が呼ばれる（streak=1 加算）
assert_grep "Req 3.4: 作業ツリー失敗時も rollback save streak=1" "^fr_save_state 42 1 in-progress .* 1$" "$SAVE_STATE_TRACE"

cleanup_stub_state

# ============================================================
# Section I: dedicated log path が fr_invoke_claude に渡される（Req 2.1）
# ============================================================
echo ""
echo "--- Section I: dedicated log path が fr_invoke_claude に渡される ---"

reset_stub_state

LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":0,"history":[]}'
INVOKE_CLAUDE_RC=0

set +e
fr_run_recovery_attempt "issue" "42"
set -e

# fr_invoke_claude の trace に dedicated log path が含まれる
assert_grep "Req 2.1: fr_invoke_claude に専用ログパスが渡される" "ded_log=/tmp/fr-imm-test-dedicated-issue-42.log" "$INVOKE_CLAUDE_TRACE"

cleanup_stub_state

# ============================================================
# Section J: 作業ツリー起点パスと checkout 参照名がログ記録される（Req 3.6）
# ============================================================
echo ""
echo "--- Section J: 作業ツリー起点と参照名のログ記録 ---"

reset_stub_state

LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","immediate_failure_streak":0,"history":[]}'
INVOKE_CLAUDE_RC=0
PREPARE_WORKTREE_OUTPUT="claude/issue-42-impl-test"

set +e
fr_run_recovery_attempt "issue" "42"
set -e

# REPO_DIR と checkout した参照名（claude/issue-42-impl-test）がログに記録される
assert_grep "Req 3.6: REPO_DIR がログに記録される" "repo_dir=/tmp/fr-imm-test-stub-repo" "$FR_LOG_TRACE"
assert_grep "Req 3.6: checkout 参照名がログに記録される" "ref=claude/issue-42-impl-test" "$FR_LOG_TRACE"

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
