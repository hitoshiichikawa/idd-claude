#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/auto-merge-design.sh の Issue #354（auto-merge-design.sh
#       — 設計 PR を checks 全 green で squash auto-merge）で追加した関数群を
#       fixture と gh stub で検証するスモークテスト。
#
#       対象関数:
#         - amd_resolve_gate_enabled    (Req 1.3 / NFR 1.1 安全側正規化)
#         - amd_should_enable_for_pr    (Req 2.x, 6.x 対象 PR 判定)
#         - amd_enable_auto_merge_for_pr (Req 3.1, 7.x, 9.1)
#         - process_auto_merge_design   (Req 1.x, 6.x AND 二重 opt-in / 統合)
#
#       検証する AC（docs/specs/354-feat-watcher-pr-auto-merge-awaiting-desi/requirements.md）:
#         - Req 1.3: AUTO_MERGE_DESIGN_ENABLED 値正規化（=true 厳密一致以外は OFF）
#         - Req 1.2: AND 二重 opt-in（AUTO_MERGE_DESIGN_ENABLED && FULL_AUTO_ENABLED）
#         - Req 1.4: FULL_AUTO_ENABLED OFF → gh ゼロ呼び出し（#348 ログに委譲）
#         - Req 2.1: head pattern `^claude/issue-.*-design` mismatch → skip
#         - Req 2.2: draft → skip
#         - Req 2.3: mergeable=MERGEABLE のみ通す
#         - Req 2.4: mergeable=CONFLICTING → skip
#         - Req 2.5: mergeable=UNKNOWN → skip
#         - Req 2.6: impl PR pattern との非干渉（client-side filter）
#         - Req 3.1: 全条件満たし → `gh pr merge --auto --squash --delete-branch -- <N>`
#         - Req 6.2: claude-failed 除外
#         - Req 6.3: needs-decisions 除外
#         - Req 6.4: needs-iteration 除外（設計 PR iteration 中は merge 抑止）
#         - Req 6.6: 既に auto-merge enabled → skip（冪等）
#         - Req 6.7: impl PR の head pattern (`-impl`) は本 processor の対象外
#         - Req 7.1, 7.2, 7.5: enable 失敗時 WARN ログを残し 3 分類（transport-error /
#           repo-config-rejected / api-error）に振り分ける
#         - Req 7.3 / 7.4: 失敗時もパイプライン継続（process_auto_merge_design rc=0）
#         - Req 8.1: gate OFF で gh ゼロ呼び出し
#         - Req 9.1: 成功時 PR 番号 / head sha / head branch を含む log line
#         - Req 9.2: AUTO_MERGE_DESIGN_ENABLED OFF 起因の suppression ログ 1 行
#         - Req 9.3: FULL_AUTO_ENABLED OFF 起因では本 processor から log を出さない
#
# 配置先: local-watcher/test/auto-merge-design_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto-merge-design_test.sh

set -euo pipefail

# 抽出関数および stub から indirect 参照される変数を多用するため、shellcheck からは
# 未使用に見える。本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMD_MOD="$SCRIPT_DIR/../bin/modules/auto-merge-design.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$AMD_MOD" ]; then
  echo "ERROR: cannot find auto-merge-design.sh at $AMD_MOD" >&2
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

# 対象関数群を auto-merge-design.sh から読み込む
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AMD_MOD" "amd_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AMD_MOD" "amd_warn")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AMD_MOD" "amd_error")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AMD_MOD" "amd_resolve_gate_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AMD_MOD" "amd_should_enable_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AMD_MOD" "amd_enable_auto_merge_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$AMD_MOD" "process_auto_merge_design")"

# full_auto_enabled は issue-watcher.sh 本体に定義されている（#348）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in amd_resolve_gate_enabled amd_should_enable_for_pr amd_enable_auto_merge_for_pr process_auto_merge_design full_auto_enabled; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# Issue #370 task 4: amd_enable_auto_merge_for_pr の rc=0 path で `sn_notify` を呼ぶため、
# unbound 回避と call 観測のためにローカル stub を用意する（auto-merge_test.sh と同形式）。
SN_NOTIFY_CALL_COUNT=0
SN_NOTIFY_LAST_EVENT=""
SN_NOTIFY_LAST_NUMBER=""
SN_NOTIFY_LAST_RESULT=""
SN_NOTIFY_LAST_DETAIL=""
sn_notify() {
  SN_NOTIFY_CALL_COUNT=$((SN_NOTIFY_CALL_COUNT + 1))
  SN_NOTIFY_LAST_EVENT="${1:-}"
  SN_NOTIFY_LAST_NUMBER="${2:-}"
  SN_NOTIFY_LAST_RESULT="${4:-}"
  SN_NOTIFY_LAST_DETAIL="${5:-}"
  return 0
}

