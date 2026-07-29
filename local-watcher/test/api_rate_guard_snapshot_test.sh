#!/usr/bin/env bash
#
# 用途: Issue #521 task 1 で新規追加した local-watcher/bin/modules/api-rate-guard.sh の
#       スナップショット共有基盤（Req 2）を fixture + gh stub で検証するスモークテスト。
#       live GitHub API を呼ばず、timeout / gh を stub して判定を観測する（NFR 6.2）。
#
#       対象関数:
#         - grl_snapshot_init           (Req 2.1, 2.2, 2.5, 2.6 / gate off no-op / fetch 失敗 fallback)
#         - grl_snapshot_active         (active/inactive 判定)
#         - grl_snapshot_prs / _issues  (超集合 file accessor)
#         - grl_pr_snapshot_or_live     (Req 2.3 active=超集合 / 非 active=live 委譲)
#         - grl_issue_snapshot_or_live  (同上 Issue 版)
#
#       検証する AC（docs/specs/521-feat-watcher-github-api-rate-limit/requirements.md）:
#         - Req 1.1 / 1.2 / 1.3: gate off / 未設定 / 不正値 → 新挙動なし（active=off / gh 非呼び出し）
#         - Req 2.1 / 2.2: gate on で PR/Issue 超集合を各 1 回取得し file 共有
#         - Req 2.5 / 2.6: 取得失敗は warn + active=off で個別取得へフォールバック
#         - Req 2.3: 非 active 時にラッパが live 引数へ byte 等価に委譲
#
# 配置先: local-watcher/test/api_rate_guard_snapshot_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/api_rate_guard_snapshot_test.sh

# 抽出関数および stub から indirect 参照される変数を多用するため、shellcheck からは
# 未使用に見える。本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
GRL_MOD="$SCRIPT_DIR/../bin/modules/api-rate-guard.sh"
CORE_MOD="$SCRIPT_DIR/../bin/modules/core_utils.sh"

for f in "$GRL_MOD" "$CORE_MOD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: cannot find $f" >&2
    exit 2
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH" >&2
  exit 2
fi

# grl ロガーは core_utils.sh 定義、snapshot 系は api-rate-guard.sh 定義。
for fn in grl_log grl_warn grl_error; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$CORE_MOD" "$fn")"
done
for fn in grl_snapshot_pr_fields grl_snapshot_issue_fields grl_snapshot_dir \
          grl_atomic_write grl_snapshot_init grl_snapshot_active \
          grl_snapshot_prs grl_snapshot_issues \
          grl_pr_snapshot_or_live grl_issue_snapshot_or_live; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$GRL_MOD" "$fn")"
done

for fn in grl_snapshot_init grl_snapshot_active grl_pr_snapshot_or_live grl_issue_snapshot_or_live; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

# ── グローバル env（遅延束縛で抽出関数本体から参照される） ──
REPO="owner/test-repo"
REPO_SLUG="owner-test-repo"
LABEL_TRIGGER="auto-dev"
GRL_SNAPSHOT_STATUS="inactive"

# 一時 snapshot ディレクトリ
GH_API_SNAPSHOT_DIR="$(mktemp -d)"
trap 'rm -rf "$GH_API_SNAPSHOT_DIR" 2>/dev/null || true' EXIT
GH_API_SNAPSHOT_PR_LIMIT="100"
GH_API_SNAPSHOT_ISSUE_LIMIT="100"
GH_API_SNAPSHOT_GH_TIMEOUT="60"

# ── stub: timeout は bash 関数 gh を実行するため duration を捨てて "$@" を実行 ──
GH_CALL_LOG="$(mktemp)"
trap 'rm -rf "$GH_API_SNAPSHOT_DIR" "$GH_CALL_LOG" 2>/dev/null || true' EXIT
timeout() { shift; "$@"; }

# gh stub。GH_STUB_MODE で挙動を切り替える。呼び出し引数を GH_CALL_LOG に追記。
PR_SUPERSET='[{"number":1,"title":"a","isDraft":false},{"number":2,"title":"b","isDraft":true}]'
ISSUE_SUPERSET='[{"number":10,"labels":[{"name":"auto-dev"}]},{"number":11,"labels":[{"name":"auto-dev"},{"name":"claude-picked-up"}]}]'
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  local kind="$2"  # $1=pr|issue, $2=list
  case "$1" in
    pr)
      if [ "${GH_STUB_MODE:-ok}" = "pr-fail" ]; then return 1; fi
      echo "$PR_SUPERSET"
      ;;
    issue)
      if [ "${GH_STUB_MODE:-ok}" = "issue-fail" ]; then return 1; fi
      echo "$ISSUE_SUPERSET"
      ;;
  esac
  : "$kind"
}

