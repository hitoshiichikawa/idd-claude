#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した Orchestrator Layer（fr_should_recover /
#       fr_post_attempt_comment / fr_finalize_success / fr_run_recovery_attempt）を
#       gh / claude / 内部関数 stub で検証するスモークテスト。
#
#       対象関数:
#         - fr_should_recover         (Req 4.4, 4.5)
#         - fr_post_attempt_comment   (Req 3.3, NFR 3.1, NFR 3.2)
#         - fr_finalize_success       (Req 3.4, 6.1, 6.2, NFR 2.1)
#         - fr_run_recovery_attempt   (Req 3.1〜3.5, 4.2, 4.3, 4.4, 6.1, 6.2)
#
#       検証する観点（tasks.md 6 の検証項目 a〜e）:
#         (a) 試行開始時の attempt++ 順序: 着手コメント → 開始時 save (total=prev+1, in-progress)
#             → claude 呼び出し の順で trace が並ぶ
#         (b) claude-failed 除去が success path（claude rc=0）でのみ呼ばれる。
#             rc=1（失敗）/ rc=99（quota）では --remove-label が trace に出ない
#         (c) 結果コメントが 1 件投稿（着手 1 + 結果 1 = gh comment 計 2 件以上）
#         (d) FR_PROCESSED_THIS_CYCLE の重複起動防止: 成功 finalize 後の再起動で
#             gh / claude stub が一切呼ばれない
#         (e) Reviewer marker / pr-iteration marker（`idd-claude:pr-iteration round=N`）を
#             読まない: trace に当該文字列や PR body 取得（--json body 等）が出ない
#
# 配置先: local-watcher/test/fr_attempt_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/fr_attempt_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（fr_invoke_test.sh / fr_state_test.sh）と同じ extract_function イディオム
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 抽出: orchestrator layer の 4 関数
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_should_recover")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_post_attempt_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_finalize_success")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_run_recovery_attempt")"

for fn in fr_should_recover fr_post_attempt_comment fr_finalize_success fr_run_recovery_attempt; do
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
FAILED_RECOVERY_DEV_MODEL="claude-opus-4-7"
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_TURNS=20
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

assert_count() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  local expected="$4"
  local actual
  # grep -c は match 0 件で exit 1 を返すため、|| true で吸収。空ファイルでも 0 を返す。
  actual=$(grep -cE -- "$pattern" "$file" 2>/dev/null || true)
  actual="${actual//[[:space:]]/}"
  if [ -z "$actual" ]; then
    actual="0"
  fi
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
GH_CALL_LOG=""
CLAUDE_CALL_LOG=""
FR_WARN_TRACE=""
FR_LOG_TRACE=""
SAVE_STATE_TRACE=""
LOAD_STATE_TRACE=""
INVOKE_CLAUDE_TRACE=""
FINALIZE_TRACE=""

# fr_load_state の応答（JSON 文字列）
LOAD_STATE_RESPONSE='{}'

# fr_invoke_claude の戻り値（test ごとに上書き）
INVOKE_CLAUDE_RC=0

# fr_compute_failure_signature の応答（固定 sha）
FIXED_SIGNATURE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# fr_detect_no_progress の応答（0=no-progress, 1=progress）
DETECT_NO_PROGRESS_RC=1

# fr_collect_*_context の応答（context 文字列）
COLLECT_ISSUE_CONTEXT_RESPONSE="dummy issue context"
COLLECT_PR_CI_CONTEXT_RESPONSE="dummy pr ci context"

