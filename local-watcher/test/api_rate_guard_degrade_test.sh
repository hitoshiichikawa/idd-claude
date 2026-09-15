#!/usr/bin/env bash
#
# 用途: Issue #521 task 5/6 で追加し #536 で graphql 取得経路を是正した api-rate-guard.sh の
#       バケット可視化（grl_buckets_refresh / grl_graphql_bucket_refresh / grl_buckets_log）と
#       縮退（grl_degrade_should_run）を fixture + gh stub で検証するスモークテスト
#       （live GitHub API なし / NFR 6.2 / #536 Req 6）。
#
#       検証観点:
#         #521 requirements（docs/specs/521-feat-watcher-github-api-rate-limit/）:
#         - Req 3.1 / 3.3: cycle 終端に固定書式 1 行 `gh-rate-limit: core=r/l graphql=r/l search=r/l`
#         - Req 3.4: 取得失敗は warn + 継続（後続を中断しない）
#         - Req 1.1 / NFR 1.1: BUCKET_LOG / DEGRADE 双方 off で gh 非呼び出し（no-op）
#         #536 requirements（docs/specs/536-fix-watcher-github-api-rate-guard-graphq/）:
#         - Req 1.1 / 1.2 / 1.3: graphql は GraphQL rateLimit クエリ由来、core/search は REST 由来
#         - Req 2.1 / 2.2: graphql 実残量 < 閾値で非必須 skip + WARN（processor/bucket/remaining/threshold）
#         - Req 3.1 / 3.2 / 3.3: 可視化ログの graphql 欄が GraphQL 実残量、core/search は REST 値
#         - Req 4.1 / 4.2: rate limit 起因の graphql 取得失敗 → 残量 0 とみなして縮退発火 + WARN
#         - Req 4.3 / 4.4: rate limit 以外の graphql 取得失敗 → 全プロセッサ実行 + WARN
#         - Req 5.1 / NFR 1.1: 両 gate off で GraphQL クエリを含む新規 API 呼び出しゼロ
#         - Req 6.1〜6.4: 上記を live GitHub API 呼び出しなしで検証
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
for fn in grl_buckets_refresh grl_graphql_bucket_refresh grl_buckets_log grl_degrade_should_run; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$GRL_MOD" "$fn")"
done
for fn in grl_buckets_refresh grl_graphql_bucket_refresh grl_buckets_log grl_degrade_should_run; do
  if ! declare -F "$fn" >/dev/null; then echo "ERROR: $fn not loaded" >&2; exit 2; fi
done

PASS_COUNT=0
FAIL_COUNT=0

REPO="owner/test-repo"

