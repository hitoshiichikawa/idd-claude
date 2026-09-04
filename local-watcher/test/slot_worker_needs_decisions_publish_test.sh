#!/usr/bin/env bash
# LABEL_CLAIMED / LABEL_NEEDS_DECISIONS / REPO / NUMBER / DECISION_COUNT / LOG /
# TRIAGE_FILE は eval 抽出した対象関数から参照されるため shellcheck が静的に検出できない
# （SC2034 false-positive をファイル全体で抑止）。
# shellcheck disable=SC2034
# =============================================================================
# slot_worker_needs_decisions_publish_test.sh — needs-decisions のコメント投稿 /
#   ラベル遷移の成否検証と宙吊り防止（#533 / Requirement 1〜6）
#
# slot-worker.sh の `_slot_publish_needs_decisions`（+ フォールバック
# `_slot_reclaim_claimed_for_next_cycle`）を隔離抽出し、gh / grl_retry_label_op /
# slot_log / slot_warn / jq を stub して以下を呼び出しトレースで検証する:
#   A) comment 成功 + label 遷移成功 → 成功ログ 2 種 / claude-claimed 除去 + needs-decisions 付与
#      （Req 1.1 / 2.1 / 6.3 / NFR 1.2）
#   B) label 遷移失敗 → 「取り消し済」ログを出さない / warn / claude-claimed をフォールバック除去
#      （Req 2.2 / 2.3 / 3.2 / 3.3）
#   C) comment 投稿失敗 → 「起票しました」ログを出さない / warn / needs-decisions 非付与 /
#      claude-claimed をフォールバック除去（Req 1.2 / 1.3 / 3.2 / 6 sequencing）
#   D) rate-limit 起因失敗（grl_retry_label_op が上限到達で非 0 を返す）→ 遷移は
#      grl_retry_label_op 経由（raw gh issue edit を使わない）/ claim 非残留（Req 4.1 / 4.2）
#   E) フォールバック除去も失敗 → 二重 warn で silent fail を作らない（NFR 2.1）/ rc 0
#
# 配置先: local-watcher/test/slot_worker_needs_decisions_publish_test.sh
# 実行:   bash local-watcher/test/slot_worker_needs_decisions_publish_test.sh
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

# 対象関数（本体 + フォールバック）を実ソースから隔離抽出して読み込む
eval "$(extract_function "$SLOT" _slot_publish_needs_decisions)"
eval "$(extract_function "$SLOT" _slot_reclaim_claimed_for_next_cycle)"

# ── 共通環境 / ラベル ──
LABEL_CLAIMED="claude-claimed"
LABEL_NEEDS_DECISIONS="needs-decisions"
REPO="owner/repo"
LOG="/dev/null"
DECISION_COUNT=2
TRIAGE_FILE="/dev/null"   # jq は stub するため実ファイル内容は参照しない

# ── 制御可能な rc ──
GH_COMMENT_RC=0        # gh issue comment の rc
GRL_TRANSITION_RC=0    # ラベル遷移（--add-label あり）の grl_retry_label_op rc
GRL_FALLBACK_RC=0      # フォールバック（--remove-label のみ）の grl_retry_label_op rc

TRACE=""     # gh / grl_retry_label_op 呼び出しトレース
LOGTRACE=""  # slot_log トレース
WARNTRACE="" # slot_warn トレース

gh() {
  echo "gh $*" >> "$TRACE"
  case "$*" in
    *"issue comment"*) return "$GH_COMMENT_RC" ;;
    *) return 0 ;;
  esac
}
grl_retry_label_op() {
  echo "grl_retry_label_op $*" >> "$TRACE"
  case "$*" in
    *"--add-label"*) return "$GRL_TRANSITION_RC" ;;  # claude-claimed→needs-decisions 遷移
    *) return "$GRL_FALLBACK_RC" ;;                  # claude-claimed 単独除去（フォールバック）
  esac
}
slot_log() { echo "slot_log: $*" >> "$LOGTRACE"; }
slot_warn() { echo "slot_warn: $*" >> "$WARNTRACE"; }
# jq は固定 COMMENT を返す stub（TRIAGE_FILE のパースを不要にする）
jq() { printf '%s' "## dummy needs-decisions comment"; }

reset_case() {
  TRACE="$(mktemp)"; LOGTRACE="$(mktemp)"; WARNTRACE="$(mktemp)"
  : > "$TRACE"; : > "$LOGTRACE"; : > "$WARNTRACE"
  GH_COMMENT_RC=0; GRL_TRANSITION_RC=0; GRL_FALLBACK_RC=0
}

echo "=== Case A: comment 成功 + label 遷移成功 → 成功ログ 2 種 / claude-claimed 除去 + needs-decisions 付与 ==="
reset_case
NUMBER=533
OUT="$(_slot_publish_needs_decisions)"; rc=$?
TRACE_A="$(cat "$TRACE")"; LOG_A="$(cat "$LOGTRACE")"; WARN_A="$(cat "$WARNTRACE")"
assert_eq "Case A: 戻り値 0" "0" "$rc"
assert_contains "Case A: 決定事項コメントを投稿" "$TRACE_A" "gh issue comment 533"
assert_contains "Case A: 遷移は grl_retry_label_op 経由（claude-claimed 除去 + needs-decisions 付与）" \
  "$TRACE_A" "grl_retry_label_op 533 --repo owner/repo --remove-label claude-claimed --add-label needs-decisions"
