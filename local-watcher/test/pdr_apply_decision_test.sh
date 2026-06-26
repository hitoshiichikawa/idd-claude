#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の label / status publish / decision comment 投稿
#       関数群の挙動を、PATH 経由の stub gh で検証するスモークテスト。
#
#       対象関数:
#         - pdr_apply_label_decision    (needs-iteration add/remove 冪等)
#         - pdr_apply_status_decision   (claude-review publish / 既存 pr_publish_claude_status 流用)
#         - pdr_post_decision_comment   (hidden marker prefix idd-claude:pr-design-reviewer)
#
#       検証する受入基準（docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/requirements.md）:
#         - Req 3.1 approve → claude-review = success
#         - Req 3.2 reject → claude-review = failure
#         - Req 3.4 context 名は "claude-review" に統一
#         - Req 3.5 status のみ操作（awaiting-design-review ラベルに触らない）
#         - Req 4.1 reject → needs-iteration 付与
#         - Req 4.2 approve → needs-iteration 解消
#         - Req 5.1 PR コメントで観測可能（hidden marker 付き）
#         - Req 5.3 / NFR 1.2 marker prefix pr-design-reviewer が pi self-filter
#           idd-claude:pr-iteration と非衝突
#         - Req 6.4 既存ラベル名（needs-iteration）と既存 context 名（claude-review）を変更しない
#
#       検証ケース:
#         A. pdr_apply_label_decision
#           A.1 verdict=reject → --add-label needs-iteration
#           A.2 verdict=approve → --remove-label needs-iteration
#           A.3 PR 番号 / verdict 不正 → rc=2 + gh 呼ばれない
#         B. pdr_apply_status_decision
#           B.1 verdict=approve → pr_publish_claude_status approve → state=success / context=claude-review
#           B.2 verdict=reject → pr_publish_claude_status reject → state=failure / context=claude-review
#           B.3 入力検証
#         C. pdr_post_decision_comment
#           C.1 hidden marker `idd-claude:pr-design-reviewer sha=<sha> kind=decision` 付き投稿
#           C.2 marker prefix が pr-iteration / pr-reviewer の前方一致でないことを scan
#           C.3 入力検証
#
# 配置先: local-watcher/test/pdr_apply_decision_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pdr_apply_decision_test.sh

set -euo pipefail

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"
PR_MOD="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"

if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
  exit 2
fi
if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
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

# pr-design-reviewer.sh から 3 関数を抽出
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_apply_label_decision")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_apply_status_decision")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_post_decision_comment")"
# pr-reviewer.sh から status publish 関連を抽出（read-only 流用 / Req 7.2）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_status_check_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_commit_status")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_claude_status")"

for fn in pdr_apply_label_decision pdr_apply_status_decision pdr_post_decision_comment \
          pr_status_check_enabled pr_publish_commit_status pr_publish_claude_status; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"
# shellcheck disable=SC2034
LABEL_NEEDS_ITERATION="needs-iteration"

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
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  expected NOT to contain: $(printf '%q' "$needle")"
      echo "  actual                 : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
}

# ── stub state ──
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  GH_NEXT_RC="${GH_NEXT_RC:-0}"
  # shellcheck disable=SC2034
  PR_STATUS_GATE_SUPPRESS_LOGGED=0
  GH_API_BODY="[]"
  GH_API_RC=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$LOG_LOG" "$WARN_LOG" 2>/dev/null || true
}

# pdr_log / pdr_warn / pr_log / pr_warn stub
# shellcheck disable=SC2317
pdr_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pdr_warn() { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
pr_log()   { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pr_warn()  { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 最初の引数を捨てて残りを実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${1:-}" in
    api)
      local arg
      for arg in "$@"; do
        case "$arg" in
          *"/issues/"*"/comments"*) printf '%s' "$GH_API_BODY"; return "$GH_API_RC" ;;
        esac
      done
      return "${GH_NEXT_RC:-0}"
      ;;
    pr) return "${GH_NEXT_RC:-0}" ;;
    *)  return "${GH_NEXT_RC:-0}" ;;
  esac
}

