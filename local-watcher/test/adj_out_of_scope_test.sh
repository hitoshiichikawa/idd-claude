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
#         - adj_route_out_of_scope        (共通ヘルパ pi_route_out_of_scope_escalate への委譲判定)
#
#       検証する受入基準（docs/specs/437-pr-iteration-pr-design-spec-max-rounds/requirements.md）:
#         - Req 1.1 gate ON で verdict 3 値 (legitimate|excessive|out-of-scope) を許容
#         - Req 1.3 out-of-scope を round 駆動 legitimate 件数から除外
#         - Req 3.1 legitimate=0 かつ out-of-scope≥1 で共通ヘルパへ委譲（還流ルーティング）
#         - Req 2.4 legitimate≥1 残存時は委譲せず iteration 継続（route=continue ログ）
#         - NFR 3.3 無効な PR 番号 / sha は WARN + rc=2（入力検証）
#         - NFR 1.1 gate OFF（既定）で 3 値 decisions を schema 違反として弾く（2 値厳格維持）
#         - NFR 1.3 gate OFF で legitimate+excessive==total 不変条件を維持
#
# 配置先: local-watcher/test/adj_out_of_scope_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/adj_out_of_scope_test.sh

set -euo pipefail

# 抽出関数経由（遅延束縛）で参照される env / state 変数が shellcheck から未使用に見える対策。
# PR_ITERATION_OOS_ENABLED / PR_REVIEWER_OOS_ROUTE_LABEL / REPO 等は抽出関数本体から参照される。
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
# #437 refactor（commit 986f1ec）以降、adj_route_out_of_scope は gh を直接叩かず、
# ルーティング副作用（ラベル付与 / コメント / 冪等 marker）は共通ヘルパ
# pi_route_out_of_scope_escalate に集約された（design.md Components and Interfaces）。
# 本テストは adj 層の「委譲判定」（委譲する / continue する / no-op する）を検証し、
# 副作用本体（gh 呼び出し / WARN）は pr_iteration_oos_routing_test.sh 側で検証する。
reset_stub_state() {
  LOG_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  PI_CALL_LOG="$(mktemp)"
}
cleanup_stub_state() {
  rm -f "$LOG_LOG" "$WARN_LOG" "$PI_CALL_LOG" 2>/dev/null || true
}

# adj_log / adj_warn stub。LOG_LOG / WARN_LOG が未初期化（純粋関数テスト時 = reset_stub_state
# 未呼び出し）の場合は /dev/null に逃がす（set -u 配下で unbound 参照エラーを避ける）。
# shellcheck disable=SC2317
adj_log()  { echo "$*" >>"${LOG_LOG:-/dev/null}"; }
# shellcheck disable=SC2317
adj_warn() { echo "$*" >>"${WARN_LOG:-/dev/null}"; }

# pi_route_out_of_scope_escalate stub: 委譲されたか（＝呼び出し引数）を記録するだけ。
# 実体（副作用）は pr-iteration.sh 側にあり、本テストの対象外。
# shellcheck disable=SC2317
pi_route_out_of_scope_escalate() {
  echo "pi_route $*" >>"${PI_CALL_LOG:-/dev/null}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# A. adj_oos_enabled gate 評価（既定 OFF / opt-in）
# ─────────────────────────────────────────────────────────────────────────────
PR_ITERATION_OOS_ENABLED="false"
if adj_oos_enabled; then r="on"; else r="off"; fi
assert_eq "A.1 gate=false で OFF" "off" "$r"

unset PR_ITERATION_OOS_ENABLED
if adj_oos_enabled; then r="on"; else r="off"; fi
assert_eq "A.2 gate 未設定で OFF（安全側既定）" "off" "$r"

PR_ITERATION_OOS_ENABLED="true"
if adj_oos_enabled; then r="on"; else r="off"; fi
assert_eq "A.3 gate=true で ON" "on" "$r"

# ─────────────────────────────────────────────────────────────────────────────
# B. adj_validate_decisions gate-aware schema 検証
# ─────────────────────────────────────────────────────────────────────────────
FINDINGS_3='[{"severity":"high","file":"a.sh","line":1,"message":"x"},{"severity":"low","file":"b.sh","line":2,"message":"y"},{"severity":"medium","file":"c.sh","line":3,"message":"z"}]'

# 3 値 decisions（legitimate / excessive / out-of-scope 各 1 件）
DEC_3VAL='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"legitimate","reason":"r1"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"excessive","reason":"r2"},
  {"id":3,"severity":"medium","file":"c.sh","line":3,"verdict":"out-of-scope","reason":"design 確定事項と矛盾"}
],"summary":{"total":3,"legitimate":1,"excessive":1,"out_of_scope":1}}'

# gate OFF（既定）: 3 値 decisions は schema 違反で reject（NFR 1.1 / 2 値厳格維持）
PR_ITERATION_OOS_ENABLED="false"
if adj_validate_decisions "$FINDINGS_3" "$DEC_3VAL" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.1 gate OFF で 3 値 decisions を reject（NFR 1.1）" "1" "$rc"

# gate ON: 3 値 decisions は valid
PR_ITERATION_OOS_ENABLED="true"
if adj_validate_decisions "$FINDINGS_3" "$DEC_3VAL" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.2 gate ON で 3 値 decisions を許容（Req 1.1）" "0" "$rc"

