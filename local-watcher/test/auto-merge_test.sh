#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/auto-merge.sh の Issue #352（auto-merge.sh —
#       実装 PR を checks 全 green で squash auto-merge）で追加した関数群を
#       fixture と gh stub で検証するスモークテスト。
#
#       対象関数:
#         - am_resolve_gate_enabled    (Req 1.2, 1.3 / NFR 1.1 安全側正規化)
#         - am_should_enable_for_pr    (Req 2.x, 4.x 対象 PR 判定)
#         - am_enable_auto_merge_for_pr (Req 3.1, 5.x, 7.1)
#         - process_auto_merge         (Req 1.x, 6.x AND 二重 opt-in / 統合)
#
#       検証する AC（docs/specs/352-feat-watcher-auto-merge-sh-pr-checks-gre/requirements.md）:
#         - Req 1.3: AUTO_MERGE_ENABLED 値正規化（=true 厳密一致以外は OFF）
#         - Req 1.2: AND 二重 opt-in（AUTO_MERGE_ENABLED && FULL_AUTO_ENABLED）
#         - Req 1.4: FULL_AUTO_ENABLED OFF → gh ゼロ呼び出し
#         - Req 2.1: head pattern mismatch → skip
#         - Req 2.2: ready-for-review ラベル無し → skip
#         - Req 2.3: draft → skip
#         - Req 2.4: mergeable=MERGEABLE のみ通す
#         - Req 2.5: mergeable=CONFLICTING → skip
#         - Req 2.6: mergeable=UNKNOWN → skip
#         - Req 3.1: 全条件満たし → `gh pr merge --auto --squash --delete-branch`
#         - Req 4.2: claude-failed 除外
#         - Req 4.3: needs-decisions 除外
#         - Req 4.5: 既に auto-merge enabled → skip（冪等）
#         - Req 5.1, 5.4: enable 失敗時 WARN ログを残す（silent fail 禁止）
#         - Req 6.1: gate OFF で gh ゼロ呼び出し
#         - Req 7.1: 成功時 PR 番号 / head sha / head branch を含む log line
#
# 配置先: local-watcher/test/auto-merge_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto-merge_test.sh

set -euo pipefail

# 抽出関数および stub から indirect 参照される変数を多用するため、shellcheck からは
# 未使用に見える。本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM_MOD="$SCRIPT_DIR/../bin/modules/auto-merge.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$AM_MOD" ]; then
  echo "ERROR: cannot find auto-merge.sh at $AM_MOD" >&2
  exit 2
fi
if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を auto-merge.sh から読み込む
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AM_MOD" "am_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AM_MOD" "am_warn")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AM_MOD" "am_error")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AM_MOD" "am_resolve_gate_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AM_MOD" "am_should_enable_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AM_MOD" "am_enable_auto_merge_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AM_MOD" "process_auto_merge")"

# full_auto_enabled は issue-watcher.sh 本体に定義されている（#348）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in am_resolve_gate_enabled am_should_enable_for_pr am_enable_auto_merge_for_pr process_auto_merge full_auto_enabled; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される）
REPO="owner/test-repo"
LABEL_READY="ready-for-review"
LABEL_FAILED="claude-failed"
LABEL_NEEDS_DECISIONS="needs-decisions"
AUTO_MERGE_MAX_PRS=10
AUTO_MERGE_GIT_TIMEOUT=60
AUTO_MERGE_HEAD_PATTERN='^claude/issue-.*-impl'

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

# ── stub state ──
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  LOG_OUT="$(mktemp)"
  WARN_OUT="$(mktemp)"
  GH_PR_LIST_RESPONSE='[]'
  GH_PR_MERGE_RC=0
  GH_PR_MERGE_STDERR=""
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$LOG_OUT" "$WARN_OUT" 2>/dev/null || true
}

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_logs() {
  local file="$1"
  local pattern="$2"
  local n
  n=$( { grep -E -- "$pattern" "$file" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# am_log / am_warn / am_error を上書きして出力をファイルへリダイレクト
# （extract_function は 1 関数ずつ読み込むので、redefine で観測可能にする）
# shellcheck disable=SC2317
am_log()   { echo "$*" >>"$LOG_OUT"; }
# shellcheck disable=SC2317
am_warn()  { echo "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
am_error() { echo "$*" >>"$WARN_OUT"; }

# timeout を no-op に。実 gh ではなく stub を呼ぶ。
# shellcheck disable=SC2317
timeout() {
  shift  # 第 1 引数（秒数）を捨てる
  "$@"
}

# gh stub: gh pr list / gh pr merge の呼び出しを観測。
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${1:-}" in
    pr)
      case "${2:-}" in
        list)
          # `--json ...` 含む gh pr list 呼び出しに対し固定 JSON を返す
          printf '%s' "$GH_PR_LIST_RESPONSE"
          return 0
          ;;
        merge)
          # 失敗注入が有効なら stderr に書いて返す
          if [ -n "$GH_PR_MERGE_STDERR" ]; then
            printf '%s\n' "$GH_PR_MERGE_STDERR" >&2
          fi
          return "$GH_PR_MERGE_RC"
          ;;
      esac
      ;;
  esac
  return 0
}

