#!/usr/bin/env bash
#
# 用途: Issue #404 task 7 で追加した PR Iteration Processor の adjudicator-excessive
#       フィルタ `pi_general_filter_excessive` のスモークテスト。
#
#       検証する受入基準（docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md）:
#         - Req 2.4 / 2.5  PR Iteration Processor が adjudicator excessive と判定された
#                          指摘を iteration agent の入力から除外し、legitimate のみ keep する
#         - Req 4.3        excessive marker `idd-claude:pr-adjudicator-excessive` を含む
#                          コメントを除外するが、adjudicator 自身の summary marker
#                          `idd-claude:pr-adjudicator sha=...` および既存 self-filter
#                          prefix `idd-claude:pr-iteration` とは substring 衝突しない
#         - NFR 1.1        gate OFF / 未設定 / 不正値 / typo はすべて pass-through で
#                          既存件数挙動を維持する
#         - NFR 2.2        既存 pi_general_filter_self の挙動と非衝突（#400 規約整合）
#
# 配置先: local-watcher/test/pi_general_filter_excessive_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pi_general_filter_excessive_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi

# 既存テスト (pi_general_filter_self_test.sh / adj_resolve_gate_test.sh) と同じイディオム:
# 対象スクリプトから 1 関数だけを awk で切り出して eval する。
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
eval "$(extract_function "$PR_ITERATION_SH" "pi_general_filter_excessive")"
# 既存 self-filter との非衝突確認に流用するため pi_general_filter_self も読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_general_filter_self")"

if ! declare -F pi_general_filter_excessive >/dev/null; then
  echo "ERROR: pi_general_filter_excessive not loaded" >&2
  exit 2
fi
if ! declare -F pi_general_filter_self >/dev/null; then
  echo "ERROR: pi_general_filter_self not loaded" >&2
  exit 2
fi

# eval で動的に source される関数は SC2034 を抑止しないと参照外し警告が出るため抑止する。
# shellcheck disable=SC2034

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

# ─── pi_general_filter_excessive: gate ON で marker 除外 (Req 2.4 / 2.5) ───

echo "--- pi_general_filter_excessive cases (gate ON / Issue #404 Req 2.4, 2.5) ---"

# Case 1: gate ON + excessive marker を含むコメント 1 件入力 → 0 件出力
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
input='[{"id":1,"body":"## 自動裁定: excessive\n\n- id: 1\n- severity: low\n- file: foo.sh\n- line: 10\n- 理由: 主観的\n\n<!-- idd-claude:pr-adjudicator-excessive id=1 sha=abc1234 -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r 'length')
assert_eq "Req 2.4: gate ON で idd-claude:pr-adjudicator-excessive marker 単体は除外" "0" "$actual"

# Case 2: gate ON + excessive marker 不在コメント 1 件入力 → 1 件 keep
input='[{"id":2,"body":"このロジックは redundant です","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "Req 2.5: gate ON で marker 不在の通常コメントは keep" "2" "$actual"

# Case 6: gate ON + 混在ケース（excessive 2 件 + 通常 2 件）→ 通常 2 件のみ keep
input='[
  {"id":11,"body":"通常コメント A","created_at":"2026-06-23T10:00:00Z"},
  {"id":12,"body":"<!-- idd-claude:pr-adjudicator-excessive id=1 sha=abc -->","created_at":"2026-06-23T10:01:00Z"},
  {"id":13,"body":"通常コメント B","created_at":"2026-06-23T10:02:00Z"},
  {"id":14,"body":"## 自動裁定: excessive\n- 理由: 主観的\n<!-- idd-claude:pr-adjudicator-excessive id=2 sha=def -->","created_at":"2026-06-23T10:03:00Z"}
]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '[.[].id] | join(",")')
assert_eq "Req 2.4 / 2.5: gate ON で混在入力から excessive 2 件のみ除外、通常 2 件 keep" "11,13" "$actual"

# ─── pi_general_filter_excessive: gate OFF / 未設定 / typo で pass-through (NFR 1.1) ───

echo "--- pi_general_filter_excessive cases (gate OFF / NFR 1.1) ---"

# Case 3: gate OFF + excessive marker を含むコメント 1 件入力 → 1 件 keep (pass-through)
export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
input='[{"id":21,"body":"<!-- idd-claude:pr-adjudicator-excessive id=1 sha=abc -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "NFR 1.1: gate OFF (false) は excessive marker も keep（pass-through）" "21" "$actual"

# Case 4: gate OFF + 複数コメント混在 → 全件 keep
input='[
  {"id":22,"body":"<!-- idd-claude:pr-adjudicator-excessive id=1 sha=abc -->","created_at":"2026-06-23T10:00:00Z"},
  {"id":23,"body":"通常コメント","created_at":"2026-06-23T10:01:00Z"},
  {"id":24,"body":"<!-- idd-claude:pr-adjudicator-excessive id=2 sha=def -->","created_at":"2026-06-23T10:02:00Z"}
]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '[.[].id] | join(",")')
assert_eq "NFR 1.1: gate OFF は混在入力で全件 keep（既存件数挙動維持）" "22,23,24" "$actual"

