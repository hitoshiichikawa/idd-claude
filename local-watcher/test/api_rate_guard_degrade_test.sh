#!/usr/bin/env bash
#
# 用途: Issue #521 task 5/6 で追加した api-rate-guard.sh のバケット可視化（grl_buckets_refresh /
#       grl_buckets_log）と縮退（grl_degrade_should_run）を fixture + gh stub で検証する
#       スモークテスト（live GitHub API なし / NFR 6.2）。
#
#       検証観点（docs/specs/521-feat-watcher-github-api-rate-limit/requirements.md）:
#         - Req 3.1 / 3.3: cycle 終端に固定書式 1 行 `gh-rate-limit: core=r/l graphql=r/l search=r/l`
#         - Req 3.2: rate_limit 参照は `gh api rate_limit`（非消費経路）
#         - Req 3.4: 取得失敗は warn + 継続（後続を中断しない）
#         - Req 1.1 / NFR 1.1: BUCKET_LOG / DEGRADE 双方 off で gh 非呼び出し（no-op）
#         - Req 4.1 / 4.2 / 4.5: graphql 残量 < 閾値で WARN + 非必須 skip（skip ログに bucket/残量/閾値）
#         - Req 4.3 / 4.6 / NFR 2.2: essential は常に run / gate off は常に run
#
# 配置先: local-watcher/test/api_rate_guard_degrade_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/api_rate_guard_degrade_test.sh

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
if ! command -v jq >/dev/null 2>&1; then echo "ERROR: jq required" >&2; exit 2; fi

for fn in grl_log grl_warn grl_error; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$CORE_MOD" "$fn")"
done
for fn in grl_buckets_refresh grl_buckets_log grl_degrade_should_run; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$GRL_MOD" "$fn")"
done
for fn in grl_buckets_refresh grl_buckets_log; do
  if ! declare -F "$fn" >/dev/null; then echo "ERROR: $fn not loaded" >&2; exit 2; fi
done

PASS_COUNT=0
FAIL_COUNT=0

REPO="owner/test-repo"

