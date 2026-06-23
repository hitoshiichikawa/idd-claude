#!/usr/bin/env bash
#
# 用途: Issue #400 で限定範囲化した PR Iteration Processor の self-filter
#       `pi_general_filter_self` のスモークテスト。
#
#       検証する受入基準（docs/specs/400-fix-pr-iteration-self-filter-pr-reviewer/requirements.md）:
#         - Req 1.1〜1.4 PR Reviewer 投稿 (`idd-claude:pr-reviewer ... kind=review`) を keep
#         - Req 2.1〜2.4 自身の marker (`idd-claude:pr-iteration` / `-processing` / `-529-warning`) を除外
#         - Req 2.4         他系統 (security-review / quota-reset / auto-rebase 等) は keep
#         - Req 2.5         `idd-claude:pr-iteration-<suffix>` 形式の前方互換性
#         - Req 3.1〜3.4 last-run 境界の維持 (== 除外側、後は採用) を `pi_general_filter_resolved`
#                          と組み合わせて検証
#         - Req 5.1〜5.3 line-comment 経路にも同じ self-filter 規約が適用される (substring 検証)
#
# 配置先: local-watcher/test/pi_general_filter_self_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pi_general_filter_self_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
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
eval "$(extract_function "$PR_ITERATION_SH" "pi_general_filter_self")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_general_filter_resolved")"

if ! declare -F pi_general_filter_self >/dev/null; then
  echo "ERROR: pi_general_filter_self not loaded" >&2
  exit 2
fi
if ! declare -F pi_general_filter_resolved >/dev/null; then
  echo "ERROR: pi_general_filter_resolved not loaded" >&2
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

# ─── pi_general_filter_self (Issue #400 Req 1 / Req 2) ───

echo "--- pi_general_filter_self cases (Issue #400 Req 1 / Req 2) ---"

# Req 1.1 / 1.3 / 2.4: PR Reviewer 投稿 (idd-claude:pr-reviewer kind=review) は keep する
input='[{"id":1,"body":"## :mag: PR Reviewer 自動レビュー\n\n指摘 1: foo\n\n<!-- idd-claude:pr-reviewer sha=abc1234 kind=review tool=codex -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r '.[0].id // "MISSING"')
assert_eq "Req 1.1 / 2.4: PR Reviewer kind=review コメントは self-filter で除外されず keep" "1" "$actual"

# Req 2.1: 自身の marker (round=N last-run=...) を持つコメントは除外
input='[{"id":2,"body":"<!-- idd-claude:pr-iteration round=1 last-run=2026-06-23T10:00:00Z no-progress-streak=0 -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r 'length')
assert_eq "Req 2.1: idd-claude:pr-iteration round=N marker は self として除外" "0" "$actual"

# Req 2.2: 着手表明コメント (idd-claude:pr-iteration-processing) は除外
input='[{"id":3,"body":":robot: PR Iteration Processor が処理を開始しました (round 2/3)。\n<!-- idd-claude:pr-iteration-processing round=2 -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r 'length')
assert_eq "Req 2.2: idd-claude:pr-iteration-processing は self として除外" "0" "$actual"

# Req 2.3: 529 warning コメント (idd-claude:pr-iteration-529-warning) は除外
input='[{"id":4,"body":":warning: Claude API 一時混雑エラー\n<!-- idd-claude:pr-iteration-529-warning round=1 -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r 'length')
assert_eq "Req 2.3: idd-claude:pr-iteration-529-warning は self として除外" "0" "$actual"

# Req 2.4: security-review は keep
input='[{"id":5,"body":"## Security Review\n<!-- idd-claude:security-review sha=abc kind=review -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r '.[0].id // "MISSING"')
assert_eq "Req 2.4: idd-claude:security-review は keep" "5" "$actual"

# Req 2.4: quota-reset は keep
input='[{"id":6,"body":"<!-- idd-claude:quota-reset -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r '.[0].id // "MISSING"')
assert_eq "Req 2.4: idd-claude:quota-reset は keep" "6" "$actual"

# Req 2.4: auto-rebase は keep
input='[{"id":7,"body":"<!-- idd-claude:auto-rebase -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r '.[0].id // "MISSING"')
assert_eq "Req 2.4: idd-claude:auto-rebase は keep" "7" "$actual"

# Req 2.4: idd-claude:review (PR Reviewer の汎用 marker) は keep
input='[{"id":8,"body":"<!-- idd-claude:review tool=codex -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r '.[0].id // "MISSING"')
assert_eq "Req 2.4: idd-claude:review は keep" "8" "$actual"

# Req 2.5: idd-claude:pr-iteration-<suffix> 形式の前方互換性
input='[{"id":9,"body":"<!-- idd-claude:pr-iteration-foo round=1 -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" | pi_general_filter_self | jq -r 'length')
assert_eq "Req 2.5: idd-claude:pr-iteration-foo 形式の新サブ種別も self として除外" "0" "$actual"