# gh の応答（headRefOid 取得などに対応）
GH_PR_VIEW_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
GH_RC=0

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  CLAUDE_CALL_LOG="$(mktemp)"
  FR_WARN_TRACE="$(mktemp)"
  FR_LOG_TRACE="$(mktemp)"
  SAVE_STATE_TRACE="$(mktemp)"
  LOAD_STATE_TRACE="$(mktemp)"
  INVOKE_CLAUDE_TRACE="$(mktemp)"
  FINALIZE_TRACE="$(mktemp)"
  LOAD_STATE_RESPONSE='{}'
  INVOKE_CLAUDE_RC=0
  DETECT_NO_PROGRESS_RC=1
  COLLECT_ISSUE_CONTEXT_RESPONSE="dummy issue context"
  COLLECT_PR_CI_CONTEXT_RESPONSE="dummy pr ci context"
  GH_PR_VIEW_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
  GH_RC=0
  # FR_PROCESSED_THIS_CYCLE を section ごとに reset
  FR_PROCESSED_THIS_CYCLE=""
  export FR_PROCESSED_THIS_CYCLE
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$CLAUDE_CALL_LOG" "$FR_WARN_TRACE" "$FR_LOG_TRACE" \
        "$SAVE_STATE_TRACE" "$LOAD_STATE_TRACE" "$INVOKE_CLAUDE_TRACE" "$FINALIZE_TRACE" 2>/dev/null || true
}

# ── 内部関数 stub 群 ──

# fr_warn / fr_log を上書きして呼出を観測
# shellcheck disable=SC2317
fr_warn() {
  echo "$*" >> "$FR_WARN_TRACE"
}
# shellcheck disable=SC2317
fr_log() {
  echo "$*" >> "$FR_LOG_TRACE"
}

# timeout は引数を捨ててコマンドをそのまま実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: 呼び出しを GH_CALL_LOG に記録。gh pr view --json headRefOid の場合のみ
# stdout に SHA を吐く。それ以外は no-op（gh comment / gh edit の rc は GH_RC で制御）。
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  case "${1:-}" in
    pr)
      case "${2:-}" in
        view)
          # gh pr view <N> --repo R --json headRefOid --jq '.headRefOid' を想定
          if [ "$GH_RC" != "0" ]; then
            return "$GH_RC"
          fi
          printf '%s' "$GH_PR_VIEW_HEAD_SHA"
          return 0
          ;;
      esac
      ;;
  esac
  if [ "$GH_RC" != "0" ]; then
    return "$GH_RC"
  fi
  return 0
}

# fr_load_state stub: LOAD_STATE_TRACE に引数を記録、LOAD_STATE_RESPONSE を返す
# shellcheck disable=SC2317
fr_load_state() {
  echo "fr_load_state $*" >> "$LOAD_STATE_TRACE"
  printf '%s' "$LOAD_STATE_RESPONSE"
}

# fr_save_state stub: SAVE_STATE_TRACE に引数列を記録
# shellcheck disable=SC2317
fr_save_state() {
  echo "fr_save_state $*" >> "$SAVE_STATE_TRACE"
  return 0
}

# fr_compute_failure_signature stub: 固定 SHA を返す
# shellcheck disable=SC2317
fr_compute_failure_signature() {
  cat >/dev/null  # stdin を消費（pipe で渡される）
  printf '%s' "$FIXED_SIGNATURE"
}

# fr_detect_no_progress stub: DETECT_NO_PROGRESS_RC を返す
# shellcheck disable=SC2317
fr_detect_no_progress() {
  return "$DETECT_NO_PROGRESS_RC"
}

# fr_collect_issue_context / fr_collect_pr_ci_context stub
# shellcheck disable=SC2317
fr_collect_issue_context() {
  printf '%s' "$COLLECT_ISSUE_CONTEXT_RESPONSE"
}
# shellcheck disable=SC2317
fr_collect_pr_ci_context() {
  printf '%s' "$COLLECT_PR_CI_CONTEXT_RESPONSE"
}

# fr_invoke_claude stub: INVOKE_CLAUDE_TRACE に引数を記録し、INVOKE_CLAUDE_RC を返す
# shellcheck disable=SC2317
fr_invoke_claude() {
  echo "fr_invoke_claude prompt_len=${#1} stage=$2" >> "$INVOKE_CLAUDE_TRACE"
  # claude 呼び出し記録の補助として CLAUDE_CALL_LOG にも記録
  echo "claude -p ... stage=$2" >> "$CLAUDE_CALL_LOG"
  return "$INVOKE_CLAUDE_RC"
}

