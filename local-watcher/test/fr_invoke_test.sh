#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した Context Collection Layer + Recovery Execution Layer
#       （fr_collect_issue_context / fr_collect_pr_ci_context / fr_invoke_claude）を
#       gh / claude stub で検証するスモークテスト。
#
#       対象関数:
#         - fr_collect_issue_context  (Issue #359 Req 3.1 / 3.5 / NFR 3.1 / NFR 5.2)
#         - fr_collect_pr_ci_context  (Issue #359 Req 3.2 / 3.5 / NFR 3.1 / NFR 5.2)
#         - fr_invoke_claude          (Issue #359 Req 3.1 / 3.2 / NFR 3.1 / NFR 3.2 /
#                                       NFR 5.2、quota 検出 exit 99 伝播)
#
#       検証する AC（docs/specs/359-feat-watcher-failed-recovery-sh-claude-f/requirements.md）:
#         - Req 3.1: claude session 起動で Issue context を集約
#         - Req 3.2: PR の CI ログ集約
#         - Req 3.5: 未信頼入力（branch 名 / コメント本文）の sanitize
#         - NFR 3.1: Issue/PR 番号 ^[0-9]+$ 検証、jq --arg、gh 引数経由
#         - NFR 3.2: secrets を prompt 本文に埋め込まない（caller が値を引数で渡す）
#         - NFR 5.2: API 失敗時に fr_warn + 部分結果（caller を落とさない）
#         - quota 検出時 exit 99 が伝播する（fr_invoke_claude の sentinel 契約）
#
# 配置先: local-watcher/test/fr_invoke_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/fr_invoke_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"
QUOTA_AWARE_SH="$SCRIPT_DIR/../bin/modules/quota-aware.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi
if [ ! -f "$QUOTA_AWARE_SH" ]; then
  echo "ERROR: cannot find quota-aware.sh at $QUOTA_AWARE_SH" >&2
  exit 2
fi

# 既存テスト（fr_state_test.sh / fr_fetch_test.sh / fr_no_progress_test.sh）と同じ
# イディオム: 対象スクリプトから 1 関数だけを awk で切り出して eval で読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 抽出: failed-recovery.sh から 3 関数 + quota-aware.sh から qa_detect_rate_limit
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_collect_issue_context")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_collect_pr_ci_context")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_invoke_claude")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$QUOTA_AWARE_SH" "qa_detect_rate_limit")"

for fn in fr_collect_issue_context fr_collect_pr_ci_context fr_invoke_claude qa_detect_rate_limit; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── グローバル env（遅延束縛で抽出関数本体から参照される） ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
FAILED_RECOVERY_GIT_TIMEOUT=60
# shellcheck disable=SC2034
FAILED_RECOVERY_DEV_MODEL="claude-opus-4-7"
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_TURNS=20

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
  local actual_rc="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  pattern: $pattern"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "FAIL: $label"
    echo "  unexpected match for pattern: $pattern"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ── stub state ──
GH_CALL_LOG=""
FR_WARN_TRACE=""
FR_LOG_TRACE=""
CLAUDE_CALL_LOG=""
GH_ISSUE_VIEW_RESPONSE=""
GH_PR_CHECKS_RESPONSE=""
GH_RUN_VIEW_RESPONSE=""
GH_ISSUE_VIEW_RC=0
GH_PR_CHECKS_RC=0
GH_RUN_VIEW_RC=0
CLAUDE_STREAM_FIXTURE=""
CLAUDE_RC=0

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  FR_WARN_TRACE="$(mktemp)"
  FR_LOG_TRACE="$(mktemp)"
  CLAUDE_CALL_LOG="$(mktemp)"
  GH_ISSUE_VIEW_RESPONSE=""
  GH_PR_CHECKS_RESPONSE=""
  GH_RUN_VIEW_RESPONSE=""
  GH_ISSUE_VIEW_RC=0
  GH_PR_CHECKS_RC=0
  GH_RUN_VIEW_RC=0
  CLAUDE_STREAM_FIXTURE=""
  CLAUDE_RC=0
  LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$FR_WARN_TRACE" "$FR_LOG_TRACE" "$CLAUDE_CALL_LOG" "${LOG:-}" 2>/dev/null || true
}

# fr_warn / fr_log を上書きして呼出を観測（実体は core_utils.sh）
# shellcheck disable=SC2317
fr_warn() {
  echo "$*" >> "$FR_WARN_TRACE"
}
# shellcheck disable=SC2317
fr_log() {
  echo "$*" >> "$FR_LOG_TRACE"
}

