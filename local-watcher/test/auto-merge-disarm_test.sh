#!/usr/bin/env bash
#
# 用途: Issue #434 Defect A（arm 後の terminal 遷移を disarm する processor）で
#       新規追加した local-watcher/bin/modules/auto-merge-disarm.sh の関数群を
#       fixture と gh stub で検証するスモークテスト。
#
#       対象関数:
#         - amx_resolve_gate_enabled    (NFR 1.1, 1.2 / gate OR 拡張 + kill switch AND)
#         - amx_should_disarm_for_pr    (Req 1.1〜1.3, 1.5 / Req 2.1, 2.2 純粋判定)
#         - amx_disarm_pr               (Req 1.x / Req 2.4 fail-open / NFR 2.1, 2.2, 3.1)
#         - process_auto_merge_disarm   (Req 1.4, 2.3, 2.5 / NFR 1.1, 3.x 統合)
#
#       検証する AC（docs/specs/434-fix-auto-merge-claude-failed-arm-native/requirements.md）:
#         - Req 1.1: arm 済み + claude-failed → disarm 対象
#         - Req 1.2: arm 済み + needs-decisions → disarm 対象
#         - Req 1.3: arm 済み + 両 terminal ラベル → disarm 対象
#         - Req 1.4: GitHub 直接クエリで対象列挙（gh pr list 経由 / pending state dir 非依存）
#         - Req 1.5: arm 済みだが terminal ラベル無し → disarm しない
#         - Req 2.1: 未 arm（autoMergeRequest == null）→ 対象外（no-op）
#         - Req 2.2: open でない（merged / closed）→ 対象外
#         - Req 2.3: disarm 対象 0 件 → 外部副作用なしでサイクル終了
#         - Req 2.4: disarm 失敗時 WARN 1 行 + fail-open
#         - Req 2.5: 1 件失敗で残りを中断しない
#         - NFR 1.1: gate OFF（両 arm 源 OFF / kill switch OFF）→ gh ゼロ呼び出し
#
# 配置先: local-watcher/test/auto-merge-disarm_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto-merge-disarm_test.sh

set -euo pipefail

# 抽出関数および stub から indirect 参照される変数を多用するため、shellcheck からは
# 未使用に見える。本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMX_MOD="$SCRIPT_DIR/../bin/modules/auto-merge-disarm.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$AMX_MOD" ]; then
  echo "ERROR: cannot find auto-merge-disarm.sh at $AMX_MOD" >&2
  exit 2
fi
if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH" >&2
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

# 対象関数群を auto-merge-disarm.sh から読み込む
for fn in amx_log amx_warn amx_error amx_resolve_gate_enabled amx_should_disarm_for_pr amx_disarm_pr process_auto_merge_disarm; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$AMX_MOD" "$fn")"
done

# full_auto_enabled は issue-watcher.sh 本体に定義されている（#348）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in amx_resolve_gate_enabled amx_should_disarm_for_pr amx_disarm_pr process_auto_merge_disarm full_auto_enabled; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される / SC2034 false-positive）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
LABEL_NEEDS_DECISIONS="needs-decisions"
# shellcheck disable=SC2034
AUTO_MERGE_GIT_TIMEOUT=60
# shellcheck disable=SC2034
AUTO_MERGE_DISARM_MAX_PRS=10
# shellcheck disable=SC2034
AUTO_MERGE_HEAD_PATTERN='^claude/issue-.*-impl'
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
  # 失敗注入を PR 番号で制御する場合に使う（"" なら無効）。
  GH_PR_MERGE_FAIL_FOR=""
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

# amx_log / amx_warn / amx_error を上書きして出力をファイルへリダイレクト
# shellcheck disable=SC2317
amx_log()   { echo "$*" >>"$LOG_OUT"; }
# shellcheck disable=SC2317
amx_warn()  { echo "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
amx_error() { echo "$*" >>"$WARN_OUT"; }

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
          printf '%s' "$GH_PR_LIST_RESPONSE"
          return 0
          ;;
        merge)
          # `gh pr merge --repo ... --disable-auto -- <PR>` の PR 番号を末尾引数から取る。
          local last_arg=""
          for last_arg in "$@"; do :; done
          # 特定 PR 番号への失敗注入（Req 2.4 / 2.5）。
          if [ -n "$GH_PR_MERGE_FAIL_FOR" ] && [ "$last_arg" = "$GH_PR_MERGE_FAIL_FOR" ]; then
            [ -n "$GH_PR_MERGE_STDERR" ] && printf '%s\n' "$GH_PR_MERGE_STDERR" >&2
            return 1
          fi
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