# Issue #388: amd_enable_auto_merge_for_pr の rc=0 path で amm_save_pending を呼ぶ。
# unbound 回避と call 観測のため stub を提供する。
AMM_SAVE_PENDING_CALL_COUNT=0
AMM_SAVE_PENDING_LAST_PR=""
AMM_SAVE_PENDING_LAST_EVENT_TYPE=""
amm_save_pending() {
  AMM_SAVE_PENDING_CALL_COUNT=$((AMM_SAVE_PENDING_CALL_COUNT + 1))
  AMM_SAVE_PENDING_LAST_PR="${1:-}"
  AMM_SAVE_PENDING_LAST_EVENT_TYPE="${2:-}"
  return 0
}

# グローバル env（遅延束縛で抽出関数本体から参照される）。
# 各代入に対して inline disable=SC2034 を付与する（既存 auto-merge_test.sh との parity を
# 保ちつつ、警告を inline で抑止する）。
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
LABEL_NEEDS_DECISIONS="needs-decisions"
# shellcheck disable=SC2034
LABEL_NEEDS_ITERATION="needs-iteration"
# shellcheck disable=SC2034
AUTO_MERGE_DESIGN_MAX_PRS=10
# shellcheck disable=SC2034
AUTO_MERGE_DESIGN_GIT_TIMEOUT=60
# shellcheck disable=SC2034
AUTO_MERGE_DESIGN_HEAD_PATTERN='^claude/issue-.*-design'

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