# Helper: am_should_enable_for_pr 用の PR JSON ビルダー
build_pr_json() {
  local pr_number="$1"
  local head_ref="$2"
  local mergeable="$3"
  local is_draft="$4"
  local labels_csv="$5"      # "ready-for-review,foo,..." (カンマ区切り)
  local auto_merge="$6"      # "" or "{...}"
  local labels_json
  labels_json=$(echo "$labels_csv" | awk -F',' '{
    printf "[";
    for (i = 1; i <= NF; i++) {
      if ($i == "") continue;
      if (printed) printf ",";
      printf "{\"name\":\"%s\"}", $i;
      printed = 1;
    }
    printf "]";
  }')
  local auto_merge_field
  if [ -z "$auto_merge" ] || [ "$auto_merge" = "null" ]; then
    auto_merge_field="null"
  else
    auto_merge_field="$auto_merge"
  fi
  cat <<EOF
{
  "number": $pr_number,
  "headRefName": "$head_ref",
  "headRefOid": "abc123def456",
  "baseRefName": "main",
  "mergeable": "$mergeable",
  "labels": $labels_json,
  "url": "https://github.com/owner/test-repo/pull/$pr_number",
  "isDraft": $is_draft,
  "headRepositoryOwner": {"login": "owner"},
  "autoMergeRequest": $auto_merge_field
}
EOF
}

# ============================================================
# Section 1: am_resolve_gate_enabled 値正規化（Req 1.3 / NFR 1.1）
# ============================================================
echo "--- Section 1: am_resolve_gate_enabled 値正規化（Req 1.3 / NFR 1.1） ---"

# 既定値（未設定）は OFF
unset AUTO_MERGE_ENABLED
assert_rc "Req 1.3: 未設定なら disabled（rc=1）" 1 am_resolve_gate_enabled

# =true 厳密一致のみ ON
AUTO_MERGE_ENABLED="true"
assert_rc "Req 1.2: =true 厳密一致で enabled（rc=0）" 0 am_resolve_gate_enabled

# それ以外はすべて OFF（安全側）
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes" "enable" "enabled" "tRue" "  true  " "trues"; do
  AUTO_MERGE_ENABLED="$v"
  assert_rc "Req 1.3: AUTO_MERGE_ENABLED=$(printf '%q' "$v") は disabled" 1 am_resolve_gate_enabled
done

# ============================================================
# Section 2: am_should_enable_for_pr PR 判定（Req 2.x, 4.x）
# ============================================================
echo ""
echo "--- Section 2: am_should_enable_for_pr PR 判定 ---"

# 全条件満たし → rc=0
PR_OK=$(build_pr_json 100 "claude/issue-352-impl-foo" "MERGEABLE" "false" "ready-for-review" "")
assert_rc "Req 2.1〜2.4: 全条件満たし → rc=0" 0 am_should_enable_for_pr "$PR_OK"

# Req 2.1: head pattern mismatch → rc=1
PR_HEAD_MISMATCH=$(build_pr_json 101 "feature/manual-branch" "MERGEABLE" "false" "ready-for-review" "")
assert_rc "Req 2.1: head pattern mismatch → skip" 1 am_should_enable_for_pr "$PR_HEAD_MISMATCH"

# Req 2.1: 設計 PR（impl ではない）→ rc=1
PR_DESIGN=$(build_pr_json 102 "claude/issue-352-design-foo" "MERGEABLE" "false" "ready-for-review" "")
assert_rc "Req 2.1: 設計 PR（impl ではない） → skip" 1 am_should_enable_for_pr "$PR_DESIGN"