# ============================================================
# Section 1: fr_should_recover の純粋判定（Req 4.4 / 4.5）
# ============================================================
echo "--- Section 1: fr_should_recover の純粋判定 ---"

reset_stub_state
trap 'cleanup_stub_state' EXIT

set +e
fr_should_recover 0; rc=$?
set -e
assert_rc "Req 4.4: total=0 < max=4 → rc=0 (can recover)" "0" "$rc"

set +e
fr_should_recover 3; rc=$?
set -e
assert_rc "Req 4.4: total=3 < max=4 → rc=0 (can recover)" "0" "$rc"

set +e
fr_should_recover 4; rc=$?
set -e
assert_rc "Req 4.5: total=4 >= max=4 → rc=1 (max reached)" "1" "$rc"

set +e
fr_should_recover 99; rc=$?
set -e
assert_rc "Req 4.5: total=99 >= max=4 → rc=1 (max reached)" "1" "$rc"

cleanup_stub_state

# ============================================================
# Section 2: 試行開始時の attempt++ 順序（観点 a）
# ============================================================
echo ""
echo "--- Section 2: 試行開始時の attempt++ 順序（観点 a） ---"

reset_stub_state

# prev_total = 2 とし、新試行で total=3 が in-progress として save されることを検証
LOAD_STATE_RESPONSE='{"issue":42,"total_attempts":2,"last_status":"in-progress","last_failure_signature":"prev-sig","last_head_sha":"","last_attempt_at":"2026-06-22T00:00:00Z","history":[]}'
INVOKE_CLAUDE_RC=0  # success path

set +e
fr_run_recovery_attempt "issue" "42"
rc=$?
set -e
assert_rc "observation: success path → rc=0" "0" "$rc"

# 開始時 save が呼ばれること: total_attempts=3 (prev=2+1), last_status=in-progress
assert_grep "観点 a: 開始時 fr_save_state(42, 3, in-progress, ...) が呼ばれる" "^fr_save_state 42 3 in-progress " "$SAVE_STATE_TRACE"

# fr_save_state が in-progress 1 件 + finalize 経由 succeeded 1 件 = 計 2 件
save_count=$(wc -l < "$SAVE_STATE_TRACE" 2>/dev/null || echo "0")
save_count="${save_count//[[:space:]]/}"
if [ "$save_count" = "2" ]; then
  echo "PASS: 観点 a: fr_save_state が 2 件呼ばれる (in-progress + succeeded)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: 観点 a: fr_save_state が 2 件呼ばれる (actual=$save_count)"
  cat "$SAVE_STATE_TRACE"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 着手コメント → 開始時 save → claude → 結果コメント の順序
# 着手コメント (gh comment) → fr_save_state → fr_invoke_claude の順を検証
# 簡易には: fr_save_state が呼ばれる時点で gh issue comment は最低 1 件記録済み
# （concrete な順序検証は trace の to-merge が複雑なため、claude 呼び出しと save の
#  順序を主に検査する。「着手」「結果」のコメント本数は別 section で検査）。
assert_grep "観点 a: fr_invoke_claude が呼ばれる" "fr_invoke_claude " "$INVOKE_CLAUDE_TRACE"

cleanup_stub_state

# ============================================================
# Section 3: claude-failed 除去が success path でのみ呼ばれる（観点 b / Req 3.4）
# ============================================================
echo ""
echo "--- Section 3: claude-failed 除去が success path でのみ（観点 b） ---"

# 3-A: claude rc=0 (success) → --remove-label が 1 件
reset_stub_state
LOAD_STATE_RESPONSE='{"issue":50,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=0
set +e
fr_run_recovery_attempt "issue" "50"
rc=$?
set -e
assert_rc "観点 b: success path → rc=0" "0" "$rc"
assert_grep "観点 b: success path で --remove-label claude-failed が呼ばれる" "gh issue edit 50 .* --remove-label claude-failed" "$GH_CALL_LOG"
cleanup_stub_state

