#!/usr/bin/env bash
#
# 用途: PR Iteration out-of-scope 第 3 判定 (#437) の Developer マーカー検出 /
#       内容ベース no-progress 判定（fingerprint / streak）関数群のスモークテスト。
#       いずれも純粋関数（副作用なし）のため extract_function 隔離 + 入出力 fixture で検証する。
#
#       対象関数:
#         - pi_detect_developer_oos_marker   (Developer 応答ログの OUT-OF-SCOPE マーカー検出)
#         - pi_oos_fingerprint               (out-of-scope 指摘内容ハッシュ / SHA 非依存)
#         - pi_read_oos_no_progress_streak   (PR body marker から streak 読み取り)
#         - pi_read_oos_fingerprint          (PR body marker から fingerprint 読み取り)
#         - pi_next_oos_no_progress_streak   (fingerprint 同一で +1 / 変化で 0 リセット)
#
#       検証する受入基準（docs/specs/437-pr-iteration-pr-design-spec-max-rounds/requirements.md）:
#         - Req 4.2 / 4.5  厳密書式 OUT-OF-SCOPE: (design|spec-stale) のみ検出、語彙外/不在は空（安全側）
#         - Req 5.1        fingerprint 同一が連続したら streak を加算
#         - Req 5.3        streak は head commit SHA に依存せず内容 fingerprint で加算
#         - Req 5.5        指摘内容が実質変化したら fingerprint が変わり streak を 0 リセット
#         - NFR 1.3        既存 marker（oos キー無し）は streak=0 / fingerprint 空（後方互換）
#         - NFR 3.1 / 3.2  read-only / fail-safe（ログ不在・不能は空返し）
#
# 配置先: local-watcher/test/pr_iteration_oos_no_progress_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/pr_iteration_oos_no_progress_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# extract_function / assert_eq / assert_contains / assert_rc を共有ライブラリから source（#474）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration-oos.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration-oos.sh at $PR_ITERATION_SH" >&2
  exit 2
fi

for fn in pi_detect_developer_oos_marker pi_oos_fingerprint \
          pi_read_oos_no_progress_streak pi_read_oos_fingerprint \
          pi_next_oos_no_progress_streak; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$PR_ITERATION_SH" "$fn")"
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

assert_ne() {
  local label="$1" a="$2" b="$3"
  if [ "$a" != "$b" ]; then
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected different, both = $(printf '%q' "$a")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# A. pi_detect_developer_oos_marker（Developer 応答ログからの厳密書式検出 / fail-safe）
# ─────────────────────────────────────────────────────────────────────────────
LOG_DESIGN="$(mktemp)"
printf '前置きテキスト\nOUT-OF-SCOPE: design\n後続テキスト\n' >"$LOG_DESIGN"
assert_eq "A.1 design マーカーを検出（Req 4.2）" "design" "$(pi_detect_developer_oos_marker "$LOG_DESIGN")"

LOG_SPEC="$(mktemp)"
printf 'OUT-OF-SCOPE: spec-stale\n' >"$LOG_SPEC"
assert_eq "A.2 spec-stale マーカーを検出（Req 4.2）" "spec-stale" "$(pi_detect_developer_oos_marker "$LOG_SPEC")"

LOG_VOCAB="$(mktemp)"
printf 'OUT-OF-SCOPE: foo\n' >"$LOG_VOCAB"
assert_eq "A.3 語彙集合外（foo）は空返し（安全側 / Req 4.5）" "" "$(pi_detect_developer_oos_marker "$LOG_VOCAB")"

LOG_NONE="$(mktemp)"
printf '通常の応答本文。マーカーなし。\n' >"$LOG_NONE"
assert_eq "A.4 マーカー不在は空返し（Req 4.5）" "" "$(pi_detect_developer_oos_marker "$LOG_NONE")"

LOG_INLINE="$(mktemp)"
printf 'これは OUT-OF-SCOPE: design ではなく行中言及\n' >"$LOG_INLINE"
assert_eq "A.5 行頭一致でない言及は検出しない（厳密書式）" "" "$(pi_detect_developer_oos_marker "$LOG_INLINE")"

assert_eq "A.6 ログファイル不在は空返し（fail-safe / NFR 3.1）" "" "$(pi_detect_developer_oos_marker "/nonexistent/path/xyz")"
assert_eq "A.7 引数空は空返し（fail-safe）" "" "$(pi_detect_developer_oos_marker "")"

LOG_DASH="$(mktemp)"
printf -- '--not-an-option OUT-OF-SCOPE: design\nOUT-OF-SCOPE: design\n' >"$LOG_DASH"
assert_eq "A.8 '-' 始まり行を含んでも安全に検出（grep -- / NFR 3.2）" "design" "$(pi_detect_developer_oos_marker "$LOG_DASH")"

rm -f "$LOG_DESIGN" "$LOG_SPEC" "$LOG_VOCAB" "$LOG_NONE" "$LOG_INLINE" "$LOG_DASH" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# B. pi_oos_fingerprint（内容ハッシュ / SHA 非依存 / 順序非依存）
# ─────────────────────────────────────────────────────────────────────────────
DEC_A='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"out-of-scope","message":"矛盾X"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"out-of-scope","message":"矛盾Y"}
],"summary":{"total":2,"legitimate":0,"excessive":0,"out_of_scope":2}}'
# DEC_A と同内容だが decisions 順序が逆（順序非依存を検証）
DEC_A_REORDER='{"decisions":[
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"out-of-scope","message":"矛盾Y"},
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"out-of-scope","message":"矛盾X"}
],"summary":{"total":2,"legitimate":0,"excessive":0,"out_of_scope":2}}'
# DEC_B は message が変化（内容実質変化）
DEC_B='{"decisions":[
  {"id":1,"severity":"high","file":"a.sh","line":1,"verdict":"out-of-scope","message":"矛盾Z(別内容)"},
  {"id":2,"severity":"low","file":"b.sh","line":2,"verdict":"out-of-scope","message":"矛盾Y"}
],"summary":{"total":2,"legitimate":0,"excessive":0,"out_of_scope":2}}'

