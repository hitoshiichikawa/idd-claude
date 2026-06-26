#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の opt-in gate OFF 時の完全 no-op を検証する
#       スモークテスト。
#
#       検証する受入基準（docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/requirements.md）:
#         - NFR 1.1 観測ログ増加を + 10 行以内（gate OFF 時はゼロ）
#         - NFR 2.1 gate OFF 時の log diff ゼロ
#         - Req 6.2 gate 無効時は claude / gh / git 呼び出しゼロ
#
#       検証ケース:
#         1. DESIGN_REVIEWER_ENABLED=false（既定）→ process_pr_design_reviewer 呼び出しで
#            (a) gh が呼ばれない / (b) claude が呼ばれない / (c) git が呼ばれない /
#            (d) pdr_log / pdr_warn が呼ばれない
#         2. DESIGN_REVIEWER_ENABLED unset → 同上
#         3. DESIGN_REVIEWER_ENABLED=True（大文字違い / typo 想定 / 正規化済み env を
#            前提とした厳密一致判定で OFF 扱い）→ 同上
#         4. impl PR head pattern（claude/issue-N-impl-...）に対して
#            pdr_classify_design_pr が rc=1 を返し、Reviewer が起動しない（Req 7.4 補強）
#
# 配置先: local-watcher/test/pdr_no_op_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pdr_no_op_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"

if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
  exit 2
fi

# pr-design-reviewer.sh を `set -euo pipefail` 配下で source して全関数を読み込む。
# 個別関数の `extract_function` 抽出ではなく、process_pr_design_reviewer の dispatch 経路
# 全体を回すため `source` を使う。
# shellcheck disable=SC1090
source "$PDR_SH"

if ! declare -F process_pr_design_reviewer >/dev/null; then
  echo "ERROR: process_pr_design_reviewer not loaded" >&2
  exit 2
fi
if ! declare -F pdr_gate_enabled >/dev/null; then
  echo "ERROR: pdr_gate_enabled not loaded" >&2
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

# stub state
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  GIT_CALL_LOG="$(mktemp)"
  CLAUDE_CALL_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$GIT_CALL_LOG" "$CLAUDE_CALL_LOG" "$LOG_LOG" "$WARN_LOG" 2>/dev/null || true
}

# stub gh / git / claude / timeout / log / warn
# shellcheck disable=SC2317
gh() { echo "gh $*" >>"$GH_CALL_LOG"; return 0; }
# shellcheck disable=SC2317
git() { echo "git $*" >>"$GIT_CALL_LOG"; return 0; }
# shellcheck disable=SC2317
claude() { echo "claude $*" >>"$CLAUDE_CALL_LOG"; return 0; }
# shellcheck disable=SC2317
timeout() { shift; "$@"; }
# pdr_log / pdr_warn を再定義（source で読み込んだ既定実装を上書き）
# shellcheck disable=SC2317
pdr_log() { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pdr_warn() { echo "$*" >>"$WARN_LOG"; }

count_lines() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "0"
    return
  fi
  wc -l <"$file" | tr -d '[:space:]'
}

# グローバル env
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"

# ============================================================
# Case 1: DESIGN_REVIEWER_ENABLED=false → 完全 no-op
# ============================================================
echo "--- Case 1: DESIGN_REVIEWER_ENABLED=false → 完全 no-op (NFR 1.1, 2.1) ---"
reset_stub_state
export DESIGN_REVIEWER_ENABLED="false"
rc=0
process_pr_design_reviewer || rc=$?
assert_eq "Case 1: process_pr_design_reviewer rc=0" "0" "$rc"
assert_eq "Req 6.2 / NFR 2.1: gh 呼び出しゼロ" "0" "$(count_lines "$GH_CALL_LOG")"
assert_eq "Req 6.2 / NFR 2.1: git 呼び出しゼロ" "0" "$(count_lines "$GIT_CALL_LOG")"
assert_eq "Req 6.2 / NFR 2.1: claude 呼び出しゼロ" "0" "$(count_lines "$CLAUDE_CALL_LOG")"
assert_eq "NFR 1.1: pdr_log 呼び出しゼロ（観測ログ diff ゼロ）" "0" "$(count_lines "$LOG_LOG")"
assert_eq "NFR 1.1: pdr_warn 呼び出しゼロ" "0" "$(count_lines "$WARN_LOG")"
cleanup_stub_state

# ============================================================
# Case 2: DESIGN_REVIEWER_ENABLED unset → 完全 no-op
# ============================================================
echo ""
echo "--- Case 2: DESIGN_REVIEWER_ENABLED unset → 完全 no-op ---"
reset_stub_state
unset DESIGN_REVIEWER_ENABLED
rc=0
process_pr_design_reviewer || rc=$?
assert_eq "Case 2: process_pr_design_reviewer rc=0" "0" "$rc"
assert_eq "Req 6.2: gh 呼び出しゼロ (unset)" "0" "$(count_lines "$GH_CALL_LOG")"
assert_eq "Req 6.2: claude 呼び出しゼロ (unset)" "0" "$(count_lines "$CLAUDE_CALL_LOG")"
assert_eq "NFR 1.1: pdr_log 呼び出しゼロ (unset)" "0" "$(count_lines "$LOG_LOG")"
cleanup_stub_state

# ============================================================
# Case 3: DESIGN_REVIEWER_ENABLED=True (大文字違い) → OFF 解釈で完全 no-op
# Note: issue-watcher.sh Config の正規化は run-time に行われるため、test 内では
#       正規化されていない `True` を渡しても pdr_gate_enabled は厳密 `=true` 一致
#       のみで ON を返す（重複正規化はしない契約 / Req 6.1 安全側）。
# ============================================================
echo ""
echo "--- Case 3: DESIGN_REVIEWER_ENABLED=True (大文字違い / 正規化されていない値) → OFF (Req 6.1 安全側) ---"
reset_stub_state
export DESIGN_REVIEWER_ENABLED="True"
rc=0
process_pr_design_reviewer || rc=$?
assert_eq "Case 3: process_pr_design_reviewer rc=0" "0" "$rc"
assert_eq "Req 6.1 安全側: gh 呼び出しゼロ (typo)" "0" "$(count_lines "$GH_CALL_LOG")"
assert_eq "Req 6.1 安全側: claude 呼び出しゼロ (typo)" "0" "$(count_lines "$CLAUDE_CALL_LOG")"
assert_eq "NFR 1.1: pdr_log 呼び出しゼロ (typo)" "0" "$(count_lines "$LOG_LOG")"
cleanup_stub_state

# ============================================================
# Case 4: impl PR head pattern は pdr_classify_design_pr で除外される（Req 7.4 補強）
# ============================================================
echo ""
echo "--- Case 4: impl PR head は除外（Req 7.4 / NFR 3.1） ---"
# shellcheck disable=SC2034
export DESIGN_REVIEWER_HEAD_PATTERN="^claude/issue-[0-9]+-design-"

rc=0
pdr_classify_design_pr "claude/issue-407-impl-foo" || rc=$?
assert_eq "Req 7.4: impl PR は非 design (rc=1)" "1" "$rc"

rc=0
pdr_classify_design_pr "claude/issue-407-design-foo" || rc=$?
assert_eq "Req 7.4: design PR は design (rc=0)" "0" "$rc"

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
