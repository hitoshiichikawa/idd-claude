#!/usr/bin/env bash
#
# 用途: Issue #388（armed/merged 通知の区別）で新規追加した
#       local-watcher/bin/modules/auto-merge-merged.sh の関数群を fixture と
#       gh / sn_notify stub で検証するスモークテスト。
#
#       対象関数:
#         - amm_resolve_gate_enabled    (Req 3.4, 3.5 / NFR 4.1 安全側正規化)
#         - amm_state_dir / amm_state_path (純粋関数)
#         - amm_save_pending            (Req 2.1, 2.2 / NFR 1.1 / NFR 4.1)
#         - amm_remove_pending          (Req 2.3 / NFR 1.2)
#         - amm_list_pending_pr_numbers (NFR 1.2 / 列挙ヘルパ)
#         - amm_check_one_pending       (Req 2.1, 2.2, 2.3, 2.4 / NFR 4.2)
#         - process_auto_merge_merged   (Req 3.1 / NFR 3.2 / NFR 4.1 統合)
#
#       検証する AC（docs/specs/388-fix-slack-notify-auto-merge-result-succe/requirements.md）:
#         - Req 2.1: auto-merge 経路で merged 観測時に Slack 通知を 1 度送信
#         - Req 2.2: auto-merge-design 経路で merged 観測時に同等に通知
#         - Req 2.3: 同一 PR の merged 通知は運用ライフサイクル中 1 回のみ（state 削除で担保）
#         - Req 2.4: state file に積まれていない PR は通知しない（人間 merge 等）
#         - Req 2.5: SLACK_NOTIFY_ENABLED OFF で curl ゼロ + state file も書かない
#         - Req 3.1 / 3.4: SLACK_NOTIFY_MERGED_ENABLED OFF で本機能導入前と等価
#         - NFR 1.1, 1.2: 1 度発火後の重複抑止（state 削除）
#         - NFR 3.2: 1 サイクルあたりの gh 呼び出し件数に上限を持つ
#         - NFR 4.1: 未 opt-in 時は本機能導入前と等価（gh ゼロ呼び出し / state file 不作成）
#         - NFR 4.2: 観測不能（gh 失敗 / MERGED but mergedAt 空）時は偽陽性発火しない
#
# 配置先: local-watcher/test/auto-merge-merged_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp
# 実行:   bash local-watcher/test/auto-merge-merged_test.sh

set -euo pipefail

# 抽出関数および stub から indirect 参照される変数を多用するため、shellcheck からは
# 未使用に見える。本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMM_MOD="$SCRIPT_DIR/../bin/modules/auto-merge-merged.sh"

if [ ! -f "$AMM_MOD" ]; then
  echo "ERROR: cannot find auto-merge-merged.sh at $AMM_MOD" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH" >&2
  exit 2
fi

# extract_function イディオム
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を auto-merge-merged.sh から読み込む
for fn in amm_log amm_warn amm_error amm_resolve_gate_enabled amm_state_dir amm_state_path amm_save_pending amm_remove_pending amm_list_pending_pr_numbers amm_check_one_pending process_auto_merge_merged; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$AMM_MOD" "$fn")"
done

for fn in amm_resolve_gate_enabled amm_state_dir amm_save_pending amm_check_one_pending process_auto_merge_merged; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ログを観測したいケース用に再定義（既存 auto-merge_test.sh と同形式）。
# LOG_OUT / WARN_OUT は reset_stub_state で初期化される。
LOG_OUT="$(mktemp)"
WARN_OUT="$(mktemp)"
# shellcheck disable=SC2317
amm_log()   { echo "$*" >>"$LOG_OUT"; }
# shellcheck disable=SC2317
amm_warn()  { echo "$*" >>"$WARN_OUT"; }
# shellcheck disable=SC2317
amm_error() { echo "$*" >>"$WARN_OUT"; }

# sn_notify stub: call count + 引数記録（Slack 通知発火を観測）
SN_NOTIFY_CALL_COUNT=0
SN_NOTIFY_LAST_EVENT=""
SN_NOTIFY_LAST_NUMBER=""
SN_NOTIFY_LAST_URL=""
SN_NOTIFY_LAST_RESULT=""
# shellcheck disable=SC2034  # 観測用 / Section ごとに値検証
SN_NOTIFY_LAST_DETAIL=""
# shellcheck disable=SC2317
sn_notify() {
  SN_NOTIFY_CALL_COUNT=$((SN_NOTIFY_CALL_COUNT + 1))
  SN_NOTIFY_LAST_EVENT="${1:-}"
  SN_NOTIFY_LAST_NUMBER="${2:-}"
  SN_NOTIFY_LAST_URL="${3:-}"
  SN_NOTIFY_LAST_RESULT="${4:-}"
  SN_NOTIFY_LAST_DETAIL="${5:-}"
  return 0
}