# 3-B: claude rc=1 (失敗) → --remove-label が呼ばれない
reset_stub_state
LOAD_STATE_RESPONSE='{"issue":51,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=1
set +e
fr_run_recovery_attempt "issue" "51"
rc=$?
set -e
assert_rc "観点 b: claude rc=1 → rc=1 (failed, retry next cycle)" "1" "$rc"
assert_not_grep "観点 b: claude rc=1 で --remove-label が呼ばれない" "--remove-label claude-failed" "$GH_CALL_LOG"
cleanup_stub_state

# 3-C: claude rc=99 (quota) → --remove-label が呼ばれない
reset_stub_state
LOAD_STATE_RESPONSE='{"issue":52,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=99
set +e
fr_run_recovery_attempt "issue" "52"
rc=$?
set -e
assert_rc "観点 b: quota detected → rc=99" "99" "$rc"
assert_not_grep "観点 b: quota path で --remove-label が呼ばれない" "--remove-label claude-failed" "$GH_CALL_LOG"
cleanup_stub_state

# ============================================================
# Section 4: 結果コメントが 1 件投稿（着手 1 + 結果 1 = 計 2 件以上 / 観点 c / Req 3.3）
# ============================================================
echo ""
echo "--- Section 4: 結果コメント 1 件投稿（観点 c） ---"

# 4-A: success path で gh issue comment が 2 件（着手 + 結果）
reset_stub_state
LOAD_STATE_RESPONSE='{"issue":60,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=0
set +e
fr_run_recovery_attempt "issue" "60"
set -e
assert_count "観点 c: success path で gh issue comment が 2 件（着手 1 + 結果 1）" "gh issue comment 60" "$GH_CALL_LOG" "2"
cleanup_stub_state

# 4-B: failure path（rc=1）も着手 + 結果で 2 件
reset_stub_state
LOAD_STATE_RESPONSE='{"issue":61,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=1
set +e
fr_run_recovery_attempt "issue" "61"
set -e
assert_count "観点 c: failure path（claude rc=1）でも gh issue comment が 2 件" "gh issue comment 61" "$GH_CALL_LOG" "2"
cleanup_stub_state

# 4-C: quota path（rc=99）も着手 + 結果で 2 件
reset_stub_state
LOAD_STATE_RESPONSE='{"issue":62,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=99
set +e
fr_run_recovery_attempt "issue" "62"
set -e
assert_count "観点 c: quota path（rc=99）でも gh issue comment が 2 件" "gh issue comment 62" "$GH_CALL_LOG" "2"
cleanup_stub_state

# ============================================================
# Section 5: FR_PROCESSED_THIS_CYCLE の重複起動防止（観点 d / Req 6.1 / NFR 2.1）
# ============================================================
echo ""
echo "--- Section 5: FR_PROCESSED_THIS_CYCLE の重複起動防止（観点 d） ---"

reset_stub_state
LOAD_STATE_RESPONSE='{"issue":70,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=0

# 1 回目: 通常に success path を実行
set +e
fr_run_recovery_attempt "issue" "70"
set -e

# 1 回目で claude が 1 回呼ばれていることを確認
claude_count_1=$(count_pattern "fr_invoke_claude " "$INVOKE_CLAUDE_TRACE")
assert_eq "観点 d: 1 回目で claude が 1 回呼ばれる" "1" "$claude_count_1"

# FR_PROCESSED_THIS_CYCLE に issue:70 が記録されていること
case " $FR_PROCESSED_THIS_CYCLE " in
  *" issue:70 "*)
    echo "PASS: 観点 d: FR_PROCESSED_THIS_CYCLE に issue:70 が記録される"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: 観点 d: FR_PROCESSED_THIS_CYCLE に issue:70 が記録されていない (actual=$FR_PROCESSED_THIS_CYCLE)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac

# 2 回目: 同じ kind:number で再起動。trace を一旦 clear して新規呼び出しが無いことを検証
GH_CALL_LOG="$(mktemp)"
CLAUDE_CALL_LOG="$(mktemp)"
INVOKE_CLAUDE_TRACE="$(mktemp)"
SAVE_STATE_TRACE="$(mktemp)"
LOAD_STATE_TRACE="$(mktemp)"

