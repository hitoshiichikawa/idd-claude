#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した `fr_is_enabled` 関数の二重 opt-in 評価と正規化挙動を
#       fixture で検証するスモークテスト。
#
#       対象関数:
#         - fr_is_enabled (Issue #359 Req 1.1 / 1.2 / 1.3 / 1.4 / 1.5 / NFR 1.3 / NFR 5.2)
#
#       検証する AC（docs/specs/359-feat-watcher-failed-recovery-sh-claude-f/requirements.md）:
#         - Req 1.1: FAILED_RECOVERY_ENABLED=true AND FULL_AUTO_ENABLED=true 同時成立で 0 を返す
#         - Req 1.2: FAILED_RECOVERY_ENABLED が未設定 / true 以外なら 1 を返す
#         - Req 1.3: FULL_AUTO_ENABLED が未設定 / true 以外なら 1 を返す
#         - Req 1.4: gate 無効時は何もしない（純粋関数 / 副作用なし）
#         - Req 1.5: typo（True / TRUE / 1 等）はすべて安全側 1 として扱う
#         - NFR 1.3: gate off で完全等価な挙動（rc=1）
#
#       本 test は task 2.1 の `_Requirements_partial:_ 1.5` を本 task でカバーするものでもある。
#
# 配置先: local-watcher/test/fr_is_enabled_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/fr_is_enabled_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（full_auto_enabled_test.sh）と同じイディオム: 対象スクリプトから 1
# 関数だけを awk で切り出して eval で読み込む。トップレベル副作用は回避する。
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
eval "$(extract_function "$MODULE_SH" "fr_is_enabled")"

if ! declare -F fr_is_enabled >/dev/null; then
  echo "ERROR: fr_is_enabled not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  shift 2
  local actual_rc=0
  "$@" >/dev/null 2>&1 || actual_rc=$?
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ============================================================
# Section 1: 両方 ON（Req 1.1）
# ============================================================
echo "--- Section 1: 両方 ON（Req 1.1） ---"

FAILED_RECOVERY_ENABLED="true"
FULL_AUTO_ENABLED="true"
assert_rc "Req 1.1: FAILED_RECOVERY=true AND FULL_AUTO=true で rc=0" 0 fr_is_enabled

# ============================================================
# Section 2: 両方 OFF（Req 1.2 / 1.3 / NFR 1.3）
# ============================================================
echo ""
echo "--- Section 2: 両方 OFF（Req 1.2 / 1.3 / NFR 1.3） ---"

FAILED_RECOVERY_ENABLED="false"
FULL_AUTO_ENABLED="false"
assert_rc "Req 1.2 / 1.3: 両方 false で rc=1" 1 fr_is_enabled

unset FAILED_RECOVERY_ENABLED
unset FULL_AUTO_ENABLED
assert_rc "Req 1.2 / 1.3 / NFR 1.3: 両方未設定で rc=1（既定 OFF）" 1 fr_is_enabled

# ============================================================
# Section 3: 片方 only（Req 1.2 / Req 1.3）
# ============================================================
echo ""
echo "--- Section 3: 片方 only（Req 1.2 / 1.3） ---"

# Case A: FAILED_RECOVERY=true, FULL_AUTO=false → rc=1（Req 1.3）
FAILED_RECOVERY_ENABLED="true"
FULL_AUTO_ENABLED="false"
assert_rc "Req 1.3: FAILED_RECOVERY=true / FULL_AUTO=false で rc=1" 1 fr_is_enabled

# Case A': FAILED_RECOVERY=true, FULL_AUTO 未設定 → rc=1（Req 1.3）
FAILED_RECOVERY_ENABLED="true"
unset FULL_AUTO_ENABLED
assert_rc "Req 1.3: FAILED_RECOVERY=true / FULL_AUTO 未設定で rc=1" 1 fr_is_enabled

# Case B: FAILED_RECOVERY=false, FULL_AUTO=true → rc=1（Req 1.2）
FAILED_RECOVERY_ENABLED="false"
FULL_AUTO_ENABLED="true"
assert_rc "Req 1.2: FAILED_RECOVERY=false / FULL_AUTO=true で rc=1" 1 fr_is_enabled