# Helper: amx_should_disarm_for_pr 用の PR JSON ビルダー
build_pr_json() {
  local pr_number="$1"
  local head_ref="$2"
  local state="$3"           # OPEN / MERGED / CLOSED
  local labels_csv="$4"      # "claude-failed,..." (カンマ区切り / 空可)
  local auto_merge="$5"      # "" or "{...}"（autoMergeRequest）
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
  "labels": $labels_json,
  "url": "https://github.com/owner/test-repo/pull/$pr_number",
  "state": "$state",
  "isDraft": false,
  "headRepositoryOwner": {"login": "owner"},
  "autoMergeRequest": $auto_merge_field
}
EOF
}

ARMED='{"enabledAt":"2026-06-29T00:00:00Z"}'

# ============================================================
# Section 1: amx_resolve_gate_enabled（NFR 1.1, 1.2 / gate OR 拡張 + kill switch AND）
# ============================================================
echo "--- Section 1: amx_resolve_gate_enabled gate 判定 ---"

# kill switch OFF → 常に OFF
unset FULL_AUTO_ENABLED
AUTO_MERGE_ENABLED="true"
AUTO_MERGE_DESIGN_ENABLED="true"
assert_rc "NFR 1.1: FULL_AUTO_ENABLED OFF → gate OFF（rc=1）" 1 amx_resolve_gate_enabled

# kill switch ON / 両 arm 源 OFF → OFF
FULL_AUTO_ENABLED="true"
unset AUTO_MERGE_ENABLED
unset AUTO_MERGE_DESIGN_ENABLED
assert_rc "NFR 1.1: 両 arm 源 OFF → gate OFF（rc=1）" 1 amx_resolve_gate_enabled

# kill switch ON / AUTO_MERGE_ENABLED のみ ON → ON
FULL_AUTO_ENABLED="true"
AUTO_MERGE_ENABLED="true"
unset AUTO_MERGE_DESIGN_ENABLED
assert_rc "gate OR: AUTO_MERGE_ENABLED のみ ON → gate ON（rc=0）" 0 amx_resolve_gate_enabled

# kill switch ON / AUTO_MERGE_DESIGN_ENABLED のみ ON → ON
FULL_AUTO_ENABLED="true"
unset AUTO_MERGE_ENABLED
AUTO_MERGE_DESIGN_ENABLED="true"
assert_rc "gate OR: AUTO_MERGE_DESIGN_ENABLED のみ ON → gate ON（rc=0）" 0 amx_resolve_gate_enabled

# 不正値（安全側 OFF）
FULL_AUTO_ENABLED="true"
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes"; do
  AUTO_MERGE_ENABLED="$v"
  AUTO_MERGE_DESIGN_ENABLED="$v"
  assert_rc "NFR 1.1: arm 源='$v' は安全側 OFF" 1 amx_resolve_gate_enabled
done
# テスト後の gate 値を ON に戻しておく（後続 Section 4 用）
# shellcheck disable=SC2034
FULL_AUTO_ENABLED="true"
# shellcheck disable=SC2034
AUTO_MERGE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_MERGE_DESIGN_ENABLED="true"

# ============================================================
# Section 2: amx_should_disarm_for_pr 純粋判定（Req 1.1〜1.3, 1.5 / Req 2.1, 2.2）
# ============================================================
echo ""
echo "--- Section 2: amx_should_disarm_for_pr 判定 ---"

# Req 1.1: arm 済み + claude-failed → true（rc=0）
PR_FAILED=$(build_pr_json 100 "claude/issue-434-impl-foo" "OPEN" "claude-failed" "$ARMED")
assert_rc "Req 1.1: arm 済み + claude-failed → disarm 対象" 0 amx_should_disarm_for_pr "$PR_FAILED"

# Req 1.2: arm 済み + needs-decisions → true
PR_NEEDS=$(build_pr_json 101 "claude/issue-434-impl-foo" "OPEN" "needs-decisions" "$ARMED")
assert_rc "Req 1.2: arm 済み + needs-decisions → disarm 対象" 0 amx_should_disarm_for_pr "$PR_NEEDS"

# Req 1.3: arm 済み + 両 terminal ラベル → true
PR_BOTH=$(build_pr_json 102 "claude/issue-434-impl-foo" "OPEN" "claude-failed,needs-decisions" "$ARMED")
assert_rc "Req 1.3: arm 済み + 両 terminal ラベル → disarm 対象" 0 amx_should_disarm_for_pr "$PR_BOTH"

# Req 1.5: arm 済みだが terminal ラベル無し → false（rc=1）
PR_NO_TERMINAL=$(build_pr_json 103 "claude/issue-434-impl-foo" "OPEN" "ready-for-review" "$ARMED")
assert_rc "Req 1.5: arm 済み + terminal ラベル無し → disarm しない" 1 amx_should_disarm_for_pr "$PR_NO_TERMINAL"

