#!/usr/bin/env bash
#
# 用途: PR Reviewer out-of-scope 第 3 判定 (#437) で追加 / 拡張した adjudicator 関数群の
#       挙動を、純粋関数（schema 検証 / 件数算出）は入出力 fixture で、副作用関数
#       （routing）は PATH 経由 stub gh で検証するスモークテスト。
#
#       対象関数:
#         - adj_oos_enabled               (opt-in gate 評価 / 既定 OFF)
#         - adj_validate_decisions        (gate-aware schema 検証 / 2 値 ⇔ 3 値)
#         - adj_extract_legitimate_count  (round 駆動 legitimate 件数 = out-of-scope 除外)
#         - adj_extract_out_of_scope_count(out-of-scope 件数算出)
#         - adj_route_out_of_scope        (needs-decisions 還流 + 追跡コメント)
#
#       検証する受入基準（docs/specs/437-pr-iteration-pr-design-spec-max-rounds/requirements.md）:
#         - Req 1.1 gate ON で verdict 3 値 (legitimate|excessive|legitimate-out-of-scope) を許容
#         - Req 1.3 out-of-scope を round 駆動 legitimate 件数から除外
#         - Req 2.1 legitimate=0 かつ out-of-scope≥1 で還流ラベル付与
#         - Req 2.2 out-of-scope 裁定を追跡可能な PR コメントに記録
#         - Req 2.4 legitimate≥1 残存時は還流せず iteration 継続（ラベル付与しない）
#         - Req 2.5 ラベル付与失敗でも silent fail せず WARN + rc=0（安全側）
#         - NFR 1.1 gate OFF（既定）で 3 値 decisions を schema 違反として弾く（2 値厳格維持）
#         - NFR 1.3 gate OFF で legitimate+excessive==total 不変条件を維持
#
# 配置先: local-watcher/test/adj_out_of_scope_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/adj_out_of_scope_test.sh

set -euo pipefail

# 抽出関数経由（遅延束縛）で参照される env / state 変数が shellcheck から未使用に見える対策。
# PR_REVIEWER_OOS_ENABLED / PR_REVIEWER_OOS_ROUTE_LABEL / REPO 等は抽出関数本体から参照される。
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/modules/adjudicator.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi

# 既存テストと同じ extract_function イディオム。
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
eval "$(extract_function "$ADJ_SH" "adj_oos_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_validate_decisions")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_extract_legitimate_count")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_extract_out_of_scope_count")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_route_out_of_scope")"

for fn in adj_oos_enabled adj_validate_decisions adj_extract_legitimate_count \
          adj_extract_out_of_scope_count adj_route_out_of_scope; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env / ロガー stub。
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"
# shellcheck disable=SC2034
PR_REVIEWER_OOS_ROUTE_LABEL="needs-decisions"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  expected NOT to contain: $(printf '%q' "$needle")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *) echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  esac
}

# ── stub state（routing 用）──
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  GH_EDIT_RC=0
  GH_COMMENT_RC=0
}
cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$LOG_LOG" "$WARN_LOG" 2>/dev/null || true
}

# adj_log / adj_warn stub。LOG_LOG / WARN_LOG が未初期化（純粋関数テスト時 = reset_stub_state
# 未呼び出し）の場合は /dev/null に逃がす（set -u 配下で unbound 参照エラーを避ける）。
# shellcheck disable=SC2317
adj_log()  { echo "$*" >>"${LOG_LOG:-/dev/null}"; }
# shellcheck disable=SC2317
adj_warn() { echo "$*" >>"${WARN_LOG:-/dev/null}"; }

# timeout stub: 秒数を捨てて残りを実行
# shellcheck disable=SC2317
timeout() { shift; "$@"; }

# gh stub: 痕跡を記録し edit/comment の rc をシナリオ別に切替
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "$2" in
    edit)    return "$GH_EDIT_RC" ;;
    comment) return "$GH_COMMENT_RC" ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# A. adj_oos_enabled gate 評価（既定 OFF / opt-in）