# timeout は引数を捨ててコマンドをそのまま実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: gh issue view / gh pr checks / gh run view の呼び出しを観測。
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  case "${1:-}" in
    issue)
      case "${2:-}" in
        view)
          if [ "$GH_ISSUE_VIEW_RC" != "0" ]; then
            return "$GH_ISSUE_VIEW_RC"
          fi
          printf '%s' "$GH_ISSUE_VIEW_RESPONSE"
          return 0
          ;;
      esac
      ;;
    pr)
      case "${2:-}" in
        checks)
          if [ "$GH_PR_CHECKS_RC" != "0" ]; then
            return "$GH_PR_CHECKS_RC"
          fi
          printf '%s' "$GH_PR_CHECKS_RESPONSE"
          return 0
          ;;
      esac
      ;;
    run)
      case "${2:-}" in
        view)
          if [ "$GH_RUN_VIEW_RC" != "0" ]; then
            return "$GH_RUN_VIEW_RC"
          fi
          printf '%s' "$GH_RUN_VIEW_RESPONSE"
          return 0
          ;;
      esac
      ;;
  esac
  return 0
}

# claude stub: 引数列を記録して、CLAUDE_STREAM_FIXTURE の内容を stdout に出す。
# fixture は stream-json の 1 行 1 JSON 形式（quota-aware の qa_detect_rate_limit が
# fold する）。CLAUDE_RC で exit code を制御可能。
# shellcheck disable=SC2317
claude() {
  echo "claude $*" >> "$CLAUDE_CALL_LOG"
  if [ -n "$CLAUDE_STREAM_FIXTURE" ]; then
    printf '%s' "$CLAUDE_STREAM_FIXTURE"
  fi
  return "$CLAUDE_RC"
}

# ============================================================
# Section 1: fr_collect_issue_context — 正常 path（Req 3.1）
# ============================================================
echo "--- Section 1: fr_collect_issue_context 正常 path ---"

reset_stub_state
trap 'cleanup_stub_state' EXIT

GH_ISSUE_VIEW_RESPONSE=$(jq -n '{
  title: "test issue",
  body: "本文本文",
  labels: [{"name":"claude-failed"},{"name":"auto-dev"}],
  comments: [
    {"author":{"login":"user1"},"body":"comment-1"},
    {"author":{"login":"user2"},"body":"comment-2"},
    {"author":{"login":"user3"},"body":"comment-3"},
    {"author":{"login":"user4"},"body":"comment-4"},
    {"author":{"login":"user5"},"body":"comment-5"},
    {"author":{"login":"user6"},"body":"comment-6"}
  ]
}')

out=$(fr_collect_issue_context "42")
context_out="$(mktemp)"
printf '%s' "$out" > "$context_out"

assert_grep "Req 3.1: context に title が含まれる" "test issue" "$context_out"
assert_grep "Req 3.1: context に body が含まれる" "本文本文" "$context_out"
assert_grep "Req 3.1: context に labels が含まれる" "claude-failed" "$context_out"
# 末尾 5 件のみ（comment-1 は含まれず comment-2〜6 が含まれる）
assert_not_grep "Req 3.1: 末尾 5 件のみ抽出（comment-1 は含まれない）" "comment-1" "$context_out"
assert_grep "Req 3.1: 末尾 5 件目（comment-2）は含まれる" "comment-2" "$context_out"
assert_grep "Req 3.1: 末尾 1 件目（comment-6）は含まれる" "comment-6" "$context_out"

# gh issue view が呼ばれ --json 指定が含まれること
assert_grep "Req 3.1: gh issue view が呼ばれる" "^gh issue view 42" "$GH_CALL_LOG"
assert_grep "Req 3.1: --json comments,body,title,labels で取得" "comments,body,title,labels" "$GH_CALL_LOG"
assert_grep "Req 3.1: --repo owner/test-repo が渡される" "--repo owner/test-repo" "$GH_CALL_LOG"

rm -f "$context_out"
cleanup_stub_state

# ============================================================
# Section 2: fr_collect_issue_context — Issue 番号 sanitize（NFR 3.1）
# ============================================================
echo ""
echo "--- Section 2: Issue 番号 sanitize ---"

reset_stub_state
set +e
out=$(fr_collect_issue_context "abc")
rc=$?
set -e
assert_rc "NFR 3.1: 非数値 Issue 番号 → rc=1" "1" "$rc"
assert_eq "NFR 3.1: 非数値 Issue 番号 → stdout 空" "" "$out"
# gh issue view が呼ばれていないこと
assert_not_grep "NFR 3.1: 非数値時は gh issue view を呼ばない" "^gh issue view" "$GH_CALL_LOG"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
assert_eq "NFR 3.1: fr_warn が 1 件呼ばれる" "1" "$warn_count"