# gh stub: gh pr view 呼び出し観測
GH_CALL_LOG="$(mktemp)"
GH_PR_VIEW_RESPONSE='{"state":"OPEN","mergedAt":null,"mergeCommit":null,"url":""}'
GH_PR_VIEW_RC=0
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    if [ "$GH_PR_VIEW_RC" -ne 0 ]; then
      return "$GH_PR_VIEW_RC"
    fi
    printf '%s' "$GH_PR_VIEW_RESPONSE"
    return 0
  fi
  return 0
}

# timeout を no-op に
# shellcheck disable=SC2317
timeout() {
  shift  # 第 1 引数（秒数）を捨てる
  "$@"
}

# テスト全体で同じ state dir（mktemp で隔離）を使う
TEST_STATE_DIR=$(mktemp -d -t amm_test.XXXXXX)
trap 'rm -rf "$TEST_STATE_DIR" "$LOG_OUT" "$WARN_OUT" "$GH_CALL_LOG" 2>/dev/null || true' EXIT
# shellcheck disable=SC2034  # 遅延束縛で amm_* 関数本体から参照される
AUTO_MERGE_MERGED_STATE_DIR="$TEST_STATE_DIR"
# shellcheck disable=SC2034
AUTO_MERGE_MERGED_MAX_CHECKS=50
# shellcheck disable=SC2034
AUTO_MERGE_MERGED_GH_TIMEOUT=60

# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
REPO_SLUG="owner-test-repo"

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

reset_state() {
  : >"$LOG_OUT"
  : >"$WARN_OUT"
  : >"$GH_CALL_LOG"
  SN_NOTIFY_CALL_COUNT=0
  SN_NOTIFY_LAST_EVENT=""
  SN_NOTIFY_LAST_NUMBER=""
  SN_NOTIFY_LAST_URL=""
  SN_NOTIFY_LAST_RESULT=""
  # shellcheck disable=SC2034  # 観測専用変数 / Section 内 case で値検証する
  SN_NOTIFY_LAST_DETAIL=""
  rm -f "$TEST_STATE_DIR"/pr-*.json 2>/dev/null || true
}

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# ============================================================
# Section 1: amm_resolve_gate_enabled（Req 3.4, 3.5 / NFR 4.1）
# ============================================================
echo "--- Section 1: amm_resolve_gate_enabled 値正規化（Req 3.4, 3.5 / NFR 4.1） ---"

# 両 OFF（既定）→ disabled
unset SLACK_NOTIFY_ENABLED
unset SLACK_NOTIFY_MERGED_ENABLED
assert_rc "Req 3.4 / NFR 4.1: 両 env 未設定で disabled" 1 amm_resolve_gate_enabled

# SLACK_NOTIFY_ENABLED=true / SLACK_NOTIFY_MERGED_ENABLED 未設定 → disabled（後方互換 / NFR 4.1）
SLACK_NOTIFY_ENABLED="true"
unset SLACK_NOTIFY_MERGED_ENABLED
assert_rc "NFR 4.1: SLACK_NOTIFY_MERGED_ENABLED 未設定で disabled（既存ユーザは影響なし）" 1 amm_resolve_gate_enabled

# SLACK_NOTIFY_ENABLED=false / SLACK_NOTIFY_MERGED_ENABLED=true → disabled（emitter 自体 OFF）
SLACK_NOTIFY_ENABLED="false"
SLACK_NOTIFY_MERGED_ENABLED="true"
assert_rc "Req 3.4: SLACK_NOTIFY_ENABLED OFF が優先（merged だけ ON でも no-op）" 1 amm_resolve_gate_enabled

# 両 true → enabled
SLACK_NOTIFY_ENABLED="true"
SLACK_NOTIFY_MERGED_ENABLED="true"
assert_rc "Req 3.4: 両 env が =true でのみ enabled" 0 amm_resolve_gate_enabled

# SLACK_NOTIFY_MERGED_ENABLED の不正値（typo / 大文字）はすべて OFF
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes" "Enabled" "  true  "; do
  SLACK_NOTIFY_MERGED_ENABLED="$v"
  assert_rc "Req 3.5: SLACK_NOTIFY_MERGED_ENABLED=$(printf '%q' "$v") は disabled（安全側 OFF）" 1 amm_resolve_gate_enabled