# Req 2.2: ready-for-review 無し → rc=1
PR_NO_READY=$(build_pr_json 103 "claude/issue-352-impl-foo" "MERGEABLE" "false" "" "")
assert_rc "Req 2.2: ready-for-review 無し → skip" 1 am_should_enable_for_pr "$PR_NO_READY"

# Req 2.3: draft → rc=1
PR_DRAFT=$(build_pr_json 104 "claude/issue-352-impl-foo" "MERGEABLE" "true" "ready-for-review" "")
assert_rc "Req 2.3: draft → skip" 1 am_should_enable_for_pr "$PR_DRAFT"

# Req 2.5: mergeable=CONFLICTING → rc=1
PR_CONFLICT=$(build_pr_json 105 "claude/issue-352-impl-foo" "CONFLICTING" "false" "ready-for-review" "")
assert_rc "Req 2.5: mergeable=CONFLICTING → skip" 1 am_should_enable_for_pr "$PR_CONFLICT"

# Req 2.6: mergeable=UNKNOWN → rc=1
PR_UNKNOWN=$(build_pr_json 106 "claude/issue-352-impl-foo" "UNKNOWN" "false" "ready-for-review" "")
assert_rc "Req 2.6: mergeable=UNKNOWN → skip" 1 am_should_enable_for_pr "$PR_UNKNOWN"

# Req 4.2: claude-failed 除外
PR_FAILED=$(build_pr_json 107 "claude/issue-352-impl-foo" "MERGEABLE" "false" "ready-for-review,claude-failed" "")
assert_rc "Req 4.2: claude-failed ラベル付き → skip" 1 am_should_enable_for_pr "$PR_FAILED"

# Req 4.3: needs-decisions 除外
PR_NEEDS_DEC=$(build_pr_json 108 "claude/issue-352-impl-foo" "MERGEABLE" "false" "ready-for-review,needs-decisions" "")
assert_rc "Req 4.3: needs-decisions ラベル付き → skip" 1 am_should_enable_for_pr "$PR_NEEDS_DEC"

# Req 4.5: 既に auto-merge enabled → rc=2（冪等 skip）
PR_ALREADY=$(build_pr_json 109 "claude/issue-352-impl-foo" "MERGEABLE" "false" "ready-for-review" '{"enabledAt":"2026-06-22T00:00:00Z"}')
assert_rc "Req 4.5: 既に auto-merge enabled → rc=2（冪等 skip）" 2 am_should_enable_for_pr "$PR_ALREADY"

# ============================================================
# Section 3: am_enable_auto_merge_for_pr 呼び出し検証（Req 3.1, 5.x, 7.1）
# ============================================================
echo ""
echo "--- Section 3: am_enable_auto_merge_for_pr 呼び出し検証 ---"

# Req 3.1: gh pr merge --auto --squash --delete-branch が呼ばれる
reset_stub_state
GH_PR_MERGE_RC=0
am_enable_auto_merge_for_pr 100 "claude/issue-352-impl-foo" "abc123def456" "https://github.com/owner/test-repo/pull/100"
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 3.1: 全条件満たし → gh pr merge 呼び出しが 1 回発火" "1" "$merge_call_count"
# `--auto --squash --delete-branch` 全フラグが揃っていることを確認
auto_flag=$(count_calls "gh pr merge.*--auto")
squash_flag=$(count_calls "gh pr merge.*--squash")
delete_flag=$(count_calls "gh pr merge.*--delete-branch")
assert_eq "Req 3.1: --auto フラグあり" "1" "$auto_flag"
assert_eq "Req 3.1: --squash フラグあり" "1" "$squash_flag"
assert_eq "Req 3.1: --delete-branch フラグあり" "1" "$delete_flag"
# Req 7.1: 成功時 log line に PR 番号 / head sha / head branch を含む
success_log_count=$(count_logs "$LOG_OUT" "PR #100.*auto-merge enabled")
assert_eq "Req 7.1: 成功時 log line に PR 番号 + auto-merge enabled" "1" "$success_log_count"
head_log_count=$(count_logs "$LOG_OUT" "head=claude/issue-352-impl-foo")
assert_eq "Req 7.1: 成功時 log line に head branch" "1" "$head_log_count"
sha_log_count=$(count_logs "$LOG_OUT" "sha=abc123def456")
assert_eq "Req 7.1: 成功時 log line に head sha" "1" "$sha_log_count"
cleanup_stub_state