# gate ON でも不変条件破壊（legitimate+excessive+oos != total）は reject
DEC_BAD_SUM='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"legitimate","reason":"r1"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"excessive","reason":"r2"},
  {"id":3,"severity":"medium","file":"c.sh","line":3,"verdict":"out-of-scope","reason":"r3"}
],"summary":{"total":3,"legitimate":2,"excessive":1,"out_of_scope":1}}'
PR_ITERATION_OOS_ENABLED="true"
if adj_validate_decisions "$FINDINGS_3" "$DEC_BAD_SUM" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.3 gate ON で 3 値不変条件破壊を reject（集計整合性）" "1" "$rc"

# gate OFF で 2 値 decisions（既存）は valid（NFR 1.3 後方互換）
FINDINGS_2='[{"severity":"high","file":"a.sh","line":1,"message":"x"},{"severity":"low","file":"b.sh","line":2,"message":"y"}]'
DEC_2VAL='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"legitimate","reason":"r1"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"excessive","reason":"r2"}
],"summary":{"total":2,"legitimate":1,"excessive":1}}'
PR_ITERATION_OOS_ENABLED="false"
if adj_validate_decisions "$FINDINGS_2" "$DEC_2VAL" 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "B.4 gate OFF で 2 値 decisions を許容（NFR 1.3）" "0" "$rc"

# gate ON でも 2 値 decisions（out-of-scope フィールド不在 = 0）は valid（後方互換）
PR_ITERATION_OOS_ENABLED="true"
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
# D. adj_route_out_of_scope（委譲判定 / iteration 継続 / no-op / 入力検証）
#    refactor 後は共通ヘルパ pi_route_out_of_scope_escalate への委譲判定のみを担う。
#    副作用本体（ラベル付与 / コメント / 失敗時 WARN）は pr_iteration_oos_routing_test.sh で検証。
# ─────────────────────────────────────────────────────────────────────────────
PR_ITERATION_OOS_ENABLED="true"
SHA="0123456789abcdef0123456789abcdef01234567"

# D.1 legitimate=0 かつ out-of-scope=1 → 共通ヘルパへ委譲（Req 3.1）
reset_stub_state
adj_route_out_of_scope "42" "$SHA" "0" "1" "$DEC_3VAL" || true
pi_calls="$(cat "$PI_CALL_LOG")"
assert_contains "D.1a 共通ヘルパへ委譲（pi_route_out_of_scope_escalate / Req 3.1）" "$pi_calls" "pi_route 42 $SHA"
assert_contains "D.1b 委譲時に source=adjudicator を渡す" "$pi_calls" "adjudicator"
cleanup_stub_state

# D.2 legitimate>=1 残存 → 委譲せず route=continue ログ（Req 2.4）
reset_stub_state
adj_route_out_of_scope "42" "$SHA" "2" "1" "$DEC_3VAL" || true
pi_calls="$(cat "$PI_CALL_LOG")"
log_calls="$(cat "$LOG_LOG")"
assert_eq "D.2a in-scope 残存で委譲しない（Req 2.4）" "" "$pi_calls"
assert_contains "D.2b continue ログ（route=continue / Req 2.4）" "$log_calls" "route=continue"
cleanup_stub_state

# D.3 out-of-scope=0 → 何もしない（通常経路 / 委譲なし）
reset_stub_state
adj_route_out_of_scope "42" "$SHA" "1" "0" "$DEC_2VAL" || true
pi_calls="$(cat "$PI_CALL_LOG")"
assert_eq "D.3 out-of-scope=0 で委譲ゼロ（通常経路）" "" "$pi_calls"
cleanup_stub_state

# D.4 無効な PR 番号 / sha → silent fail せず WARN + rc=2（NFR 3.3 入力検証）
reset_stub_state
route_rc=0
adj_route_out_of_scope "not-a-number" "$SHA" "0" "1" "$DEC_3VAL" || route_rc=$?
warn_calls="$(cat "$WARN_LOG")"
pi_calls="$(cat "$PI_CALL_LOG")"
assert_eq "D.4a 無効 PR 番号で rc=2（入力検証 / NFR 3.3）" "2" "$route_rc"
assert_contains "D.4b 無効 PR 番号を WARN で記録（silent fail 禁止）" "$warn_calls" "無効な PR 番号"
assert_eq "D.4c 検証失敗時は委譲しない" "" "$pi_calls"
cleanup_stub_state

# D.5 gate OFF → 早期 return（防御的二重確認 / NFR 1.1 / 委譲なし）
reset_stub_state
# shellcheck disable=SC2034  # 抽出関数 adj_route_out_of_scope 経由（遅延束縛）で参照される
PR_ITERATION_OOS_ENABLED="false"
adj_route_out_of_scope "42" "$SHA" "0" "1" "$DEC_3VAL" || true
pi_calls="$(cat "$PI_CALL_LOG")"
assert_eq "D.5 gate OFF で委譲ゼロ（NFR 1.1 no-op）" "" "$pi_calls"
cleanup_stub_state

echo ""
echo "==================================="
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
echo "==================================="
[ "$FAIL_COUNT" -eq 0 ]