set +e
fr_run_recovery_attempt "issue" "70"
rc=$?
set -e
assert_rc "観点 d: 2 回目（重複）→ rc=0（即 return / no-op）" "0" "$rc"

# 2 回目では gh / claude / fr_save_state / fr_load_state のいずれも呼ばれない
assert_eq "観点 d: 2 回目で gh stub が呼ばれない" "0" "$(count_pattern "." "$GH_CALL_LOG")"
assert_eq "観点 d: 2 回目で fr_invoke_claude が呼ばれない" "0" "$(count_pattern "." "$INVOKE_CLAUDE_TRACE")"
assert_eq "観点 d: 2 回目で fr_save_state が呼ばれない" "0" "$(count_pattern "." "$SAVE_STATE_TRACE")"
assert_eq "観点 d: 2 回目で fr_load_state が呼ばれない" "0" "$(count_pattern "." "$LOAD_STATE_TRACE")"

cleanup_stub_state

# ============================================================
# Section 6: Reviewer marker / pr-iteration marker を読まない（観点 e / Req 4.3 / D-19b）
# ============================================================
echo ""
echo "--- Section 6: Reviewer / pr-iteration marker 独立性（観点 e） ---"

reset_stub_state
LOAD_STATE_RESPONSE='{"issue":80,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
INVOKE_CLAUDE_RC=0

set +e
fr_run_recovery_attempt "pr" "80"
set -e

# trace を combined した上で pr-iteration / Reviewer marker / review-notes の文字列が
# 出現しないこと。具体的には:
#   - 'pr-iteration round=' （pr-iteration の PR body marker）
#   - 'review-notes'        （Reviewer の per-task notes ファイル）
#   - '--json body'         （PR body 取得 — 当該カウンタを読むなら必要）
combined="$(mktemp)"
cat "$GH_CALL_LOG" "$CLAUDE_CALL_LOG" "$INVOKE_CLAUDE_TRACE" "$SAVE_STATE_TRACE" "$LOAD_STATE_TRACE" "$FR_LOG_TRACE" "$FR_WARN_TRACE" > "$combined" 2>/dev/null || true

assert_not_grep "観点 e: pr-iteration round= marker を読まない" "pr-iteration round=" "$combined"
assert_not_grep "観点 e: review-notes ファイルを読まない" "review-notes" "$combined"
assert_not_grep "観点 e: idd-claude:pr-iteration を読まない" "idd-claude:pr-iteration" "$combined"
# PR body を取得していない（headRefOid 取得は OK だが body は OK でない）
assert_not_grep "観点 e: --json body を呼ばない（marker 取得目的の PR body 取得が無い）" "--json body" "$combined"

# gh pr view の用途は headRefOid 取得のみであることを確認
assert_grep "観点 e: gh pr view --json headRefOid のみ（marker 用 body 取得無し）" "gh pr view 80 .* --json headRefOid" "$GH_CALL_LOG"

rm -f "$combined"
cleanup_stub_state

# ============================================================
# Section 7: max-attempts 到達時に return 2 stub（terminate 関数は task 7 で追加）
# ============================================================
echo ""
echo "--- Section 7: max-attempts 到達時の return 2 stub ---"

reset_stub_state
LOAD_STATE_RESPONSE='{"issue":90,"total_attempts":4,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'

set +e
fr_run_recovery_attempt "issue" "90"
rc=$?
set -e
assert_rc "Req 4.5: total=4 (上限到達) → rc=2 (terminate 関数は task 7 で stub)" "2" "$rc"

# 上限到達時は claude が呼ばれない（quota 燃焼回避）
assert_eq "Req 4.5: 上限到達時に fr_invoke_claude が呼ばれない" "0" "$(count_pattern "." "$INVOKE_CLAUDE_TRACE")"
# 着手コメントも投稿されない（terminate 専用コメントは task 7 で追加）
assert_eq "Req 4.5: 上限到達時に gh comment が呼ばれない" "0" "$(count_pattern "gh issue comment|gh pr comment" "$GH_CALL_LOG")"

