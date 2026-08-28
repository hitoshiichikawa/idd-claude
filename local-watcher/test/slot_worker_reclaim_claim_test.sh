#!/usr/bin/env bash
# LABEL_CLAIMED / LABEL_TRIGGER / REPO / NUMBER / GH_VIEW_* は eval 抽出した対象関数から
# 参照されるため shellcheck が静的に検出できない（SC2034 false-positive をファイル全体で抑止）。
# shellcheck disable=SC2034
# =============================================================================
# slot_worker_reclaim_claim_test.sh — 異常終了時の claim 残留回収
#   (#530 / Requirement 2)
#
# slot-worker.sh `_slot_reclaim_stale_claim`（EXIT trap 連結の回収関数）を隔離抽出し、
# gh / slot_log を stub して ground-truth ベースの回収挙動を呼び出しトレースで検証する:
#   - claude-claimed 残存時のみ claude-claimed 除去 + auto-dev 確保 + ログ 1 行（Req 2.1 /
#     NFR 2.1）
#   - claude-claimed 不在（正常完了相当）は no-op（gh 除去を呼ばない / Req 2.2 / 2.3 / 2.5）
#   - claude-picked-up 残存でも claimed 不在なら picked-up を触らない（Req 2.4 / 2.6）
#   - NUMBER 空 / 非数値では gh を 1 回も呼ばない（未信頼 ID 防御）
#   - gh view 失敗は fail-open で return 0（回収せず次 tick へ委ねる）
#
# 配置先: local-watcher/test/slot_worker_reclaim_claim_test.sh
# 実行:   bash local-watcher/test/slot_worker_reclaim_claim_test.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"

SLOT="$SCRIPT_DIR/../bin/modules/slot-worker.sh"

PASS_COUNT=0
FAIL_COUNT=0

if [ ! -f "$SLOT" ]; then
  echo "FATAL: slot-worker.sh not found at $SLOT" >&2
  exit 1
fi

# 対象関数を実ソースから隔離抽出して読み込む
eval "$(extract_function "$SLOT" _slot_reclaim_stale_claim)"

# ── 共通スタブ / 共通環境 ──
LABEL_CLAIMED="claude-claimed"
LABEL_TRIGGER="auto-dev"
REPO="owner/repo"

TRACE=""      # gh 呼び出しトレースを格納するファイル
LOGTRACE=""   # slot_log 呼び出しトレースを格納するファイル
GH_VIEW_JSON='{"labels":[]}'
GH_VIEW_RC=0

gh() {
  echo "gh $*" >> "$TRACE"
  case "$*" in
    *"issue view"*"--json labels"*)
      printf '%s' "$GH_VIEW_JSON"
      return "$GH_VIEW_RC"
      ;;
    *"issue edit"*)
      return 0
      ;;
  esac
  return 0
}
slot_log() { echo "slot_log: $*" >> "$LOGTRACE"; }

# 1 ケース分の環境を初期化する
reset_case() {
  TRACE="$(mktemp)"
  LOGTRACE="$(mktemp)"
  : > "$TRACE"
  : > "$LOGTRACE"
}

echo "=== Case A: claude-claimed 残存 → 除去 + auto-dev 確保 + ログ 1 行 ==="
reset_case
NUMBER=530
GH_VIEW_JSON='{"labels":[{"name":"claude-claimed"},{"name":"auto-dev"}]}'
GH_VIEW_RC=0
rc=0
_slot_reclaim_stale_claim || rc=$?
TRACE_A="$(cat "$TRACE")"
LOG_A="$(cat "$LOGTRACE")"
assert_eq "Case A: 戻り値 0（fail-open）" "0" "$rc"
assert_contains "Case A: ground-truth の issue view を発行" "$TRACE_A" "gh issue view 530"
assert_contains "Case A: claude-claimed を除去" "$TRACE_A" "--remove-label claude-claimed"
assert_contains "Case A: auto-dev を確保（add-label）" "$TRACE_A" "--add-label auto-dev"
assert_contains "Case A: 回収ログを 1 行出力" "$LOG_A" "claim 残留回収"

