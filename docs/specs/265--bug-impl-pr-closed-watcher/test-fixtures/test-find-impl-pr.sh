#!/usr/bin/env bash
# Issue #265 / stage_checkpoint_find_impl_pr の jq 採用ロジックを fixture JSON に対して
# 直接適用し、Req 1.1/1.2/1.3/1.4/1.5 の挙動を回帰確認する一発スクリプト。
#
# 使い方: bash docs/specs/265--bug-impl-pr-closed-watcher/test-fixtures/test-find-impl-pr.sh
# 期待: 各ケースで PASS が出ること（失敗時は FAIL を出して exit 1）。
#
# 本スクリプトは外部 IO（gh / git）を行わない。`gh pr list` の戻り JSON を fixture で
# 模した上で、issue-watcher.sh 内に実装した「OPEN > MERGED > (include_closed=true なら CLOSED)」
# 採用優先順位を再現する。`gh` 呼び出しを差し替えた E2E テストは別途 watcher の本流統合
# テストの範囲（本 spec の Out of Scope）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# issue-watcher.sh の find-impl-pr ロジックと等価な選別関数（jq クエリは本体と同一）。
pick_impl_pr() {
  local prs="$1"
  local include_closed="${2:-false}"
  local open_pr merged_pr closed_pr
  open_pr=$(echo "$prs"   | jq -r '[.[] | select(.state == "OPEN")]   | .[0] // empty')
  merged_pr=$(echo "$prs" | jq -r '[.[] | select(.state == "MERGED")] | .[0] // empty')
  closed_pr=$(echo "$prs" | jq -r '[.[] | select(.state == "CLOSED")] | .[0] // empty')

  local found=""
  if [ -n "$open_pr" ]; then
    found="$open_pr"
  elif [ -n "$merged_pr" ]; then
    found="$merged_pr"
  elif [ -n "$closed_pr" ] && [ "$include_closed" = "true" ]; then
    found="$closed_pr"
  fi

  if [ -z "$found" ]; then
    echo "NONE"
    return 1
  fi
  echo "$found" | jq -r '"\(.number),\(.state)"'
  return 0
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

read_fixture() {
  cat "$SCRIPT_DIR/$1"
}

# ──────────────────────────────────────────────────────────────────────
# Case 1: empty array → 既存 PR なし（rc=1, stdout=NONE）
# Req 1.4 と等価（CLOSED のみ → なし扱い）の縮退ケース
# ──────────────────────────────────────────────────────────────────────
out=$(pick_impl_pr "$(read_fixture empty.json)" false || true)
assert_eq "empty/default"       "NONE" "$out"
out=$(pick_impl_pr "$(read_fixture empty.json)" true || true)
assert_eq "empty/include_closed" "NONE" "$out"

# ──────────────────────────────────────────────────────────────────────
# Case 2: CLOSED のみ → Req 1.1, 1.4
#  既定（include_closed=false）: 「既存 PR なし」扱いで stdout=NONE
#  include_closed=true（#212 Stage C ガード経路）: CLOSED を採用
# ──────────────────────────────────────────────────────────────────────
out=$(pick_impl_pr "$(read_fixture closed-only.json)" false || true)
assert_eq "closed-only/default"         "NONE"        "$out"
out=$(pick_impl_pr "$(read_fixture closed-only.json)" true || true)
assert_eq "closed-only/include_closed"  "101,CLOSED"  "$out"

# ──────────────────────────────────────────────────────────────────────
# Case 3: OPEN のみ → Req 1.2（OPEN を採用、既存挙動と一致）
# ──────────────────────────────────────────────────────────────────────
out=$(pick_impl_pr "$(read_fixture open-only.json)" false || true)
assert_eq "open-only/default"        "201,OPEN" "$out"
out=$(pick_impl_pr "$(read_fixture open-only.json)" true || true)
assert_eq "open-only/include_closed" "201,OPEN" "$out"

# ──────────────────────────────────────────────────────────────────────
# Case 4: MERGED のみ → Req 1.3（MERGED を採用、既存挙動と一致）
# ──────────────────────────────────────────────────────────────────────
out=$(pick_impl_pr "$(read_fixture merged-only.json)" false || true)
assert_eq "merged-only/default"        "301,MERGED" "$out"
out=$(pick_impl_pr "$(read_fixture merged-only.json)" true || true)
assert_eq "merged-only/include_closed" "301,MERGED" "$out"

# ──────────────────────────────────────────────────────────────────────
# Case 5: OPEN + CLOSED 混在 → Req 1.5（OPEN 優先採用 / CLOSED 除外）
# ──────────────────────────────────────────────────────────────────────
out=$(pick_impl_pr "$(read_fixture open-and-closed.json)" false || true)
assert_eq "open+closed/default"        "201,OPEN" "$out"
out=$(pick_impl_pr "$(read_fixture open-and-closed.json)" true || true)
assert_eq "open+closed/include_closed" "201,OPEN" "$out"

# ──────────────────────────────────────────────────────────────────────
# Case 6: MERGED + CLOSED 混在 → Req 1.5（MERGED 優先採用 / CLOSED 除外）
# ──────────────────────────────────────────────────────────────────────
out=$(pick_impl_pr "$(read_fixture merged-and-closed.json)" false || true)
assert_eq "merged+closed/default"        "301,MERGED" "$out"
out=$(pick_impl_pr "$(read_fixture merged-and-closed.json)" true || true)
assert_eq "merged+closed/include_closed" "301,MERGED" "$out"

# ──────────────────────────────────────────────────────────────────────
# Case 7: OPEN + MERGED + CLOSED 三者混在 → Req 1.5（OPEN > MERGED > CLOSED）
# ──────────────────────────────────────────────────────────────────────
out=$(pick_impl_pr "$(read_fixture open-merged-closed.json)" false || true)
assert_eq "open+merged+closed/default"        "202,OPEN" "$out"
out=$(pick_impl_pr "$(read_fixture open-merged-closed.json)" true || true)
assert_eq "open+merged+closed/include_closed" "202,OPEN" "$out"

echo ""
echo "──────────────────────────────────────────────"
echo "Summary: PASS=$PASS FAIL=$FAIL"
echo "──────────────────────────────────────────────"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