# gh stub: `gh api rate_limit` に fixture JSON を返す。呼び出しを GH_CALL_LOG に記録。
GH_CALL_LOG="$(mktemp)"
trap 'rm -f "$GH_CALL_LOG" 2>/dev/null || true' EXIT
RATE_LIMIT_JSON='{"resources":{"core":{"limit":5000,"remaining":4990},"graphql":{"limit":5000,"remaining":4800},"search":{"limit":30,"remaining":28}}}'
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  if [ "${1:-}" = "api" ] && [ "${2:-}" = "rate_limit" ]; then
    if [ "${GH_STUB_MODE:-ok}" = "fail" ]; then return 1; fi
    printf '%s' "$RATE_LIMIT_JSON"
    return 0
  fi
  return 0
}
reset_calls() { : > "$GH_CALL_LOG"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. gate off（BUCKET_LOG / DEGRADE 双方 off）→ gh 非呼び出し（NFR 1.1）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="false"
GH_API_DEGRADE_ENABLED="false"
GRL_BUCKET_STATUS=""
reset_calls
grl_buckets_refresh
assert_eq "gate off: STATUS=disabled" "disabled" "$GRL_BUCKET_STATUS"
assert_eq "gate off: gh api rate_limit 非呼び出し" "" "$(cat "$GH_CALL_LOG")"
out="$(grl_buckets_log 2>&1)"
assert_eq "gate off: buckets_log は no-op（出力なし）" "" "$out"

# ─────────────────────────────────────────────────────────────────────────────
# 2. BUCKET_LOG on + 取得成功 → parse + 固定書式ログ（Req 3.1, 3.2, 3.3）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="true"
GH_STUB_MODE="ok"
GRL_BUCKET_STATUS=""
reset_calls
grl_buckets_refresh
assert_eq "refresh: STATUS=ok" "ok" "$GRL_BUCKET_STATUS"
assert_eq "refresh: core remaining" "4990" "$GRL_BUCKET_CORE_REMAINING"
assert_eq "refresh: graphql remaining" "4800" "$GRL_BUCKET_GRAPHQL_REMAINING"
assert_eq "refresh: search limit" "30" "$GRL_BUCKET_SEARCH_LIMIT"
assert_contains "refresh: 非消費経路 gh api rate_limit" "$(cat "$GH_CALL_LOG")" "gh api rate_limit"

log_out="$(grl_buckets_log 2>&1)"
assert_contains "buckets_log: 固定書式 prefix" "$log_out" "gh-rate-limit: core=4990/5000 graphql=4800/5000 search=28/30"

# ─────────────────────────────────────────────────────────────────────────────
# 3. 取得失敗 → warn + STATUS=unavailable + 継続（Req 3.4 / NFR 2.1）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="true"
GH_STUB_MODE="fail"
GRL_BUCKET_STATUS=""
# subshell 化するとグローバル代入が失われるため、current shell で実行して stderr を file 捕捉。
warn_file="$(mktemp)"
grl_buckets_refresh 2>"$warn_file" || true
assert_eq "取得失敗: STATUS=unavailable" "unavailable" "$GRL_BUCKET_STATUS"
assert_contains "取得失敗: warn 出力" "$(cat "$warn_file")" "gh-rate-limit: WARN"
rm -f "$warn_file"
# buckets_log も warn で継続（クラッシュしない）
logfail_out="$(grl_buckets_log 2>&1 || true)"
assert_contains "取得失敗: buckets_log は warn で継続" "$logfail_out" "gh-rate-limit: WARN"

# ─────────────────────────────────────────────────────────────────────────────
# 4. grl_degrade_should_run（Req 4）: 閾値割れで非必須 skip / essential は呼び出し側で
#    gate しないため本関数は processor 名を問わず同一判定（skip 判定は残量のみに依存）。
# ─────────────────────────────────────────────────────────────────────────────
# gate off → 常に rc=0（従来挙動 / Req 4.6）
GH_API_DEGRADE_ENABLED="false"
GRL_BUCKET_STATUS="ok"
GRL_BUCKET_GRAPHQL_REMAINING="10"
GH_API_DEGRADE_GRAPHQL_THRESHOLD="500"
assert_rc "degrade gate off: 残量僅少でも rc=0（skip しない）" 0 grl_degrade_should_run "pr-reviewer"

# gate on + 残量 >= 閾値 → rc=0（実行）
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_GRAPHQL_REMAINING="600"
assert_rc "degrade on + 残量>=閾値: rc=0（実行）" 0 grl_degrade_should_run "pr-reviewer"

# gate on + 残量 < 閾値 → rc=1（skip）+ WARN に bucket/残量/閾値
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_GRAPHQL_REMAINING="100"
GH_API_DEGRADE_GRAPHQL_THRESHOLD="500"
assert_rc "degrade on + 残量<閾値: rc=1（skip）" 1 grl_degrade_should_run "pr-reviewer"
skip_out="$(grl_degrade_should_run "pr-reviewer" 2>&1 1>/dev/null || true)"
assert_contains "skip ログに processor 名" "$skip_out" "skip processor=pr-reviewer"
assert_contains "skip ログに reason=degrade" "$skip_out" "reason=degrade"
assert_contains "skip ログに bucket=graphql" "$skip_out" "bucket=graphql"
assert_contains "skip ログに remaining/threshold" "$skip_out" "remaining=100 threshold=500"

# gate on + 残量未取得（status != ok）→ 安全側 rc=0（必須処理を守る / NFR 2.2）
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_STATUS="unavailable"
GRL_BUCKET_GRAPHQL_REMAINING="0"
assert_rc "degrade on + 残量未取得: 安全側 rc=0（実行）" 0 grl_degrade_should_run "pr-reviewer"

# gate on + 残量非整数（"?"）→ 安全側 rc=0
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_STATUS="ok"
GRL_BUCKET_GRAPHQL_REMAINING="?"
assert_rc "degrade on + 残量非整数: 安全側 rc=0（実行）" 0 grl_degrade_should_run "pr-reviewer"

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "api_rate_guard_degrade_test: all passed"