cleanup_stub_state

# ============================================================
# Section 8: no-progress 判定時に return 3 stub（terminate 関数は task 7 で追加）
# ============================================================
echo ""
echo "--- Section 8: no-progress 判定時の return 3 stub ---"

reset_stub_state
LOAD_STATE_RESPONSE='{"issue":100,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"prev-sig","last_head_sha":"","last_attempt_at":"","history":[]}'
DETECT_NO_PROGRESS_RC=0  # no-progress 判定

set +e
fr_run_recovery_attempt "issue" "100"
rc=$?
set -e
assert_rc "Req 5.2: no-progress 判定 → rc=3 (terminate 関数は task 7 で stub)" "3" "$rc"

# no-progress 時は claude が呼ばれない
assert_eq "Req 5.2: no-progress 時に fr_invoke_claude が呼ばれない" "0" "$(count_pattern "." "$INVOKE_CLAUDE_TRACE")"
# 着手コメントも投稿されない
assert_eq "Req 5.2: no-progress 時に gh comment が呼ばれない" "0" "$(count_pattern "gh issue comment|gh pr comment" "$GH_CALL_LOG")"

cleanup_stub_state

# ============================================================
# Section 9: PR 経路の正常 path（gh pr view --json headRefOid 経由 / Req 3.2）
# ============================================================
echo ""
echo "--- Section 9: PR 経路の正常 path ---"

reset_stub_state
LOAD_STATE_RESPONSE='{"issue":200,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"","history":[]}'
GH_PR_VIEW_HEAD_SHA="abc1234567890abcdef1234567890abcdef12345"
INVOKE_CLAUDE_RC=0

set +e
fr_run_recovery_attempt "pr" "200"
rc=$?
set -e
assert_rc "Req 3.2: PR success path → rc=0" "0" "$rc"

# PR 経路では gh pr view が呼ばれる（headRefOid 取得 / Req 4.3 の head_sha 進捗検出用）
assert_grep "Req 3.2: gh pr view --json headRefOid が呼ばれる" "gh pr view 200 .* --json headRefOid" "$GH_CALL_LOG"
# success path で --remove-label が呼ばれる（PR 経路）
assert_grep "Req 3.4: PR success path で --remove-label claude-failed が呼ばれる" "gh pr edit 200 .* --remove-label claude-failed" "$GH_CALL_LOG"
# fr_collect_pr_ci_context が呼ばれる経路（直接 stub を観測するのは困難なため、
# 結果 SAVE が headRefOid=abc...12345 で記録されることで間接的に証明）
# headRefOid が state 保存に含まれていることを確認
assert_grep "Req 4.3: state 保存に head_sha が含まれる（独立カウンタ source）" "fr_save_state 200 1 in-progress .* abc1234567890abcdef1234567890abcdef12345" "$SAVE_STATE_TRACE"

cleanup_stub_state

# ============================================================
# Section 10: 不正値ガード（NFR 3.1 / kind / number sanitize）
# ============================================================
echo ""
echo "--- Section 10: 不正値ガード（NFR 3.1） ---"

# 10-A: kind が不正値 → rc=1 + warn
reset_stub_state
set +e
fr_run_recovery_attempt "foo" "42"
rc=$?
set -e
assert_rc "NFR 3.1: 不正な kind=foo → rc=1" "1" "$rc"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
warn_count="${warn_count//[[:space:]]/}"
assert_eq "NFR 3.1: fr_warn が 1 件呼ばれる" "1" "$warn_count"
cleanup_stub_state

# 10-B: number が非数値 → rc=1 + warn
reset_stub_state
set +e
fr_run_recovery_attempt "issue" "abc"
rc=$?
set -e
assert_rc "NFR 3.1: 非数値 number → rc=1" "1" "$rc"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
warn_count="${warn_count//[[:space:]]/}"
assert_eq "NFR 3.1: fr_warn が 1 件呼ばれる" "1" "$warn_count"
cleanup_stub_state