# amd_log / amd_warn / amd_error を上書きして出力をファイルへリダイレクト
# （extract_function は 1 関数ずつ読み込むので、redefine で観測可能にする）
# shellcheck disable=SC2317
amd_log()   { echo "$*" >>"$LOG_OUT"; }
# shellcheck disable=SC2317
amd_warn()  { echo "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
amd_error() { echo "$*" >>"$WARN_OUT"; }

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

# Helper: amd_should_enable_for_pr 用の PR JSON ビルダー
# 設計 PR 用には `ready-for-review` ラベル必須要件がないため、labels_csv は
# 空文字列（ラベルなし）でも fixture として有効。
build_pr_json() {
  local pr_number="$1"
  local head_ref="$2"
  local mergeable="$3"
  local is_draft="$4"
  local labels_csv="$5"      # "foo,bar,..." (カンマ区切り。空文字でラベルなし)
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
# Section 1: amd_resolve_gate_enabled 値正規化（Req 1.3 / NFR 1.1）
# ============================================================
echo "--- Section 1: amd_resolve_gate_enabled 値正規化（Req 1.3 / NFR 1.1） ---"

# 既定値（未設定）は OFF
unset AUTO_MERGE_DESIGN_ENABLED
assert_rc "Req 1.3: 未設定なら disabled（rc=1）" 1 amd_resolve_gate_enabled

# =true 厳密一致のみ ON
AUTO_MERGE_DESIGN_ENABLED="true"
assert_rc "Req 1.2: =true 厳密一致で enabled（rc=0）" 0 amd_resolve_gate_enabled

# それ以外はすべて OFF（安全側）
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes" "enable" "enabled" "tRue" "  true  " "trues"; do
  AUTO_MERGE_DESIGN_ENABLED="$v"
  assert_rc "Req 1.3: AUTO_MERGE_DESIGN_ENABLED=$(printf '%q' "$v") は disabled" 1 amd_resolve_gate_enabled
done

# ============================================================
# Section 2: amd_should_enable_for_pr PR 判定（Req 2.x, 6.x）
# ============================================================
echo ""
echo "--- Section 2: amd_should_enable_for_pr PR 判定 ---"

# 全条件満たし（design PR / ラベル無し）→ rc=0
PR_OK=$(build_pr_json 100 "claude/issue-354-design-foo" "MERGEABLE" "false" "" "")
assert_rc "Req 2.1〜2.3: 全条件満たし → rc=0" 0 amd_should_enable_for_pr "$PR_OK"

# Req 2.1: head pattern mismatch（人間が手書きの branch）→ rc=1
PR_HEAD_MISMATCH=$(build_pr_json 101 "feature/manual-branch" "MERGEABLE" "false" "" "")
assert_rc "Req 2.1: head pattern mismatch（手書き branch）→ skip" 1 amd_should_enable_for_pr "$PR_HEAD_MISMATCH"

# Req 2.6 / 6.7: impl PR（`-impl`）は本 processor の対象外（client-side filter で排他）
PR_IMPL=$(build_pr_json 102 "claude/issue-354-impl-foo" "MERGEABLE" "false" "" "")
assert_rc "Req 2.6 / 6.7: 実装 PR（impl pattern）→ skip" 1 amd_should_enable_for_pr "$PR_IMPL"

# Req 2.2: draft → rc=1
PR_DRAFT=$(build_pr_json 104 "claude/issue-354-design-foo" "MERGEABLE" "true" "" "")
assert_rc "Req 2.2: draft → skip" 1 amd_should_enable_for_pr "$PR_DRAFT"

# Req 2.4: mergeable=CONFLICTING → rc=1
PR_CONFLICT=$(build_pr_json 105 "claude/issue-354-design-foo" "CONFLICTING" "false" "" "")
assert_rc "Req 2.4: mergeable=CONFLICTING → skip" 1 amd_should_enable_for_pr "$PR_CONFLICT"

# Req 2.5: mergeable=UNKNOWN → rc=1
PR_UNKNOWN=$(build_pr_json 106 "claude/issue-354-design-foo" "UNKNOWN" "false" "" "")
assert_rc "Req 2.5: mergeable=UNKNOWN → skip" 1 amd_should_enable_for_pr "$PR_UNKNOWN"

# Req 6.2: claude-failed 除外
PR_FAILED=$(build_pr_json 107 "claude/issue-354-design-foo" "MERGEABLE" "false" "claude-failed" "")
assert_rc "Req 6.2: claude-failed ラベル付き → skip" 1 amd_should_enable_for_pr "$PR_FAILED"

# Req 6.3: needs-decisions 除外
PR_NEEDS_DEC=$(build_pr_json 108 "claude/issue-354-design-foo" "MERGEABLE" "false" "needs-decisions" "")
assert_rc "Req 6.3: needs-decisions ラベル付き → skip" 1 amd_should_enable_for_pr "$PR_NEEDS_DEC"

# Req 6.4: needs-iteration 除外（設計 PR iteration 中は merge 抑止）
PR_NEEDS_ITER=$(build_pr_json 109 "claude/issue-354-design-foo" "MERGEABLE" "false" "needs-iteration" "")
assert_rc "Req 6.4: needs-iteration ラベル付き → skip" 1 amd_should_enable_for_pr "$PR_NEEDS_ITER"

# Req 6.6: 既に auto-merge enabled → rc=2（冪等 skip）
PR_ALREADY=$(build_pr_json 110 "claude/issue-354-design-foo" "MERGEABLE" "false" "" '{"enabledAt":"2026-06-22T00:00:00Z"}')
assert_rc "Req 6.6: 既に auto-merge enabled → rc=2（冪等 skip）" 2 amd_should_enable_for_pr "$PR_ALREADY"

# ============================================================
# Section 3: amd_enable_auto_merge_for_pr 呼び出し検証（Req 3.1, 7.x, 9.1）
# ============================================================
echo ""
echo "--- Section 3: amd_enable_auto_merge_for_pr 呼び出し検証 ---"

# Req 3.1: gh pr merge --auto --squash --delete-branch -- <N> が exactly once 呼ばれる
reset_stub_state
SN_NOTIFY_CALL_COUNT=0
SN_NOTIFY_LAST_EVENT=""
SN_NOTIFY_LAST_NUMBER=""
SN_NOTIFY_LAST_RESULT=""
SN_NOTIFY_LAST_DETAIL=""
AMM_SAVE_PENDING_CALL_COUNT=0
AMM_SAVE_PENDING_LAST_PR=""
AMM_SAVE_PENDING_LAST_EVENT_TYPE=""
GH_PR_MERGE_RC=0
amd_enable_auto_merge_for_pr 100 "claude/issue-354-design-foo" "abc123def456" "https://github.com/owner/test-repo/pull/100"
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 3.1: 全条件満たし → gh pr merge 呼び出しが 1 回発火" "1" "$merge_call_count"
# Issue #370 Req 2.1 task 4: 成功 path で sn_notify が auto-merge-design event_type で発火
assert_eq "#370 Req 2.1: 成功時 sn_notify が 1 回呼ばれる" "1" "$SN_NOTIFY_CALL_COUNT"
assert_eq "#370 Req 2.1: sn_notify event_type=auto-merge-design" "auto-merge-design" "$SN_NOTIFY_LAST_EVENT"
assert_eq "#370 Req 2.1: sn_notify number=100" "100" "$SN_NOTIFY_LAST_NUMBER"
# Issue #388 Req 1.2, 1.3: result=success → result=armed に変更（design PR でも誤読を防ぐ）
assert_eq "#388 Req 1.2: design armed callsite は result=armed を渡す" "armed" "$SN_NOTIFY_LAST_RESULT"
case "$SN_NOTIFY_LAST_DETAIL" in
  *"armed (squash on green checks)"*)
    echo "PASS: #388 Req 1.3: design detail に armed 明示文言を含む"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: #388 Req 1.3: design detail に armed 明示なし: $SN_NOTIFY_LAST_DETAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
# Issue #388 Req 2.2: design 経路でも amm_save_pending を呼んで pending state 登録
assert_eq "#388 Req 2.2: design armed 成功時に amm_save_pending が呼ばれる" "1" "$AMM_SAVE_PENDING_CALL_COUNT"
assert_eq "#388 Req 2.2: amm_save_pending に pr_number=100 を渡す" "100" "$AMM_SAVE_PENDING_LAST_PR"
assert_eq "#388 Req 2.2: amm_save_pending に event_type=auto-merge-design-merged を渡す" "auto-merge-design-merged" "$AMM_SAVE_PENDING_LAST_EVENT_TYPE"
# `--auto --squash --delete-branch` 全フラグが揃っていることを確認
auto_flag=$(count_calls "gh pr merge.*--auto")
squash_flag=$(count_calls "gh pr merge.*--squash")
delete_flag=$(count_calls "gh pr merge.*--delete-branch")
dashdash_flag=$(count_calls "gh pr merge.*-- 100")
assert_eq "Req 3.1: --auto フラグあり" "1" "$auto_flag"
assert_eq "Req 3.1: --squash フラグあり" "1" "$squash_flag"
assert_eq "Req 3.1: --delete-branch フラグあり" "1" "$delete_flag"
assert_eq "NFR 1.2: -- でオプション解釈打ち切り（'-- 100' 形式）" "1" "$dashdash_flag"
# Req 9.1: 成功時 log line に PR 番号 / head sha / head branch を含む
success_log_count=$(count_logs "$LOG_OUT" "PR #100.*auto-merge enabled")
assert_eq "Req 9.1: 成功時 log line に PR 番号 + auto-merge enabled" "1" "$success_log_count"
head_log_count=$(count_logs "$LOG_OUT" "head=claude/issue-354-design-foo")
assert_eq "Req 9.1: 成功時 log line に head branch" "1" "$head_log_count"
sha_log_count=$(count_logs "$LOG_OUT" "sha=abc123def456")
assert_eq "Req 9.1: 成功時 log line に head sha" "1" "$sha_log_count"
cleanup_stub_state

# Req 7.1, 7.4: enable 失敗時 WARN ログを残す（silent fail 禁止）
reset_stub_state
SN_NOTIFY_CALL_COUNT=0
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: Pull Request is not mergeable"
amd_enable_auto_merge_for_pr 200 "claude/issue-354-design-bar" "deadbeef" "https://github.com/owner/test-repo/pull/200" || true
warn_log_count=$(count_logs "$WARN_OUT" "PR #200.*auto-merge enable failed")
assert_eq "Req 7.1 / 7.4: enable 失敗時 WARN ログを残す（api-error）" "1" "$warn_log_count"
api_error_count=$(count_logs "$WARN_OUT" "api-error")
assert_eq "Req 7.1: 一般 API エラーは api-error category で WARN" "1" "$api_error_count"
# Issue #370 Req 2.5: 失敗 path では sn_notify を発火しない
assert_eq "#370 Req 2.5: 失敗 path で sn_notify は呼ばれない" "0" "$SN_NOTIFY_CALL_COUNT"
cleanup_stub_state

# Req 7.2: transport-error 種別の検出
reset_stub_state
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="could not resolve host: api.github.com"
amd_enable_auto_merge_for_pr 201 "claude/issue-354-design-bar" "deadbeef" "https://github.com/owner/test-repo/pull/201" || true
transport_warn_count=$(count_logs "$WARN_OUT" "transport-error")
assert_eq "Req 7.2: network エラーは transport-error category で WARN" "1" "$transport_warn_count"
cleanup_stub_state

# Req 7.5: branch protection rejection の検出
reset_stub_state
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: GraphQL error: Pull request Auto merge is not allowed for this repository"
amd_enable_auto_merge_for_pr 202 "claude/issue-354-design-bar" "deadbeef" "https://github.com/owner/test-repo/pull/202" || true
repo_warn_count=$(count_logs "$WARN_OUT" "repo-config-rejected")
assert_eq "Req 7.5: auto merge 不可は repo-config-rejected category で WARN" "1" "$repo_warn_count"
cleanup_stub_state

# NFR 1.3: 数値でない PR 番号は skip
reset_stub_state
amd_enable_auto_merge_for_pr "abc" "claude/issue-354-design" "sha" "url" || true
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "NFR 1.3: 数値以外の PR 番号で gh pr merge を呼ばない" "0" "$merge_call_count"
cleanup_stub_state

# ============================================================
# Section 4: process_auto_merge_design 統合（AND 二重 opt-in / Req 1.x, 6.x, 7.x）
# ============================================================
echo ""
echo "--- Section 4: process_auto_merge_design AND 二重 opt-in（Req 1.x, 6.x） ---"

# Case A: 両 gate OFF（既定）→ gh ゼロ呼び出し（Req 8.1）
reset_stub_state
unset AUTO_MERGE_DESIGN_ENABLED
unset FULL_AUTO_ENABLED
process_auto_merge_design
gh_count=$(count_calls "^gh ")
assert_eq "Req 8.1: 両 gate OFF で gh ゼロ呼び出し" "0" "$gh_count"
# Req 7.3 (パイプライン継続): process_auto_merge_design 自身は rc=0
assert_rc "Req 7.3 / 7.4: 両 gate OFF でも process_auto_merge_design rc=0（パイプライン継続）" 0 process_auto_merge_design
cleanup_stub_state

# Case B: AUTO_MERGE_DESIGN_ENABLED=true / FULL_AUTO_ENABLED OFF → 早期 return（gh ゼロ呼び出し）
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
unset FULL_AUTO_ENABLED
process_auto_merge_design
gh_count=$(count_calls "^gh ")
assert_eq "Req 1.4: FULL_AUTO_ENABLED OFF で gh ゼロ呼び出し" "0" "$gh_count"
# Req 9.3: FULL_AUTO_ENABLED OFF 起因は #348 既存ログに委ねるため auto-merge-design: ログを出さない
sup_log=$(count_logs "$LOG_OUT" "suppressed")
assert_eq "Req 9.3: FULL_AUTO_ENABLED OFF 起因では auto-merge-design suppression ログを出さない" "0" "$sup_log"
cleanup_stub_state

# Case C: AUTO_MERGE_DESIGN_ENABLED OFF / FULL_AUTO_ENABLED=true → 早期 return（gh ゼロ呼び出し）
reset_stub_state
unset AUTO_MERGE_DESIGN_ENABLED
FULL_AUTO_ENABLED="true"
process_auto_merge_design
gh_count=$(count_calls "^gh ")
assert_eq "Req 1.3 / 8.1: AUTO_MERGE_DESIGN_ENABLED OFF で gh ゼロ呼び出し" "0" "$gh_count"
# Req 9.2: AUTO_MERGE_DESIGN_ENABLED OFF 起因の suppression ログを 1 行出力
sup_log=$(count_logs "$LOG_OUT" "suppressed by AUTO_MERGE_DESIGN_ENABLED")
assert_eq "Req 9.2: AUTO_MERGE_DESIGN_ENABLED OFF 起因の suppression ログを 1 行" "1" "$sup_log"
cleanup_stub_state

# Case D: 両 gate ON / 対象 design PR=1 件 / 全条件満たし → gh pr merge 1 回（design PR fixture）
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 100,
    "headRefName": "claude/issue-354-design-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/100",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
GH_PR_MERGE_RC=0
process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 3.1: 両 gate ON / 全条件満たし → gh pr merge 1 回（design PR）" "1" "$merge_call_count"
# 単記 exactly once（fixture 1 件に対する 1 回呼び出し）の検証
merge_design_call=$(count_calls "gh pr merge.*--auto.*--squash.*--delete-branch.*-- 100")
assert_eq "Req 3.1: gh pr merge --auto --squash --delete-branch -- 100 が exactly once" "1" "$merge_design_call"
cleanup_stub_state

# Case E: 両 gate ON / CONFLICTING design PR → gh pr merge 呼び出しなし（Req 2.4）
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 101,
    "headRefName": "claude/issue-354-design-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "CONFLICTING",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/101",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.4: CONFLICTING design PR → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case F: 両 gate ON / draft design PR → gh pr merge 呼び出しなし（Req 2.2）
# server-side filter で -draft:true があるので gh pr list は draft を返さないはずだが、
# client-side の保険として直接 draft=true を含めて検証する
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 102,
    "headRefName": "claude/issue-354-design-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/102",
    "isDraft": true,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.2: draft design PR → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case G: 両 gate ON / needs-iteration ラベル付き → gh pr merge 呼び出しなし（Req 6.4）
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 103,
    "headRefName": "claude/issue-354-design-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [{"name": "needs-iteration"}],
    "url": "https://github.com/owner/test-repo/pull/103",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 6.4: needs-iteration ラベル付き → gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case H: 両 gate ON / head pattern mismatch（人間が手書きの PR）→ gh pr merge 呼び出しなし（Req 2.1）
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 104,
    "headRefName": "feature/manual-pr",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/104",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.1: head pattern mismatch（手書き branch）→ gh pr merge 呼ばれない" "0" "$merge_call_count"
cleanup_stub_state

# Case I: 両 gate ON / 実装 PR（impl pattern）→ gh pr merge 呼び出しなし（Req 2.6 / 6.7）
# Case I は impl 版（#352）の「設計 PR → skip」と対称構造で、design 版では「実装 PR → skip」を検証する
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 105,
    "headRefName": "claude/issue-354-impl-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/105",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.6 / 6.7: 実装 PR（impl pattern）→ gh pr merge 呼ばれない（非干渉）" "0" "$merge_call_count"
cleanup_stub_state

# Case J: 両 gate ON / 既に auto-merge enabled → gh pr merge 呼び出しなし（Req 6.6 冪等）
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 106,
    "headRefName": "claude/issue-354-design-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/106",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": {"enabledAt": "2026-06-22T00:00:00Z"}
  }
]'
process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 6.6: 既に enabled → gh pr merge 呼ばれない（冪等）" "0" "$merge_call_count"
# already-enabled サマリログを確認
already_log=$(count_logs "$LOG_OUT" "auto-merge already enabled")
assert_eq "Req 6.6: 既に enabled 時の log 出力あり" "1" "$already_log"
cleanup_stub_state