assert_contains "Case A: 成功ログ①「起票しました」を stdout へ出力（Req 1.1）" "$OUT" "件の決定事項を起票しました"
assert_contains "Case A: 成功ログ②「取り消し済」を slot_log へ出力（Req 2.1）" "$LOG_A" "claude-claimed 取り消し済"
assert_eq "Case A: warn を出さない（正常経路）" "" "$WARN_A"
# フォールバック（--remove-label のみ）は呼ばれない
FB_A="$(grep -c 'grl_retry_label_op .* --remove-label claude-claimed$' "$TRACE" || true)"
assert_eq "Case A: フォールバック除去を呼ばない" "0" "$FB_A"

echo "=== Case B: label 遷移失敗 → 「取り消し済」ログ非出力 / warn / claude-claimed フォールバック除去 ==="
reset_case
NUMBER=534
GRL_TRANSITION_RC=1
OUT="$(_slot_publish_needs_decisions)"; rc=$?
TRACE_B="$(cat "$TRACE")"; LOG_B="$(cat "$LOGTRACE")"; WARN_B="$(cat "$WARNTRACE")"
assert_eq "Case B: 戻り値 0" "0" "$rc"
assert_eq "Case B: 「起票しました」を出さない（遷移失敗で return / Req 2.2 sequencing）" \
  "0" "$(printf '%s' "$OUT" | grep -c '起票しました' || true)"
assert_eq "Case B: 「取り消し済」ログを出さない（Req 2.2）" "0" \
  "$(grep -c '取り消し済' "$LOGTRACE" || true)"
assert_contains "Case B: ラベル遷移失敗を warn で明示（Req 2.3 / NFR 2）" "$WARN_B" "ラベル遷移に失敗"
assert_contains "Case B: 未達事実を warn で明示し次サイクルへ委譲（Req 3.3）" "$WARN_B" "次サイクル再 pickup へ委譲"
assert_contains "Case B: claude-claimed をフォールバック除去（Req 3.2）" "$TRACE_B" \
  "grl_retry_label_op 534 --repo owner/repo --remove-label claude-claimed"

echo "=== Case C: comment 投稿失敗 → 「起票しました」非出力 / warn / needs-decisions 非付与 / claude-claimed 除去 ==="
reset_case
NUMBER=535
GH_COMMENT_RC=1
OUT="$(_slot_publish_needs_decisions)"; rc=$?
TRACE_C="$(cat "$TRACE")"; LOG_C="$(cat "$LOGTRACE")"; WARN_C="$(cat "$WARNTRACE")"
assert_eq "Case C: 戻り値 0" "0" "$rc"
assert_eq "Case C: 「起票しました」を出さない（Req 1.2）" "0" \
  "$(printf '%s' "$OUT" | grep -c '起票しました' || true)"
assert_contains "Case C: コメント投稿失敗を warn で明示（Req 1.3 / NFR 2）" "$WARN_C" "コメントの投稿に失敗"
# needs-decisions を付けない（--add-label を含む grl_retry_label_op を呼ばない / sequencing / Req 6）
assert_eq "Case C: needs-decisions を付与しない（--add-label 呼び出しなし）" "0" \
  "$(grep -c 'add-label needs-decisions' "$TRACE" || true)"
assert_contains "Case C: claude-claimed をフォールバック除去（Req 3.2）" "$TRACE_C" \
  "grl_retry_label_op 535 --repo owner/repo --remove-label claude-claimed"
assert_eq "Case C: 「取り消し済」ログを出さない" "0" "$(grep -c '取り消し済' "$LOGTRACE" || true)"

echo "=== Case D: rate-limit 起因の遷移失敗 → grl_retry_label_op 経由（raw gh edit 不使用）/ claim 非残留 ==="
reset_case
NUMBER=536
GRL_TRANSITION_RC=1   # rate-limit リトライ上限到達を模擬（grl_retry_label_op が非 0 を返す / Req 4.2）
_slot_publish_needs_decisions >/dev/null; rc=$?
TRACE_D="$(cat "$TRACE")"
assert_eq "Case D: 戻り値 0" "0" "$rc"
# 遷移は grl_retry_label_op 経由でリトライ基盤に載る（Req 4.1）。raw `gh issue edit` は使わない。
assert_eq "Case D: raw gh issue edit を遷移に使わない（grl_retry_label_op 経由 / Req 4.1）" "0" \
  "$(grep -c 'gh issue edit' "$TRACE" || true)"
assert_contains "Case D: 上限到達でも claude-claimed を除去し残留させない（Req 4.2 / 3.2）" "$TRACE_D" \
  "grl_retry_label_op 536 --repo owner/repo --remove-label claude-claimed"

echo "=== Case E: フォールバック除去も失敗 → 二重 warn（silent fail 回避 / NFR 2.1）/ rc 0 ==="
reset_case
NUMBER=537
GRL_TRANSITION_RC=1
GRL_FALLBACK_RC=1
_slot_publish_needs_decisions >/dev/null; rc=$?
WARN_E="$(cat "$WARNTRACE")"
assert_eq "Case E: 戻り値 0（best-effort / クラッシュしない）" "0" "$rc"
assert_contains "Case E: 遷移失敗の warn" "$WARN_E" "ラベル遷移に失敗"
assert_contains "Case E: フォールバック失敗の warn（#530 EXIT trap 回収へ委譲）" "$WARN_E" "フォールバックにも失敗"

# 後始末
rm -f "$TRACE" "$LOGTRACE" "$WARNTRACE" 2>/dev/null || true

echo ""
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
