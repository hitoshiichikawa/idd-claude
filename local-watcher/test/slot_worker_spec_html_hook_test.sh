#!/usr/bin/env bash
# =============================================================================
# slot_worker_spec_html_hook_test.sh — spec-html call site 配線の統合テスト
#   (#526 / Task 3)
#
# slot-worker.sh `_slot_run_issue` の design / impl 完了直後に配線した
# `shx_run_for_spec_dir || true` hook を、実ソースからの構造検証 + call site 相当の
# 挙動再現で検証する:
#   (A) 構造検証（実 slot-worker.sh から）:
#       - design 分岐: `shx_run_for_spec_dir || true` が `tc_run_post_architect_check
#         || true` の **直後**にあり、`return 0` より前（Req 2.1, 4.1）
#       - impl 分岐: `shx_run_for_spec_dir || true` が `_impl_rc` の `0)` case 内、
#         `return 0` より前にある（Req 2.1, 4.1）
#   (B) 挙動再現（call site の `|| true` 非伝播不変条件）:
#       - gate ON 相当（hook 到達）で本流戻り値 0（対象生成がトリガされる）
#       - gate OFF 相当（hook が no-op return 0）で本流戻り値 0（Req 1.4）
#       - render 失敗（hook 非 0）が `|| true` で吸収され本流戻り値に伝播しない
#         （Req 3.4, 5.1, 5.3）
#
# 配置先: local-watcher/test/slot_worker_spec_html_hook_test.sh
# 実行:   bash local-watcher/test/slot_worker_spec_html_hook_test.sh
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

echo "=== (A) 構造検証: 実 slot-worker.sh の call site 配置 ==="

# design 分岐: tc_run_post_architect_check の直後に shx_run_for_spec_dir が来ているか。
# awk で「tc hook 行の次に現れる shx_run_for_spec_dir 呼び出し」までの間に他の実行行
# （コメント除く）が挟まっていないことを確認する。
DESIGN_ADJACENT="$(awk '
  /tc_run_post_architect_check \|\| true/ { seen_tc = 1; next }
  seen_tc {
    # コメント / 空行はスキップ
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (line == "" || line ~ /^#/) next
    if (line ~ /^shx_run_for_spec_dir \|\| true/) { print "adjacent"; exit }
    print "other:" line; exit
  }
' "$SLOT")"
assert_eq "design: shx hook が tc hook の直後" "adjacent" "$DESIGN_ADJACENT"

# impl 分岐: `_impl_rc` の case で `0)` ブロック内、`return 0` より前に
# shx_run_for_spec_dir が来ているか。`run_impl_pipeline` 以降の最初の `0)` case を対象にする。
# return / hook の照合は行頭アンカー（`^[[:space:]]*`）で「文」のみを対象にし、
# コメント中の "return 0" 等の語（本 hook のコメントにも登場する）に誤反応しない。
IMPL_ORDER="$(awk '
  /run_impl_pipeline \|\| _impl_rc=/ { in_impl = 1 }
  in_impl && /^[[:space:]]*0\)/ { in_case = 1; next }
  in_case && /^[[:space:]]*shx_run_for_spec_dir \|\| true/ { print "hook-before-return"; exit }
  in_case && /^[[:space:]]*return 0/ { print "return-before-hook"; exit }
' "$SLOT")"
assert_eq "impl: shx hook が return 0 より前" "hook-before-return" "$IMPL_ORDER"

# 両 call site とも `|| true` 付きであること（fail-open / Req 5.3）
HOOK_COUNT="$(grep -c 'shx_run_for_spec_dir || true' "$SLOT" || true)"
assert_eq "call site は 2 箇所（design / impl）" "2" "$HOOK_COUNT"
# `|| true` を欠いた裸の呼び出しが無いこと（総出現数 = `|| true` 付き数）
TOTAL_CALLS="$(grep -cE '^[[:space:]]*shx_run_for_spec_dir' "$SLOT" || true)"
assert_eq "裸の shx_run_for_spec_dir 呼び出しなし（総数=guarded 数）" "$HOOK_COUNT" "$TOTAL_CALLS"

echo "=== (B) 挙動再現: call site の |1 true 非伝播不変条件 ==="

# design 段 tail の 2 行（実 call site と同一）を、hook を stub 化して再現する。
# tc/shx の戻り値を変えても本流（return 0）は不変であることを検証する。
run_design_tail() {
  # $1 = tc rc / $2 = shx rc
  local tc_rc="$1" shx_rc="$2"
  tc_run_post_architect_check() { echo "tc-reached"; return "$tc_rc"; }
  shx_run_for_spec_dir() { echo "shx-reached"; return "$shx_rc"; }
  # ↓ 実 slot-worker.sh design 分岐 rc=0 case tail と同一シーケンス
  tc_run_post_architect_check || true
  shx_run_for_spec_dir || true
  return 0
}
assert_rc "design tail: 全成功で return 0"          0 run_design_tail 0 0
assert_rc "design tail: shx 失敗でも return 0"      0 run_design_tail 0 1
assert_rc "design tail: tc+shx 失敗でも return 0"    0 run_design_tail 1 1
# hook が実際に到達している（gate ON でトリガされる）ことを stdout で確認
DTAIL_OUT="$(run_design_tail 0 0)"
assert_contains "design tail: shx hook 到達" "$DTAIL_OUT" "shx-reached"

# impl 段 0) case 相当（slot_log の後に shx hook、その後 return 0）を再現する。
run_impl_case() {
  # $1 = shx rc（gate OFF は 0 no-op / render 失敗は 非 0）
  local shx_rc="$1"
  slot_log() { :; }
  shx_run_for_spec_dir() { echo "shx-reached"; return "$shx_rc"; }
  # ↓ 実 impl 分岐 0) case と同一シーケンス
  slot_log "完了"
  shx_run_for_spec_dir || true
  return 0
}
assert_rc "impl case: gate OFF/成功で return 0"     0 run_impl_case 0
assert_rc "impl case: render 失敗でも return 0"     0 run_impl_case 1
ICASE_OUT="$(run_impl_case 0)"
assert_contains "impl case: shx hook 到達" "$ICASE_OUT" "shx-reached"

echo ""
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