# ─────────────────────────────────────────────────────────────────────────────
PR_REVIEWER_OOS_ENABLED="false"
if adj_oos_enabled; then r="on"; else r="off"; fi
assert_eq "A.1 gate=false で OFF" "off" "$r"

unset PR_REVIEWER_OOS_ENABLED
if adj_oos_enabled; then r="on"; else r="off"; fi
assert_eq "A.2 gate 未設定で OFF（安全側既定）" "off" "$r"

PR_REVIEWER_OOS_ENABLED="true"
if adj_oos_enabled; then r="on"; else r="off"; fi
assert_eq "A.3 gate=true で ON" "on" "$r"

# ─────────────────────────────────────────────────────────────────────────────
# B. adj_validate_decisions gate-aware schema 検証
# ─────────────────────────────────────────────────────────────────────────────
FINDINGS_3='[{"severity":"high","file":"a.sh","line":1,"message":"x"},{"severity":"low","file":"b.sh","line":2,"message":"y"},{"severity":"medium","file":"c.sh","line":3,"message":"z"}]'

# 3 値 decisions（legitimate / excessive / legitimate-out-of-scope 各 1 件）
DEC_3VAL='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"legitimate","reason":"r1"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"excessive","reason":"r2"},
  {"id":3,"severity":"medium","file":"c.sh","line":3,"verdict":"legitimate-out-of-scope","reason":"design 確定事項と矛盾"}
],"summary":{"total":3,"legitimate":1,"excessive":1,"legitimate_out_of_scope":1}}'

# gate OFF（既定）: 3 値 decisions は schema 違反で reject（NFR 1.1 / 2 値厳格維持）
PR_REVIEWER_OOS_ENABLED="false"
if adj_validate_decisions "$FINDINGS_3" "$DEC_3VAL" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.1 gate OFF で 3 値 decisions を reject（NFR 1.1）" "1" "$rc"

# gate ON: 3 値 decisions は valid
PR_REVIEWER_OOS_ENABLED="true"
if adj_validate_decisions "$FINDINGS_3" "$DEC_3VAL" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.2 gate ON で 3 値 decisions を許容（Req 1.1）" "0" "$rc"

# gate ON でも不変条件破壊（legitimate+excessive+oos != total）は reject
DEC_BAD_SUM='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"legitimate","reason":"r1"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"excessive","reason":"r2"},
  {"id":3,"severity":"medium","file":"c.sh","line":3,"verdict":"legitimate-out-of-scope","reason":"r3"}
],"summary":{"total":3,"legitimate":2,"excessive":1,"legitimate_out_of_scope":1}}'
PR_REVIEWER_OOS_ENABLED="true"
if adj_validate_decisions "$FINDINGS_3" "$DEC_BAD_SUM" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.3 gate ON で 3 値不変条件破壊を reject（集計整合性）" "1" "$rc"

# gate OFF で 2 値 decisions（既存）は valid（NFR 1.3 後方互換）
FINDINGS_2='[{"severity":"high","file":"a.sh","line":1,"message":"x"},{"severity":"low","file":"b.sh","line":2,"message":"y"}]'
DEC_2VAL='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"legitimate","reason":"r1"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"excessive","reason":"r2"}
],"summary":{"total":2,"legitimate":1,"excessive":1}}'
PR_REVIEWER_OOS_ENABLED="false"
if adj_validate_decisions "$FINDINGS_2" "$DEC_2VAL" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.4 gate OFF で 2 値 decisions を許容（NFR 1.3）" "0" "$rc"

# gate ON でも 2 値 decisions（out-of-scope フィールド不在 = 0）は valid（後方互換）
PR_REVIEWER_OOS_ENABLED="true"
if adj_validate_decisions "$FINDINGS_2" "$DEC_2VAL" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.5 gate ON でも 2 値 decisions（oos フィールド不在）を許容" "0" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# C. 件数算出（out-of-scope 除外 / Req 1.3）
# ─────────────────────────────────────────────────────────────────────────────
legit=$(adj_extract_legitimate_count "$DEC_3VAL")
assert_eq "C.1 round 駆動 legitimate=1（out-of-scope 除外 / Req 1.3）" "1" "$legit"
oos=$(adj_extract_out_of_scope_count "$DEC_3VAL")
assert_eq "C.2 out-of-scope=1" "1" "$oos"
# 2 値 decisions では out-of-scope=0（フィールド不在）
oos2=$(adj_extract_out_of_scope_count "$DEC_2VAL")
assert_eq "C.3 2 値 decisions で out-of-scope=0" "0" "$oos2"