# command injection を試みる input（;rm -rf 等）も sanitize される
set +e
out=$(fr_collect_issue_context "42; rm -rf /tmp/x")
rc=$?
set -e
assert_rc "NFR 3.1: スペース・特殊文字を含む Issue 番号 → rc=1" "1" "$rc"

cleanup_stub_state

# ============================================================
# Section 3: fr_collect_issue_context — gh 失敗時の fail-continue（NFR 5.2）
# ============================================================
echo ""
echo "--- Section 3: gh issue view 失敗時の fail-continue ---"

reset_stub_state
GH_ISSUE_VIEW_RC=1
set +e
out=$(fr_collect_issue_context "100")
rc=$?
set -e
assert_rc "NFR 5.2: gh issue view 失敗時も rc=0（fail-continue）" "0" "$rc"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
assert_eq "NFR 5.2: fr_warn が 1 件呼ばれる" "1" "$warn_count"

cleanup_stub_state

# ============================================================
# Section 4: fr_collect_pr_ci_context — 正常 path（Req 3.2）
# ============================================================
echo ""
echo "--- Section 4: fr_collect_pr_ci_context 正常 path ---"

reset_stub_state

GH_PR_CHECKS_RESPONSE=$(jq -n '[
  {"name":"ci","state":"FAILURE","conclusion":"FAILURE","detailsUrl":"https://github.com/owner/repo/actions/runs/9999"},
  {"name":"lint","state":"SUCCESS","conclusion":"SUCCESS","detailsUrl":"https://github.com/owner/repo/actions/runs/8888"},
  {"name":"test","state":"COMPLETED","conclusion":"TIMED_OUT","detailsUrl":"https://github.com/owner/repo/actions/runs/7777"}
]')
GH_RUN_VIEW_RESPONSE=$'log line 1\nlog line 2\nfailure detected\n'

out=$(fr_collect_pr_ci_context "200")
ci_out="$(mktemp)"
printf '%s' "$out" > "$ci_out"

# failing check が 2 件（ci FAILURE / test TIMED_OUT、lint SUCCESS は除外）
assert_grep "Req 3.2: header に failing checks 件数（2 件）" "Failing Checks \(count: 2\)" "$ci_out"
assert_grep "Req 3.2: ci check 名が含まれる" "ci" "$ci_out"
assert_grep "Req 3.2: test check 名が含まれる" "test" "$ci_out"
assert_not_grep "Req 3.2: 成功 check (lint) は含まれない（header 内のみ）" "Log for check: lint" "$ci_out"
assert_grep "Req 3.2: ログ tail が含まれる" "failure detected" "$ci_out"

# gh pr checks + gh run view（2 件分）が呼ばれること
assert_grep "Req 3.2: gh pr checks が呼ばれる" "^gh pr checks 200" "$GH_CALL_LOG"
assert_grep "Req 3.2: gh run view 9999（ci FAILURE） が呼ばれる" "^gh run view 9999" "$GH_CALL_LOG"
assert_grep "Req 3.2: gh run view 7777（test TIMED_OUT） が呼ばれる" "^gh run view 7777" "$GH_CALL_LOG"
assert_not_grep "Req 3.2: 成功 check（lint, run 8888）に gh run view を呼ばない" "^gh run view 8888" "$GH_CALL_LOG"
assert_grep "Req 3.2: --log-failed が渡される" "--log-failed" "$GH_CALL_LOG"

rm -f "$ci_out"
cleanup_stub_state

# ============================================================
# Section 5: fr_collect_pr_ci_context — PR 番号 sanitize（NFR 3.1）
# ============================================================
echo ""
echo "--- Section 5: PR 番号 sanitize ---"

reset_stub_state
set +e
out=$(fr_collect_pr_ci_context "-1")
rc=$?
set -e
assert_rc "NFR 3.1: 非数値 PR 番号（-1）→ rc=1" "1" "$rc"
assert_not_grep "NFR 3.1: 非数値時は gh pr checks を呼ばない" "^gh pr checks" "$GH_CALL_LOG"

set +e
out=$(fr_collect_pr_ci_context "abc; cat /etc/passwd")
rc=$?
set -e
assert_rc "NFR 3.1: 特殊文字を含む PR 番号 → rc=1" "1" "$rc"

cleanup_stub_state

# ============================================================
# Section 6: fr_collect_pr_ci_context — gh pr checks 失敗時の fail-continue（NFR 5.2）
# ============================================================
echo ""
echo "--- Section 6: gh pr checks 失敗時の fail-continue ---"

