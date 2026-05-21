#!/usr/bin/env bash
# 用途: tasks.md budget overflow check の count 抽出 regex と判定境界 (10/11/13/14) の整合性検証
# 配置先: docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh
# 依存: bash 4+, grep (POSIX ERE)
# セットアップ参照先: docs/specs/131-feat-architect-tasks-md-budget-overflow/impl-notes.md
#
# Usage:
#   bash docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh
#
# Exit code:
#   0 = すべての fixture が期待件数 / 期待判定と一致
#   1 = いずれかの fixture が不一致（standard error にどれが失敗したか出力）

set -euo pipefail

# Count 抽出 regex（design-review-gate.md / architect.md と同一定義）
#   ^- \[ \]\*? [0-9]+\. <space>
# 子タスク（1.1 等）/ deferrable テスト（- [ ]*）の整数 ID は数えるが、小数階層 ID はマッチしない
readonly COUNT_REGEX='^- \[ \]\*? [0-9]+\. '

# 閾値表（design-review-gate.md と同期）
#   ≤10  : pass
#   11-13: consolidate (失敗時に split)
#   ≥14  : forced_split
classify() {
  local count="$1"
  if [ "$count" -le 10 ]; then
    echo "pass"
  elif [ "$count" -le 13 ]; then
    echo "consolidate"
  else
    echo "forced_split"
  fi
}

count_top_level_tasks() {
  local file="$1"
  grep -cE "$COUNT_REGEX" "$file" || true
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FIXTURE_DIR="$SCRIPT_DIR/test-fixtures"

# 期待値: (fixture_basename, expected_count, expected_classification)
declare -a CASES=(
  "tasks-10.md 10 pass"
  "tasks-11.md 11 consolidate"
  "tasks-13.md 13 consolidate"
  "tasks-14.md 14 forced_split"
)

fail_count=0
for case_str in "${CASES[@]}"; do
  read -r fname expected_count expected_class <<<"$case_str"
  fpath="$FIXTURE_DIR/$fname"

  if [ ! -f "$fpath" ]; then
    echo "[FAIL] fixture not found: $fpath" >&2
    fail_count=$((fail_count + 1))
    continue
  fi

  actual_count=$(count_top_level_tasks "$fpath")
  actual_class=$(classify "$actual_count")

  if [ "$actual_count" != "$expected_count" ] || [ "$actual_class" != "$expected_class" ]; then
    echo "[FAIL] $fname: count=$actual_count (expected $expected_count), class=$actual_class (expected $expected_class)" >&2
    fail_count=$((fail_count + 1))
  else
    echo "[OK]   $fname: count=$actual_count, class=$actual_class"
  fi
done

if [ "$fail_count" -gt 0 ]; then
  echo "" >&2
  echo "$fail_count fixture(s) failed. Check the regex and threshold table consistency." >&2
  exit 1
fi

echo ""
echo "All 4 boundary fixtures match expected count and classification."
