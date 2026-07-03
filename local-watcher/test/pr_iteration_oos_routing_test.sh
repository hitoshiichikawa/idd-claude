#!/usr/bin/env bash
#
# 用途: PR Iteration out-of-scope 第 3 判定 (#437) の filter / ルーティング関数群の
#       スモークテスト。純粋 jq フィルタ（pi_general_filter_oos）は入出力 fixture で、
#       副作用関数（pi_route_out_of_scope_escalate）は PATH 経由 stub gh で検証する。
#
#       対象関数:
#         - pi_general_filter_oos            (out-of-scope marker コメント除外 / gate no-op)
#         - pi_route_out_of_scope_escalate   (needs-decisions 還流 + 追跡コメント + 冪等 + 入力検証)
#
#       検証する受入基準（docs/specs/437-pr-iteration-pr-design-spec-max-rounds/requirements.md）:
#         - Req 2.1  out-of-scope 判定コメントを iteration 入力から除外（round 非消費）
#         - Req 3.1  legitimate=0 かつ out-of-scope≥1 で既定経路（needs-decisions）へ還流
#         - Req 3.2  needs-iteration 除去 + needs-decisions 付与
#         - Req 3.3  追跡コメントを投稿し判定根拠を含める
#         - Req 3.4  ラベル / コメント失敗でも silent fail せず WARN + rc=0（安全側）
#         - Req 3.5  同一 PR・同一 SHA で既ルーティング済みなら再ルーティング skip（冪等）
#         - NFR 1.1  gate OFF / 未設定 / 不正値 / typo はすべて pass-through / no-op
#         - NFR 3.3  無効な PR 番号 / SHA は WARN + rc=2（入力検証）
#         - NFR 4.1  `reason=out-of-scope route=<route>` を含む 1 行観測ログ
#
# 配置先: local-watcher/test/pr_iteration_oos_routing_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/pr_iteration_oos_routing_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# extract_function / assert_eq / assert_contains / assert_rc を共有ライブラリから source（#474）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
# #469 の family 分割で pi_route_out_of_scope_escalate は pr-iteration-oos.sh、
# pi_general_filter_oos は filter chain 側の pr-iteration-comments.sh へ切り出された。
# 関数ごとに抽出元 family を使い分ける。
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration-oos.sh"
PR_ITERATION_COMMENTS_SH="$SCRIPT_DIR/../bin/modules/pr-iteration-comments.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration-oos.sh at $PR_ITERATION_SH" >&2
  exit 2
fi
if [ ! -f "$PR_ITERATION_COMMENTS_SH" ]; then
  echo "ERROR: cannot find pr-iteration-comments.sh at $PR_ITERATION_COMMENTS_SH" >&2
  exit 2
fi

# 既存テストと同じ extract_function イディオム（awk で 1 関数だけ切り出して eval）。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_COMMENTS_SH" "pi_general_filter_oos")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_route_out_of_scope_escalate")"

for fn in pi_general_filter_oos pi_route_out_of_scope_escalate; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env stub（抽出関数本体が遅延束縛で参照する）。
# shellcheck disable=SC2034
REPO="owner/test-repo"

PASS_COUNT=0
FAIL_COUNT=0

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  expected NOT to contain: $(printf '%q' "$needle")"
      FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    *) echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# A. pi_general_filter_oos（out-of-scope marker コメント除外 / gate no-op）
# ─────────────────────────────────────────────────────────────────────────────
# 3 件: (1) 通常コメント / (2) out-of-scope marker 付き / (3) adjudicator summary marker
COMMENTS_JSON='[
  {"id":1,"body":"通常のレビュー指摘"},
  {"id":2,"body":"強化要件です <!-- idd-claude:pr-adjudicator-out-of-scope id=3 sha=abc -->"},
  {"id":3,"body":"裁定サマリ <!-- idd-claude:pr-adjudicator sha=abc -->"}
]'