FP_A=$(pi_oos_fingerprint "$DEC_A")
FP_A2=$(pi_oos_fingerprint "$DEC_A")
FP_A_RE=$(pi_oos_fingerprint "$DEC_A_REORDER")
FP_B=$(pi_oos_fingerprint "$DEC_B")
assert_eq "B.1 同一内容で同一 fingerprint（決定的 / Req 5.3）" "$FP_A" "$FP_A2"
assert_eq "B.2 decisions 順序が違っても同一 fingerprint（順序非依存）" "$FP_A" "$FP_A_RE"
assert_ne "B.3 message が変化すると別 fingerprint（Req 5.5）" "$FP_A" "$FP_B"
# out-of-scope が無い / 空入力でも安定した値を返す（クラッシュしない）
FP_EMPTY1=$(pi_oos_fingerprint "")
FP_EMPTY2=$(pi_oos_fingerprint "")
assert_eq "B.4 空入力でも安定 fingerprint（決定的 / 非空）" "$FP_EMPTY1" "$FP_EMPTY2"

# ─────────────────────────────────────────────────────────────────────────────
# C. pi_read_oos_no_progress_streak / pi_read_oos_fingerprint（marker 読み取り）
# ─────────────────────────────────────────────────────────────────────────────
BODY_OOS='本文
<!-- idd-claude:pr-iteration round=3 last-run=2026-07-01T00:00:00Z no-progress-streak=1 oos-no-progress-streak=2 oos-fingerprint=deadbeef -->'
assert_eq "C.1 oos-no-progress-streak を読み取る" "2" "$(pi_read_oos_no_progress_streak "$BODY_OOS")"
assert_eq "C.2 oos-fingerprint を読み取る" "deadbeef" "$(pi_read_oos_fingerprint "$BODY_OOS")"

# 既存 marker（oos キー無し）は後方互換で 0 / 空（NFR 1.3）
BODY_LEGACY='本文
<!-- idd-claude:pr-iteration round=2 last-run=2026-07-01T00:00:00Z no-progress-streak=1 -->'
assert_eq "C.3 既存 marker（oos キー無し）は streak=0（NFR 1.3）" "0" "$(pi_read_oos_no_progress_streak "$BODY_LEGACY")"
assert_eq "C.4 既存 marker（oos キー無し）は fingerprint 空（NFR 1.3）" "" "$(pi_read_oos_fingerprint "$BODY_LEGACY")"

assert_eq "C.5 marker 不在は streak=0" "0" "$(pi_read_oos_no_progress_streak "marker なし本文")"
assert_eq "C.6 空 body は streak=0" "0" "$(pi_read_oos_no_progress_streak "")"

# ─────────────────────────────────────────────────────────────────────────────
# D. pi_next_oos_no_progress_streak（fingerprint 同一で +1 / 変化で 0 リセット）
# ─────────────────────────────────────────────────────────────────────────────
assert_eq "D.1 fingerprint 同一で +1（Req 5.1）" "3" "$(pi_next_oos_no_progress_streak "abc" "abc" "2")"
assert_eq "D.2 fingerprint 変化で 0 リセット（Req 5.5）" "0" "$(pi_next_oos_no_progress_streak "abc" "xyz" "2")"
assert_eq "D.3 prev fingerprint 空は 0（初回 round / 安全側）" "0" "$(pi_next_oos_no_progress_streak "" "abc" "2")"
assert_eq "D.4 current fingerprint 空は 0（取得失敗 / 安全側）" "0" "$(pi_next_oos_no_progress_streak "abc" "" "2")"
assert_eq "D.5 prev_streak 非数値は 1 に丸める（同一 fingerprint 時）" "1" "$(pi_next_oos_no_progress_streak "abc" "abc" "notnum")"

echo ""
echo "==================================="
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
echo "==================================="
[ "$FAIL_COUNT" -eq 0 ]
