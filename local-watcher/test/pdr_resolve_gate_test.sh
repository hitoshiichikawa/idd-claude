#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の opt-in gate / env Config 安全側正規化を検証する
#       スモークテスト。
#
#       検証する受入基準（docs/specs/432-fix-watcher-design-reviewer-407-opt-in-o/requirements.md）:
#         - Req 1.1〜1.5 opt-out gate（#432 で既定 ON へ反転 / `=false` 厳密一致のみ OFF /
#           それ以外は安全側＝有効に正規化）
#         - Req 3.3 既存 env 名 / 意味の不変性（本 test は DESIGN_REVIEWER_ENABLED のみを扱う）
#         - Req 6.1 / 6.2 既存 exit code・ログ stderr/stdout 契約の不変性（pdr_gate_enabled は
#           副作用なし）
#
#       前提: `DESIGN_REVIEWER_ENABLED` は issue-watcher.sh の Config ブロックで既に
#             `case false) ... *) true` で正規化済みである（#432 既定 ON）。本テストでは
#               (a) Config ブロックの正規化挙動を直接シミュレート（adj 既存テストと同形式）
#               (b) `pr-design-reviewer.sh` 配下の `pdr_gate_enabled` 関数を
#                   `extract_function` で抽出し、正規化済み env を厳密 `=true` 一致で
#                   ON 判定することを検証する。
#
# 配置先: local-watcher/test/pdr_resolve_gate_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pdr_resolve_gate_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"

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

# ─── (a) Config ブロックの正規化挙動を直接シミュレート（#432 既定 ON / opt-out） ─────────
# issue-watcher.sh の Config ブロックと同じ `case false) :;; *) true` パターンで安全側正規化が
# 「false 厳密一致のみ false、それ以外すべて true」になることを検査する。`${VAR:-true}` による
# 既定 ON 展開（未設定 / 空文字 → true）も併せて検証する。
#
#   入力: $1 = 生の env 値（空文字は ""）
#         $2 = "set" or "unset"（unset 状態を再現するため）
normalize_design_reviewer_enabled() {
  local raw="${1:-}"
  local mode="${2:-set}"
  local v
  if [ "$mode" = "unset" ]; then
    # `${VAR:-true}` 相当: 未設定は既定 true
    v="true"
  elif [ -z "$raw" ]; then
    # 空文字も `${VAR:-true}` で既定 true に展開される（bash の `:-` 仕様）
    v="true"
  else
    v="$raw"
  fi
  case "$v" in
    false) printf '%s' "false" ;;
    *)     printf '%s' "true" ;;
  esac
}

echo "--- (a) Config ブロックの正規化挙動シミュレーション（#432 既定 ON / opt-out / Req 1.1〜1.5） ---"
assert_eq "Req 1.1: 未設定 → true (default ON)" "true" "$(normalize_design_reviewer_enabled "" "unset")"
assert_eq "Req 1.2: 空文字 → true (default ON)" "true" "$(normalize_design_reviewer_enabled "" "set")"
assert_eq "Req 1.3: 'true' 明示 → true" "true" "$(normalize_design_reviewer_enabled "true" "set")"
assert_eq "Req 1.4: 'false' 明示 → false (opt-out)" "false" "$(normalize_design_reviewer_enabled "false" "set")"
assert_eq "Req 1.5 安全側: 'True' 大文字違い → true" "true" "$(normalize_design_reviewer_enabled "True" "set")"
assert_eq "Req 1.5 安全側: 'FALSE' 全大文字 → true (NOT a valid OFF value)" "true" "$(normalize_design_reviewer_enabled "FALSE" "set")"
assert_eq "Req 1.5 安全側: typo 'flase' → true" "true" "$(normalize_design_reviewer_enabled "flase" "set")"
assert_eq "Req 1.5 安全側: 数値風 '1' → true" "true" "$(normalize_design_reviewer_enabled "1" "set")"
assert_eq "Req 1.5 安全側: 数値風 '0' → true (NOT a valid OFF value)" "true" "$(normalize_design_reviewer_enabled "0" "set")"
assert_eq "Req 1.5 安全側: 'on' → true" "true" "$(normalize_design_reviewer_enabled "on" "set")"
assert_eq "Req 1.5 安全側: 別 alias 'enabled' → true" "true" "$(normalize_design_reviewer_enabled "enabled" "set")"

# ─── (b) pdr_gate_enabled 関数の抽出テスト ─────────────────────────────────────
# pr-design-reviewer.sh が存在する場合のみ実行。
#
# 重要な契約（#432 既定 ON 後も不変）: pdr_gate_enabled は **正規化を行わず** 厳密 `=true`
# 一致のみで ON を返す。正規化（`=false` のみ OFF・それ以外 true）は Config ブロックの責務。
# 本関数の防御的 default は `${DESIGN_REVIEWER_ENABLED:-true}` のため、unset は ON になる。
# したがって本テストでは「正規化前の生 env を直接渡した場合の pdr_gate_enabled の素の挙動」を
# 検証する（Config を経た正規化済み値の ON/OFF は (a) と pdr_no_op_test.sh が担保する）。
if [ -f "$PDR_SH" ]; then
  echo ""
  echo "--- (b) pdr_gate_enabled 関数の厳密一致判定（#432 既定 ON / 防御的 default :-true） ---"

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
  eval "$(extract_function "$PDR_SH" "pdr_gate_enabled")"

  if ! declare -F pdr_gate_enabled >/dev/null; then
    echo "FAIL: pdr_gate_enabled not loaded from $PDR_SH"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    # 正規化済み値 = "true"（Config 通過後）→ ON
    # shellcheck disable=SC2034
    export DESIGN_REVIEWER_ENABLED="true"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 1.3: DESIGN_REVIEWER_ENABLED=true (正規化済み) は ON (rc=0)" "0" "$rc"

    # 正規化済み値 = "false"（Config 通過後の唯一の OFF 値）→ OFF
    export DESIGN_REVIEWER_ENABLED="false"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 1.4: DESIGN_REVIEWER_ENABLED=false (正規化済み opt-out) は OFF (rc=1)" "1" "$rc"

    # 防御的 default `:-true`: unset は ON（Config が常に先に正規化するが、念のため fail-safe ON）
    unset DESIGN_REVIEWER_ENABLED
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 1.1: DESIGN_REVIEWER_ENABLED unset は防御的 default で ON (rc=0)" "0" "$rc"

    # 厳密一致契約（正規化されていない非空の生値は ON にならない / 重複正規化はしない）
    export DESIGN_REVIEWER_ENABLED="True"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "契約: 未正規化の 'True' を渡すと厳密一致せず OFF (rc=1)" "1" "$rc"

    # 防御的 default `:-true`: 空文字は bash の `:-` 仕様で既定 true に展開され ON
    # （Config が常に先に正規化するが、export 済み空文字でも fail-safe ON / Req 1.2 と整合）
    export DESIGN_REVIEWER_ENABLED=""
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 1.2: 空文字は防御的 default で ON (rc=0)" "0" "$rc"
  fi
else
  echo ""
  echo "--- (b) pdr_gate_enabled 関数は module 未作成のため skip ---"
fi

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