PR_ITERATION_OOS_ENABLED="true"
out=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos)
cnt=$(printf '%s' "$out" | jq 'length')
assert_eq "A.1 gate ON で out-of-scope marker コメントを除外（3→2 / Req 2.1）" "2" "$cnt"
ids=$(printf '%s' "$out" | jq -c '[.[].id]')
assert_eq "A.2 gate ON で id=2（oos marker）のみ除外" "[1,3]" "$ids"
# summary marker（pr-adjudicator sha=...）は substring 衝突せず keep される
has3=$(printf '%s' "$out" | jq '[.[] | select(.id==3)] | length')
assert_eq "A.3 adjudicator summary marker は除外しない（substring 非衝突）" "1" "$has3"

PR_ITERATION_OOS_ENABLED="false"
cnt_off=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos | jq 'length')
assert_eq "A.4 gate OFF で pass-through（件数不変 3 / NFR 1.1）" "3" "$cnt_off"

unset PR_ITERATION_OOS_ENABLED
cnt_unset=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos | jq 'length')
assert_eq "A.5 gate 未設定で pass-through（既定 OFF）" "3" "$cnt_unset"

PR_ITERATION_OOS_ENABLED="True"
cnt_typo=$(printf '%s' "$COMMENTS_JSON" | pi_general_filter_oos | jq 'length')
assert_eq "A.6 gate typo 'True' は pass-through（厳密 =true のみ ON / NFR 1.1）" "3" "$cnt_typo"

# ─────────────────────────────────────────────────────────────────────────────
# B. pi_route_out_of_scope_escalate（還流 / 冪等 / 入力検証 / 失敗安全側）
# ─────────────────────────────────────────────────────────────────────────────
SHA="0123456789abcdef0123456789abcdef01234567"
DECISIONS='{"decisions":[
  {"id":3,"severity":"medium","file":"c.sh","line":5,"verdict":"out-of-scope","reason":"design 3値状態機械 NFR 1.1 と矛盾"}
],"summary":{"total":1,"legitimate":0,"excessive":0,"out_of_scope":1}}'

# stub state
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  GH_BODY_FIXTURE=""       # gh pr view --json body が返す PR body
  GH_COMMENTS_FIXTURE=""   # gh api .../comments --jq '.[].body' が返すコメント body 群
  GH_ADD_RC=0
  GH_COMMENT_RC=0
}
cleanup_stub_state() { rm -f "$GH_CALL_LOG" "$LOG_LOG" "$WARN_LOG" 2>/dev/null || true; }

# shellcheck disable=SC2317
pi_log()  { echo "$*" >>"${LOG_LOG:-/dev/null}"; }
# shellcheck disable=SC2317
pi_warn() { echo "$*" >>"${WARN_LOG:-/dev/null}"; }
# shellcheck disable=SC2317
timeout() { shift; "$@"; }

# gh stub: サブコマンドを記録し fixture / rc をシナリオ別に返す。
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "$1" in
    api) printf '%s' "$GH_COMMENTS_FIXTURE"; return 0 ;;
    pr)
      case "$2" in
        view)    printf '%s' "$GH_BODY_FIXTURE"; return 0 ;;
        comment) return "$GH_COMMENT_RC" ;;
        edit)
          case "$*" in
            *--add-label*) return "$GH_ADD_RC" ;;
            *) return 0 ;;
          esac ;;
      esac ;;
  esac
  return 0
}

PR_ITERATION_OOS_ENABLED="true"

# B.1 gate OFF → no-op（gh 呼び出しゼロ / NFR 1.1）
reset_stub_state
PR_ITERATION_OOS_ENABLED="false"
pi_route_out_of_scope_escalate "42" "$SHA" "$DECISIONS" "adjudicator" "1" || true
assert_eq "B.1 gate OFF で gh 呼び出しゼロ（NFR 1.1 no-op）" "" "$(cat "$GH_CALL_LOG")"
cleanup_stub_state
# shellcheck disable=SC2034  # 抽出関数 pi_route_out_of_scope_escalate 経由（遅延束縛）で参照
PR_ITERATION_OOS_ENABLED="true"

