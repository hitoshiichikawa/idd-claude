#!/usr/bin/env bash
#
# 用途: Issue #434 Defect B（terminal ラベル付き PR への claude-review=success の fail-closed 化）で
#       local-watcher/bin/modules/pr-reviewer.sh の pr_publish_claude_status に追加した
#       success 公開直前ガードを fixture と gh stub で検証するスモークテスト。
#
#       対象関数:
#         - pr_publish_claude_status  (Req 3.1, 3.2, 3.5 / Req 4.1, 4.2, 4.3)
#
#       検証する AC（docs/specs/434-fix-auto-merge-claude-failed-arm-native/requirements.md）:
#         - Req 3.1: claude-failed 付き PR への success → publish しない（fail-closed）
#         - Req 3.2: needs-decisions 付き PR への success → publish しない
#         - Req 3.5: terminal ラベル無し → 従来どおり approve/reject に応じた publish
#         - Req 4.1: success publish 直前に現在のラベル集合を再取得して判定
#         - Req 4.2: ラベル再取得失敗時は従来どおり publish 継続（fail-open）
#         - Req 4.3: ラベル再取得失敗時に WARN ログを 1 行残す
#       （Req 3.3 adjudicator 経路 / Req 3.4 catch-up 経路 は本関数 1 箇所への集約で
#         自動的に fail-closed 化されるため、本関数の検証で間接的にカバーされる）
#
# 配置先: local-watcher/test/pr_reviewer_claude_status_fail_closed_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/pr_reviewer_claude_status_fail_closed_test.sh

set -euo pipefail

# 抽出関数および stub から indirect 参照される変数を多用するため、shellcheck からは
# 未使用に見える。本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MOD="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"

if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH" >&2
  exit 2
fi

# extract_function イディオム
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数を pr-reviewer.sh から読み込む
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_claude_status")"

if ! declare -F pr_publish_claude_status >/dev/null; then
  echo "ERROR: pr_publish_claude_status not loaded" >&2
  exit 2
fi

# グローバル env（遅延束縛で参照される / SC2034 false-positive）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
LABEL_NEEDS_DECISIONS="needs-decisions"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT=60

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

count_logs() {
  local file="$1"
  local pattern="$2"
  local n
  n=$( { grep -E -- "$pattern" "$file" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# ── stub state ──
reset_stub_state() {
  WARN_OUT="$(mktemp)"
  PUBLISH_CALL_LOG="$(mktemp)"
  GH_PR_VIEW_LABELS='{"labels":[]}'    # 既定: terminal ラベル無し
  GH_PR_VIEW_RC=0                       # ラベル再取得 rc（!=0 で取得失敗注入）
}

cleanup_stub_state() {
  rm -f "$WARN_OUT" "$PUBLISH_CALL_LOG" 2>/dev/null || true
}

# pr_warn を上書きして WARN を観測
# shellcheck disable=SC2317
pr_warn() { echo "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
pr_log()  { :; }

# timeout を no-op に（第 1 引数の秒数を捨てて後続を実行）
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: gh pr view --json labels の応答を制御
# shellcheck disable=SC2317
gh() {
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    if [ "$GH_PR_VIEW_RC" -ne 0 ]; then
      return "$GH_PR_VIEW_RC"
    fi
    printf '%s' "$GH_PR_VIEW_LABELS"
    return 0
  fi
  return 0
}

# pr_publish_commit_status stub: 呼び出しと引数を記録（実 publish が走ったかの観測）
# shellcheck disable=SC2317
pr_publish_commit_status() {
  # $1=pr_number $2=sha $3=context $4=state $5=description $6=target_url
  echo "publish pr=$1 context=$3 state=$4" >>"$PUBLISH_CALL_LOG"
  return 0
}

count_publish() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$PUBLISH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

VALID_SHA="0123456789abcdef0123456789abcdef01234567"

# ============================================================
# Section 1: terminal ラベル付き PR への success → fail-closed（Req 3.1, 3.2, 4.1）
# ============================================================
echo "--- Section 1: terminal ラベル付き success の fail-closed ---"

# Req 3.1: claude-failed 付き → success を publish しない
reset_stub_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"claude-failed"}]}'
pr_publish_claude_status 100 "$VALID_SHA" approve "https://example.com/notes"
publish_count=$(count_publish "context=claude-review")
assert_eq "Req 3.1: claude-failed 付き → success publish ゼロ（fail-closed）" "0" "$publish_count"
skip_warn=$(count_logs "$WARN_OUT" "terminal label.*skip claude-review=success")
assert_eq "Req 3.1: skip 時に WARN 1 行を残す" "1" "$skip_warn"
cleanup_stub_state

# Req 3.2: needs-decisions 付き → success を publish しない
reset_stub_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"needs-decisions"}]}'
pr_publish_claude_status 101 "$VALID_SHA" approve ""
publish_count=$(count_publish "context=claude-review")
assert_eq "Req 3.2: needs-decisions 付き → success publish ゼロ" "0" "$publish_count"
cleanup_stub_state