# Case 8a: gate env unset で pass-through
unset PR_REVIEWER_ADJUDICATOR_ENABLED
input='[{"id":31,"body":"<!-- idd-claude:pr-adjudicator-excessive id=1 sha=abc -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "NFR 1.1: gate unset は pass-through（OFF 等価）" "31" "$actual"

# Case 8b: gate env 空文字で pass-through
export PR_REVIEWER_ADJUDICATOR_ENABLED=""
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "NFR 1.1: gate='' (空文字) は pass-through" "31" "$actual"

# Case 8c: gate env typo (`trrue`) で pass-through
export PR_REVIEWER_ADJUDICATOR_ENABLED="trrue"
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "NFR 1.1: gate=trrue (typo) は pass-through" "31" "$actual"

# Case 8d: gate env 大文字違い (`True`) で pass-through（厳密 lowercase 一致のみ ON）
export PR_REVIEWER_ADJUDICATOR_ENABLED="True"
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "NFR 1.1: gate=True (大文字違い) は pass-through（厳密 true 一致のみ ON）" "31" "$actual"

# Case 8e: gate env 数値 (`1`) で pass-through
export PR_REVIEWER_ADJUDICATOR_ENABLED="1"
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "NFR 1.1: gate=1 (数値) は pass-through" "31" "$actual"

# ─── 既存 self-filter prefix との非衝突 (Req 4.3 / NFR 2.2 / #400 規約整合) ───

echo "--- 既存 self-filter prefix との非衝突 (Req 4.3 / NFR 2.2 / #400 規約整合) ---"

# Case 5: gate ON + self-filter prefix `idd-claude:pr-iteration` を含むコメントが
#         excessive filter を素通りすること（pi_general_filter_self が前段で除外する責務、
#         excessive filter は前方一致しないため非衝突 / #400 規約整合）
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
input='[{"id":41,"body":"<!-- idd-claude:pr-iteration round=1 last-run=2026-06-23T10:00:00Z -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "Req 4.3: gate ON + pr-iteration marker は excessive filter を keep（非衝突）" "41" "$actual"

# Case 7: gate ON + adjudicator 単独 marker (kind=decision) は keep（summary は iteration agent
#         に渡すべき情報。excessive 個別 marker のみが pi 側で除外対象 / NFR 1.2）
input='[{"id":42,"body":"## 自動裁定サマリ\n\n- total: 3\n- legitimate: 0\n- excessive: 3\n\n<!-- idd-claude:pr-adjudicator sha=abc1234 kind=decision -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_excessive | jq -r '.[0].id // "MISSING"')
assert_eq "Req 4.3: gate ON + pr-adjudicator (decision summary) marker は keep（excessive prefix 非一致）" "42" "$actual"

# Case 5b: gate ON で前段 self-filter を chain した混在入力（pr-iteration / pr-adjudicator /
#         pr-adjudicator-excessive / 通常コメント）→ pr-iteration は self で除外、
#         excessive は本関数で除外、adjudicator decision summary と通常コメントは keep
input='[
  {"id":51,"body":"<!-- idd-claude:pr-iteration round=1 last-run=2026-06-23T10:00:00Z -->","created_at":"2026-06-23T10:00:00Z"},
  {"id":52,"body":"<!-- idd-claude:pr-adjudicator sha=abc kind=decision -->","created_at":"2026-06-23T10:01:00Z"},
  {"id":53,"body":"<!-- idd-claude:pr-adjudicator-excessive id=1 sha=abc -->","created_at":"2026-06-23T10:02:00Z"},
  {"id":54,"body":"通常レビューコメント","created_at":"2026-06-23T10:03:00Z"}
]'
actual=$(echo "$input" | pi_general_filter_self | pi_general_filter_excessive | jq -r '[.[].id] | join(",")')
assert_eq "Req 4.3 / NFR 2.2: self → excessive chain で pr-iteration 除外 + excessive 除外、summary + 通常コメントは keep" "52,54" "$actual"

# Case: gate OFF で前段 self-filter を chain した同じ入力 → pr-iteration は self で除外、
#       excessive 含む残りはすべて keep（NFR 1.1 既存件数挙動）
export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
actual=$(echo "$input" | pi_general_filter_self | pi_general_filter_excessive | jq -r '[.[].id] | join(",")')
assert_eq "NFR 1.1: gate OFF chain で pr-iteration のみ除外、excessive marker は pass-through で keep" "52,53,54" "$actual"

# ─── サマリ ───

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