# B.2 正常還流: needs-iteration 除去 + needs-decisions 付与 + 追跡コメント + 観測ログ
reset_stub_state
pi_route_out_of_scope_escalate "42" "$SHA" "$DECISIONS" "adjudicator" "1" || true
gh_calls="$(cat "$GH_CALL_LOG")"
log_calls="$(cat "$LOG_LOG")"
assert_contains "B.2a needs-iteration 除去（Req 3.2）" "$gh_calls" "--remove-label needs-iteration"
assert_contains "B.2b needs-decisions 付与（Req 3.1 / 3.2）" "$gh_calls" "--add-label needs-decisions"
assert_contains "B.2c 追跡コメント投稿（Req 3.3）" "$gh_calls" "pr comment 42"
assert_contains "B.2d 観測ログ reason=out-of-scope route=needs-decisions（NFR 4.1）" "$log_calls" "reason=out-of-scope route=needs-decisions"
cleanup_stub_state

# B.3 冪等: PR body に同一 sha の routed marker が既存 → skip（ラベル/コメント呼び出しなし / Req 3.5）
reset_stub_state
GH_BODY_FIXTURE="本文 <!-- idd-claude:pr-iteration-oos-routed sha=${SHA} -->"
pi_route_out_of_scope_escalate "42" "$SHA" "$DECISIONS" "adjudicator" "1" || true
gh_calls="$(cat "$GH_CALL_LOG")"
log_calls="$(cat "$LOG_LOG")"
assert_not_contains "B.3a 冪等 skip 時はラベル付与しない（Req 3.5）" "$gh_calls" "--add-label"
assert_contains "B.3b 冪等 skip をログに記録（action=skip-already-routed）" "$log_calls" "action=skip-already-routed"
cleanup_stub_state

# B.4 入力検証: 無効な PR 番号 → WARN + rc=2、gh 呼び出しなし（NFR 3.3）
reset_stub_state
route_rc=0
pi_route_out_of_scope_escalate "not-a-num" "$SHA" "$DECISIONS" "adjudicator" "1" || route_rc=$?
assert_eq "B.4a 無効 PR 番号で rc=2（NFR 3.3）" "2" "$route_rc"
assert_contains "B.4b 無効 PR 番号を WARN（silent fail 禁止）" "$(cat "$WARN_LOG")" "無効な PR 番号"
assert_eq "B.4c 検証失敗時は gh 呼び出しゼロ" "" "$(cat "$GH_CALL_LOG")"
cleanup_stub_state

# B.5 入力検証: 無効な SHA → WARN + rc=2（NFR 3.3）
reset_stub_state
route_rc=0
pi_route_out_of_scope_escalate "42" "ZZZ" "$DECISIONS" "adjudicator" "1" || route_rc=$?
assert_eq "B.5a 無効 SHA で rc=2（NFR 3.3）" "2" "$route_rc"
assert_contains "B.5b 無効 SHA を WARN" "$(cat "$WARN_LOG")" "無効な SHA"
cleanup_stub_state

# B.6 未知 route（design-reflow）は needs-decisions に丸める（安全側 / Req 3.1 二重防御）
reset_stub_state
# shellcheck disable=SC2034  # 抽出関数 pi_route_out_of_scope_escalate 経由（遅延束縛）で参照
PR_ITERATION_OOS_ROUTE="design-reflow"
pi_route_out_of_scope_escalate "42" "$SHA" "$DECISIONS" "adjudicator" "1" || true
assert_contains "B.6 未知 route は needs-decisions に正規化" "$(cat "$GH_CALL_LOG")" "--add-label needs-decisions"
unset PR_ITERATION_OOS_ROUTE
cleanup_stub_state

# B.7 ラベル付与失敗 → silent fail せず WARN + rc=0（Req 3.4）
reset_stub_state
GH_ADD_RC=1
route_rc=0
pi_route_out_of_scope_escalate "42" "$SHA" "$DECISIONS" "adjudicator" "1" || route_rc=$?
assert_eq "B.7a ラベル付与失敗でも rc=0（安全側 / Req 3.4）" "0" "$route_rc"
assert_contains "B.7b ラベル付与失敗を WARN（silent fail 禁止 / Req 3.4）" "$(cat "$WARN_LOG")" "付与失敗"
cleanup_stub_state

echo ""
echo "==================================="
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
echo "==================================="
[ "$FAIL_COUNT" -eq 0 ]
