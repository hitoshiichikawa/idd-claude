#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の head pattern マッチング関数 pdr_classify_design_pr の
#       挙動を検証するスモークテスト。
#
#       検証する受入基準（docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/requirements.md）:
#         - Req 1.3 impl PR / 非対応 head は除外
#         - Req 7.4 impl + design 同時 open 時、impl 経路に介入しない
#
#       検証ケース:
#         1. `claude/issue-1-design-foo` → design (rc=0)
#         2. `claude/issue-407-design-feat-bar` → design (rc=0)
#         3. `claude/issue-1-impl-foo` → 非 design (rc=1)
#         4. `claude/issue-999-impl-test` → 非 design (rc=1)
#         5. `claude/something-else` → 非 design (rc=1)
#         6. `feature/non-claude-branch` → 非 design (rc=1)
#         7. 空入力 → 非 design (rc=1)
#         8. `claude/issue-design-no-number-foo`（pattern 形式不正）→ 非 design (rc=1)
#
# 配置先: local-watcher/test/pdr_classify_design_pr_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pdr_classify_design_pr_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"

if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_classify_design_pr")"

if ! declare -F pdr_classify_design_pr >/dev/null; then
  echo "ERROR: pdr_classify_design_pr not loaded" >&2
  exit 2
fi

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

# DESIGN_REVIEWER_HEAD_PATTERN を既定値 (issue-watcher.sh Config と同一) で設定。
# pdr_classify_design_pr は extract_function で抽出された関数本体内で参照される。
# shellcheck disable=SC2034
export DESIGN_REVIEWER_HEAD_PATTERN="^claude/issue-[0-9]+-design-"

echo "--- pdr_classify_design_pr (Issue #407 Req 1.3, 7.4) ---"

# 設計 PR pattern（design / rc=0）
rc=0
pdr_classify_design_pr "claude/issue-1-design-foo" || rc=$?
assert_eq "Req 1.3: claude/issue-1-design-foo → design (rc=0)" "0" "$rc"

rc=0
pdr_classify_design_pr "claude/issue-407-design-feat-bar" || rc=$?
assert_eq "Req 1.3: claude/issue-407-design-feat-bar → design (rc=0)" "0" "$rc"

# impl PR pattern（非 design / rc=1 / Req 7.4 impl 経路非介入）
rc=0
pdr_classify_design_pr "claude/issue-1-impl-foo" || rc=$?
assert_eq "Req 7.4: claude/issue-1-impl-foo → 非 design (rc=1)" "1" "$rc"

rc=0
pdr_classify_design_pr "claude/issue-999-impl-test" || rc=$?
assert_eq "Req 7.4: claude/issue-999-impl-test → 非 design (rc=1)" "1" "$rc"

# その他の非対応 head
rc=0
pdr_classify_design_pr "claude/something-else" || rc=$?
assert_eq "Req 1.3: claude/something-else → 非 design (rc=1)" "1" "$rc"

rc=0
pdr_classify_design_pr "feature/non-claude-branch" || rc=$?
assert_eq "Req 1.3: feature/non-claude-branch → 非 design (rc=1)" "1" "$rc"

# 空入力
rc=0
pdr_classify_design_pr "" || rc=$?
assert_eq "Req 1.3: 空入力 → 非 design (rc=1)" "1" "$rc"

# 不正形式（Issue 番号なし）
rc=0
pdr_classify_design_pr "claude/issue-design-no-number-foo" || rc=$?
assert_eq "Req 1.3: claude/issue-design-no-number-foo (Issue 番号欠落) → 非 design (rc=1)" "1" "$rc"

# pattern override（custom ERE）でも厳密に動作することを確認
# shellcheck disable=SC2034
export DESIGN_REVIEWER_HEAD_PATTERN="^design/.*"
rc=0
pdr_classify_design_pr "design/foo" || rc=$?
assert_eq "Custom pattern: design/foo → design (rc=0)" "0" "$rc"

rc=0
pdr_classify_design_pr "claude/issue-1-design-foo" || rc=$?
assert_eq "Custom pattern '^design/.*': claude/issue-1-design-foo → 非 design (rc=1)" "1" "$rc"

# 元の pattern に戻す（後続テストへの影響回避）
# shellcheck disable=SC2034
export DESIGN_REVIEWER_HEAD_PATTERN="^claude/issue-[0-9]+-design-"

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