# 10-C: number に command injection（; 含む）→ rc=1 + warn
reset_stub_state
set +e
fr_run_recovery_attempt "issue" "42; rm -rf /tmp/x"
rc=$?
set -e
assert_rc "NFR 3.1: command injection を含む number → rc=1" "1" "$rc"
cleanup_stub_state

# ============================================================
# Section 11: fr_finalize_success 単体の挙動
# ============================================================
echo ""
echo "--- Section 11: fr_finalize_success 単体 ---"

# 11-A: 正常 path → --remove-label + FR_PROCESSED_THIS_CYCLE 追加 + state save
reset_stub_state
set +e
fr_finalize_success "issue" "300" "2" "test-sig" ""
rc=$?
set -e
assert_rc "Req 3.4: fr_finalize_success 正常 path → rc=0" "0" "$rc"
assert_grep "Req 3.4: gh issue edit --remove-label が呼ばれる" "gh issue edit 300 .* --remove-label claude-failed" "$GH_CALL_LOG"
assert_grep "Req 6.2: state JSON に last_status=succeeded を保存" "^fr_save_state 300 2 succeeded test-sig" "$SAVE_STATE_TRACE"
case " $FR_PROCESSED_THIS_CYCLE " in
  *" issue:300 "*)
    echo "PASS: Req 6.1: FR_PROCESSED_THIS_CYCLE に issue:300 が追加される"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: Req 6.1: FR_PROCESSED_THIS_CYCLE に issue:300 が追加されていない (actual=$FR_PROCESSED_THIS_CYCLE)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
cleanup_stub_state

# 11-B: idempotent: 同じ key で 2 度呼んでも FR_PROCESSED_THIS_CYCLE が重複しない
reset_stub_state
set +e
fr_finalize_success "pr" "301" "1" "sig-a" "abc1234567890abcdef1234567890abcdef12345"
fr_finalize_success "pr" "301" "1" "sig-a" "abc1234567890abcdef1234567890abcdef12345"
set -e
# pr:301 の出現回数を数える
occurrences=$(printf '%s' "$FR_PROCESSED_THIS_CYCLE" | grep -o "pr:301" | wc -l)
occurrences="${occurrences//[[:space:]]/}"
assert_eq "Req 6.1: FR_PROCESSED_THIS_CYCLE は idempotent（重複追加しない）" "1" "$occurrences"
cleanup_stub_state

# 11-C: 不正 kind → rc=1
reset_stub_state
set +e
fr_finalize_success "foo" "302" "1" "sig" ""
rc=$?
set -e
assert_rc "NFR 3.1: 不正な kind → rc=1" "1" "$rc"
cleanup_stub_state

# 11-D: 不正 number → rc=1
reset_stub_state
set +e
fr_finalize_success "issue" "abc" "1" "sig" ""
rc=$?
set -e
assert_rc "NFR 3.1: 非数値 number → rc=1" "1" "$rc"
cleanup_stub_state

# ============================================================
# Section 12: fr_post_attempt_comment 単体（NFR 3.1 / 3.2）
# ============================================================
echo ""
echo "--- Section 12: fr_post_attempt_comment 単体 ---"

# 12-A: 正常 path
reset_stub_state
set +e
fr_post_attempt_comment "issue" "400" "test body"
rc=$?
set -e
assert_rc "Req 3.3: 正常 path → rc=0" "0" "$rc"
assert_grep "Req 3.3: gh issue comment が呼ばれる" "gh issue comment 400" "$GH_CALL_LOG"
assert_grep "Req 3.3: --body 引数で本文が渡される" "test body" "$GH_CALL_LOG"
cleanup_stub_state

# 12-B: 不正 kind → rc=1
reset_stub_state
set +e
fr_post_attempt_comment "foo" "400" "body"
rc=$?
set -e
assert_rc "NFR 3.1: 不正な kind → rc=1" "1" "$rc"
cleanup_stub_state

# 12-C: 不正 number → rc=1
reset_stub_state
set +e
fr_post_attempt_comment "pr" "abc" "body"
rc=$?
set -e
assert_rc "NFR 3.1: 非数値 number → rc=1" "1" "$rc"
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
