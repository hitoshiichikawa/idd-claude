#!/usr/bin/env bash
#
# 用途: Issue #412 で実施した `PR_REVIEWER_ADJUDICATOR_ENABLED` の既定反転
#       （opt-in / 既定 OFF → opt-out / 既定 ON）の値正規化挙動を検証するスモークテスト。
#
#       検証する受入基準（docs/specs/412-enhancement-pr-reviewer-404-adjudicator/requirements.md）:
#         - Req 1.1 未設定で ON に正規化される
#         - Req 1.2 空文字で ON に正規化される
#         - Req 1.3 =true で ON のまま
#         - Req 1.4 =false で OFF（opt-out 明示は不変）
#         - Req 1.5 =True / =FALSE / =0 / =1 / typo はすべて ON に正規化される
#         - Req 5.1 `=false` を明示した既存 cron / launchd 環境は本変更前と等価で OFF
#         - Req 5.2 `=true` を明示した既存 cron / launchd 環境は ON を維持
#
# 配置先: local-watcher/test/pr_reviewer_adjudicator_default_on_test.sh
# 依存:   bash 4+
# 実行:   bash local-watcher/test/pr_reviewer_adjudicator_default_on_test.sh
#
# 検証手段:
#   issue-watcher.sh 本体トップレベルの `case` 文 + 「デフォルト有効化フラグの値正規化」
#   ループによる 2 段正規化を本テスト内に等価コピーした関数を作り、各 env 値で
#   resolve した結果を直接観測する（issue-watcher.sh 本体は大量の startup 依存物を抱えて
#   いるため source できない / 既存 normalize 系テストと同じイディオム）。
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

# normalize_adjudicator_enabled: issue-watcher.sh の正規化 2 段（case + ループ）の等価実装。
#   入力: $1 = 生の env 値（unset は事前に `unset` で渡し、空文字は ""）
#         $2 = "set" or "unset"（unset 状態を再現するため）
#   出力: stdout に最終正規化後の値（"true" or "false"）
normalize_adjudicator_enabled() {
  local mode="$2"
  local raw="$1"
  # 1 段目: `${VAR:-true}` で既定 true、続いて `case false) :;; *) true` で正規化
  local v1
  if [ "$mode" = "unset" ]; then
    v1="${PR_REVIEWER_ADJUDICATOR_ENABLED_UNSET_PROBE:-true}"
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

# ─── Req 1.1〜1.5 / Req 5.1〜5.2 の値正規化マトリクス ───

echo "--- PR_REVIEWER_ADJUDICATOR_ENABLED default-flip normalization (#412 Req 1.x / 5.x) ---"

# Req 1.1: 未設定 → ON
unset PR_REVIEWER_ADJUDICATOR_ENABLED_UNSET_PROBE
assert_eq "Req 1.1: unset → true (default ON)" \
  "true" "$(normalize_adjudicator_enabled "" "unset")"

# Req 1.2: 空文字 → ON
assert_eq "Req 1.2: '' (empty) → true" \
  "true" "$(normalize_adjudicator_enabled "" "set")"

# Req 1.3: =true → ON
assert_eq "Req 1.3: 'true' → true" \
  "true" "$(normalize_adjudicator_enabled "true" "set")"

# Req 1.4 / Req 5.1: =false → OFF（明示 opt-out は不変）
assert_eq "Req 1.4 / 5.1: 'false' (explicit opt-out) → false" \
  "false" "$(normalize_adjudicator_enabled "false" "set")"

# Req 1.5: =False / =FALSE / =0 / =1 / =True / =TRUE / typo → ON
assert_eq "Req 1.5: 'False' (capitalized) → true" \
  "true" "$(normalize_adjudicator_enabled "False" "set")"
assert_eq "Req 1.5: 'FALSE' (all caps) → true" \
  "true" "$(normalize_adjudicator_enabled "FALSE" "set")"
assert_eq "Req 1.5: 'True' (capitalized) → true" \
  "true" "$(normalize_adjudicator_enabled "True" "set")"
assert_eq "Req 1.5: 'TRUE' (all caps) → true" \
  "true" "$(normalize_adjudicator_enabled "TRUE" "set")"
assert_eq "Req 1.5: '1' → true" \
  "true" "$(normalize_adjudicator_enabled "1" "set")"
assert_eq "Req 1.5: '0' → true (NOT a valid OFF value)" \
  "true" "$(normalize_adjudicator_enabled "0" "set")"
assert_eq "Req 1.5: 'flase' (typo) → true" \
  "true" "$(normalize_adjudicator_enabled "flase" "set")"
assert_eq "Req 1.5: 'on' → true" \
  "true" "$(normalize_adjudicator_enabled "on" "set")"
assert_eq "Req 1.5: 'yes' → true" \
  "true" "$(normalize_adjudicator_enabled "yes" "set")"

# Req 5.2: =true を明示している既存環境は ON を維持（変更前と等価）
assert_eq "Req 5.2: existing cron with 'true' stays true" \
  "true" "$(normalize_adjudicator_enabled "true" "set")"

# ─── adj_gate_enabled の契約は不変（厳密 =true で ON、=false で OFF） ───
#   正規化後の値しか受け取らないので、ON/OFF の 2 値のみ動作確認する。

echo ""
echo "--- adj_gate_enabled contract (unchanged after #412) ---"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/modules/adjudicator.sh"
if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
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
eval "$(extract_function "$ADJ_SH" "adj_gate_enabled")"

export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
rc=0; adj_gate_enabled || rc=$?
assert_eq "adj_gate_enabled: normalized=true → ON (rc=0)" "0" "$rc"

export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
rc=0; adj_gate_enabled || rc=$?
assert_eq "adj_gate_enabled: normalized=false → OFF (rc=1)" "1" "$rc"

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
