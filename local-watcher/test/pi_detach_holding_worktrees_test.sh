#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-iteration.sh の Issue #529 Requirement 1
#       （PR Iteration Processor が head branch を保持する他 worktree を checkout 前に
#       detach する）で追加した pi_detach_holding_worktrees を回帰テストする。
#
#       対象関数:
#         - pi_detach_holding_worktrees (#529 Req 1 / AC 1.1〜1.5 / NFR 1.2 / NFR 2)
#
#       検証する AC:
#         - AC 1.1 / 1.2: head_ref を保持する他 worktree を detach する
#         - AC 1.4: 対象 head_ref を保持する worktree のみ detach（他 branch は不干渉）
#         - AC 1.5: detach 失敗でも return 0（fail-safe / round を止めない）
#         - NFR 1.2: 誰も保持していない正常系は no-op（detach 呼び出しなし）
#         - NFR 2.2: `-` 始まりの head_ref でも git オプションとして解釈させない
#         - 現在の worktree（REPO_DIR）自身が保持するケースは detach 対象外
#
#       git / timeout / pi_log / pi_warn を stub し、`git -C <path> checkout --detach` の
#       呼び出しトレース（detach 対象 path）を log file へ記録して観測する。
#
# 配置先: local-watcher/test/pi_detach_holding_worktrees_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pi_detach_holding_worktrees_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
  exit 2
fi

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_detach_holding_worktrees")"

if ! declare -F pi_detach_holding_worktrees >/dev/null; then
  echo "ERROR: pi_detach_holding_worktrees not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

# ─── 環境 stub ──────────────────────────────────────────────────────────────
PR_ITERATION_GIT_TIMEOUT=60
export PR_ITERATION_GIT_TIMEOUT

STUB_DETACH_LOG="$(mktemp)"
STUB_CURRENT_TOP=""
STUB_PORCELAIN=""
STUB_DETACH_RC=0
trap 'rm -f "$STUB_DETACH_LOG"' EXIT

# timeout stub: 先頭の duration を捨てて残りを実行
timeout() { shift; "$@"; }

# git stub: subcommand で分岐。checkout --detach は対象 path を log へ append。
git() {
  case "$1" in
    rev-parse)
      printf '%s\n' "$STUB_CURRENT_TOP"
      ;;
    worktree)
      printf '%s\n' "$STUB_PORCELAIN"
      ;;
    -C)
      # git -C <path> checkout --detach  ($2=path, $3=checkout, $4=--detach)
      printf '%s\n' "$2" >> "$STUB_DETACH_LOG"
      return "${STUB_DETACH_RC:-0}"
      ;;
    *)
      return 0
      ;;
  esac
}

# ロガー stub（no-op）
pi_log() { :; }
pi_warn() { :; }

# ヘルパー: 1 シナリオ実行し rc と detach log を採取
LAST_RC=0
run_detach() {
  : > "$STUB_DETACH_LOG"
  LAST_RC=0
  pi_detach_holding_worktrees "$1" >/dev/null 2>&1 || LAST_RC=$?
}

REPO_TOP="/home/user/repo"
SLOT1="/home/user/.issue-watcher/worktrees/o-r/slot-1"
SLOT2="/home/user/.issue-watcher/worktrees/o-r/slot-2"

# ─── AC 1.1 / 1.2: 他 worktree が head_ref を保持 → detach する ──────────────
echo "--- pi_detach_holding_worktrees: 他 worktree 保持 → detach (AC 1.1 / 1.2) ---"

STUB_CURRENT_TOP="$REPO_TOP"
STUB_DETACH_RC=0
STUB_PORCELAIN="worktree ${REPO_TOP}
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree ${SLOT1}
HEAD 2222222222222222222222222222222222222222
branch refs/heads/claude/issue-529-foo
"
run_detach "claude/issue-529-foo"
assert_eq "他 worktree 保持: rc=0" "0" "$LAST_RC"
assert_contains "他 worktree 保持: slot-1 が detach された" \
  "$(cat "$STUB_DETACH_LOG")" "$SLOT1"
assert_eq "他 worktree 保持: detach 対象は 1 件のみ（REPO_TOP は含まない）" \
  "$SLOT1" \
  "$(cat "$STUB_DETACH_LOG")"

echo ""

# ─── AC 1.4: 対象 head_ref を保持する worktree のみ detach ────────────────────
echo "--- pi_detach_holding_worktrees: 対象 branch のみ detach (AC 1.4) ---"

