#!/usr/bin/env bash
#
# 用途: PR Reviewer Adjudicator (#404) task 6 で追加した catch-up suppression helper
#       `pr_catchup_should_defer_for_adjudicator` の挙動を検証するスモークテスト。
#
#       Architecture Decision: claude-review publisher contention の Behavior contract:
#         - adjudicator 管轄 PR（gate ON + marker `<!-- idd-claude:pr-adjudicator sha=<sha> -->`
#           存在）に対しては catch-up を skip し、adjudicator が単独 publisher として
#           claude-review を確定する。
#         - gate OFF / marker 不在 / sha 不一致は catch-up 続行（既存挙動を維持）。
#
#       検証する受入基準（docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md）:
#         - Req 3.2 adjudicator が claude-review を publish（catch-up と競合しない）
#         - Req 4.3 marker key `idd-claude:pr-adjudicator` の self-filter 非衝突
#         - NFR 1.1 gate OFF 時に既存 catch-up 挙動を維持
#
#       検証ケース:
#         S.1 gate ON + marker 存在 sha 一致         → rc=0（defer）
#         S.2 gate OFF                                 → rc=1（catch-up 続行）
#         S.3 gate ON + marker 不在（コメントなし）   → rc=1（passthrough 経路）
#         S.4 gate ON + marker 存在 sha 不一致         → rc=1（別 sha は対象外）
#         S.5 gate ON + gh 取得失敗                    → rc=1（安全側 / catch-up 続行）
#         S.6 入力検証: pr_number 不正 / sha 不正      → rc=1（早期 reject）
#         S.7 gate ON + 他 marker prefix（pr-iteration）→ rc=1（非衝突確認 / Req 4.3）
#
# 配置先: local-watcher/test/pr_catchup_suppression_test.sh
# 依存:   bash 4+, awk, jq, grep, mktemp
# 実行:   bash local-watcher/test/pr_catchup_suppression_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/modules/adjudicator.sh"
PR_MOD="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi
if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して eval。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# pr_catchup_should_defer_for_adjudicator は adj_gate_enabled を呼ぶため、両関数を抽出
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_gate_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_catchup_should_defer_for_adjudicator")"

for fn in adj_gate_enabled pr_catchup_should_defer_for_adjudicator; do
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

# ── stub state ──
# gh stub をシナリオで切り替えるために、stub gh は GH_STUB_MODE / GH_STUB_BODY を読む。
# GH_STUB_MODE:
#   "marker_match"     → body に `idd-claude:pr-adjudicator sha=<MATCH_SHA>` を含む comment を 1 件返す
#   "marker_absent"    → 空 body を返す（コメント 0 件）
#   "marker_mismatch"  → 別 sha の adjudicator marker を含む comment を返す
#   "marker_iteration" → 他 prefix（pr-iteration）の marker のみ返す（非衝突確認）
#   "api_failure"      → 非 0 で exit
GH_CALL_LOG="$(mktemp)"
trap 'rm -f "$GH_CALL_LOG" 2>/dev/null || true' EXIT

# timeout stub: 第 1 引数（秒数）を捨てて残りを実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: 呼び出し痕跡を記録し、GH_STUB_MODE で挙動を切り替える
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${GH_STUB_MODE:-marker_absent}" in
    marker_match)
      # gh pr view ... --json comments --jq '.comments[].body' は改行区切りの body 列を返す
      printf 'irrelevant header\n<!-- idd-claude:pr-adjudicator sha=%s kind=decision -->\n' "${MATCH_SHA:-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"
      return 0
      ;;
    marker_absent)
      # 空 stdout（コメント 0 件）
      return 0
      ;;
    marker_mismatch)
      # adjudicator marker は存在するが sha が不一致
      printf 'header\n<!-- idd-claude:pr-adjudicator sha=%s kind=decision -->\n' "1111111111111111111111111111111111111111"
      return 0
      ;;
    marker_iteration)
      # 他 prefix（pi self-filter prefix）のみ → adjudicator marker は不在
      printf '<!-- idd-claude:pr-iteration kind=fix-attempt -->\n'
      return 0
      ;;
    api_failure)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

# pr_log stub（pr-reviewer.sh の関数を eval していないので、抽出関数経由で呼ばれる
# ことはない。ただし他の eval 関数が pr_warn / pr_log を呼ぶ可能性に備えて潰しておく）。
# shellcheck disable=SC2317
pr_log()  { :; }
# shellcheck disable=SC2317
pr_warn() { :; }
# shellcheck disable=SC2317
adj_log()  { :; }
# shellcheck disable=SC2317
adj_warn() { :; }

# グローバル env
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"

# 共通 fixture
VALID_PR="404"
VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
OTHER_SHA="0123456789abcdef0123456789abcdef01234567"

# ============================================================
# Section S: pr_catchup_should_defer_for_adjudicator 4 ケース + 補助
# ============================================================
echo "--- Section S: pr_catchup_should_defer_for_adjudicator ---"

