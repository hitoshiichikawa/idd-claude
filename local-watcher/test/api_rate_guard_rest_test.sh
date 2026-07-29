#!/usr/bin/env bash
#
# 用途: Issue #521 task 8 で追加した grl_rest_prs_for_head（GraphQL→REST 負荷分散）を
#       fixture + gh stub で検証するスモークテスト（live GitHub API なし / NFR 6.2）。
#
#       検証観点（docs/specs/521-feat-watcher-github-api-rate-limit/requirements.md）:
#         - Req 6.1 / 6.2: offload on 時に REST core 経由取得し gh pr list --head 互換 JSON へ
#                          正規化（open→OPEN / closed+merged_at→MERGED / closed→CLOSED /
#                          headRefName=head.ref / headRefOid=head.sha / url=html_url）
#         - Req 6.3: REST 失敗時は従来 gh pr list --head へ fallback + warn
#         - Req 6.4 / NFR 1.1: gate off 時は従来 gh pr list --head 経路
#
# 配置先: local-watcher/test/api_rate_guard_rest_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/api_rate_guard_rest_test.sh

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
for fn in grl_gh_pr_list_head grl_rest_prs_for_head; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$GRL_MOD" "$fn")"
done
if ! declare -F grl_rest_prs_for_head >/dev/null; then
  echo "ERROR: grl_rest_prs_for_head not loaded" >&2; exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

REPO="owner/test-repo"

# fixtures
REST_JSON='[
  {"number":1,"state":"open","merged_at":null,"head":{"ref":"claude/issue-1-impl","sha":"aaa"},"html_url":"https://h/1"},
  {"number":2,"state":"closed","merged_at":"2026-01-01T00:00:00Z","head":{"ref":"claude/issue-2-impl","sha":"bbb"},"html_url":"https://h/2"},
  {"number":3,"state":"closed","merged_at":null,"head":{"ref":"claude/issue-3-impl","sha":"ccc"},"html_url":"https://h/3"}
]'
FALLBACK_JSON='[{"number":99,"state":"OPEN","headRefName":"claude/issue-99-impl","headRefOid":"zzz","url":"https://h/99"}]'

GH_CALL_LOG="$(mktemp)"
trap 'rm -f "$GH_CALL_LOG" 2>/dev/null || true' EXIT
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  case "${1:-}" in
    api)
      if [ "${GH_STUB_MODE:-ok}" = "rest-fail" ]; then return 1; fi
      printf '%s' "$REST_JSON"; return 0
      ;;
    pr)
      if [ "${2:-}" = "list" ]; then printf '%s' "$FALLBACK_JSON"; return 0; fi
      ;;
  esac
  return 0
}
timeout() { shift; "$@"; }
reset_calls() { : > "$GH_CALL_LOG"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. gate off（offload off）→ 従来 gh pr list --head 経路（Req 6.4 / NFR 1.1）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_REST_OFFLOAD_ENABLED="false"
reset_calls
out="$(grl_rest_prs_for_head "claude/issue-99-impl" "all")"
assert_eq "gate off: 従来 gh pr list --head の結果を返す" "$FALLBACK_JSON" "$out"
assert_contains "gate off: gh pr list を呼ぶ" "$(cat "$GH_CALL_LOG")" "gh pr list"
assert_eq "gate off: gh api rate offload を呼ばない" "0" "$(grep -c 'gh api' "$GH_CALL_LOG" || true)"

# ─────────────────────────────────────────────────────────────────────────────
# 2. offload on + REST 成功 → 正規化（OPEN/MERGED/CLOSED 変換 / Req 6.1, 6.2）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_REST_OFFLOAD_ENABLED="true"
GH_STUB_MODE="ok"
reset_calls
out="$(grl_rest_prs_for_head "claude/issue-1-impl" "all")"
assert_contains "offload on: REST(gh api pulls) を呼ぶ" "$(cat "$GH_CALL_LOG")" "gh api repos/owner/test-repo/pulls"
assert_eq "offload on: PR1 open→OPEN" "OPEN" "$(echo "$out" | jq -r '.[0].state')"
assert_eq "offload on: PR2 closed+merged_at→MERGED" "MERGED" "$(echo "$out" | jq -r '.[1].state')"
assert_eq "offload on: PR3 closed→CLOSED" "CLOSED" "$(echo "$out" | jq -r '.[2].state')"
assert_eq "offload on: headRefName=head.ref" "claude/issue-2-impl" "$(echo "$out" | jq -r '.[1].headRefName')"
assert_eq "offload on: headRefOid=head.sha" "bbb" "$(echo "$out" | jq -r '.[1].headRefOid')"
assert_eq "offload on: url=html_url" "https://h/3" "$(echo "$out" | jq -r '.[2].url')"
assert_eq "offload on: 数=3" "3" "$(echo "$out" | jq 'length')"

# ─────────────────────────────────────────────────────────────────────────────
# 3. offload on + REST 失敗 → 従来 gh pr list --head へ fallback + warn（Req 6.3）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_REST_OFFLOAD_ENABLED="true"
GH_STUB_MODE="rest-fail"
reset_calls
out="$(grl_rest_prs_for_head "claude/issue-99-impl" "all" 2>/dev/null)"
assert_eq "REST 失敗: gh pr list --head へ fallback" "$FALLBACK_JSON" "$out"
warn_out="$(grl_rest_prs_for_head "claude/issue-99-impl" "all" 2>&1 1>/dev/null)"
assert_contains "REST 失敗: warn 出力" "$warn_out" "gh-rate-limit: WARN"
assert_contains "REST 失敗: fallback 経路で gh pr list を呼ぶ" "$(cat "$GH_CALL_LOG")" "gh pr list"

# ─────────────────────────────────────────────────────────────────────────────
# 4. offload on + timeout 指定（元々 timeout 付き consumer）→ timeout 経由でも正規化される
# ─────────────────────────────────────────────────────────────────────────────
GH_API_REST_OFFLOAD_ENABLED="true"
GH_STUB_MODE="ok"
reset_calls
out="$(grl_rest_prs_for_head "claude/issue-1-impl" "all" "120")"
assert_eq "timeout 指定 offload on: 正規化される（PR1 OPEN）" "OPEN" "$(echo "$out" | jq -r '.[0].state')"

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "api_rate_guard_rest_test: all passed"