echo "=== Case B: claude-claimed 不在（正常完了相当）→ no-op ==="
reset_case
NUMBER=531
GH_VIEW_JSON='{"labels":[{"name":"claude-picked-up"},{"name":"auto-dev"}]}'
GH_VIEW_RC=0
rc=0
_slot_reclaim_stale_claim || rc=$?
TRACE_B="$(cat "$TRACE")"
LOG_B="$(cat "$LOGTRACE")"
assert_eq "Case B: 戻り値 0" "0" "$rc"
assert_contains "Case B: ground-truth の issue view は発行" "$TRACE_B" "gh issue view 531"
# claimed 不在 → issue edit を一切呼ばない
EDIT_B="$(grep -c 'issue edit' "$TRACE" || true)"
assert_eq "Case B: issue edit を呼ばない（no-op）" "0" "$EDIT_B"
assert_eq "Case B: 回収ログを出さない" "" "$LOG_B"

echo "=== Case C: claude-picked-up 残存でも claimed 不在なら picked-up を触らない ==="
reset_case
NUMBER=532
GH_VIEW_JSON='{"labels":[{"name":"claude-picked-up"}]}'
GH_VIEW_RC=0
rc=0
_slot_reclaim_stale_claim || rc=$?
assert_eq "Case C: 戻り値 0" "0" "$rc"
PICKED_C="$(grep -c 'remove-label claude-picked-up' "$TRACE" || true)"
assert_eq "Case C: claude-picked-up を除去しない（Stale Pickup Reaper の領分）" "0" "$PICKED_C"
EDIT_C="$(grep -c 'issue edit' "$TRACE" || true)"
assert_eq "Case C: issue edit を呼ばない" "0" "$EDIT_C"

echo "=== Case D: NUMBER 空 / 非数値では gh を一切呼ばない ==="
reset_case
NUMBER=""
GH_VIEW_JSON='{"labels":[{"name":"claude-claimed"}]}'
rc=0
_slot_reclaim_stale_claim || rc=$?
GH_D_EMPTY="$(grep -c 'gh ' "$TRACE" || true)"
assert_eq "Case D-1: NUMBER 空で戻り値 0" "0" "$rc"
assert_eq "Case D-1: NUMBER 空で gh を呼ばない" "0" "$GH_D_EMPTY"

reset_case
NUMBER="abc; rm -rf /"
rc=0
_slot_reclaim_stale_claim || rc=$?
GH_D_INVALID="$(grep -c 'gh ' "$TRACE" || true)"
assert_eq "Case D-2: 非数値 NUMBER で戻り値 0" "0" "$rc"
assert_eq "Case D-2: 非数値 NUMBER で gh を呼ばない（injection 防御）" "0" "$GH_D_INVALID"

echo "=== Case E: gh view 失敗は fail-open で return 0・回収しない ==="
reset_case
NUMBER=533
GH_VIEW_JSON=''
GH_VIEW_RC=1
rc=0
_slot_reclaim_stale_claim || rc=$?
TRACE_E="$(cat "$TRACE")"
LOG_E="$(cat "$LOGTRACE")"
assert_eq "Case E: view 失敗でも戻り値 0（fail-open）" "0" "$rc"
assert_contains "Case E: view は試行する" "$TRACE_E" "gh issue view 533"
EDIT_E="$(grep -c 'issue edit' "$TRACE" || true)"
assert_eq "Case E: view 失敗時は issue edit を呼ばない" "0" "$EDIT_E"
assert_eq "Case E: 回収ログを出さない" "" "$LOG_E"

# 後始末（mktemp ファイル）
rm -f "$TRACE" "$LOGTRACE" 2>/dev/null || true

echo ""
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