# S.1: gate ON + marker 存在 sha 一致 → rc=0（defer）
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
export GH_STUB_MODE="marker_match"
export MATCH_SHA="$VALID_SHA"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "S.1 (gate ON + marker 存在 sha 一致): rc=0 (defer)" "0" "$local_rc"
# gh API が 1 回呼ばれていること
gh_count=$( { grep -c '^gh ' "$GH_CALL_LOG" 2>/dev/null || true; } | tail -n 1)
gh_count=${gh_count//[!0-9]/}
assert_eq "S.1 (gate ON + marker 存在 sha 一致): gh 呼び出し回数=1" "1" "${gh_count:-0}"

# S.2: gate OFF（unset）→ rc=1（catch-up 続行）+ gh 呼び出しゼロ
: > "$GH_CALL_LOG"
unset PR_REVIEWER_ADJUDICATOR_ENABLED || true
export GH_STUB_MODE="marker_match"  # たとえ marker があっても gate OFF なら早期 reject
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "S.2 (gate OFF unset): rc=1 (catch-up 続行)" "1" "$local_rc"
gh_count=$( { grep -c '^gh ' "$GH_CALL_LOG" 2>/dev/null || true; } | tail -n 1)
gh_count=${gh_count//[!0-9]/}
assert_eq "S.2 (gate OFF unset): gh 呼び出しゼロ (NFR 1.1)" "0" "${gh_count:-0}"

# S.2b: gate OFF（=false 明示）→ rc=1
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "S.2b (gate OFF =false): rc=1 (catch-up 続行)" "1" "$local_rc"
gh_count=$( { grep -c '^gh ' "$GH_CALL_LOG" 2>/dev/null || true; } | tail -n 1)
gh_count=${gh_count//[!0-9]/}
assert_eq "S.2b (gate OFF =false): gh 呼び出しゼロ" "0" "${gh_count:-0}"

# S.3: gate ON + marker 不在 → rc=1（passthrough 経路で catch-up 引き継ぎ）
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
export GH_STUB_MODE="marker_absent"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "S.3 (gate ON + marker 不在): rc=1 (catch-up 引き継ぎ)" "1" "$local_rc"

# S.4: gate ON + marker 存在 sha 不一致 → rc=1（別 sha は対象外）
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
export GH_STUB_MODE="marker_mismatch"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "S.4 (gate ON + marker 存在 sha 不一致): rc=1" "1" "$local_rc"

# S.5: gate ON + gh API 失敗 → rc=1（安全側で catch-up 続行）
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
export GH_STUB_MODE="api_failure"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "S.5 (gate ON + gh API 失敗): rc=1 (安全側)" "1" "$local_rc"

# S.6: 入力検証
# 6a: PR 番号不正 → rc=1（早期 reject、gh 呼び出しゼロ）
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
export GH_STUB_MODE="marker_match"
local_rc=0
pr_catchup_should_defer_for_adjudicator "not-a-number" "$VALID_SHA" || local_rc=$?
assert_eq "S.6a (PR 番号不正): rc=1" "1" "$local_rc"
gh_count=$( { grep -c '^gh ' "$GH_CALL_LOG" 2>/dev/null || true; } | tail -n 1)
gh_count=${gh_count//[!0-9]/}
assert_eq "S.6a (PR 番号不正): gh 呼び出しゼロ" "0" "${gh_count:-0}"

# 6b: sha 不正（短すぎる）→ rc=1
: > "$GH_CALL_LOG"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "abc" || local_rc=$?
assert_eq "S.6b (sha 短すぎ): rc=1" "1" "$local_rc"
gh_count=$( { grep -c '^gh ' "$GH_CALL_LOG" 2>/dev/null || true; } | tail -n 1)
gh_count=${gh_count//[!0-9]/}
assert_eq "S.6b (sha 短すぎ): gh 呼び出しゼロ" "0" "${gh_count:-0}"

# 6c: sha 不正（hex でない）→ rc=1
: > "$GH_CALL_LOG"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "ZZZZZZZZ" || local_rc=$?
assert_eq "S.6c (sha hex でない): rc=1" "1" "$local_rc"

# 6d: 空 PR 番号 → rc=1
: > "$GH_CALL_LOG"
local_rc=0
pr_catchup_should_defer_for_adjudicator "" "$VALID_SHA" || local_rc=$?
assert_eq "S.6d (PR 番号空): rc=1" "1" "$local_rc"

# S.7: gate ON + pr-iteration marker のみ（pr-adjudicator 不在）→ rc=1（非衝突確認 / Req 4.3）
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
export GH_STUB_MODE="marker_iteration"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "S.7 (gate ON + pr-iteration marker のみ): rc=1 (非衝突 / Req 4.3)" "1" "$local_rc"

# S.8: OTHER_SHA を渡しても marker_match シナリオで MATCH_SHA != OTHER_SHA なら rc=1
: > "$GH_CALL_LOG"
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
export GH_STUB_MODE="marker_match"
export MATCH_SHA="$VALID_SHA"
local_rc=0
pr_catchup_should_defer_for_adjudicator "$VALID_PR" "$OTHER_SHA" || local_rc=$?
assert_eq "S.8 (gate ON + marker MATCH_SHA != 引数 sha): rc=1" "1" "$local_rc"

# クリーンアップ
unset PR_REVIEWER_ADJUDICATOR_ENABLED GH_STUB_MODE MATCH_SHA || true

# ============================================================
echo ""
echo "================================================================"
echo "Test summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "================================================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