reset_calls() { : > "$GH_CALL_LOG"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. gate off（既定 false）→ no-op（active=off / gh 非呼び出し）（Req 1.1, 1.2）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_SNAPSHOT_ENABLED="false"
GRL_SNAPSHOT_STATUS="inactive"
reset_calls
grl_snapshot_init
assert_eq "gate off: status=inactive" "inactive" "$GRL_SNAPSHOT_STATUS"
assert_rc "gate off: grl_snapshot_active rc=1" 1 grl_snapshot_active
assert_eq "gate off: gh 非呼び出し" "" "$(cat "$GH_CALL_LOG")"

# ─────────────────────────────────────────────────────────────────────────────
# 2. 不正値（typo）→ 安全側 off（Req 1.3）
#    ※ config 正規化は watcher-config.sh 側だが、init 自体も `!= true` で安全側に倒す
# ─────────────────────────────────────────────────────────────────────────────
GH_API_SNAPSHOT_ENABLED="TRUE"   # 大文字は true 厳密一致でない
GRL_SNAPSHOT_STATUS="inactive"
reset_calls
grl_snapshot_init
assert_eq "typo(TRUE): status=inactive" "inactive" "$GRL_SNAPSHOT_STATUS"
assert_rc "typo(TRUE): active rc=1" 1 grl_snapshot_active

# ─────────────────────────────────────────────────────────────────────────────
# 3. gate on + 取得成功 → active / file 書き込み（Req 2.1, 2.2）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_SNAPSHOT_ENABLED="true"
GH_STUB_MODE="ok"
GRL_SNAPSHOT_STATUS="inactive"
reset_calls
grl_snapshot_init
assert_eq "gate on: status=active" "active" "$GRL_SNAPSHOT_STATUS"
assert_rc "gate on: active rc=0" 0 grl_snapshot_active
assert_eq "gate on: prs.json 内容" "$PR_SUPERSET" "$(cat "$GH_API_SNAPSHOT_DIR/prs.json")"
assert_eq "gate on: issues.json 内容" "$ISSUE_SUPERSET" "$(cat "$GH_API_SNAPSHOT_DIR/issues.json")"
# PR / Issue 各 1 回のみ取得（NFR 3.1）
assert_eq "gate on: PR list 1 回" "1" "$(grep -c 'gh pr list' "$GH_CALL_LOG")"
assert_eq "gate on: Issue list 1 回" "1" "$(grep -c 'gh issue list' "$GH_CALL_LOG")"
# accessor
assert_eq "grl_snapshot_prs=超集合" "$PR_SUPERSET" "$(grl_snapshot_prs)"
assert_eq "grl_snapshot_issues=超集合" "$ISSUE_SUPERSET" "$(grl_snapshot_issues)"

# ─────────────────────────────────────────────────────────────────────────────
# 4. gate on + PR 取得失敗 → warn + active=off（Req 2.5, 2.6 / NFR 2.1）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_SNAPSHOT_ENABLED="true"
GH_STUB_MODE="pr-fail"
GRL_SNAPSHOT_STATUS="inactive"
reset_calls
warn_out="$(grl_snapshot_init 2>&1 1>/dev/null || true)"
assert_eq "PR fetch fail: status=inactive" "inactive" "$GRL_SNAPSHOT_STATUS"
assert_contains "PR fetch fail: warn 出力" "$warn_out" "gh-rate-limit: WARN"

# ─────────────────────────────────────────────────────────────────────────────
# 5. gate on + Issue 取得失敗 → warn + active=off（Req 2.5, 2.6）
# ─────────────────────────────────────────────────────────────────────────────
GH_STUB_MODE="issue-fail"
GRL_SNAPSHOT_STATUS="inactive"
grl_snapshot_init >/dev/null 2>&1 || true
assert_eq "Issue fetch fail: status=inactive" "inactive" "$GRL_SNAPSHOT_STATUS"

# ─────────────────────────────────────────────────────────────────────────────
# 6. ラッパ: active 時は超集合を返す（live 引数を無視 / Req 2.3）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_SNAPSHOT_ENABLED="true"
GH_STUB_MODE="ok"
GRL_SNAPSHOT_STATUS="inactive"
grl_snapshot_init >/dev/null 2>&1
reset_calls
out="$(grl_pr_snapshot_or_live 60 "review:approved -draft:true" "number,title" 50)"
assert_eq "wrapper active(PR): 超集合返却" "$PR_SUPERSET" "$out"
assert_eq "wrapper active(PR): live gh 非呼び出し" "" "$(cat "$GH_CALL_LOG")"
out="$(grl_issue_snapshot_or_live 60 "label:auto-dev" "number,labels" 50)"
assert_eq "wrapper active(Issue): 超集合返却" "$ISSUE_SUPERSET" "$out"

# ─────────────────────────────────────────────────────────────────────────────
# 7. ラッパ: 非 active（gate off）時は live 引数で従来 gh を実行（byte 等価 / Req 2.3）
# ─────────────────────────────────────────────────────────────────────────────
GH_API_SNAPSHOT_ENABLED="false"
GRL_SNAPSHOT_STATUS="inactive"
reset_calls
out="$(grl_pr_snapshot_or_live 60 "review:approved -draft:true" "number,title" 50)"
assert_eq "wrapper live(PR): 超集合を stub gh から返却" "$PR_SUPERSET" "$out"
assert_contains "wrapper live(PR): --search を含む" "$(cat "$GH_CALL_LOG")" '--search review:approved -draft:true'
assert_contains "wrapper live(PR): --json を含む" "$(cat "$GH_CALL_LOG")" '--json number,title'
assert_contains "wrapper live(PR): --limit を含む" "$(cat "$GH_CALL_LOG")" '--limit 50'

# 空 search → --search を付けない（auto-merge-disarm 互換 / byte 等価）
reset_calls
out="$(grl_pr_snapshot_or_live 60 "" "number,title" 100)"
calls="$(cat "$GH_CALL_LOG")"
assert_eq "wrapper live(PR, 空 search): --search なし" "0" "$(printf '%s' "$calls" | grep -c -- '--search' || true)"
assert_contains "wrapper live(PR, 空 search): --state open" "$calls" '--state open'

# Issue live 委譲
reset_calls
out="$(grl_issue_snapshot_or_live 60 "label:\"needs-quota-wait\"" "number,labels" 50)"
assert_contains "wrapper live(Issue): --search を含む" "$(cat "$GH_CALL_LOG")" 'gh issue list'

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
echo "api_rate_guard_snapshot_test: all passed"