# 混在ケース: reviewer keep + self exclude を同時に検証（実稼働の fetched=8, filtered_self=7, final=0 シナリオの逆再現）
input='[
  {"id":11,"body":"<!-- idd-claude:pr-reviewer sha=a kind=review tool=codex -->","created_at":"2026-06-23T10:00:00Z"},
  {"id":12,"body":"<!-- idd-claude:pr-reviewer sha=b kind=review tool=claude -->","created_at":"2026-06-23T10:01:00Z"},
  {"id":13,"body":"<!-- idd-claude:pr-iteration round=1 last-run=2026-06-23T09:00:00Z -->","created_at":"2026-06-23T09:30:00Z"},
  {"id":14,"body":"<!-- idd-claude:pr-iteration-processing round=2 -->","created_at":"2026-06-23T10:02:00Z"},
  {"id":15,"body":"<!-- idd-claude:security-review -->","created_at":"2026-06-23T10:03:00Z"}
]'
actual=$(echo "$input" | pi_general_filter_self | jq -r '[.[].id] | join(",")')
assert_eq "Req 1.4 / 4.2: 混在入力で reviewer / security は keep、pr-iteration 系のみ除外" "11,12,15" "$actual"

# ─── pi_general_filter_resolved (Issue #400 Req 3) との組み合わせ検証 ───

echo "--- pi_general_filter_self + pi_general_filter_resolved 統合 (Issue #400 Req 3) ---"

# Req 3.1: last-run TS と同時刻の reviewer コメントは除外（== は除外側に倒す既存挙動の維持）
input='[{"id":21,"body":"<!-- idd-claude:pr-reviewer sha=x kind=review -->","created_at":"2026-06-23T10:00:00Z"}]'
actual=$(echo "$input" \
  | pi_general_filter_self \
  | pi_general_filter_resolved "2026-06-23T10:00:00Z" \
  | jq -r 'length')
assert_eq "Req 3.1: last-run TS と同時刻の reviewer コメントは除外" "0" "$actual"

# Req 3.2: last-run TS より後の reviewer コメントは最終入力に含める
input='[{"id":22,"body":"<!-- idd-claude:pr-reviewer sha=y kind=review -->","created_at":"2026-06-23T10:00:01Z"}]'
actual=$(echo "$input" \
  | pi_general_filter_self \
  | pi_general_filter_resolved "2026-06-23T10:00:00Z" \
  | jq -r '.[0].id // "MISSING"')
assert_eq "Req 3.2: last-run TS より後の reviewer コメントは最終入力に含める" "22" "$actual"

# Req 3.1: last-run TS より前の reviewer コメントは除外
input='[{"id":23,"body":"<!-- idd-claude:pr-reviewer sha=z kind=review -->","created_at":"2026-06-23T09:59:59Z"}]'
actual=$(echo "$input" \
  | pi_general_filter_self \
  | pi_general_filter_resolved "2026-06-23T10:00:00Z" \
  | jq -r 'length')
assert_eq "Req 3.1: last-run TS より前の reviewer コメントは除外" "0" "$actual"

# Req 3.3: last-run 不在 (初回 round) では reviewer コメント全件が採用される
input='[
  {"id":24,"body":"<!-- idd-claude:pr-reviewer sha=p kind=review -->","created_at":"2026-06-23T09:00:00Z"},
  {"id":25,"body":"<!-- idd-claude:pr-reviewer sha=q kind=review -->","created_at":"2026-06-23T10:00:00Z"}
]'
actual=$(echo "$input" \
  | pi_general_filter_self \
  | pi_general_filter_resolved "" \
  | jq -r '[.[].id] | join(",")')
assert_eq "Req 3.3: last-run 空文字列 (初回 round) は reviewer コメントを除外しない" "24,25" "$actual"

# ─── line-comment 経路の self-filter 規約 (Issue #400 Req 5) ───

echo "--- line-comment 経路の self-filter (Issue #400 Req 5) ---"

# Req 5.2: line-comment にも同じ jq filter で pr-iteration marker を除外する整合（実装と同じ式で検証）
# 実装側の line-comment projection は `[.[] | {id, path, line, user, body} | select((.body // "") | contains("idd-claude:pr-iteration") | not)]`
line_filter() {
  jq '[.[] | {id, path, line, user: (.user.login // ""), body} | select((.body // "") | contains("idd-claude:pr-iteration") | not)]'
}

# Req 5.2: line-comment に pr-iteration marker が含まれていれば除外
input='[{"id":31,"path":"foo.sh","line":10,"user":{"login":"bot"},"body":"<!-- idd-claude:pr-iteration round=1 -->"}]'
actual=$(echo "$input" | line_filter | jq -r 'length')
assert_eq "Req 5.2: line-comment の idd-claude:pr-iteration marker は除外" "0" "$actual"

# Req 5.3: line-comment に他 prefix の marker が含まれていても keep
input='[{"id":32,"path":"foo.sh","line":10,"user":{"login":"bot"},"body":"<!-- idd-claude:pr-reviewer sha=x kind=review tool=codex -->\n指摘内容: foo.sh の 10 行目で..."}]'
actual=$(echo "$input" | line_filter | jq -r '.[0].id // "MISSING"')
assert_eq "Req 5.3: line-comment の idd-claude:pr-reviewer marker は keep" "32" "$actual"

# Req 5.3: marker を含まない通常の line-comment は keep
input='[{"id":33,"path":"foo.sh","line":15,"user":{"login":"alice"},"body":"このロジックは redundant です"}]'
actual=$(echo "$input" | line_filter | jq -r '.[0].id // "MISSING"')
assert_eq "Req 5.3: marker 不在の通常 line-comment は keep" "33" "$actual"

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