# Case K: 両 gate ON / 失敗注入 → gh pr merge 呼ばれるが WARN ログを残し process rc=0（Req 7.1, 7.3, 7.4）
reset_stub_state
AUTO_MERGE_DESIGN_ENABLED="true"
FULL_AUTO_ENABLED="true"
GH_PR_LIST_RESPONSE='[
  {
    "number": 107,
    "headRefName": "claude/issue-354-design-foo",
    "headRefOid": "abc123",
    "baseRefName": "main",
    "mergeable": "MERGEABLE",
    "labels": [],
    "url": "https://github.com/owner/test-repo/pull/107",
    "isDraft": false,
    "headRepositoryOwner": {"login": "owner"},
    "autoMergeRequest": null
  }
]'
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: not mergeable"
# Req 7.3: 失敗注入でも process_auto_merge_design 自身は rc=0（パイプライン継続）
assert_rc "Req 7.3 / 7.4: gh stub 失敗時にも process_auto_merge_design rc=0" 0 process_auto_merge_design
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 7.1: 失敗注入時も gh pr merge は 1 回呼ばれる" "1" "$merge_call_count"
warn_count=$(count_logs "$WARN_OUT" "auto-merge enable failed")
assert_eq "Req 7.1 / 7.4: 失敗時 WARN ログを残し silent fail させない" "1" "$warn_count"
cleanup_stub_state

# Case L: AUTO_MERGE_DESIGN_ENABLED 不正値（yes / 空文字 / 1 / True / TRUE）→ gh ゼロ呼び出し
for v in "yes" "" "1" "True" "TRUE"; do
  reset_stub_state
  # shellcheck disable=SC2034
  AUTO_MERGE_DESIGN_ENABLED="$v"
  # shellcheck disable=SC2034
  FULL_AUTO_ENABLED="true"
  process_auto_merge_design
  gh_count=$(count_calls "^gh ")
  assert_eq "Req 1.3: AUTO_MERGE_DESIGN_ENABLED='$v' → gh ゼロ呼び出し（安全側 OFF）" "0" "$gh_count"
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