reset_stub_state
GH_PR_CHECKS_RC=1
set +e
out=$(fr_collect_pr_ci_context "300")
rc=$?
set -e
assert_rc "NFR 5.2: gh pr checks 失敗時も rc=0（fail-continue）" "0" "$rc"
assert_eq "NFR 5.2: gh pr checks 失敗時の stdout は空" "" "$out"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
assert_eq "NFR 5.2: fr_warn が 1 件呼ばれる" "1" "$warn_count"

cleanup_stub_state

# ============================================================
# Section 7: fr_invoke_claude — quota 検出時に exit 99 が伝播
# ============================================================
echo ""
echo "--- Section 7: fr_invoke_claude quota 検出時の exit 99 伝播 ---"

reset_stub_state

# stream-json fixture: rate_limit_event_v1 互換（status="exceeded" + reset epoch）
# qa_detect_rate_limit が `<path>\t<epoch>` を返し、fr_invoke_claude が exit 99 する
CLAUDE_STREAM_FIXTURE='{"type":"rate_limit_event","status":"exceeded","resetsAt":1750000000}
{"type":"result","is_error":false}
'
CLAUDE_RC=0

# fr_invoke_claude 内部の set -e/+e が caller の set -e を上書きするため
# subshell で囲って rc を取り出す（test スクリプトが return 99 で死なないように）
rc=0
( fr_invoke_claude "test prompt body" "test-stage-issue-42" ) || rc=$?
assert_rc "Req 3.x: quota 検出 → exit 99 sentinel" "99" "$rc"

# claude が --model / --max-turns / --permission-mode / --output-format stream-json で呼ばれたこと
assert_grep "Req 3.1: claude -p が呼ばれる" "^claude -p" "$CLAUDE_CALL_LOG"
assert_grep "Req 3.1: --model に FAILED_RECOVERY_DEV_MODEL が渡される" "claude-opus-4-7" "$CLAUDE_CALL_LOG"
assert_grep "Req 3.1: --max-turns に FAILED_RECOVERY_MAX_TURNS が渡される" "max-turns 20" "$CLAUDE_CALL_LOG"
assert_grep "Req 3.1: --permission-mode bypassPermissions" "bypassPermissions" "$CLAUDE_CALL_LOG"
assert_grep "Req 3.1: --output-format stream-json" "stream-json" "$CLAUDE_CALL_LOG"

# prompt が引数として渡されていること（NFR 3.2 + Req 3.1）
assert_grep "NFR 3.2: prompt が引数として渡される（環境変数経由ではない）" "test prompt body" "$CLAUDE_CALL_LOG"
# secrets を含む env var を直接埋め込んでいないこと（GH_TOKEN 等は call log に出ない）
assert_not_grep "NFR 3.2: GH_TOKEN を含む文字列が claude call に登場しない" "GH_TOKEN" "$CLAUDE_CALL_LOG"

cleanup_stub_state

# ============================================================
# Section 8: fr_invoke_claude — 正常終了 → rc=0
# ============================================================
echo ""
echo "--- Section 8: fr_invoke_claude 正常終了 → rc=0 ---"

reset_stub_state

# quota 検出を含まない通常の stream
CLAUDE_STREAM_FIXTURE='{"type":"system","subtype":"init"}
{"type":"result","is_error":false}
'
CLAUDE_RC=0

rc=0
( fr_invoke_claude "another prompt" "test-stage-pr-200" ) || rc=$?
assert_rc "Req 3.1: 正常終了時 rc=0" "0" "$rc"

# fr_log が start / end の 2 回呼ばれていること（観測ログ NFR 4.1 関連）
log_count=$(grep -c "claude session" "$FR_LOG_TRACE" 2>/dev/null || echo "0")
# wc -l 出力に余分な空白が入る環境向けに ascii 値で再評価
log_count=$(printf '%s' "$log_count" | tr -d '[:space:]')
if [ "$log_count" -ge 2 ]; then
  echo "PASS: NFR 4.1: fr_log が 2 件以上呼ばれる（start + end）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 4.1: fr_log が 2 件以上呼ばれる（actual=$log_count）"
  cat "$FR_LOG_TRACE"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_stub_state

# ============================================================
# Section 9: fr_invoke_claude — claude 非ゼロ exit（quota 以外）を透過
# ============================================================
echo ""
echo "--- Section 9: fr_invoke_claude claude 非ゼロ exit 透過 ---"

reset_stub_state

CLAUDE_STREAM_FIXTURE='{"type":"result","is_error":true,"api_error_status":500}
'
CLAUDE_RC=7

rc=0
( fr_invoke_claude "prompt" "test-stage-fail" ) || rc=$?
# quota 検出（429）ではなく 500 + claude rc=7 なので rc=7 が透過する
assert_rc "NFR 5.2: claude 非ゼロ exit（quota 以外）は透過（rc=7）" "7" "$rc"

cleanup_stub_state

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