STUB_CURRENT_TOP="$REPO_TOP"
STUB_PORCELAIN="worktree ${REPO_TOP}
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree ${SLOT1}
HEAD 2222222222222222222222222222222222222222
branch refs/heads/claude/issue-529-foo

worktree ${SLOT2}
HEAD 3333333333333333333333333333333333333333
branch refs/heads/claude/issue-999-bar
"
run_detach "claude/issue-529-foo"
assert_contains "対象 branch のみ: slot-1（target 保持）を detach" \
  "$(cat "$STUB_DETACH_LOG")" "$SLOT1"
# slot-2 は別 branch を保持 → detach されない
case "$(cat "$STUB_DETACH_LOG")" in
  *"$SLOT2"*) echo "FAIL: 別 branch の slot-2 が誤って detach された"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
  *)          echo "PASS: 別 branch の slot-2 は detach されない (AC 1.4)"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
esac

echo ""

# ─── NFR 1.2: 誰も head_ref を保持していない → no-op ─────────────────────────
echo "--- pi_detach_holding_worktrees: 未保持 → no-op (NFR 1.2) ---"

STUB_CURRENT_TOP="$REPO_TOP"
STUB_PORCELAIN="worktree ${REPO_TOP}
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main
"
run_detach "claude/issue-529-foo"
assert_eq "未保持: rc=0" "0" "$LAST_RC"
assert_eq "未保持: detach 呼び出しなし（正常系 no-op）" "" "$(cat "$STUB_DETACH_LOG")"

echo ""

# ─── 現在の worktree 自身が保持 → detach 対象外 ──────────────────────────────
echo "--- pi_detach_holding_worktrees: 現 worktree 保持 → 除外 (NFR 1.2) ---"

STUB_CURRENT_TOP="$REPO_TOP"
STUB_PORCELAIN="worktree ${REPO_TOP}
HEAD 2222222222222222222222222222222222222222
branch refs/heads/claude/issue-529-foo
"
run_detach "claude/issue-529-foo"
assert_eq "現 worktree 保持: rc=0" "0" "$LAST_RC"
assert_eq "現 worktree 保持: checkout -B が扱うため detach しない" "" "$(cat "$STUB_DETACH_LOG")"

echo ""

# ─── AC 1.5: detach 失敗でも return 0（fail-safe） ──────────────────────────
echo "--- pi_detach_holding_worktrees: detach 失敗 → fail-safe (AC 1.5) ---"

STUB_CURRENT_TOP="$REPO_TOP"
STUB_DETACH_RC=1
STUB_PORCELAIN="worktree ${REPO_TOP}
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree ${SLOT1}
HEAD 2222222222222222222222222222222222222222
branch refs/heads/claude/issue-529-foo
"
run_detach "claude/issue-529-foo"
assert_eq "detach 失敗: それでも rc=0（round を止めない）" "0" "$LAST_RC"
STUB_DETACH_RC=0

echo ""

# ─── 引数不正: head_ref 空 → 即 return 0 ────────────────────────────────────
echo "--- pi_detach_holding_worktrees: head_ref 空 → return 0 ---"

STUB_CURRENT_TOP="$REPO_TOP"
STUB_PORCELAIN="worktree ${REPO_TOP}
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main
"
run_detach ""
assert_eq "head_ref 空: rc=0" "0" "$LAST_RC"
assert_eq "head_ref 空: detach なし" "" "$(cat "$STUB_DETACH_LOG")"

echo ""

# ─── NFR 2.2: `-` 始まりの head_ref でも git オプション注入されない ──────────
echo "--- pi_detach_holding_worktrees: '-' 始まり head_ref (NFR 2.2) ---"

STUB_CURRENT_TOP="$REPO_TOP"
STUB_PORCELAIN="worktree ${REPO_TOP}
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree ${SLOT1}
HEAD 2222222222222222222222222222222222222222
branch refs/heads/-evil
"
run_detach "-evil"
assert_eq "'-'始まり head_ref: rc=0（クラッシュせず処理継続）" "0" "$LAST_RC"
# refs/heads/-evil を保持する slot-1 を完全一致で検出し detach（git のフラグとして解釈されない）
assert_contains "'-'始まり head_ref: 完全一致で slot-1 を detach" \
  "$(cat "$STUB_DETACH_LOG")" "$SLOT1"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
