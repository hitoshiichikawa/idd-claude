#!/usr/bin/env bash
#
# 用途: 設計ルート fail-closed 検証 `_slot_verify_design_pr_created` (#446) のスモークテスト。
#       design モード rc=0 直後に「設計 PR が実際に作成されたか / awaiting-design-review へ
#       ラベル遷移したか」を検証し、いずれも未確認なら fail-closed（rc=1）へ倒す挙動を検証する。
#       gh は PATH stub で置換し、副作用（読み取り呼び出し）をシナリオ別に模擬する。
#
#       検証観点（Issue #446）:
#         - gate OFF（DESIGN_PR_VERIFY_ENABLED=false）で検証 skip（rc=2 / 導入前と同一挙動）
#         - open 設計 PR が存在すれば成功（rc=0）
#         - PR 無し + awaiting-design-review ラベル遷移済みなら成功（rc=0）
#         - PR 無し + ラベル未遷移なら fail-closed（rc=1 / ゾンビ検出）
#         - 入力破損 / gh 取得失敗は false-fail を避け安全側で成功扱い（rc=0）
#
# 配置先: local-watcher/test/slot_verify_design_pr_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/slot_verify_design_pr_test.sh

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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_slot_verify_design_pr_created")"
if ! declare -F _slot_verify_design_pr_created >/dev/null; then
  echo "ERROR: _slot_verify_design_pr_created not loaded" >&2
  exit 2
fi

# 参照グローバル
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_AWAITING_DESIGN="awaiting-design-review"

PASS_COUNT=0
FAIL_COUNT=0
assert_rc() {
  local label="$1" expected="$2"; shift 2
  local rc=0
  "$@" || rc=$?
  if [ "$rc" = "$expected" ]; then
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (expected rc=$expected, got rc=$rc)"; FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# gh stub: シナリオ変数で pr list 件数 / issue ラベル / エラーを切替
# GH_PR_COUNT       : `gh pr list ... --jq 'length'` が返す値
# GH_ISSUE_LABELS   : `gh issue view ... --jq '.labels[].name'` が返す改行区切りラベル
# GH_PR_FAIL=1      : gh pr list を非0 exit させる
# GH_ISSUE_FAIL=1   : gh issue view を非0 exit させる
# shellcheck disable=SC2317
gh() {
  case "$1" in
    pr)   # gh pr list ...
      [ "${GH_PR_FAIL:-0}" = "1" ] && return 1
      printf '%s' "${GH_PR_COUNT:-0}"; return 0 ;;
    issue) # gh issue view ...
      [ "${GH_ISSUE_FAIL:-0}" = "1" ] && return 1
      printf '%s\n' "${GH_ISSUE_LABELS:-}"; return 0 ;;
  esac
  return 0
}

# ── 1. gate OFF → rc=2 (検証 skip) ──
DESIGN_PR_VERIFY_ENABLED="false"
assert_rc "1. gate OFF で検証 skip（rc=2 / 導入前と同一）" 2 _slot_verify_design_pr_created "claude/issue-39-design-x" "39"

# shellcheck disable=SC2034  # 抽出関数 _slot_verify_design_pr_created 経由（遅延束縛）で参照
DESIGN_PR_VERIFY_ENABLED="true"

# ── 2. open 設計 PR が存在 → rc=0 ──
GH_PR_COUNT=1; GH_ISSUE_LABELS="claude-claimed"
assert_rc "2. open 設計 PR ありで成功（rc=0）" 0 _slot_verify_design_pr_created "claude/issue-39-design-x" "39"

# ── 3. PR 無し + awaiting-design-review 遷移済み → rc=0 ──
GH_PR_COUNT=0; GH_ISSUE_LABELS=$'auto-dev\nawaiting-design-review'
assert_rc "3. PR 無し + ラベル遷移済みで成功（rc=0）" 0 _slot_verify_design_pr_created "claude/issue-39-design-x" "39"

# ── 4. PR 無し + ラベル未遷移（claude-claimed のまま） → rc=1 (fail-closed / ゾンビ検出) ──
GH_PR_COUNT=0; GH_ISSUE_LABELS=$'auto-dev\nclaude-claimed'
assert_rc "4. PR 無し + ラベル未遷移で fail-closed（rc=1 / #446 ゾンビ検出）" 1 _slot_verify_design_pr_created "claude/issue-39-design-x" "39"

# ── 5. 入力破損（非数値 number） → 安全側 rc=0 ──
GH_PR_COUNT=0; GH_ISSUE_LABELS="claude-claimed"
assert_rc "5. 非数値 number は安全側で成功扱い（rc=0 / false-fail 回避）" 0 _slot_verify_design_pr_created "claude/issue-39-design-x" "not-a-number"

# ── 6. gh issue view 取得失敗 → 安全側 rc=0（PR 無し・ラベル取得不能でも fail-closed しない） ──
GH_PR_COUNT=0; GH_ISSUE_FAIL=1
assert_rc "6. gh issue view 失敗は安全側で成功扱い（rc=0 / false-fail 回避）" 0 _slot_verify_design_pr_created "claude/issue-39-design-x" "39"
GH_ISSUE_FAIL=0

# ── 7. gh pr list 失敗（件数取得不能）でもラベル遷移済みなら rc=0 ──
GH_PR_FAIL=1; GH_ISSUE_LABELS="awaiting-design-review"
assert_rc "7. gh pr list 失敗 + ラベル遷移済みで成功（rc=0）" 0 _slot_verify_design_pr_created "claude/issue-39-design-x" "39"
GH_PR_FAIL=0

echo ""
echo "==================================="
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
echo "==================================="
[ "$FAIL_COUNT" -eq 0 ]