count_calls() {
  local pattern="$1"
  local file="$2"
  local n
  n=$( { grep -E -- "$pattern" "$file" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
VALID_PR="407"
PR_URL="https://github.com/owner/test-repo/pull/407"

# ============================================================
# Section A: pdr_apply_label_decision
# ============================================================
echo "--- Section A: pdr_apply_label_decision ---"

# A.1 verdict=reject → --add-label needs-iteration
reset_stub_state
rc=0
pdr_apply_label_decision "$VALID_PR" "reject" || rc=$?
assert_eq "A.1 (verdict=reject): rc=0" "0" "$rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.1: --add-label needs-iteration が呼ばれる" "$gh_line" "pr edit $VALID_PR --repo owner/test-repo --add-label needs-iteration"
add_count=$(count_calls "add-label" "$GH_CALL_LOG")
assert_eq "Req 4.1: --add-label 呼び出し回数=1" "1" "$add_count"
remove_count=$(count_calls "remove-label" "$GH_CALL_LOG")
assert_eq "Req 4.1: --remove-label 呼び出しゼロ" "0" "$remove_count"
cleanup_stub_state

# A.2 verdict=approve → --remove-label needs-iteration
reset_stub_state
rc=0
pdr_apply_label_decision "$VALID_PR" "approve" || rc=$?
assert_eq "A.2 (verdict=approve): rc=0" "0" "$rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.2: --remove-label needs-iteration が呼ばれる" "$gh_line" "pr edit $VALID_PR --repo owner/test-repo --remove-label needs-iteration"
remove_count=$(count_calls "remove-label" "$GH_CALL_LOG")
assert_eq "Req 4.2: --remove-label 呼び出し回数=1" "1" "$remove_count"
add_count=$(count_calls "add-label" "$GH_CALL_LOG")
assert_eq "Req 4.2: --add-label 呼び出しゼロ" "0" "$add_count"
cleanup_stub_state

# A.3 入力検証
reset_stub_state
rc=0
pdr_apply_label_decision "invalid" "reject" || rc=$?
assert_eq "A.3 (PR 番号不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "A.3 (PR 番号不正): gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

reset_stub_state
rc=0
pdr_apply_label_decision "$VALID_PR" "foo" || rc=$?
assert_eq "A.3' (verdict 不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "A.3' (verdict 不正): gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# Req 6.4: 既存ラベル名 `needs-iteration` を変更しない（assert_contains 経由で確認済み）
# Req 3.5 OR 条件併存: awaiting-design-review ラベルに触れないことを確認
reset_stub_state
pdr_apply_label_decision "$VALID_PR" "approve" || true
gh_line=$(cat "$GH_CALL_LOG")
assert_not_contains "Req 3.5: awaiting-design-review ラベルに触れない" "$gh_line" "awaiting-design-review"
cleanup_stub_state

# ============================================================
# Section B: pdr_apply_status_decision
# ============================================================
echo ""
echo "--- Section B: pdr_apply_status_decision ---"

# AND 二重 opt-in を有効化（pr_publish_commit_status 内 gate 通過）
# shellcheck disable=SC2034
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
# shellcheck disable=SC2034
FULL_AUTO_ENABLED="true"

# B.1 verdict=approve → state=success / context=claude-review
reset_stub_state
rc=0
pdr_apply_status_decision "$VALID_PR" "$VALID_SHA" "approve" "$PR_URL" || rc=$?
assert_eq "B.1 (approve): rc=0" "0" "$rc"
gh_line=$(cat "$GH_CALL_LOG")
post_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$VALID_SHA" "$GH_CALL_LOG")
assert_eq "Req 3.1: POST statuses 呼び出し回数=1" "1" "$post_count"
assert_contains "Req 3.1: state=success" "$gh_line" "state=success"
assert_contains "Req 3.4: context=claude-review" "$gh_line" "context=claude-review"
cleanup_stub_state

# B.2 verdict=reject → state=failure / context=claude-review
reset_stub_state
rc=0
pdr_apply_status_decision "$VALID_PR" "$VALID_SHA" "reject" "$PR_URL" || rc=$?
assert_eq "B.2 (reject): rc=0" "0" "$rc"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 3.2: state=failure" "$gh_line" "state=failure"
assert_contains "Req 3.4: context=claude-review" "$gh_line" "context=claude-review"
cleanup_stub_state

# B.3 入力検証
reset_stub_state
rc=0
pdr_apply_status_decision "invalid" "$VALID_SHA" "approve" "$PR_URL" || rc=$?
assert_eq "B.3.a (PR 番号不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "B.3.a (PR 番号不正): gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

reset_stub_state
rc=0
pdr_apply_status_decision "$VALID_PR" "not-a-sha" "approve" "$PR_URL" || rc=$?
assert_eq "B.3.b (sha 不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "B.3.b (sha 不正): gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

reset_stub_state
rc=0
pdr_apply_status_decision "$VALID_PR" "$VALID_SHA" "foo" "$PR_URL" || rc=$?
assert_eq "B.3.c (verdict 不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "B.3.c (verdict 不正): gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# ============================================================
# Section C: pdr_post_decision_comment（hidden marker + self-filter 非衝突）
# ============================================================
echo ""
echo "--- Section C: pdr_post_decision_comment ---"

# C.1: hidden marker 付きで投稿
# 専用 stub: gh pr comment --body の値を log に残す
reset_stub_state
# shellcheck disable=SC2317
gh() {
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
    local body=""
    local seen_body=0
    for arg in "$@"; do
      if [ "$seen_body" = "1" ]; then
        body="$arg"
        seen_body=0
        echo "GHCOMMENT_BODY: $body" >>"$GH_CALL_LOG"
        continue
      fi
      if [ "$arg" = "--body" ]; then
        seen_body=1
      fi
    done
    return 0
  fi
  case "${1:-}" in
    api) printf '%s' "$GH_API_BODY"; return "$GH_API_RC" ;;
    *) return 0 ;;
  esac
}
rc=0
pdr_post_decision_comment "$VALID_PR" "$VALID_SHA" "reject" "AC 2.4 未カバー" "Components 反映 OK" "ID 実在 OK" || rc=$?
assert_eq "C.1: rc=0" "0" "$rc"
body_log=$(cat "$GH_CALL_LOG")

# Req 5.1: 観測可能（PR コメント本文）
assert_contains "Req 5.1: 判定本文に VERDICT が記録" "$body_log" "VERDICT"
assert_contains "Req 5.1: 判定本文に 3 観点 reason が記録" "$body_log" "AC 2.4 未カバー"

# Req 5.3 / NFR 1.2: hidden marker prefix
assert_contains "Req 5.3: hidden marker prefix idd-claude:pr-design-reviewer" "$body_log" "idd-claude:pr-design-reviewer sha=$VALID_SHA kind=decision"

# Req 5.3 / NFR 1.2: pi self-filter prefix idd-claude:pr-iteration と非衝突
assert_not_contains "Req 5.3: marker に pr-iteration prefix が混入していない" "$body_log" "idd-claude:pr-iteration"
# pr-reviewer prefix も含まれない（substring 上 pr-design-reviewer は pr-reviewer を含まないが念のため）
assert_not_contains "Req 5.3: marker に pr-reviewer prefix（adj 非衝突 / catch-up と非衝突）が混入していない" "$body_log" "idd-claude:pr-reviewer "
cleanup_stub_state

# C.2: 入力検証
# stub gh を元に戻す
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${1:-}" in
    api) printf '%s' "$GH_API_BODY"; return "$GH_API_RC" ;;
    pr) return "${GH_NEXT_RC:-0}" ;;
    *)  return "${GH_NEXT_RC:-0}" ;;
  esac
}

reset_stub_state
rc=0
pdr_post_decision_comment "invalid" "$VALID_SHA" "approve" "a" "b" "c" || rc=$?
assert_eq "C.2.a (PR 番号不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "C.2.a: gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

reset_stub_state
rc=0
pdr_post_decision_comment "$VALID_PR" "not-a-sha" "approve" "a" "b" "c" || rc=$?
assert_eq "C.2.b (sha 不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "C.2.b: gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

reset_stub_state
rc=0
pdr_post_decision_comment "$VALID_PR" "$VALID_SHA" "foo" "a" "b" "c" || rc=$?
assert_eq "C.2.c (verdict 不正): rc=2" "2" "$rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "C.2.c: gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