# Req 5.1, 5.4: enable 失敗時 WARN ログを残す（silent fail 禁止）
reset_stub_state
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: Pull Request is not mergeable"
am_enable_auto_merge_for_pr 200 "claude/issue-352-impl-bar" "deadbeef" "https://github.com/owner/test-repo/pull/200" || true
warn_log_count=$(count_logs "$WARN_OUT" "PR #200.*auto-merge enable failed")
assert_eq "Req 5.1 / 5.4: enable 失敗時 WARN ログを残す" "1" "$warn_log_count"
cleanup_stub_state

# Req 5.2: transport-error 種別の検出
reset_stub_state
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="could not resolve host: api.github.com"
am_enable_auto_merge_for_pr 201 "claude/issue-352-impl-bar" "deadbeef" "https://github.com/owner/test-repo/pull/201" || true
transport_warn_count=$(count_logs "$WARN_OUT" "transport-error")
assert_eq "Req 5.2: network エラーは transport-error で WARN" "1" "$transport_warn_count"
cleanup_stub_state

# Req 5.5: branch protection rejection の検出
reset_stub_state
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: GraphQL error: Pull request Auto merge is not allowed for this repository"
am_enable_auto_merge_for_pr 202 "claude/issue-352-impl-bar" "deadbeef" "https://github.com/owner/test-repo/pull/202" || true
repo_warn_count=$(count_logs "$WARN_OUT" "repo-config-rejected")
assert_eq "Req 5.5: auto merge 不可は repo-config-rejected で WARN" "1" "$repo_warn_count"
cleanup_stub_state

# NFR 1.3: 数値でない PR 番号は skip
reset_stub_state
am_enable_auto_merge_for_pr "abc" "claude/issue-352-impl" "sha" "url" || true
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "NFR 1.3: 数値以外の PR 番号で gh pr merge を呼ばない" "0" "$merge_call_count"
cleanup_stub_state

# ============================================================
# Section 4: process_auto_merge 統合（AND 二重 opt-in / Req 1.x, 6.x）
# ============================================================
echo ""
echo "--- Section 4: process_auto_merge AND 二重 opt-in（Req 1.x, 6.x） ---"

# Case A: 両 gate OFF（既定）→ gh ゼロ呼び出し（Req 6.1）
reset_stub_state
unset AUTO_MERGE_ENABLED
unset FULL_AUTO_ENABLED
process_auto_merge
gh_count=$(count_calls "^gh ")
assert_eq "Req 6.1: 両 gate OFF で gh ゼロ呼び出し" "0" "$gh_count"
cleanup_stub_state

# Case B: AUTO_MERGE_ENABLED=true / FULL_AUTO_ENABLED OFF → 早期 return（gh ゼロ呼び出し）
reset_stub_state
AUTO_MERGE_ENABLED="true"
unset FULL_AUTO_ENABLED
process_auto_merge
gh_count=$(count_calls "^gh ")
assert_eq "Req 1.4: FULL_AUTO_ENABLED OFF で gh ゼロ呼び出し" "0" "$gh_count"
# Req 7.3: FULL_AUTO_ENABLED OFF 起因は #348 既存ログに委ねるため auto-merge: ログを出さない
sup_log=$(count_logs "$LOG_OUT" "suppressed")
assert_eq "Req 7.3: FULL_AUTO_ENABLED OFF 起因では auto-merge suppression ログを出さない" "0" "$sup_log"
cleanup_stub_state

# Case C: AUTO_MERGE_ENABLED OFF / FULL_AUTO_ENABLED=true → 早期 return（gh ゼロ呼び出し）
reset_stub_state
unset AUTO_MERGE_ENABLED
FULL_AUTO_ENABLED="true"
process_auto_merge
gh_count=$(count_calls "^gh ")
assert_eq "Req 1.3 / 6.1: AUTO_MERGE_ENABLED OFF で gh ゼロ呼び出し" "0" "$gh_count"
# Req 7.2: AUTO_MERGE_ENABLED OFF 起因の suppression ログを 1 行出力
sup_log=$(count_logs "$LOG_OUT" "suppressed by AUTO_MERGE_ENABLED")
assert_eq "Req 7.2: AUTO_MERGE_ENABLED OFF 起因の suppression ログを 1 行" "1" "$sup_log"
cleanup_stub_state

