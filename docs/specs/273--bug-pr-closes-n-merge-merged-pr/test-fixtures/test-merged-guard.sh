#!/usr/bin/env bash
# Issue #273 / sc_tasks_unchecked_count の判定 regex を fixture tasks.md に対して
# 直接適用し、Req 2.1 / 2.4 / 3.2 / 3.3 の挙動を回帰確認する一発スクリプト。
#
# 使い方: bash docs/specs/273--bug-pr-closes-n-merge-merged-pr/test-fixtures/test-merged-guard.sh
# 期待: 各ケースで PASS が出ること（失敗時は FAIL を出して exit 1）。
#
# 本スクリプトは外部 IO（gh / git）を行わない。`sc_tasks_unchecked_count` の中核である
# 「最上位 numeric ID 未チェックタスクの件数抽出」を、正本 regex `^- \[ \]\*? [0-9]+\. `
# （`.claude/rules/tasks-generation.md` の Budget overflow count 抽出 regex と完全一致）を
# fixture tasks.md に対して `grep -cE` で適用することで回帰確認する。
#
# 同期参照:
#   - .claude/rules/tasks-generation.md (Budget overflow count 抽出 regex の正本)
#   - .claude/rules/design-review-gate.md (Mechanical Check の同一 regex)
#   - 設計書: docs/specs/273--bug-pr-closes-n-merge-merged-pr/design.md の
#            "Tasks.md unchecked task 判定 regex (正本との同期)" 節
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 正本 regex（.claude/rules/tasks-generation.md と完全一致）
REGEX='^- \[ \]\*? [0-9]+\. '

# fixture に対して未チェック件数を抽出（sc_tasks_unchecked_count の中核ロジック）
#
# 注: `grep -cE` は「マッチ 0 件」のとき stdout=0 + rc=1 を返す。`set -e` の影響を回避し、
# かつ stdout に余分な `0` を重複出力しないため、rc を捨てて stdout のみ採用する。
count_unchecked() {
  local fixture="$1"
  local path="$SCRIPT_DIR/$fixture"
  local count
  if [ ! -f "$path" ]; then
    echo "ERROR: fixture not found: $path" >&2
    return 99
  fi
  count=$(grep -cE "$REGEX" "$path" 2>/dev/null) || count=0
  echo "$count"
}

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS  $label  expected='$expected'  actual='$actual'"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $label  expected='$expected'  actual='$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Case 1: unchecked 残存あり → Req 2.1（OPEN Issue + 未チェック残存で MERGED 非 terminal 化）
#   最上位 `- [ ] 1. ...` / `- [ ] 2. ...` のみがマッチし、子タスク `1.1` /
#   完了済み `- [x] 3. ...` はマッチしない → 期待値 2 件
# ──────────────────────────────────────────────────────────────────────
actual=$(count_unchecked tasks-with-unchecked.md)
assert_eq "tasks-with-unchecked.md" "2" "$actual"

# ──────────────────────────────────────────────────────────────────────
# Case 2: 全完了済み → Req 2.4（全 `- [x]` で MERGED PR を terminal 採用）
#   `- [x]` 行は判定 regex にマッチしない → 期待値 0 件
# ──────────────────────────────────────────────────────────────────────
actual=$(count_unchecked tasks-all-checked.md)
assert_eq "tasks-all-checked.md" "0" "$actual"

# ──────────────────────────────────────────────────────────────────────
# Case 3: 空（見出しのみ）→ Req 2.4 / 3.2 の縮退ケース
#   タスク行が存在しない → 期待値 0 件
# ──────────────────────────────────────────────────────────────────────
actual=$(count_unchecked tasks-empty.md)
assert_eq "tasks-empty.md" "0" "$actual"

echo ""
echo "──────────────────────────────────────────────"
echo "Summary: PASS=$PASS FAIL=$FAIL"
echo "──────────────────────────────────────────────"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
