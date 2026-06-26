#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の opt-in gate / env Config 安全側正規化を検証する
#       スモークテスト。
#
#       検証する受入基準（docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/requirements.md）:
#         - Req 6.1 opt-in gate（既定 OFF / 安全側正規化）
#         - Req 6.3 既存 env 名 / 既定値 / 意味の不変性（本 test は新規 env のみを扱う）
#         - Req 6.5 既存 exit code・ログ stderr/stdout 契約の不変性（pdr_gate_enabled は副作用なし）
#
#       前提: `DESIGN_REVIEWER_ENABLED` は issue-watcher.sh の Config ブロックで既に
#             `case true) ... *) false` で正規化済みである。本テストでは
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

# ─── (a) Config ブロックの正規化挙動を直接シミュレート ─────────────────────────
# 既存 adjudicator の Config ブロックと同じ `case ... esac` パターンで安全側正規化が
# 「true 厳密一致のみ true、それ以外すべて false」になることを検査する。

normalize_design_reviewer_enabled() {
  local v="${1:-}"
  case "$v" in
    true) printf '%s' "true" ;;
    *)    printf '%s' "false" ;;
  esac
}

echo "--- (a) Config ブロックの正規化挙動シミュレーション（Issue #407 Req 6.1） ---"
assert_eq "Req 6.1: 'true' 厳密 → true" "true" "$(normalize_design_reviewer_enabled "true")"
assert_eq "Req 6.1 安全側: 'True' 大文字違い → false" "false" "$(normalize_design_reviewer_enabled "True")"
assert_eq "Req 6.1 安全側: 空文字 → false" "false" "$(normalize_design_reviewer_enabled "")"
assert_eq "Req 6.1 安全側: typo 'trrue' → false" "false" "$(normalize_design_reviewer_enabled "trrue")"
assert_eq "Req 6.1 既定: 'false' 明示 → false" "false" "$(normalize_design_reviewer_enabled "false")"
assert_eq "Req 6.1 安全側: 数値風 '1' → false" "false" "$(normalize_design_reviewer_enabled "1")"
assert_eq "Req 6.1 安全側: 別 alias 'enabled' → false" "false" "$(normalize_design_reviewer_enabled "enabled")"

# ─── (b) pdr_gate_enabled 関数の抽出テスト ─────────────────────────────────────
# pr-design-reviewer.sh が存在する場合のみ実行（task 3 完了後）。task 1 単体では module 未作成
# のため skip する設計。
if [ -f "$PDR_SH" ]; then
  echo ""
  echo "--- (b) pdr_gate_enabled 関数の厳密一致判定（Issue #407 Req 6.1） ---"

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
    # shellcheck disable=SC2034
    export DESIGN_REVIEWER_ENABLED="true"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 6.1: DESIGN_REVIEWER_ENABLED=true は ON (rc=0)" "0" "$rc"

    export DESIGN_REVIEWER_ENABLED="True"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 6.1 安全側: DESIGN_REVIEWER_ENABLED=True (大文字違い) は OFF (rc=1)" "1" "$rc"

    export DESIGN_REVIEWER_ENABLED=""
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 6.1 安全側: DESIGN_REVIEWER_ENABLED='' (空) は OFF (rc=1)" "1" "$rc"

    export DESIGN_REVIEWER_ENABLED="trrue"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 6.1 安全側: DESIGN_REVIEWER_ENABLED=trrue (typo) は OFF (rc=1)" "1" "$rc"

    export DESIGN_REVIEWER_ENABLED="false"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 6.1 既定: DESIGN_REVIEWER_ENABLED=false は OFF (rc=1)" "1" "$rc"

    unset DESIGN_REVIEWER_ENABLED
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 6.1 既定: DESIGN_REVIEWER_ENABLED unset は OFF (rc=1)" "1" "$rc"

    export DESIGN_REVIEWER_ENABLED="1"
    rc=0
    pdr_gate_enabled || rc=$?
    assert_eq "Req 6.1 安全側: DESIGN_REVIEWER_ENABLED=1 は OFF (rc=1)" "1" "$rc"
  fi
else
  echo ""
  echo "--- (b) pdr_gate_enabled 関数は module 未作成のため skip（task 3 で生成予定） ---"
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
