#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の opt-in gate OFF 時の完全 no-op を検証する
#       スモークテスト。
#
#       検証する受入基準（docs/specs/432-fix-watcher-design-reviewer-407-opt-in-o/requirements.md）:
#         - Req 1.4 / 3.1 / NFR 1.1 `=false` 明示 opt-out 時は claude / gh / git 呼び出しゼロ・
#           観測ログ行ゼロ（本変更前の opt-in 既定 OFF と完全に等価）
#         - Req 2.1 / 2.2 / 2.4 プロンプトテンプレ未解決時の graceful no-op（claude 不起動・
#           WARN 1 行・status / ラベル不変・dispatcher fail-continue 維持）
#
#       検証ケース（#432 既定 ON / opt-out 反転後）:
#         1. DESIGN_REVIEWER_ENABLED=false（明示 opt-out）→ process_pr_design_reviewer 呼び出しで
#            (a) gh が呼ばれない / (b) claude が呼ばれない / (c) git が呼ばれない /
#            (d) pdr_log / pdr_warn が呼ばれない（gate OFF の完全 no-op）
#         2. DESIGN_REVIEWER_ENABLED=False（大文字違い / 未正規化値を厳密一致判定で OFF 扱い）
#            → 同上（pdr_gate_enabled は重複正規化せず厳密 `=true` のみ ON）
#         3. DESIGN_REVIEWER_ENABLED 未設定（既定 ON）かつ プロンプトテンプレ未解決
#            → gate は ON だが pdr_prompt_asset_resolvable が rc=1 → WARN 1 行 + return 0 の
#              graceful no-op（claude / gh が呼ばれない / Req 2.1, 2.2, 2.4）
#         4. impl PR head pattern（claude/issue-N-impl-...）に対して
#            pdr_classify_design_pr が rc=1 を返し、Reviewer が起動しない（NFR 4.1 補強）
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
# Case 1: DESIGN_REVIEWER_ENABLED=false（明示 opt-out）→ 完全 no-op
# ============================================================
echo "--- Case 1: DESIGN_REVIEWER_ENABLED=false（明示 opt-out）→ 完全 no-op (Req 1.4 / 3.1 / NFR 1.1) ---"
reset_stub_state
export DESIGN_REVIEWER_ENABLED="false"
rc=0
process_pr_design_reviewer || rc=$?
assert_eq "Case 1: process_pr_design_reviewer rc=0" "0" "$rc"
assert_eq "Req 1.4 / 3.1: gh 呼び出しゼロ" "0" "$(count_lines "$GH_CALL_LOG")"
assert_eq "Req 1.4 / 3.1: git 呼び出しゼロ" "0" "$(count_lines "$GIT_CALL_LOG")"
assert_eq "Req 1.4 / 3.1: claude 呼び出しゼロ" "0" "$(count_lines "$CLAUDE_CALL_LOG")"
assert_eq "NFR 1.1: pdr_log 呼び出しゼロ（観測ログ diff ゼロ）" "0" "$(count_lines "$LOG_LOG")"
assert_eq "NFR 1.1: pdr_warn 呼び出しゼロ" "0" "$(count_lines "$WARN_LOG")"
cleanup_stub_state

# ============================================================
# Case 2: DESIGN_REVIEWER_ENABLED=False (大文字違い / 未正規化値) → 厳密一致せず OFF で no-op
# Note: issue-watcher.sh Config の正規化は run-time に行われるため、test 内では
#       正規化されていない `False` を渡すと pdr_gate_enabled は厳密 `=true` 一致せず OFF を
#       返す（重複正規化はしない契約）。本ケースは pdr_gate_enabled の素の挙動を検証する。
# ============================================================
echo ""
echo "--- Case 2: DESIGN_REVIEWER_ENABLED=False (未正規化値) → 厳密一致せず OFF で no-op ---"
reset_stub_state
export DESIGN_REVIEWER_ENABLED="False"
rc=0
process_pr_design_reviewer || rc=$?
assert_eq "Case 2: process_pr_design_reviewer rc=0" "0" "$rc"
assert_eq "契約: gh 呼び出しゼロ (未正規化 False)" "0" "$(count_lines "$GH_CALL_LOG")"
assert_eq "契約: claude 呼び出しゼロ (未正規化 False)" "0" "$(count_lines "$CLAUDE_CALL_LOG")"
assert_eq "契約: pdr_log 呼び出しゼロ (未正規化 False)" "0" "$(count_lines "$LOG_LOG")"
cleanup_stub_state

# ============================================================
# Case 3: 既定 ON（unset）かつ プロンプトテンプレ未解決 → graceful no-op（Req 2.1, 2.2, 2.4）
# gate は ON だが pdr_prompt_asset_resolvable が rc=1 を返すため、processor 全体が
# WARN 1 行 + return 0 で no-op return する。claude / gh が起動せず、status / ラベルも不変。
# DESIGN_REVIEWER_PROMPT を unset、HOME をテンプレ不在のディレクトリに差し替えて資産不在を再現。
# ============================================================
echo ""
echo "--- Case 3: 既定 ON + プロンプトテンプレ未解決 → graceful no-op (Req 2.1, 2.2, 2.4) ---"
reset_stub_state
unset DESIGN_REVIEWER_ENABLED      # 既定 ON（`:-true`）
unset DESIGN_REVIEWER_PROMPT       # env override なし
_SAVED_HOME="${HOME:-}"
_EMPTY_HOME="$(mktemp -d)"          # bin/design-review-prompt.tmpl が存在しないディレクトリ
export HOME="$_EMPTY_HOME"
rc=0
process_pr_design_reviewer || rc=$?
export HOME="$_SAVED_HOME"
rmdir "$_EMPTY_HOME" 2>/dev/null || rm -rf "$_EMPTY_HOME" 2>/dev/null || true
assert_eq "Case 3: process_pr_design_reviewer rc=0 (graceful no-op)" "0" "$rc"
assert_eq "Req 2.1: claude 呼び出しゼロ（資産不在 skip）" "0" "$(count_lines "$CLAUDE_CALL_LOG")"
assert_eq "Req 2.1: gh 呼び出しゼロ（資産不在 skip）" "0" "$(count_lines "$GH_CALL_LOG")"
assert_eq "Req 2.1: WARN 1 行（資産不在を運用者が判別できる）" "1" "$(count_lines "$WARN_LOG")"
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