# Req 3.1: 両 terminal ラベル付き → success を publish しない
reset_stub_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"claude-failed"},{"name":"needs-decisions"}]}'
pr_publish_claude_status 102 "$VALID_SHA" approve ""
publish_count=$(count_publish "context=claude-review")
assert_eq "Req 3.1/3.2: 両 terminal ラベル → success publish ゼロ" "0" "$publish_count"
cleanup_stub_state

# ============================================================
# Section 2: terminal ラベル無しの通常経路（Req 3.5）
# ============================================================
echo ""
echo "--- Section 2: terminal ラベル無しの通常 publish ---"

# Req 3.5: terminal ラベル無し → approve を success で publish
reset_stub_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"ready-for-review"}]}'
pr_publish_claude_status 103 "$VALID_SHA" approve ""
publish_count=$(count_publish "context=claude-review state=success")
assert_eq "Req 3.5: terminal ラベル無し → success を publish" "1" "$publish_count"
cleanup_stub_state

# Req 3.5: reject は terminal ラベルの有無に依らず failure で publish（ガードは success のみ）
reset_stub_state
GH_PR_VIEW_LABELS='{"labels":[{"name":"claude-failed"}]}'
pr_publish_claude_status 104 "$VALID_SHA" reject ""
publish_count=$(count_publish "context=claude-review state=failure")
assert_eq "Req 3.5: reject は terminal でも failure を publish（ガードは success 経路のみ）" "1" "$publish_count"
# reject 経路では gh pr view ラベル再取得を行わない → skip WARN は出ない
skip_warn=$(count_logs "$WARN_OUT" "terminal label.*skip")
assert_eq "Req 3.5: reject 経路では fail-closed skip WARN を出さない" "0" "$skip_warn"
cleanup_stub_state

# ============================================================
# Section 3: ラベル再取得失敗時の fail-open（Req 4.2, 4.3）
# ============================================================
echo ""
echo "--- Section 3: ラベル再取得失敗時の fail-open ---"

# Req 4.2: gh pr view 失敗 → 従来どおり publish 継続（fail-open）
reset_stub_state
GH_PR_VIEW_RC=1
pr_publish_claude_status 105 "$VALID_SHA" approve ""
publish_count=$(count_publish "context=claude-review state=success")
assert_eq "Req 4.2: ラベル再取得失敗 → success を従来どおり publish（fail-open）" "1" "$publish_count"
# Req 4.3: 取得失敗時に WARN 1 行を残す
failopen_warn=$(count_logs "$WARN_OUT" "terminal ラベル再取得に失敗")
assert_eq "Req 4.3: ラベル再取得失敗時に WARN 1 行を残す" "1" "$failopen_warn"
cleanup_stub_state

# 不正な result はガードに到達せず従来どおり rc=4
reset_stub_state
rc=0
pr_publish_claude_status 106 "$VALID_SHA" "bogus" "" >/dev/null 2>&1 || rc=$?
assert_eq "不正 result は rc=4（既存挙動を維持）" "4" "$rc"
publish_count=$(count_publish "context=claude-review")
assert_eq "不正 result は publish しない" "0" "$publish_count"
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
