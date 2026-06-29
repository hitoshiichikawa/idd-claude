#!/usr/bin/env bash
#
# 用途: Issue #432 で実施した `DESIGN_REVIEWER_ENABLED` の既定反転
#       （opt-in / 既定 OFF → opt-out / 既定 ON）の値正規化挙動を検証するスモークテスト。
#
#       検証する受入基準（docs/specs/432-fix-watcher-design-reviewer-407-opt-in-o/requirements.md）:
#         - Req 1.1 未設定で ON に正規化される
#         - Req 1.2 空文字で ON に正規化される
#         - Req 1.3 =true で ON のまま
#         - Req 1.4 =false で OFF（opt-out 明示は不変）
#         - Req 1.5 =True / =FALSE / =0 / =1 / =on / typo はすべて ON に正規化される
#         - Req 3.1 / NFR 1.1 `=false` を明示した既存 cron / launchd 環境は本変更前と等価で OFF
#         - Req 6.3 値正規化を近接テスト（入出力テーブル）で確認できる
#
# 配置先: local-watcher/test/pdr_default_on_test.sh
# 依存:   bash 4+
# 実行:   bash local-watcher/test/pdr_default_on_test.sh
#
# 検証手段:
#   issue-watcher.sh 本体トップレベルの `case` 文 + 「デフォルト有効化フラグの値正規化」
#   ループによる 2 段正規化を本テスト内に等価コピーした関数を作り、各 env 値で
#   resolve した結果を直接観測する（issue-watcher.sh 本体は大量の startup 依存物を抱えて
#   いるため source できない / 既存 #412 normalize 系テストと同じイディオム）。
#
#   本テストは正規化 **コード本体の挙動** を AC レベルで検証する。issue-watcher.sh 本体の
#   case / ループに差分が入った際は、本テスト内のコピー側も同期させること
#   （rule↔harness mirror の規律 / CLAUDE.md「機能追加ガイドライン §4」）。

set -euo pipefail

# shellcheck disable=SC2034

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

# normalize_design_reviewer_enabled: issue-watcher.sh の正規化 2 段（case + ループ）の等価実装。
#   入力: $1 = 生の env 値（unset は $2="unset" で渡し、空文字は ""）
#         $2 = "set" or "unset"（unset 状態を再現するため）
#   出力: stdout に最終正規化後の値（"true" or "false"）
normalize_design_reviewer_enabled() {
  local raw="$1"
  local mode="$2"
  # 1 段目: `${VAR:-true}` で既定 true、続いて `case false) :;; *) true` で正規化
  local v1
  if [ "$mode" = "unset" ]; then
    v1="true"
  elif [ -z "$raw" ]; then
    # 空文字は `${VAR:-true}` で既定 true に展開される（bash の `:-` 仕様）
    v1="${raw:-true}"
  else
    v1="$raw"
  fi
  case "$v1" in
    false) v1="false" ;;
    *)     v1="true" ;;
  esac
  # 2 段目: 「デフォルト有効化フラグの値正規化」ループ（issue-watcher.sh の `for _idd_flag` と
  # 等価。`=false` で false に、それ以外は true に固定する）
  local v2
  if [ "$v1" = "false" ]; then
    v2="false"
  else
    v2="true"
  fi
  printf '%s' "$v2"
}

# ─── Req 1.1〜1.5 / Req 3.1 の値正規化マトリクス ───

echo "--- DESIGN_REVIEWER_ENABLED default-flip normalization (#432 Req 1.x / 3.1) ---"

# Req 1.1: 未設定 → ON
assert_eq "Req 1.1: unset → true (default ON)" \
  "true" "$(normalize_design_reviewer_enabled "" "unset")"

# Req 1.2: 空文字 → ON
assert_eq "Req 1.2: '' (empty) → true" \
  "true" "$(normalize_design_reviewer_enabled "" "set")"

# Req 1.3: =true → ON
assert_eq "Req 1.3: 'true' → true" \
  "true" "$(normalize_design_reviewer_enabled "true" "set")"

# Req 1.4 / Req 3.1: =false → OFF（明示 opt-out は不変）
assert_eq "Req 1.4 / 3.1: 'false' (explicit opt-out) → false" \
  "false" "$(normalize_design_reviewer_enabled "false" "set")"

# Req 1.5: =False / =FALSE / =0 / =1 / =True / =TRUE / =on / typo → ON
assert_eq "Req 1.5: 'False' (capitalized) → true" \
  "true" "$(normalize_design_reviewer_enabled "False" "set")"
assert_eq "Req 1.5: 'FALSE' (all caps) → true" \
  "true" "$(normalize_design_reviewer_enabled "FALSE" "set")"
assert_eq "Req 1.5: 'True' (capitalized) → true" \
  "true" "$(normalize_design_reviewer_enabled "True" "set")"
assert_eq "Req 1.5: 'TRUE' (all caps) → true" \
  "true" "$(normalize_design_reviewer_enabled "TRUE" "set")"
assert_eq "Req 1.5: '1' → true" \
  "true" "$(normalize_design_reviewer_enabled "1" "set")"
assert_eq "Req 1.5: '0' → true (NOT a valid OFF value)" \
  "true" "$(normalize_design_reviewer_enabled "0" "set")"
assert_eq "Req 1.5: 'flase' (typo) → true" \
  "true" "$(normalize_design_reviewer_enabled "flase" "set")"
assert_eq "Req 1.5: 'on' → true" \
  "true" "$(normalize_design_reviewer_enabled "on" "set")"
assert_eq "Req 1.5: 'yes' → true" \
  "true" "$(normalize_design_reviewer_enabled "yes" "set")"

# Req 3.1: =false を明示している既存環境は本変更前と等価で OFF を維持
assert_eq "Req 3.1: existing cron with 'false' stays false (opt-out 不変)" \
  "false" "$(normalize_design_reviewer_enabled "false" "set")"

# ─── pdr_gate_enabled の契約は不変（厳密 =true で ON、=false で OFF） ───
#   正規化後の値しか受け取らないので、ON/OFF の 2 値のみ動作確認する。

echo ""
echo "--- pdr_gate_enabled contract (unchanged after #432) ---"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"
if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
  exit 2
fi

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

export DESIGN_REVIEWER_ENABLED="true"
rc=0; pdr_gate_enabled || rc=$?
assert_eq "pdr_gate_enabled: normalized=true → ON (rc=0)" "0" "$rc"

export DESIGN_REVIEWER_ENABLED="false"
rc=0; pdr_gate_enabled || rc=$?
assert_eq "pdr_gate_enabled: normalized=false → OFF (rc=1)" "1" "$rc"

# 防御的 default `:-true`: unset は ON（Config が常に先に正規化するが fail-safe ON / Req 1.1）
unset DESIGN_REVIEWER_ENABLED
rc=0; pdr_gate_enabled || rc=$?
assert_eq "pdr_gate_enabled: unset → 防御的 default で ON (rc=0)" "0" "$rc"

# ─── サマリ ───

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