done

# ============================================================
# Section 2: amm_state_dir / amm_state_path 純粋関数
# ============================================================
echo ""
echo "--- Section 2: amm_state_dir / amm_state_path 純粋関数 ---"

assert_eq "amm_state_dir は AUTO_MERGE_MERGED_STATE_DIR を返す" "$TEST_STATE_DIR" "$(amm_state_dir)"
assert_eq "amm_state_path: PR=100 → pr-100.json" "$TEST_STATE_DIR/pr-100.json" "$(amm_state_path 100)"

# ============================================================
# Section 3: amm_save_pending — gate OFF で state file を書かない（NFR 4.1）
# ============================================================
echo ""
echo "--- Section 3: amm_save_pending gate OFF（NFR 4.1） ---"

reset_state
unset SLACK_NOTIFY_ENABLED
unset SLACK_NOTIFY_MERGED_ENABLED
amm_save_pending 100 "auto-merge-merged" "feature" "abc123" "https://example.com/100"
if [ -f "$TEST_STATE_DIR/pr-100.json" ]; then
  fail_count_inc() { echo "FAIL: NFR 4.1: gate OFF で state file が作られた"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
  fail_count_inc
else
  echo "PASS: NFR 4.1: gate OFF で state file は作られない"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# SLACK_NOTIFY_ENABLED=true のみ（既存ユーザ相当）でも state file は作られない（merged は別 opt-in）
SLACK_NOTIFY_ENABLED="true"
unset SLACK_NOTIFY_MERGED_ENABLED
amm_save_pending 101 "auto-merge-merged" "feature" "abc123" "https://example.com/101"
if [ -f "$TEST_STATE_DIR/pr-101.json" ]; then
  echo "FAIL: NFR 4.1: merged gate OFF で state file が作られた（既存ユーザ後方互換違反）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: NFR 4.1: SLACK_NOTIFY_ENABLED=true のみで merged gate OFF なら state file は作られない（後方互換）"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# ============================================================
# Section 4: amm_save_pending — gate ON で state file を書く（Req 2.1）
# ============================================================
echo ""
echo "--- Section 4: amm_save_pending gate ON（Req 2.1, 2.2） ---"

reset_state
SLACK_NOTIFY_ENABLED="true"
SLACK_NOTIFY_MERGED_ENABLED="true"
amm_save_pending 100 "auto-merge-merged" "claude/issue-100-impl-foo" "abc123def" "https://github.com/owner/test-repo/pull/100"
if [ -f "$TEST_STATE_DIR/pr-100.json" ]; then
  echo "PASS: Req 2.1: gate ON で state file が atomic に書かれる"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.1: gate ON で state file が書かれない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# state file 中の field を検証
saved_event=$(jq -r '.event_type' "$TEST_STATE_DIR/pr-100.json" 2>/dev/null || echo "")
saved_url=$(jq -r '.url' "$TEST_STATE_DIR/pr-100.json" 2>/dev/null || echo "")
saved_head_sha=$(jq -r '.head_sha' "$TEST_STATE_DIR/pr-100.json" 2>/dev/null || echo "")
assert_eq "Req 2.1: state file の event_type" "auto-merge-merged" "$saved_event"
assert_eq "Req 2.1: state file の url" "https://github.com/owner/test-repo/pull/100" "$saved_url"
assert_eq "Req 2.1: state file の head_sha" "abc123def" "$saved_head_sha"

# design 版も同等に書ける
amm_save_pending 200 "auto-merge-design-merged" "claude/issue-200-design-foo" "deadbeef" "https://github.com/owner/test-repo/pull/200"
if [ -f "$TEST_STATE_DIR/pr-200.json" ]; then
  echo "PASS: Req 2.2: design 経路も state file を書く"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.2: design 経路で state file が書かれない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 不正な PR 番号 → skip + WARN
reset_state
SLACK_NOTIFY_ENABLED="true"
SLACK_NOTIFY_MERGED_ENABLED="true"
amm_save_pending "abc" "auto-merge-merged" "feature" "" "https://example.com"
if [ -f "$TEST_STATE_DIR/pr-abc.json" ]; then
  echo "FAIL: 数値以外の PR 番号で state file が作られた"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: 数値以外の PR 番号は skip"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# 不正な event_type → skip + WARN
amm_save_pending 999 "promote" "feature" "" "https://example.com"
if [ -f "$TEST_STATE_DIR/pr-999.json" ]; then
  echo "FAIL: 不正な event_type で state file が作られた"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: 不正な event_type は skip"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# ============================================================
# Section 5: amm_remove_pending（idempotency / Req 2.3 / NFR 1.2）
# ============================================================
echo ""
echo "--- Section 5: amm_remove_pending（Req 2.3 / NFR 1.2） ---"

reset_state
SLACK_NOTIFY_ENABLED="true"
SLACK_NOTIFY_MERGED_ENABLED="true"
amm_save_pending 300 "auto-merge-merged" "feature" "" "https://example.com/300"
[ -f "$TEST_STATE_DIR/pr-300.json" ] || { echo "ERROR: setup failed (pr-300.json not created)"; exit 2; }
amm_remove_pending 300
if [ -f "$TEST_STATE_DIR/pr-300.json" ]; then
  echo "FAIL: NFR 1.2: amm_remove_pending 後も state file が残った"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: NFR 1.2: amm_remove_pending で state file が削除される"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# 不在 PR の削除（冪等）
amm_remove_pending 999999
echo "PASS: NFR 1.2: 不在 PR の削除でも crash しない（冪等）"
PASS_COUNT=$((PASS_COUNT + 1))

# ============================================================
# Section 6: amm_check_one_pending — merged 観測 → 通知 + state 削除（Req 2.1, 2.3）
# ============================================================
echo ""
echo "--- Section 6: amm_check_one_pending merged 観測（Req 2.1, 2.3） ---"

reset_state
SLACK_NOTIFY_ENABLED="true"
SLACK_NOTIFY_MERGED_ENABLED="true"
amm_save_pending 400 "auto-merge-merged" "claude/issue-400-impl-foo" "abc123" "https://github.com/owner/test-repo/pull/400"

# gh stub を MERGED + mergedAt set に
GH_PR_VIEW_RC=0
GH_PR_VIEW_RESPONSE='{"state":"MERGED","mergedAt":"2026-06-23T10:00:00Z","mergeCommit":{"oid":"def456"},"url":"https://github.com/owner/test-repo/pull/400"}'

amm_check_one_pending 400

assert_eq "Req 2.1: MERGED 観測で sn_notify 1 回発火" "1" "$SN_NOTIFY_CALL_COUNT"
assert_eq "Req 2.1: event_type=auto-merge-merged" "auto-merge-merged" "$SN_NOTIFY_LAST_EVENT"
assert_eq "Req 2.1: number=400" "400" "$SN_NOTIFY_LAST_NUMBER"
assert_eq "Req 2.1: result=merged" "merged" "$SN_NOTIFY_LAST_RESULT"
assert_eq "Req 2.1: url が armed 時点の URL" "https://github.com/owner/test-repo/pull/400" "$SN_NOTIFY_LAST_URL"

# state file が削除される
if [ -f "$TEST_STATE_DIR/pr-400.json" ]; then
  echo "FAIL: Req 2.3: merged 通知後も state file が残った（重複通知の risk）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: Req 2.3 / NFR 1.2: merged 通知発火後に state file が削除される"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# 2 回目の check（state 不在）→ 通知発火しない（重複抑止）
amm_check_one_pending 400
assert_eq "NFR 1.2: 同一 PR の 2 回目観測で sn_notify は呼ばれない（重複抑止）" "1" "$SN_NOTIFY_CALL_COUNT"

# design 経路でも同等に動く
reset_state
amm_save_pending 500 "auto-merge-design-merged" "claude/issue-500-design-foo" "feedface" "https://github.com/owner/test-repo/pull/500"
GH_PR_VIEW_RESPONSE='{"state":"MERGED","mergedAt":"2026-06-23T11:00:00Z","mergeCommit":{"oid":"abcd"},"url":"https://github.com/owner/test-repo/pull/500"}'
amm_check_one_pending 500
assert_eq "Req 2.2: design merged 観測 event_type=auto-merge-design-merged" "auto-merge-design-merged" "$SN_NOTIFY_LAST_EVENT"

# ============================================================
# Section 7: amm_check_one_pending — OPEN 観測時は state 維持 + 通知なし
# ============================================================
echo ""
echo "--- Section 7: OPEN 観測時の non-action（state 維持） ---"

reset_state
amm_save_pending 600 "auto-merge-merged" "feature" "" "https://example.com/600"
GH_PR_VIEW_RC=0
GH_PR_VIEW_RESPONSE='{"state":"OPEN","mergedAt":null,"mergeCommit":null,"url":"https://example.com/600"}'
amm_check_one_pending 600
assert_eq "OPEN 観測で sn_notify は呼ばれない" "0" "$SN_NOTIFY_CALL_COUNT"
if [ -f "$TEST_STATE_DIR/pr-600.json" ]; then
  echo "PASS: OPEN 観測時に state file は維持される（次サイクル）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: OPEN 観測で state file が削除されてしまった"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================
# Section 8: amm_check_one_pending — CLOSED 観測 → 通知せず state 削除（Req 2.4 同等）
# ============================================================
echo ""
echo "--- Section 8: CLOSED 観測（merge せず closed / Req 2.4 同等） ---"

reset_state
amm_save_pending 700 "auto-merge-merged" "feature" "" "https://example.com/700"
GH_PR_VIEW_RC=0
GH_PR_VIEW_RESPONSE='{"state":"CLOSED","mergedAt":null,"mergeCommit":null,"url":"https://example.com/700"}'
amm_check_one_pending 700
assert_eq "Req 2.4: CLOSED（unmerged）観測で sn_notify は呼ばれない" "0" "$SN_NOTIFY_CALL_COUNT"
if [ -f "$TEST_STATE_DIR/pr-700.json" ]; then
  echo "FAIL: CLOSED 観測後に state file が残った（次サイクル無駄な polling）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: CLOSED 観測後に state file は削除される"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# ============================================================
# Section 9: NFR 4.2 — gh 失敗 / MERGED but mergedAt 空 で偽陽性発火しない
# ============================================================
echo ""
echo "--- Section 9: 偽陽性禁止（NFR 4.2） ---"

# gh 失敗
reset_state
amm_save_pending 800 "auto-merge-merged" "feature" "" "https://example.com/800"
GH_PR_VIEW_RC=1
GH_PR_VIEW_RESPONSE=""
amm_check_one_pending 800
assert_eq "NFR 4.2: gh 失敗で sn_notify は呼ばれない（偽陽性禁止）" "0" "$SN_NOTIFY_CALL_COUNT"
if [ -f "$TEST_STATE_DIR/pr-800.json" ]; then
  echo "PASS: NFR 4.2: gh 失敗時に state file は維持（次サイクル再試行）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 4.2: gh 失敗で state file が削除されてしまった（次サイクル再試行不能）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# MERGED but mergedAt 空 → 偽陽性禁止
reset_state
amm_save_pending 801 "auto-merge-merged" "feature" "" "https://example.com/801"
GH_PR_VIEW_RC=0
GH_PR_VIEW_RESPONSE='{"state":"MERGED","mergedAt":null,"mergeCommit":null,"url":"https://example.com/801"}'
amm_check_one_pending 801
assert_eq "NFR 4.2: MERGED but mergedAt 空で sn_notify 呼ばれない（次サイクルで再判定）" "0" "$SN_NOTIFY_CALL_COUNT"
if [ -f "$TEST_STATE_DIR/pr-801.json" ]; then
  echo "PASS: NFR 4.2: MERGED but mergedAt 空時に state file は維持"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 4.2: state file が誤って削除された"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================
# Section 10: amm_list_pending_pr_numbers
# ============================================================
echo ""
echo "--- Section 10: amm_list_pending_pr_numbers ---"

reset_state
amm_save_pending 1000 "auto-merge-merged" "feature" "" "https://example.com/1000"
amm_save_pending 1001 "auto-merge-design-merged" "feature" "" "https://example.com/1001"
amm_save_pending 1002 "auto-merge-merged" "feature" "" "https://example.com/1002"

listed=$(amm_list_pending_pr_numbers | sort -n | tr '\n' ',' | sed 's/,$//')
assert_eq "amm_list_pending_pr_numbers が 3 件の PR 番号を列挙" "1000,1001,1002" "$listed"

# 空 dir も crash しない
rm -f "$TEST_STATE_DIR"/pr-*.json
empty_listed=$(amm_list_pending_pr_numbers)
assert_eq "空 dir で何も出力しない" "" "$empty_listed"

# ============================================================
# Section 11: process_auto_merge_merged 統合（Req 3.1 / NFR 3.2 / NFR 4.1）
# ============================================================
echo ""
echo "--- Section 11: process_auto_merge_merged 統合（Req 3.1 / NFR 3.2 / NFR 4.1） ---"

# Case A: gate OFF（merged_enabled 未設定）→ gh ゼロ呼び出し（NFR 4.1）
reset_state
SLACK_NOTIFY_ENABLED="true"
unset SLACK_NOTIFY_MERGED_ENABLED
process_auto_merge_merged
gh_count=$(count_calls "^gh ")
assert_eq "NFR 4.1: merged gate OFF で gh ゼロ呼び出し" "0" "$gh_count"
assert_eq "NFR 4.1: merged gate OFF で sn_notify ゼロ呼び出し" "0" "$SN_NOTIFY_CALL_COUNT"

# Case B: 両 gate ON / pending state 2 件 / 1 件 MERGED / 1 件 OPEN
reset_state
SLACK_NOTIFY_ENABLED="true"
SLACK_NOTIFY_MERGED_ENABLED="true"
amm_save_pending 2000 "auto-merge-merged" "feature1" "" "https://example.com/2000"
amm_save_pending 2001 "auto-merge-merged" "feature2" "" "https://example.com/2001"
# gh stub は単一レスポンスしか返さないため、まず全体に MERGED を返してから、両方が
# merged 通知される（重複抑止は state file 削除で担保される）ことを確認。
GH_PR_VIEW_RC=0
GH_PR_VIEW_RESPONSE='{"state":"MERGED","mergedAt":"2026-06-23T10:00:00Z","mergeCommit":{"oid":"abc"},"url":"https://example.com/x"}'
process_auto_merge_merged
gh_count=$(count_calls "^gh pr view")
assert_eq "Req 3.1: 両 gate ON で pending 2 件に対し gh pr view 2 回呼び出し" "2" "$gh_count"
assert_eq "Req 3.1: 両 MERGED 観測で sn_notify 2 回発火" "2" "$SN_NOTIFY_CALL_COUNT"
remaining=$(amm_list_pending_pr_numbers | wc -l | tr -d ' ')
assert_eq "Req 2.3: 全 MERGED 観測後に pending state 0 件" "0" "$remaining"

# Case C: NFR 3.2 — gh 呼び出し件数上限
reset_state
SLACK_NOTIFY_ENABLED="true"
SLACK_NOTIFY_MERGED_ENABLED="true"
for i in 3001 3002 3003 3004 3005; do
  amm_save_pending "$i" "auto-merge-merged" "feature" "" "https://example.com/$i"
done
AUTO_MERGE_MERGED_MAX_CHECKS=2
GH_PR_VIEW_RESPONSE='{"state":"OPEN","mergedAt":null,"mergeCommit":null,"url":"https://example.com/x"}'
process_auto_merge_merged
gh_count=$(count_calls "^gh pr view")
assert_eq "NFR 3.2: AUTO_MERGE_MERGED_MAX_CHECKS=2 で gh pr view は 2 回まで" "2" "$gh_count"
# 残り pending は 5 件のまま（全 OPEN）
remaining=$(amm_list_pending_pr_numbers | wc -l | tr -d ' ')
assert_eq "NFR 3.2: 上限到達後も残り pending は維持される" "5" "$remaining"
# 上限正規化（不正値は既定 50 へ）
AUTO_MERGE_MERGED_MAX_CHECKS="-1"
reset_state
amm_save_pending 4000 "auto-merge-merged" "feature" "" "https://example.com/4000"
GH_PR_VIEW_RESPONSE='{"state":"OPEN","mergedAt":null,"mergeCommit":null,"url":"https://example.com/x"}'
process_auto_merge_merged
gh_count=$(count_calls "^gh pr view")
assert_eq "NFR 3.2: AUTO_MERGE_MERGED_MAX_CHECKS=-1 は既定 50 に正規化（1 件は通る）" "1" "$gh_count"
# shellcheck disable=SC2034  # 後続テストへの reset / 値は process 内 fallback でも担保される
AUTO_MERGE_MERGED_MAX_CHECKS=50

# Case D: state dir 不在でも crash しない
reset_state
# shellcheck disable=SC2034
SLACK_NOTIFY_ENABLED="true"
# shellcheck disable=SC2034
SLACK_NOTIFY_MERGED_ENABLED="true"
rm -rf "$TEST_STATE_DIR"
process_auto_merge_merged
gh_count=$(count_calls "^gh ")
assert_eq "state dir 不在で gh ゼロ呼び出し（crash せず return）" "0" "$gh_count"
mkdir -p "$TEST_STATE_DIR"

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
