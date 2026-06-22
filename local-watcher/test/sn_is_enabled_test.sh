#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/slack-notify.sh の Issue #370（Slack 通知 emitter）で
#       追加した `sn_is_enabled` 関数の env 値正規化挙動を fixture で検証するスモークテスト。
#
#       対象関数:
#         - sn_is_enabled (#370 Req 1.1 / 1.2 / 1.3 / NFR 1.1 / NFR 4.3)
#
#       検証する AC（docs/specs/370-feat-watcher-slack-d-18/requirements.md）:
#         - Req 1.1: SLACK_NOTIFY_ENABLED=false 既定で rc=1
#         - Req 1.2: SLACK_NOTIFY_ENABLED=true 厳密一致で rc=0
#         - Req 1.3: 未設定 / 空 / true 以外（typo 含む）は安全側 rc=1
#         - NFR 1.1: gate OFF で外部副作用ゼロ（純粋関数）
#         - NFR 4.3: env 正規化テスト（不正値・typo・大文字小文字バリエーション）
#
# 配置先: local-watcher/test/sn_is_enabled_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/sn_is_enabled_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/slack-notify.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find slack-notify.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（fr_is_enabled_test.sh）と同じイディオム: awk で関数本体だけを抽出して eval。
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
eval "$(extract_function "$MODULE_SH" "sn_is_enabled")"

if ! declare -F sn_is_enabled >/dev/null; then
  echo "ERROR: sn_is_enabled not loaded" >&2
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
# Section 1: ON（Req 1.2 / 厳密一致）
# ============================================================
echo "--- Section 1: SLACK_NOTIFY_ENABLED=true 厳密一致（Req 1.2） ---"

SLACK_NOTIFY_ENABLED="true"
assert_rc "Req 1.2: =true で rc=0" 0 sn_is_enabled

# ============================================================
# Section 2: OFF（Req 1.1 既定 / Req 1.3 未設定）
# ============================================================
echo ""
echo "--- Section 2: OFF（既定 / 未設定 / Req 1.1 / 1.3） ---"

SLACK_NOTIFY_ENABLED="false"
assert_rc "Req 1.1: =false（既定）で rc=1" 1 sn_is_enabled

unset SLACK_NOTIFY_ENABLED
assert_rc "Req 1.3: 未設定で rc=1（既定 OFF）" 1 sn_is_enabled

SLACK_NOTIFY_ENABLED=""
assert_rc "Req 1.3: 空文字で rc=1" 1 sn_is_enabled

# ============================================================
# Section 3: 不正値正規化（Req 1.3 / NFR 4.3）
# ============================================================
echo ""
echo "--- Section 3: 不正値・typo・大文字小文字（Req 1.3 / NFR 4.3） ---"

for v in "False" "FALSE" "True" "TRUE" "0" "1" "on" "On" "yes" "Yes" "enable" "enabled" "tRue" "  true  " "true " " true" "trues" "TrUe"; do
  SLACK_NOTIFY_ENABLED="$v"
  assert_rc "Req 1.3: $(printf '%q' "$v") は OFF (rc=1)" 1 sn_is_enabled
done

# ============================================================
# Section 4: 副作用なし（NFR 1.1 / 純粋関数）
# ============================================================
echo ""
echo "--- Section 4: 副作用なし（NFR 1.1） ---"

SLACK_NOTIFY_ENABLED="true"
sn_is_enabled || true
if [ "$SLACK_NOTIFY_ENABLED" = "true" ]; then
  echo "PASS: NFR 1.1: sn_is_enabled は env 変数を改変しない（ON 維持）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.1: sn_is_enabled が env 変数を改変した"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# stdout / stderr に出力を出さないこと
SLACK_NOTIFY_ENABLED="true"
stdout_out=$(sn_is_enabled 2>/dev/null || true)
if [ -z "$stdout_out" ]; then
  echo "PASS: NFR 1.1: ON 時に stdout 出力なし"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.1: ON 時 stdout に出力: $(printf '%q' "$stdout_out")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

SLACK_NOTIFY_ENABLED="false"
stderr_out=$(sn_is_enabled 2>&1 >/dev/null || true)
if [ -z "$stderr_out" ]; then
  echo "PASS: NFR 1.1: OFF 時に stderr 出力なし"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.1: OFF 時 stderr に出力: $(printf '%q' "$stderr_out")"
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
