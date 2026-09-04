#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-iteration-state.sh の Issue #529 Requirement 2
#       （同一 PR・同一 round の着手表明コメント再投稿抑止 / dedupe）で追加・変更した
#       関数を回帰テストする。
#
#       対象関数:
#         - pi_processing_comment_posted (#529 Req 2: 既投稿判定 / fail-open 用 rc)
#         - pi_post_processing_comment   (#529 Req 2: dedupe 統合 / AC 2.1〜2.3)
#
#       検証する AC:
#         - AC 2.1: 同一 round のコメントが既投稿なら再投稿しない
#         - AC 2.2: 新 round では 1 回だけ投稿する
#         - AC 2.3: 判定 / 投稿失敗でも round を失敗扱いにしない（return 0 / fail-open）
#
#       gh / timeout / pi_log / pi_warn を stub し、コメント投稿の有無を log で観測する。
#
# 配置先: local-watcher/test/pi_processing_comment_dedupe_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/pi_processing_comment_dedupe_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
PR_ITERATION_STATE_SH="$SCRIPT_DIR/../bin/modules/pr-iteration-state.sh"

if [ ! -f "$PR_ITERATION_STATE_SH" ]; then
  echo "ERROR: cannot find pr-iteration-state.sh at $PR_ITERATION_STATE_SH" >&2
  exit 2
fi

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_STATE_SH" "pi_processing_comment_posted")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_STATE_SH" "pi_post_processing_comment")"

if ! declare -F pi_processing_comment_posted >/dev/null; then
  echo "ERROR: pi_processing_comment_posted not loaded" >&2
  exit 2
fi
if ! declare -F pi_post_processing_comment >/dev/null; then
  echo "ERROR: pi_post_processing_comment not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

# ─── 環境 stub ──────────────────────────────────────────────────────────────
REPO="owner/repo"
PR_ITERATION_GIT_TIMEOUT=60
PR_ITERATION_MAX_ROUNDS=3
export REPO PR_ITERATION_GIT_TIMEOUT PR_ITERATION_MAX_ROUNDS

GH_POST_LOG="$(mktemp)"
GH_EXISTING_BODIES=""
GH_API_FAIL=0
trap 'rm -f "$GH_POST_LOG"' EXIT

timeout() { shift; "$@"; }

# gh stub: `api .../comments --jq` は既存コメント本文を返す（GH_API_FAIL=1 で失敗）。
#          `pr comment` は投稿を log へ記録。
gh() {
  if [ "$1" = "api" ]; then
    if [ "${GH_API_FAIL:-0}" = "1" ]; then
      return 1
    fi
    printf '%s\n' "$GH_EXISTING_BODIES"
    return 0
  fi
  if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
    echo "posted" >> "$GH_POST_LOG"
    return 0
  fi
  return 0
}

pi_log() { :; }
pi_warn() { :; }

# ═══════════════════════════════════════════════════════════════════════════
# Part A: pi_processing_comment_posted の rc 契約
# ═══════════════════════════════════════════════════════════════════════════
echo "--- pi_processing_comment_posted: rc 契約 (#529 Req 2) ---"

GH_API_FAIL=0
GH_EXISTING_BODIES=":robot: 処理を開始しました (round 2/3)。
<!-- idd-claude:pr-iteration-processing round=2 -->"

assert_rc "同一 round=2 が既投稿 → rc=0（投稿済み）" 0 \
  pi_processing_comment_posted 100 2

assert_rc "別 round=3 は未投稿 → rc=1（未投稿）" 1 \
  pi_processing_comment_posted 100 3

GH_EXISTING_BODIES="通常のレビューコメント本文（processing marker なし）"
assert_rc "processing marker 不在 → rc=1（未投稿）" 1 \
  pi_processing_comment_posted 100 2

GH_API_FAIL=1
assert_rc "gh 取得失敗 → rc=2（判定不能 / fail-open 用）" 2 \
  pi_processing_comment_posted 100 2
GH_API_FAIL=0

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Part B: pi_post_processing_comment の dedupe 統合（AC 2.1〜2.3）
# ═══════════════════════════════════════════════════════════════════════════

# ─── AC 2.1: 既投稿 round は再投稿しない ─────────────────────────────────────
echo "--- pi_post_processing_comment: 既投稿 round は再投稿抑止 (AC 2.1) ---"

: > "$GH_POST_LOG"
GH_API_FAIL=0
GH_EXISTING_BODIES=":robot: 処理を開始しました (round 2/3)。
<!-- idd-claude:pr-iteration-processing round=2 -->"

rc=0
pi_post_processing_comment 100 2 3 >/dev/null 2>&1 || rc=$?
assert_eq "AC 2.1: dedupe でも return 0" "0" "$rc"
assert_eq "AC 2.1: 既投稿 round=2 は再投稿されない（投稿 log 空）" \
  "" "$(cat "$GH_POST_LOG")"

echo ""

# ─── AC 2.2: 新しい round は 1 回だけ投稿する ────────────────────────────────
echo "--- pi_post_processing_comment: 新 round は 1 回投稿 (AC 2.2) ---"

: > "$GH_POST_LOG"
GH_EXISTING_BODIES=":robot: 処理を開始しました (round 1/3)。
<!-- idd-claude:pr-iteration-processing round=1 -->"

rc=0
pi_post_processing_comment 100 2 3 >/dev/null 2>&1 || rc=$?
assert_eq "AC 2.2: return 0" "0" "$rc"
assert_eq "AC 2.2: 新 round=2 は 1 回投稿される" \
  "posted" "$(cat "$GH_POST_LOG")"

echo ""

# ─── AC 2.3: 判定失敗（gh api エラー）でも fail-open で投稿し round は成功継続 ─
echo "--- pi_post_processing_comment: 判定失敗は fail-open (AC 2.3) ---"

: > "$GH_POST_LOG"
GH_API_FAIL=1
GH_EXISTING_BODIES=""

rc=0
pi_post_processing_comment 100 5 3 >/dev/null 2>&1 || rc=$?
assert_eq "AC 2.3: 判定失敗でも return 0（round を失敗扱いにしない）" "0" "$rc"
assert_eq "AC 2.3: 判定失敗時は fail-open で投稿（既存挙動を維持）" \
  "posted" "$(cat "$GH_POST_LOG")"
GH_API_FAIL=0

echo ""

# ─── 初回投稿（既存コメントが空）でも投稿される ────────────────────────────
echo "--- pi_post_processing_comment: 初回投稿 (AC 2.2 補強) ---"

: > "$GH_POST_LOG"
GH_EXISTING_BODIES=""
rc=0
pi_post_processing_comment 100 1 3 >/dev/null 2>&1 || rc=$?
assert_eq "初回: return 0" "0" "$rc"
assert_eq "初回: コメント未投稿状態から 1 回投稿" "posted" "$(cat "$GH_POST_LOG")"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