# Req 2.1: 未 arm（autoMergeRequest == null）→ false
PR_NOT_ARMED=$(build_pr_json 104 "claude/issue-434-impl-foo" "OPEN" "claude-failed" "")
assert_rc "Req 2.1: 未 arm + claude-failed → disarm 対象外（no-op）" 1 amx_should_disarm_for_pr "$PR_NOT_ARMED"

# Req 2.2: MERGED（open でない）→ false
PR_MERGED=$(build_pr_json 105 "claude/issue-434-impl-foo" "MERGED" "claude-failed" "$ARMED")
assert_rc "Req 2.2: MERGED PR → disarm 対象外" 1 amx_should_disarm_for_pr "$PR_MERGED"

# Req 2.2: CLOSED（open でない）→ false
PR_CLOSED=$(build_pr_json 106 "claude/issue-434-impl-foo" "CLOSED" "needs-decisions" "$ARMED")
assert_rc "Req 2.2: CLOSED PR → disarm 対象外" 1 amx_should_disarm_for_pr "$PR_CLOSED"

# design PR（arm 済み + terminal）も対象（head pattern は process 側でフィルタ。判定は state/label/arm のみ）
PR_DESIGN=$(build_pr_json 107 "claude/issue-434-design-foo" "OPEN" "claude-failed" "$ARMED")
assert_rc "design PR でも arm + terminal なら disarm 対象" 0 amx_should_disarm_for_pr "$PR_DESIGN"

# ============================================================
# Section 3: amx_disarm_pr 呼び出し検証（Req 1.x / Req 2.4 / NFR 2.1, 2.2, 3.1）
# ============================================================
echo ""
echo "--- Section 3: amx_disarm_pr 呼び出し検証 ---"

# Req 1.x: gh pr merge --disable-auto が呼ばれる + 成功 log
reset_stub_state
GH_PR_MERGE_RC=0
amx_disarm_pr 100 "claude/issue-434-impl-foo" "https://github.com/owner/test-repo/pull/100"
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 1.x: amx_disarm_pr → gh pr merge 1 回発火" "1" "$merge_call_count"
disable_flag=$(count_calls "gh pr merge.*--disable-auto")
assert_eq "Req 1.x: --disable-auto フラグあり" "1" "$disable_flag"
opt_term=$(count_calls "gh pr merge.*-- 100")
assert_eq "NFR 2.2: -- でオプション解釈打ち切り + PR 番号" "1" "$opt_term"
disarmed_log=$(count_logs "$LOG_OUT" "PR #100.*disarmed")
assert_eq "NFR 3.1: 成功時 disarmed log line に PR 番号" "1" "$disarmed_log"
cleanup_stub_state

# Req 2.4: disarm 失敗時 WARN 1 行 + fail-open（rc=1）
reset_stub_state
GH_PR_MERGE_RC=1
GH_PR_MERGE_STDERR="HTTP 422: something failed"
amx_disarm_pr 200 "claude/issue-434-impl-bar" "https://github.com/owner/test-repo/pull/200" || true
warn_log=$(count_logs "$WARN_OUT" "PR #200.*disarm failed")
assert_eq "Req 2.4: disarm 失敗時 WARN を 1 行残す（silent fail 禁止）" "1" "$warn_log"
assert_rc "Req 2.4: disarm 失敗で rc=1（fail-open 呼出側で吸収）" 1 amx_disarm_pr 200 "head" "url"
cleanup_stub_state

# NFR 2.1: 数値でない PR 番号は gh を呼ばずに skip
reset_stub_state
amx_disarm_pr "abc" "claude/issue-434-impl" "url" || true
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "NFR 2.1: 数値以外の PR 番号で gh pr merge を呼ばない" "0" "$merge_call_count"
cleanup_stub_state

# ============================================================
# Section 4: process_auto_merge_disarm 統合（Req 1.4, 2.3, 2.5 / NFR 1.1）
# ============================================================
echo ""
echo "--- Section 4: process_auto_merge_disarm 統合 ---"

# Case A: gate OFF（kill switch OFF）→ gh ゼロ呼び出し（NFR 1.1）
reset_stub_state
unset FULL_AUTO_ENABLED
AUTO_MERGE_ENABLED="true"
AUTO_MERGE_DESIGN_ENABLED="true"
process_auto_merge_disarm
gh_count=$(count_calls "^gh ")
assert_eq "NFR 1.1: kill switch OFF で gh ゼロ呼び出し" "0" "$gh_count"
cleanup_stub_state

# Case B: gate OFF（両 arm 源 OFF）→ gh ゼロ呼び出し（NFR 1.1）
reset_stub_state
FULL_AUTO_ENABLED="true"
unset AUTO_MERGE_ENABLED
unset AUTO_MERGE_DESIGN_ENABLED
process_auto_merge_disarm
gh_count=$(count_calls "^gh ")
assert_eq "NFR 1.1: 両 arm 源 OFF で gh ゼロ呼び出し" "0" "$gh_count"
cleanup_stub_state

