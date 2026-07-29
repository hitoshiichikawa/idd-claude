#!/usr/bin/env bash
#
# 用途: Issue #521 task 7 で追加した grl_retry_label_op（状態遷移系ラベル操作の限定リトライ）を
#       fixture + gh stub で検証するスモークテスト（live GitHub API なし / NFR 6.2）。
#
#       検証観点（docs/specs/521-feat-watcher-github-api-rate-limit/requirements.md）:
#         - Req 5.1 / 5.2: rate-limit 起因失敗のみ上限まで再試行、非 rate-limit は 1 回で即返す
#         - Req 5.3 / NFR 2.3: 再試行は有限回（上限で打ち切り）
#         - Req 5.4: 上限到達でも rc を返し（label 残置 = 次 tick 再評価 / 孤児化しない）
#         - Req 5.6: 再試行ログに issue 番号・操作種別・試行回数
#         - Req 1.1 / NFR 1.1: gate off は 1 回だけ実行（従来挙動）
#
# 配置先: local-watcher/test/api_rate_guard_retry_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/api_rate_guard_retry_test.sh

# shellcheck disable=SC2034,SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
GRL_MOD="$SCRIPT_DIR/../bin/modules/api-rate-guard.sh"
CORE_MOD="$SCRIPT_DIR/../bin/modules/core_utils.sh"

for f in "$GRL_MOD" "$CORE_MOD"; do
  if [ ! -f "$f" ]; then echo "ERROR: cannot find $f" >&2; exit 2; fi
done

for fn in grl_log grl_warn grl_error; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$CORE_MOD" "$fn")"
done
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$GRL_MOD" "grl_retry_label_op")"
if ! declare -F grl_retry_label_op >/dev/null; then
  echo "ERROR: grl_retry_label_op not loaded" >&2; exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

REPO="owner/test-repo"
GH_API_STATE_RETRY_MAX_ATTEMPTS="3"
GH_API_STATE_RETRY_SLEEP="0"

# gh stub: issue edit 呼び出しを file カウンタで数える。GH_STUB_MODE で挙動切替。
GH_CALLS_FILE="$(mktemp)"
trap 'rm -f "$GH_CALLS_FILE" 2>/dev/null || true' EXIT
gh() {
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
    local n; n=$(cat "$GH_CALLS_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$GH_CALLS_FILE"
    case "${GH_STUB_MODE:-ok}" in
      ok)        return 0 ;;
      ratelimit) echo "API rate limit exceeded for user" >&2; return 1 ;;
      other)     echo "unprocessable: some other error" >&2; return 1 ;;
      rl-then-ok)
        if [ "$n" -ge 2 ]; then return 0; else echo "You have exceeded a secondary rate limit" >&2; return 1; fi ;;
    esac
  fi
  return 0
}
# sleep を no-op に（実 sleep を避ける）
sleep() { :; }
reset_calls() { echo 0 > "$GH_CALLS_FILE"; }
calls() { cat "$GH_CALLS_FILE"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. gate off → 1 回だけ実行（従来挙動 / NFR 1.1）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_STATE_RETRY_ENABLED="false"
GH_STUB_MODE="ratelimit"
reset_calls
rc=0; grl_retry_label_op 42 --repo "$REPO" --remove-label "claude-picked-up" || rc=$?
assert_eq "gate off: gh 1 回のみ（rate-limit でもリトライしない）" "1" "$(calls)"
assert_eq "gate off: gh の rc をそのまま返す（1）" "1" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# 2. gate on + 初回成功 → 1 回、rc=0
# ─────────────────────────────────────────────────────────────────────────────
GH_API_STATE_RETRY_ENABLED="true"
GH_STUB_MODE="ok"
reset_calls
rc=0; grl_retry_label_op 42 --repo "$REPO" --remove-label "claude-picked-up" >/dev/null 2>&1 || rc=$?
assert_eq "gate on 初回成功: gh 1 回" "1" "$(calls)"
assert_eq "gate on 初回成功: rc=0" "0" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# 3. gate on + rate-limit 継続 → 上限 3 回で打ち切り、rc 非0、上限到達 warn（Req 5.2, 5.3, 5.4）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_STATE_RETRY_ENABLED="true"
GH_STUB_MODE="ratelimit"
reset_calls
out_file="$(mktemp)"
rc=0; grl_retry_label_op 42 --repo "$REPO" --remove-label "claude-picked-up" >"$out_file" 2>&1 || rc=$?
assert_eq "rate-limit 継続: gh は上限 3 回（有限打ち切り / NFR 2.3）" "3" "$(calls)"
assert_eq "rate-limit 継続: 最終 rc 非0（label 残置で次 tick / Req 5.4）" "1" "$rc"
assert_contains "再試行ログに issue/op/attempt（Req 5.6）" "$(cat "$out_file")" "retry issue=#42 op=-claude-picked-up attempt=1/3"
assert_contains "再試行ログ attempt=2/3" "$(cat "$out_file")" "attempt=2/3"
assert_contains "上限到達 warn" "$(cat "$out_file")" "attempt=3/3 上限到達"
rm -f "$out_file"

# ─────────────────────────────────────────────────────────────────────────────
# 4. gate on + 非 rate-limit 失敗 → 1 回で即返す（二次消費回避 / Req 5.2）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_STATE_RETRY_ENABLED="true"
GH_STUB_MODE="other"
reset_calls
rc=0; grl_retry_label_op 42 --repo "$REPO" --remove-label "claude-picked-up" >/dev/null 2>&1 || rc=$?
assert_eq "非 rate-limit 失敗: gh 1 回のみ（リトライしない）" "1" "$(calls)"
assert_eq "非 rate-limit 失敗: rc 非0" "1" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# 5. gate on + rate-limit 後に成功 → 2 回、rc=0
# ─────────────────────────────────────────────────────────────────────────────
GH_API_STATE_RETRY_ENABLED="true"
GH_STUB_MODE="rl-then-ok"
reset_calls
rc=0; grl_retry_label_op 42 --repo "$REPO" --remove-label "claude-picked-up" >/dev/null 2>&1 || rc=$?
assert_eq "rate-limit→成功: gh 2 回" "2" "$(calls)"
assert_eq "rate-limit→成功: rc=0" "0" "$rc"

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "api_rate_guard_retry_test: all passed"
