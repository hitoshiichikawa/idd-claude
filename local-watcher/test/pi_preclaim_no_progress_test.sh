#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-iteration.sh の Issue #529 Requirement 3
#       （着手前段（fetch / detach / checkout / prompt build）失敗を no-progress として
#       連続カウンタに計上し、PR_ITERATION_NO_PROGRESS_LIMIT 到達で claude-failed へ
#       escalate して無限リトライを打ち切る）で追加した挙動を回帰テストする。
#
#       pi_run_iteration の else 分岐（着手前段失敗経路）は、以下の既存純粋関数 +
#       escalation 機構を再利用して実装されている。本テストはその合成を隔離検証する:
#         - pi_next_no_progress_streak  (commit なし相当で streak を +1 / AC 3.1)
#         - pi_classify_round_outcome   (streak >= limit で "escalate" / AC 3.2 / 3.3)
#         - pi_escalate_to_failed       (reason=no-progress で needs-iteration 除去 +
#                                        claude-failed 付与 / AC 3.3)
#
#       検証する AC:
#         - AC 3.1: 着手前段失敗 round を no-progress として連続カウンタに +1 計上
#         - AC 3.2: limit 未満は needs-iteration 据え置き（"no-progress" = keep）
#         - AC 3.3: limit 到達で needs-iteration 除去 + claude-failed 付与
#         - AC 3.4: escalate 時に PR 番号 / streak / limit を含むエスカレ本文を出力
#         - AC 3.5: design（round 無制限）でも max_rounds に依らず no-progress 上限で escalate
#
# 配置先: local-watcher/test/pi_preclaim_no_progress_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pi_preclaim_no_progress_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
STATE_SH="$SCRIPT_DIR/../bin/modules/pr-iteration-state.sh"
EXEC_SH="$SCRIPT_DIR/../bin/modules/pr-iteration-exec.sh"

for f in "$STATE_SH" "$EXEC_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: cannot find module at $f" >&2
    exit 2
  fi
done

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$STATE_SH" "pi_next_no_progress_streak")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$STATE_SH" "pi_classify_round_outcome")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$EXEC_SH" "pi_escalate_to_failed")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$EXEC_SH" "build_recovery_hint")"

for fn in pi_next_no_progress_streak pi_classify_round_outcome pi_escalate_to_failed build_recovery_hint; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

# ═══════════════════════════════════════════════════════════════════════════
# Part A: 着手前段失敗の streak 計上 → outcome 分類の合成（AC 3.1 / 3.2 / 3.3 / 3.5）
#   pi_run_iteration else 分岐は:
#     pre_streak = pi_next_no_progress_streak "false" prev_streak
#     outcome    = pi_classify_round_outcome  "false" pre_streak limit
#   を計算し、outcome=escalate なら pi_escalate_to_failed、それ以外は needs-iteration 据え置き。
# ═══════════════════════════════════════════════════════════════════════════
echo "--- 着手前段失敗: streak 計上 → outcome 合成 (AC 3.1 / 3.2 / 3.3) ---"

# limit=3 の連続失敗シミュレーション（毎サイクル claude 未起動 = commit なし）
limit=3
prev=0
declare -a expected_outcome=("" "no-progress" "no-progress" "escalate")
declare -a expected_streak=("" "1" "2" "3")
for cycle in 1 2 3; do
  s=$(pi_next_no_progress_streak "false" "$prev")
  o=$(pi_classify_round_outcome "false" "$s" "$limit")
  assert_eq "cycle=${cycle}: 着手前段失敗で streak=${expected_streak[$cycle]} に +1 計上 (AC 3.1)" \
    "${expected_streak[$cycle]}" "$s"
  assert_eq "cycle=${cycle}: outcome=${expected_outcome[$cycle]}" \
    "${expected_outcome[$cycle]}" "$o"
  prev="$s"
done

echo ""

# ─── AC 3.2: limit 未満は "no-progress"（needs-iteration 据え置き相当） ───────
echo "--- 着手前段失敗: limit 未満は据え置き (AC 3.2) ---"

assert_eq "limit=3 / prev=0 → streak=1 → no-progress（据え置き）" \
  "no-progress" \
  "$(pi_classify_round_outcome false "$(pi_next_no_progress_streak false 0)" 3)"

echo ""

# ─── AC 3.3 / 3.5: 境界 limit=1 は初回 escalate。max_rounds に依らない（design 相当） ─
echo "--- 着手前段失敗: 境界 limit=1 で初回 escalate (AC 3.3 / 3.5) ---"

assert_eq "limit=1 / prev=0 → streak=1 → escalate（1 回で打ち切り）" \
  "escalate" \
  "$(pi_classify_round_outcome false "$(pi_next_no_progress_streak false 0)" 1)"

# AC 3.5: pi_classify_round_outcome は max_rounds を引数に取らない = round 無制限（design）
#         でも no-progress 上限のみで escalate 判定される（max_rounds 非依存を関数シグネチャで担保）。
out_design=$(pi_classify_round_outcome false 3 3)
assert_eq "AC 3.5: design（round 無制限）でも streak>=limit で escalate（max_rounds 非依存）" \
  "escalate" "$out_design"

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Part B: escalate 経路の pi_escalate_to_failed（reason=no-progress）（AC 3.3 / 3.4）
# ═══════════════════════════════════════════════════════════════════════════
echo "--- pi_escalate_to_failed reason=no-progress: ラベル遷移 + 本文 (AC 3.3 / 3.4) ---"

REPO="owner/repo"
PR_ITERATION_GIT_TIMEOUT=60
PR_ITERATION_NO_PROGRESS_LIMIT=3
LABEL_NEEDS_ITERATION="needs-iteration"
LABEL_FAILED="claude-failed"
export REPO PR_ITERATION_GIT_TIMEOUT PR_ITERATION_NO_PROGRESS_LIMIT LABEL_NEEDS_ITERATION LABEL_FAILED

GH_LOG="$(mktemp)"
trap 'rm -f "$GH_LOG"' EXIT
: > "$GH_LOG"

timeout() { shift; "$@"; }
pi_warn() { :; }

# gh stub: 全呼び出しの引数（--body 本文含む）を GH_LOG へ記録
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  return 0
}

rc=0
# pi_escalate_to_failed pr_number round max_rounds reason streak
pi_escalate_to_failed 100 4 0 "no-progress" 3 >/dev/null 2>&1 || rc=$?
assert_eq "pi_escalate_to_failed: return 0" "0" "$rc"

gh_log_content="$(cat "$GH_LOG")"
assert_contains "AC 3.3: needs-iteration を除去" "$gh_log_content" "--remove-label needs-iteration"
assert_contains "AC 3.3: claude-failed を付与" "$gh_log_content" "--add-label claude-failed"
assert_contains "AC 3.4: エスカレ本文が no-progress 理由を含む" "$gh_log_content" "no-progress 連続"
assert_contains "AC 3.4: 本文が上限値 PR_ITERATION_NO_PROGRESS_LIMIT を含む" \
  "$gh_log_content" "PR_ITERATION_NO_PROGRESS_LIMIT=3"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