# 以降 gate ON
# shellcheck disable=SC2034
FULL_AUTO_ENABLED="true"
# shellcheck disable=SC2034
AUTO_MERGE_ENABLED="true"
# shellcheck disable=SC2034
AUTO_MERGE_DESIGN_ENABLED="true"

# Case C: gate ON / arm 済み + claude-failed の impl PR 1 件 → disarm 1 回（Req 1.1, 1.4）
reset_stub_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 300 "claude/issue-434-impl-foo" "OPEN" "claude-failed" "$ARMED")]"
process_auto_merge_disarm
# gh pr list が GitHub 直接クエリで呼ばれる（Req 1.4）
list_count=$(count_calls "^gh pr list")
assert_eq "Req 1.4: GitHub 直接クエリ（gh pr list）で対象列挙" "1" "$list_count"
merge_call_count=$(count_calls "^gh pr merge.*--disable-auto")
assert_eq "Req 1.1: arm + claude-failed → disarm 1 回" "1" "$merge_call_count"
summary_log=$(count_logs "$LOG_OUT" "サマリ: disarmed=1")
assert_eq "NFR 3.1: サマリ行に disarmed=1" "1" "$summary_log"
cleanup_stub_state

# Case D: gate ON / 対象 0 件（arm 済みだが terminal ラベル無し）→ disarm 呼び出しゼロ（Req 1.5, 2.3）
reset_stub_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 301 "claude/issue-434-impl-foo" "OPEN" "ready-for-review" "$ARMED")]"
process_auto_merge_disarm
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 1.5 / 2.3: terminal ラベル無し → disarm 呼び出しゼロ" "0" "$merge_call_count"
summary_log=$(count_logs "$LOG_OUT" "サマリ: disarmed=0, failed=0")
assert_eq "NFR 3.2: 対象 0 件はサマリ 1 行のみ" "1" "$summary_log"
cleanup_stub_state

# Case E: gate ON / 未 arm + terminal → disarm 呼び出しゼロ（Req 2.1）
reset_stub_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 302 "claude/issue-434-impl-foo" "OPEN" "claude-failed" "")]"
process_auto_merge_disarm
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.1: 未 arm PR → disarm 呼び出しゼロ" "0" "$merge_call_count"
cleanup_stub_state

# Case F: gate ON / 人間が手書きの PR（head pattern mismatch）→ disarm 呼び出しゼロ
reset_stub_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 303 "feature/manual-pr" "OPEN" "claude-failed" "$ARMED")]"
process_auto_merge_disarm
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "head pattern mismatch（手書き PR）→ disarm 呼び出しゼロ" "0" "$merge_call_count"
cleanup_stub_state

# Case G: gate ON / design PR + arm + needs-decisions → disarm 1 回（Req 1.2 / OR head pattern）
reset_stub_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 304 "claude/issue-434-design-foo" "OPEN" "needs-decisions" "$ARMED")]"
process_auto_merge_disarm
merge_call_count=$(count_calls "^gh pr merge.*--disable-auto")
assert_eq "Req 1.2: design PR + arm + needs-decisions → disarm 1 回" "1" "$merge_call_count"
cleanup_stub_state

# Case H: gate ON / 3 件中 1 件失敗 → 残りを中断しない（Req 2.5）
reset_stub_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 305 "claude/issue-434-impl-a" "OPEN" "claude-failed" "$ARMED"),$(build_pr_json 306 "claude/issue-434-impl-b" "OPEN" "claude-failed" "$ARMED"),$(build_pr_json 307 "claude/issue-434-impl-c" "OPEN" "claude-failed" "$ARMED")]"
GH_PR_MERGE_FAIL_FOR="306"   # 中間の PR を失敗させる
GH_PR_MERGE_STDERR="HTTP 500: boom"
process_auto_merge_disarm
merge_call_count=$(count_calls "^gh pr merge.*--disable-auto")
assert_eq "Req 2.5: 1 件失敗でも 3 件すべて disarm を試行する" "3" "$merge_call_count"
summary_disarmed=$(count_logs "$LOG_OUT" "サマリ: disarmed=2, failed=1")
assert_eq "Req 2.5: サマリに disarmed=2, failed=1" "1" "$summary_disarmed"
cleanup_stub_state

# Case I: gate ON / merged PR + arm + terminal → disarm 呼び出しゼロ（Req 2.2）
reset_stub_state
GH_PR_LIST_RESPONSE="[$(build_pr_json 308 "claude/issue-434-impl-foo" "MERGED" "claude-failed" "$ARMED")]"
process_auto_merge_disarm
merge_call_count=$(count_calls "^gh pr merge")
assert_eq "Req 2.2: MERGED PR → disarm 呼び出しゼロ" "0" "$merge_call_count"
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