# Case D: 両 gate ON / 対象 PR=1 件 / 全条件満たし → gh pr merge 1 回
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 100,
    "headRefName": "claude/issue-352-impl-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [{"name": "ready-for-review"}],
    "url": "https://github.com/owner/test-repo/pull/100",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
GH_PR_MERGE_RC=0
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 3.1: 両 gate ON / 全条件満たし → gh pr merge 1 回" "1" "$merge_call_count"
cleanup_stub_state

# Case E: 両 gate ON / CONFLICTING PR → gh pr merge 呼び出しなし（Req 2.5）
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 101,
    "headRefName": "claude/issue-352-impl-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "CONFLICTING",
    "labels": [{"name": "ready-for-review"}],
    "url": "https://github.com/owner/test-repo/pull/101",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.5: CONFLICTING PR → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case F: 両 gate ON / draft PR → gh pr merge 呼び出しなし（Req 2.3）
# server-side filter で -draft:true があるので gh pr list は draft を返さないはずだが、
# client-side の保険として直接 draft=true を含めて検証する
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 102,
    "headRefName": "claude/issue-352-impl-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [{"name": "ready-for-review"}],
    "url": "https://github.com/owner/test-repo/pull/102",
    "isDraft": true,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.3: draft PR → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case G: 両 gate ON / ready-for-review なし → gh pr merge 呼び出しなし（Req 2.2）
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 103,
    "headRefName": "claude/issue-352-impl-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/103",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.2: ready-for-review なし → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case H: 両 gate ON / head pattern mismatch（人間が手書きの PR）→ gh pr merge 呼び出しなし（Req 2.1, 6.3）
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 104,
    "headRefName": "feature/manual-pr",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [{"name": "ready-for-review"}],
    "url": "https://github.com/owner/test-repo/pull/104",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.1 / 6.3: head pattern mismatch → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case I: 両 gate ON / 設計 PR（impl ではない）→ gh pr merge 呼び出しなし（Req 6.3）
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 105,
    "headRefName": "claude/issue-352-design-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [{"name": "ready-for-review"}],
    "url": "https://github.com/owner/test-repo/pull/105",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 6.3: 設計 PR → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case J: 両 gate ON / 既に auto-merge enabled → gh pr merge 呼び出しなし（Req 4.5 冪等）
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 106,
    "headRefName": "claude/issue-352-impl-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [{"name": "ready-for-review"}],
    "url": "https://github.com/owner/test-repo/pull/106",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": {"enabledAt": "2026-06-22T00:00:00Z"}
  }
]'
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 4.5: 既に enabled → gh pr merge 呼ばれない（冪等）" "0" "$merge_call_count"
# already-enabled サマリログを確認
already_log=$(count_logs "$LOG_OUT" "auto-merge already enabled")
assert_eq "Req 4.5: 既に enabled 時の log 出力あり" "1" "$already_log"
cleanup_stub_state

# Case K: 両 gate ON / 失敗注入 → gh pr merge 呼ばれるが WARN ログを残す（Req 5.1, 5.4）
reset_stub_state
AUTO_MERGE_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 107,
    "headRefName": "claude/issue-352-impl-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [{"name": "ready-for-review"}],
    "url": "https://github.com/owner/test-repo/pull/107",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: not mergeable"
process_auto_merge
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 5.1: 失敗注入時も gh pr merge は 1 回呼ばれる" "1" "$merge_call_count"
warn_count=$(count_logs "$WARN_OUT" "auto-merge enable failed")
assert_eq "Req 5.1 / 5.4: 失敗時 WARN ログを残し silent fail させない" "1" "$warn_count"
cleanup_stub_state

# Case L: AUTO_MERGE_ENABLED 不正値（yes / 空文字 / 1）→ gh ゼロ呼び出し
for v in "yes" "" "1" "True" "TRUE"; do
  reset_stub_state
  AUTO_MERGE_ENABLED="$v"
  FULL_AUTO_ENABLED="true"
  process_auto_merge
  gh_count=$(count_calls "^gh ")
  assert_eq "Req 1.3: AUTO_MERGE_ENABLED='$v' → gh ゼロ呼び出し（安全側 OFF）" "0" "$gh_count"
  cleanup_stub_state
done

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