# gh stub:
#   `gh api rate_limit`          → REST fixture（core/search）。GH_STUB_REST_MODE=fail で rc=1。
#   `gh api graphql -f query=..` → GraphQL rateLimit fixture（graphql 実残量）。
#     GH_STUB_GRAPHQL_MODE で ok / rate_limited（rc!=0 + stderr rate limit 文言）/
#     rate_limited_body（rc=0 + errors[] RATE_LIMITED）/ timeout（rc!=0 + 非 rate-limit 文言）を切替。
#     ok モードの graphql 残量は GRAPHQL_REMAINING で可変。
# 呼び出しは GH_CALL_LOG に記録し、gate off 時の新規 API 呼び出しゼロを検証する。
GH_CALL_LOG="$(mktemp)"
trap 'rm -f "$GH_CALL_LOG" 2>/dev/null || true' EXIT
RATE_LIMIT_JSON='{"resources":{"core":{"limit":5000,"remaining":4990},"graphql":{"limit":5000,"remaining":5000},"search":{"limit":30,"remaining":28}}}'
GH_STUB_REST_MODE="ok"
GH_STUB_GRAPHQL_MODE="ok"
GRAPHQL_REMAINING="4800"
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  if [ "${1:-}" = "api" ] && [ "${2:-}" = "rate_limit" ]; then
    if [ "${GH_STUB_REST_MODE:-ok}" = "fail" ]; then return 1; fi
    printf '%s' "$RATE_LIMIT_JSON"
    return 0
  fi
  if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
    case "${GH_STUB_GRAPHQL_MODE:-ok}" in
      ok)
        printf '{"data":{"rateLimit":{"limit":5000,"used":%s,"remaining":%s,"resetAt":"2026-09-15T13:00:00Z"}}}' \
          "$((5000 - ${GRAPHQL_REMAINING:-4800}))" "${GRAPHQL_REMAINING:-4800}"
        return 0
        ;;
      rate_limited)
        # gh の非ゼロ rc + stderr の rate limit 文言（HTTP 403 / RATE_LIMITED）
        echo "gh: HTTP 403: API rate limit exceeded for installation (RATE_LIMITED)" >&2
        return 1
        ;;
      rate_limited_body)
        # rc=0 だが body に errors[].type=RATE_LIMITED（GraphQL エラー経路）
        printf '%s' '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}'
        return 0
        ;;
      timeout)
        # rate limit 以外の失敗（timeout）: 非ゼロ rc + 非 rate-limit の stderr
        echo "gh: request timed out" >&2
        return 124
        ;;
      *)
        return 1
        ;;
    esac
  fi
  return 0
}
reset_calls() { : > "$GH_CALL_LOG"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. gate off（BUCKET_LOG / DEGRADE 双方 off）→ 新規 API 呼び出しゼロ（Req 5.1 / NFR 1.1）
#    GraphQL クエリも REST も呼ばれないことを stub 呼び出しログで検証する。
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="false"
GH_API_DEGRADE_ENABLED="false"
GRL_BUCKET_STATUS=""
GRL_BUCKET_GRAPHQL_STATUS=""
reset_calls
grl_buckets_refresh
assert_eq "gate off: STATUS=disabled" "disabled" "$GRL_BUCKET_STATUS"
assert_eq "gate off: GRAPHQL_STATUS=disabled" "disabled" "$GRL_BUCKET_GRAPHQL_STATUS"
assert_eq "gate off: 新規 API 呼び出しゼロ（GraphQL クエリも REST も呼ばない / Req 5.1）" "" "$(cat "$GH_CALL_LOG")"
out="$(grl_buckets_log 2>&1)"
assert_eq "gate off: buckets_log は no-op（出力なし）" "" "$out"
assert_eq "gate off: buckets_log も新規 API 呼び出しゼロ" "" "$(cat "$GH_CALL_LOG")"

# ─────────────────────────────────────────────────────────────────────────────
# 2. BUCKET_LOG on + 両取得成功 → graphql は GraphQL クエリ由来、core/search は REST 由来、
#    固定書式ログ（#536 Req 1.1, 1.2, 1.3, 3.1, 3.2, 3.3）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="true"
GH_API_DEGRADE_ENABLED="false"
GH_STUB_REST_MODE="ok"
GH_STUB_GRAPHQL_MODE="ok"
GRAPHQL_REMAINING="4800"
GRL_BUCKET_STATUS=""
GRL_BUCKET_GRAPHQL_STATUS=""
reset_calls
grl_buckets_refresh
assert_eq "refresh: STATUS=ok（core/search REST 取得成功）" "ok" "$GRL_BUCKET_STATUS"
assert_eq "refresh: GRAPHQL_STATUS=ok" "ok" "$GRL_BUCKET_GRAPHQL_STATUS"
assert_eq "refresh: core remaining（REST 由来）" "4990" "$GRL_BUCKET_CORE_REMAINING"
assert_eq "refresh: search limit（REST 由来）" "30" "$GRL_BUCKET_SEARCH_LIMIT"
assert_eq "refresh: graphql remaining（GraphQL クエリ由来 / REST 名目値 5000 ではない）" "4800" "$GRL_BUCKET_GRAPHQL_REMAINING"
assert_eq "refresh: graphql limit（GraphQL クエリ由来）" "5000" "$GRL_BUCKET_GRAPHQL_LIMIT"
calls="$(cat "$GH_CALL_LOG")"
assert_contains "refresh: core/search は REST gh api rate_limit" "$calls" "gh api rate_limit"
assert_contains "refresh: graphql は GraphQL rateLimit クエリ" "$calls" "gh api graphql -f query="
assert_contains "refresh: GraphQL クエリ本文が rateLimit" "$calls" "rateLimit"

log_out="$(grl_buckets_log 2>&1)"
assert_contains "buckets_log: 固定書式 prefix（graphql は GraphQL 実残量）" "$log_out" "gh-rate-limit: core=4990/5000 graphql=4800/5000 search=28/30"

# ─────────────────────────────────────────────────────────────────────────────
# 3. core/search の REST 取得失敗 → warn + STATUS=unavailable + 継続（従来挙動を維持 / Req 3.4）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="true"
GH_STUB_REST_MODE="fail"
GH_STUB_GRAPHQL_MODE="ok"
GRL_BUCKET_STATUS=""
# subshell 化するとグローバル代入が失われるため、current shell で実行して stderr を file 捕捉。
warn_file="$(mktemp)"
grl_buckets_refresh 2>"$warn_file" || true
assert_eq "REST 取得失敗: STATUS=unavailable" "unavailable" "$GRL_BUCKET_STATUS"
assert_contains "REST 取得失敗: warn 出力" "$(cat "$warn_file")" "gh-rate-limit: WARN"
rm -f "$warn_file"
# buckets_log も warn で継続（クラッシュしない）
logfail_out="$(grl_buckets_log 2>&1 || true)"
assert_contains "REST 取得失敗: buckets_log は warn で継続" "$logfail_out" "gh-rate-limit: WARN"

# ─────────────────────────────────────────────────────────────────────────────
# 4. graphql 取得が rate limit 起因で失敗 → 残量 0 とみなす + WARN（#536 Req 4.1, 4.2）
#    core/search は REST ok のため可視化ログは継続し graphql 欄は 0 を示す。
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="true"
GH_STUB_REST_MODE="ok"
GH_STUB_GRAPHQL_MODE="rate_limited"
GRL_BUCKET_STATUS=""
GRL_BUCKET_GRAPHQL_STATUS=""
warn_file="$(mktemp)"
grl_buckets_refresh 2>"$warn_file" || true
assert_eq "graphql rate limit 失敗: GRAPHQL_STATUS=rate_limited" "rate_limited" "$GRL_BUCKET_GRAPHQL_STATUS"
assert_eq "graphql rate limit 失敗: 残量 0 とみなす" "0" "$GRL_BUCKET_GRAPHQL_REMAINING"
assert_eq "graphql rate limit 失敗でも core/search は REST ok" "ok" "$GRL_BUCKET_STATUS"
assert_contains "graphql rate limit 失敗: WARN に rate limit 起因" "$(cat "$warn_file")" "rate limit 起因"
rm -f "$warn_file"
log_out4="$(grl_buckets_log 2>&1)"
assert_contains "graphql rate limit 失敗: 可視化ログ graphql 欄は 0" "$log_out4" "graphql=0/"

# 4b. graphql rc=0 でも body に errors[] RATE_LIMITED → rate_limited（GraphQL エラー経路 / Req 4.1）
GH_STUB_GRAPHQL_MODE="rate_limited_body"
GRL_BUCKET_GRAPHQL_STATUS=""
grl_buckets_refresh 2>/dev/null || true
assert_eq "graphql errors[] RATE_LIMITED (rc=0): GRAPHQL_STATUS=rate_limited" "rate_limited" "$GRL_BUCKET_GRAPHQL_STATUS"

# ─────────────────────────────────────────────────────────────────────────────
# 5. graphql 取得が rate limit 以外（timeout）で失敗 → unavailable + WARN（#536 Req 4.3, 4.4）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_BUCKET_LOG_ENABLED="true"
GH_STUB_REST_MODE="ok"
GH_STUB_GRAPHQL_MODE="timeout"
GRL_BUCKET_GRAPHQL_STATUS=""
warn_file="$(mktemp)"
grl_buckets_refresh 2>"$warn_file" || true
assert_eq "graphql timeout 失敗: GRAPHQL_STATUS=unavailable" "unavailable" "$GRL_BUCKET_GRAPHQL_STATUS"
assert_contains "graphql timeout 失敗: WARN に rate limit 以外" "$(cat "$warn_file")" "rate limit 以外"
rm -f "$warn_file"

# ─────────────────────────────────────────────────────────────────────────────
# 6. grl_degrade_should_run（#536 Req 2 / Req 4）: 判定は GRL_BUCKET_GRAPHQL_STATUS に基づく。
#    essential は呼び出し側で gate しないため本関数は processor 名を問わず同一判定。
# ─────────────────────────────────────────────────────────────────────────────
# gate off → 常に rc=0（従来挙動 / Req 2.4, 4.6）
GH_API_DEGRADE_ENABLED="false"
GRL_BUCKET_GRAPHQL_STATUS="ok"
GRL_BUCKET_GRAPHQL_REMAINING="10"
GH_API_DEGRADE_GRAPHQL_THRESHOLD="500"
assert_rc "degrade gate off: 残量僅少でも rc=0（skip しない）" 0 grl_degrade_should_run "pr-reviewer"

# gate on + graphql ok + 残量 >= 閾値 → rc=0（実行 / Req 2.3）
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_GRAPHQL_STATUS="ok"
GRL_BUCKET_GRAPHQL_REMAINING="600"
assert_rc "degrade on + 残量>=閾値: rc=0（実行）" 0 grl_degrade_should_run "pr-reviewer"

# gate on + graphql ok + 残量 < 閾値 → rc=1（skip）+ WARN に processor/reason/bucket/残量/閾値（Req 2.1, 2.2）
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_GRAPHQL_STATUS="ok"
GRL_BUCKET_GRAPHQL_REMAINING="100"
GH_API_DEGRADE_GRAPHQL_THRESHOLD="500"
assert_rc "degrade on + 残量<閾値: rc=1（skip）" 1 grl_degrade_should_run "pr-reviewer"
skip_out="$(grl_degrade_should_run "pr-reviewer" 2>&1 1>/dev/null || true)"
assert_contains "skip ログに processor 名" "$skip_out" "skip processor=pr-reviewer"
assert_contains "skip ログに reason=degrade" "$skip_out" "reason=degrade"
assert_contains "skip ログに bucket=graphql" "$skip_out" "bucket=graphql"
assert_contains "skip ログに remaining/threshold" "$skip_out" "remaining=100 threshold=500"

# gate on + graphql rate_limited（rate limit 起因の取得失敗）→ 残量 0 とみなして rc=1（skip）
# + WARN に取得失敗理由・bucket・閾値（#536 Req 4.1, 4.2）
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_GRAPHQL_STATUS="rate_limited"
GRL_BUCKET_GRAPHQL_REMAINING="0"
GH_API_DEGRADE_GRAPHQL_THRESHOLD="500"
assert_rc "degrade on + graphql rate limit 失敗: rc=1（残量 0 とみなして skip / Req 4.1）" 1 grl_degrade_should_run "pr-reviewer"
rl_skip_out="$(grl_degrade_should_run "pr-reviewer" 2>&1 1>/dev/null || true)"
assert_contains "rate limit skip ログに processor 名" "$rl_skip_out" "skip processor=pr-reviewer"
assert_contains "rate limit skip ログに取得失敗理由" "$rl_skip_out" "reason=degrade-graphql-fetch-rate-limited"
assert_contains "rate limit skip ログに bucket=graphql" "$rl_skip_out" "bucket=graphql"
assert_contains "rate limit skip ログに threshold" "$rl_skip_out" "threshold=500"

# gate on + graphql unavailable（rate limit 以外の失敗）→ 安全側 rc=0（全実行 / Req 4.3 / NFR 2.2）
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_GRAPHQL_STATUS="unavailable"
GRL_BUCKET_GRAPHQL_REMAINING="?"
assert_rc "degrade on + graphql 取得失敗(非 rate limit): 安全側 rc=0（全実行 / Req 4.3）" 0 grl_degrade_should_run "pr-reviewer"

# gate on + graphql ok + 残量非整数（"?"）→ 安全側 rc=0
GH_API_DEGRADE_ENABLED="true"
GRL_BUCKET_GRAPHQL_STATUS="ok"
GRL_BUCKET_GRAPHQL_REMAINING="?"
assert_rc "degrade on + 残量非整数: 安全側 rc=0（実行）" 0 grl_degrade_should_run "pr-reviewer"

# ─────────────────────────────────────────────────────────────────────────────
# 7. 統合（refresh → degrade）: #536 Req 6.2 / 6.3 / 6.4 を live GitHub API なしで検証
# ─────────────────────────────────────────────────────────────────────────────
# 7a. graphql 実残量 < 閾値 → 縮退 skip（Req 6.2）
GH_API_BUCKET_LOG_ENABLED="false"
GH_API_DEGRADE_ENABLED="true"
GH_STUB_REST_MODE="ok"
GH_STUB_GRAPHQL_MODE="ok"
GRAPHQL_REMAINING="100"
GH_API_DEGRADE_GRAPHQL_THRESHOLD="500"
GRL_BUCKET_GRAPHQL_STATUS=""
grl_buckets_refresh 2>/dev/null || true
assert_eq "統合: refresh 後 graphql 実残量が反映される" "100" "$GRL_BUCKET_GRAPHQL_REMAINING"
assert_rc "統合: graphql 実残量<閾値 → 縮退 skip（Req 6.2）" 1 grl_degrade_should_run "pr-reviewer"

# 7b. rate limit 起因の graphql 取得失敗 → 縮退発火（Req 6.3）
GH_API_DEGRADE_ENABLED="true"
GH_STUB_REST_MODE="ok"
GH_STUB_GRAPHQL_MODE="rate_limited"
GH_API_DEGRADE_GRAPHQL_THRESHOLD="500"
GRL_BUCKET_GRAPHQL_STATUS=""
grl_buckets_refresh 2>/dev/null || true
assert_rc "統合: rate limit 起因の graphql 取得失敗 → 縮退発火（Req 6.3）" 1 grl_degrade_should_run "pr-reviewer"

# 7c. rate limit 以外の graphql 取得失敗 → 全プロセッサ実行フォールバック（Req 6.4）
GH_API_DEGRADE_ENABLED="true"
GH_STUB_REST_MODE="ok"
GH_STUB_GRAPHQL_MODE="timeout"
GRL_BUCKET_GRAPHQL_STATUS=""
grl_buckets_refresh 2>/dev/null || true
assert_rc "統合: rate limit 以外の graphql 取得失敗 → 全プロセッサ実行（Req 6.4）" 0 grl_degrade_should_run "pr-reviewer"

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "api_rate_guard_degrade_test: all passed"