# Case B': FAILED_RECOVERY 未設定, FULL_AUTO=true → rc=1（Req 1.2）
unset FAILED_RECOVERY_ENABLED
FULL_AUTO_ENABLED="true"
assert_rc "Req 1.2: FAILED_RECOVERY 未設定 / FULL_AUTO=true で rc=1" 1 fr_is_enabled

# ============================================================
# Section 4: 不正値正規化（Req 1.5 — 安全側 OFF / typo 防御）
#
# fr_is_enabled は env 値の正規化は行わず `=true` 厳密一致のみ enabled として扱う
# （正規化は issue-watcher.sh の Config ブロックで行われる）。本テストでは「正規化
# 後の値として `true` 以外が入ってきた場合に rc=1 となる」ことを直接検証する。
# ============================================================
echo ""
echo "--- Section 4: 不正値正規化（Req 1.5） ---"

# FAILED_RECOVERY 側の不正値（FULL_AUTO=true 固定）
FULL_AUTO_ENABLED="true"
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes" "enable" "enabled" "Yes" "tRue" "  true  " "trues"; do
  FAILED_RECOVERY_ENABLED="$v"
  assert_rc "Req 1.5: FAILED_RECOVERY=$(printf '%q' "$v") は disabled（FULL_AUTO=true でも rc=1）" 1 fr_is_enabled
done

# FULL_AUTO 側の不正値（FAILED_RECOVERY=true 固定）
FAILED_RECOVERY_ENABLED="true"
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes" "enable" "enabled" "Yes" "tRue" "  true  " "trues"; do
  FULL_AUTO_ENABLED="$v"
  assert_rc "Req 1.5: FULL_AUTO=$(printf '%q' "$v") は disabled（FAILED_RECOVERY=true でも rc=1）" 1 fr_is_enabled
done

# 両方 typo（同時 typo でも rc=1）
FAILED_RECOVERY_ENABLED="True"
FULL_AUTO_ENABLED="True"
assert_rc "Req 1.5: 両方 typo (True/True) で rc=1" 1 fr_is_enabled

FAILED_RECOVERY_ENABLED="1"
FULL_AUTO_ENABLED="1"
assert_rc "Req 1.5: 両方 typo (1/1) で rc=1" 1 fr_is_enabled

# ============================================================
# Section 5: 副作用なし（Req 1.4 / 純粋関数）
#
# fr_is_enabled は env 変数を書き換えず、stdout / stderr に何も出さない純粋関数
# である。複数回呼んでも env 状態が保持されることを確認する（呼出後に env を
# read してそのまま使える）。
# ============================================================
echo ""
echo "--- Section 5: 副作用なし（Req 1.4） ---"

FAILED_RECOVERY_ENABLED="true"
FULL_AUTO_ENABLED="true"
fr_is_enabled || true
if [ "$FAILED_RECOVERY_ENABLED" = "true" ] && [ "$FULL_AUTO_ENABLED" = "true" ]; then
  echo "PASS: Req 1.4: fr_is_enabled は env 変数を改変しない（ON → ON 維持）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.4: fr_is_enabled が env 変数を改変した"
  echo "  FAILED_RECOVERY_ENABLED=$FAILED_RECOVERY_ENABLED"
  echo "  FULL_AUTO_ENABLED=$FULL_AUTO_ENABLED"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# stdout / stderr に出力を出さないこと
FAILED_RECOVERY_ENABLED="true"
FULL_AUTO_ENABLED="true"
stdout_out=$(fr_is_enabled 2>/dev/null || true)
if [ -z "$stdout_out" ]; then
  echo "PASS: Req 1.4: fr_is_enabled は stdout に何も出さない"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.4: fr_is_enabled が stdout に出力した: $(printf '%q' "$stdout_out")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

FAILED_RECOVERY_ENABLED="false"
FULL_AUTO_ENABLED="false"
stderr_out=$(fr_is_enabled 2>&1 >/dev/null || true)
if [ -z "$stderr_out" ]; then
  echo "PASS: Req 1.4: gate OFF 時も stderr に何も出さない"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.4: gate OFF 時に stderr に出力: $(printf '%q' "$stderr_out")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