# ─────────────────────────────────────────────────────────────────────────────
# D. adj_route_out_of_scope（needs-decisions 還流 / iteration 継続 / 失敗安全側）
# ─────────────────────────────────────────────────────────────────────────────
PR_REVIEWER_OOS_ENABLED="true"
SHA="0123456789abcdef0123456789abcdef01234567"

# D.1 legitimate=0 かつ out-of-scope=1 → 還流ラベル付与 + 追跡コメント（Req 2.1 / 2.2 / 2.3）
reset_stub_state
adj_route_out_of_scope "42" "$SHA" "0" "1" "$DEC_3VAL" || true
gh_calls="$(cat "$GH_CALL_LOG")"
log_calls="$(cat "$LOG_LOG")"
assert_contains "D.1a 還流ラベル付与（gh pr edit --add-label needs-decisions / Req 2.1）" "$gh_calls" "--add-label needs-decisions"
assert_contains "D.1b 追跡コメント投稿（gh pr comment / Req 2.2）" "$gh_calls" "comment"
assert_contains "D.1c 還流ログ（route=needs-decisions / NFR 3.1）" "$log_calls" "route=needs-decisions"
cleanup_stub_state

# D.2 legitimate>=1 残存 → 還流ラベルを付与せず追跡コメントのみ（Req 2.4）
reset_stub_state
adj_route_out_of_scope "42" "$SHA" "2" "1" "$DEC_3VAL" || true
gh_calls="$(cat "$GH_CALL_LOG")"
log_calls="$(cat "$LOG_LOG")"
assert_not_contains "D.2a in-scope 残存で還流ラベル付与しない（Req 2.4）" "$gh_calls" "--add-label needs-decisions"
assert_contains "D.2b 追跡コメントは投稿する（Req 2.2）" "$gh_calls" "comment"
assert_contains "D.2c continue ログ（route=continue / Req 2.4）" "$log_calls" "route=continue"
cleanup_stub_state

# D.3 out-of-scope=0 → 何もしない（通常経路）
reset_stub_state
adj_route_out_of_scope "42" "$SHA" "1" "0" "$DEC_2VAL" || true
gh_calls="$(cat "$GH_CALL_LOG")"
assert_eq "D.3 out-of-scope=0 で gh 呼び出しゼロ（通常経路）" "" "$gh_calls"
cleanup_stub_state

# D.4 ラベル付与失敗 → silent fail せず WARN + rc=0（Req 2.5 / NFR 2.3）
reset_stub_state
GH_EDIT_RC=1
adj_route_out_of_scope "42" "$SHA" "0" "1" "$DEC_3VAL"; route_rc=$?
warn_calls="$(cat "$WARN_LOG")"
assert_eq "D.4a ラベル付与失敗でも rc=0（安全側 / Req 2.5）" "0" "$route_rc"
assert_contains "D.4b 失敗を WARN で記録（NFR 2.3 silent fail 禁止）" "$warn_calls" "付与失敗"
cleanup_stub_state

# D.5 gate OFF → 早期 return（防御的二重確認 / NFR 1.1）
reset_stub_state
# shellcheck disable=SC2034  # 抽出関数 adj_route_out_of_scope 経由（遅延束縛）で参照される
PR_REVIEWER_OOS_ENABLED="false"
adj_route_out_of_scope "42" "$SHA" "0" "1" "$DEC_3VAL" || true
gh_calls="$(cat "$GH_CALL_LOG")"
assert_eq "D.5 gate OFF で gh 呼び出しゼロ（NFR 1.1 no-op）" "" "$gh_calls"
cleanup_stub_state

echo ""
echo "==================================="
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
echo "==================================="
[ "$FAIL_COUNT" -eq 0 ]
