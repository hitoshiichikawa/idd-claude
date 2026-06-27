#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の Quota-Aware Stage Wrapper
#       (qa_run_claude_stage) を fixture で end-to-end 検証する。
#       Issue #104 で導入。
#
#       検証観点（Req と対応付け）:
#         - 現行スキーマ rate_limit_event_v2 検出 → exit 99 + reset_file = epoch
#           (Req 1.1, 1.2, 5.4)
#         - 旧スキーマ rate_limit_event_v1 検出 → exit 99 + reset_file = epoch
#           (Req 2.1, 5.4)
#         - synthetic 429 result（rate_limit_info 同居） → exit 99 + reset_file = epoch
#           (Req 3.1, 3.3, 5.4)
#         - 通常成功（detection なし） → exit 0
#           (Req 3.4)
#         - synthetic 429 のみで reset 不在 → claude_rc 透過 + warn
#           (Req 3.2)
#         - opt-out (QUOTA_AWARE_ENABLED!=true) → 素通し
#           (NFR 1.1)
#
# 配置先: local-watcher/test/qa_run_claude_stage_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/qa_run_claude_stage_test.sh
# 前提:   issue-watcher.sh から関数 2 つ（qa_log/qa_warn/qa_error と
#         qa_detect_rate_limit / qa_run_claude_stage）を切り出して読み込む。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
# #177 Part 1 で低レベル共通ユーティリティ（qa_log 等のロガーを含む）は
# modules/core_utils.sh へ分離された。関数抽出の探索元に core_utils.sh も含める。
CORE_UTILS_SH="$SCRIPT_DIR/../bin/modules/core_utils.sh"
# #180 Part 2 で quota 待機制御プロセッサ（qa_detect_rate_limit / qa_run_claude_stage 等）は
# modules/quota-aware.sh へ分離された。関数抽出の探索元に quota-aware.sh も含める。
QUOTA_AWARE_SH="$SCRIPT_DIR/../bin/modules/quota-aware.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/qa_detect_rate_limit"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$CORE_UTILS_SH" ]; then
  echo "ERROR: cannot find core_utils.sh at $CORE_UTILS_SH" >&2
  exit 2
fi
if [ ! -f "$QUOTA_AWARE_SH" ]; then
  echo "ERROR: cannot find quota-aware.sh at $QUOTA_AWARE_SH" >&2
  exit 2
fi

# 一時 LOG ファイル（qa_run_claude_stage は $LOG に tee する）
TMPDIR_TEST=$(mktemp -d)
LOG="$TMPDIR_TEST/test.log"
export LOG
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# 必要な関数だけを抽出して eval で読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script" "$CORE_UTILS_SH" "$QUOTA_AWARE_SH"
}

# qa_log / qa_warn / qa_error は qa_run_claude_stage が呼ぶので必ず loaded する
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_log")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_warn")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_error")"
# Issue #416: qa_detect_rate_limit は内部で qa_parse_session_limit_reset を呼ぶため、
# 当該ヘルパーも extract して同 shell に読み込む（extract_function イディオムの依存関数
# 追従 / CLAUDE.md「7. テストの近接配置」）。
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_parse_session_limit_reset")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_detect_rate_limit")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "qa_run_claude_stage")"

for fn in qa_log qa_warn qa_error qa_parse_session_limit_reset qa_detect_rate_limit qa_run_claude_stage; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ─── アサーションヘルパ ───
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

# fake-claude: fixture を stdout にダンプし、指定された exit code を返す。
# qa_run_claude_stage は "$@" を実行するため、引数として fixture と rc を受け取る。
fake_claude() {
  local fx_path="$1"
  local rc="${2:-0}"
  cat "$fx_path"
  return "$rc"
}

# テスト 1 件を実行する補助関数。
# Args: <test_label> <expected_rc> <expected_reset_file_content> <fixture> [fake_claude_rc]
# QUOTA_AWARE_ENABLED は呼び出し側で export する想定。
run_case() {
  local label="$1"
  local expected_rc="$2"
  local expected_reset="$3"
  local fx="$4"
  local fake_rc="${5:-0}"

  local reset_file
  reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
  local rc=0
  qa_run_claude_stage "TestStage" "$reset_file" -- \
    fake_claude "$FIXTURE_DIR/$fx" "$fake_rc" >/dev/null 2>&1 || rc=$?

  local actual_reset
  actual_reset=$(cat "$reset_file" 2>/dev/null || true)
  rm -f "$reset_file" "${reset_file}.detect"

  assert_eq "$label rc" "$expected_rc" "$rc"
  assert_eq "$label reset_file" "$expected_reset" "$actual_reset"
}

# ─── テストケース ───

echo "--- qa_run_claude_stage cases (opt-in) ---"
export QUOTA_AWARE_ENABLED="true"

# Req 1.1, 1.2, 5.4: 現行スキーマ単独 → exit 99 + epoch 永続化
# 注: v2-rate-limit-event-rejected は末尾に reset 無し synthetic 429 を含むが、
# epoch 付き検出を優先採用するため exit 99 + 1778821200 が期待値。
run_case "v2-rate-limit-event-rejected (Req 1.1, 1.2, 5.4)" \
  99 "1778821200" "v2-rate-limit-event-rejected.jsonl" 0

# Req 1.1, 1.3 numeric epoch
run_case "v2-numeric-epoch (Req 1.1, 1.3)" \
  99 "1747375200" "v2-numeric-epoch.jsonl" 0

# Req 1.4: 現行スキーマで reset 欠落 → claude_rc 透過 (fake rc=0) + warn
run_case "v2-no-reset (Req 1.4)" \
  0 "" "v2-no-reset.jsonl" 0

# Req 2.1, 5.4: 旧スキーマ → exit 99 + epoch
run_case "v1-rate-limit-event-exceeded (Req 2.1, 5.4)" \
  99 "1778821200" "v1-rate-limit-event-exceeded.jsonl" 0

# Req 2.2: 旧スキーマ snake-case reset_at
run_case "v1-reset-at-snake (Req 2.2)" \
  99 "1778821200" "v1-reset-at-snake.jsonl" 0

# Req 3.1, 5.4: synthetic 429 (rate_limit_info 同居) → exit 99 + epoch
run_case "synthetic-429-result (Req 3.1, 5.4)" \
  99 "1778821200" "synthetic-429-result.jsonl" 0

# Req 3.2: synthetic 429 単独 + reset 不在 → claude_rc 透過 + warn
run_case "synthetic-429-no-reset (Req 3.2)" \
  0 "" "synthetic-429-no-reset.jsonl" 0

# Req 3.4: 通常成功 → claude_rc=0 透過、reset_file 空
run_case "normal-success (Req 3.4)" \
  0 "" "normal-success.jsonl" 0

# 補助: claude が非 0 で終了する場合は素通し（quota 検出なし時）
run_case "normal-success with claude rc=2 (NFR 1.2 既存 rc 透過)" \
  2 "" "normal-success.jsonl" 2

# Req 5.4: malformed line 混入でも検出を継続
run_case "v2-rate-limit-malformed-line (Req 5.4)" \
  99 "1778821200" "v2-rate-limit-malformed-line.jsonl" 0

# ─── Issue #416: 平文セッション上限経路の統合テスト ───
# epoch は実行時刻依存のため固定値 assert ではなく以下を検証する:
#   - rc=99（既存 JSON 経路と同じ deferral 経路に合流 / Req 1.2）
#   - reset_file に numeric epoch が書かれる（Req 2.2）
#   - その epoch が現在時刻以上である（直近の該当時刻 / Req 2.1）

# 平文単独 + TZ 付き → exit 99 + epoch 永続化（#416 Req 1.1, 1.2, 1.3, 2.1〜2.3）
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rc=0
qa_run_claude_stage "TestStage" "$reset_file" -- \
  fake_claude "$FIXTURE_DIR/session-limit-plain-tokyo-pm.txt" 1 >/dev/null 2>&1 || rc=$?
actual_reset=$(cat "$reset_file" 2>/dev/null || true)
rm -f "$reset_file" "${reset_file}.detect"

assert_eq "session-limit-plain-tokyo-pm rc=99 (#416 Req 1.2)" "99" "$rc"
if [[ "$actual_reset" =~ ^[0-9]+$ ]]; then
  echo "PASS: session-limit-plain-tokyo-pm reset_file numeric (#416 Req 2.2)"
  PASS_COUNT=$((PASS_COUNT + 1))
  now=$(date +%s)
  if [ "$actual_reset" -ge "$now" ]; then
    echo "PASS: session-limit-plain-tokyo-pm epoch >= now (#416 Req 2.1)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: epoch should be >= now (got '$actual_reset' now='$now')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "FAIL: session-limit-plain-tokyo-pm reset_file should be numeric epoch (got '$actual_reset')"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 平文 + 複数行混在でも検出する（#416 Req 2.6）
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rc=0
qa_run_claude_stage "TestStage" "$reset_file" -- \
  fake_claude "$FIXTURE_DIR/session-limit-plain-multiline.txt" 1 >/dev/null 2>&1 || rc=$?
actual_reset=$(cat "$reset_file" 2>/dev/null || true)
rm -f "$reset_file" "${reset_file}.detect"
assert_eq "session-limit-plain-multiline rc=99 (#416 Req 2.6)" "99" "$rc"
if [[ "$actual_reset" =~ ^[0-9]+$ ]]; then
  echo "PASS: session-limit-plain-multiline reset_file numeric (#416 Req 2.6)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: session-limit-plain-multiline reset_file should be numeric epoch (got '$actual_reset')"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 平文だが reset 表記欠落 → reset 欠落 fallback（既存 JSON 経路の reset 欠落と同じ挙動 / #416 Req 2.5）
# 期待: claude_rc 透過（ここでは 1）、reset_file は空
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rc=0
qa_run_claude_stage "TestStage" "$reset_file" -- \
  fake_claude "$FIXTURE_DIR/session-limit-plain-no-reset.txt" 1 >/dev/null 2>&1 || rc=$?
actual_reset=$(cat "$reset_file" 2>/dev/null || true)
rm -f "$reset_file" "${reset_file}.detect"
assert_eq "session-limit-plain-no-reset rc passthrough (#416 Req 2.5)" "1" "$rc"
assert_eq "session-limit-plain-no-reset reset_file empty (#416 Req 2.5)" "" "$actual_reset"

# JSON 検出 + 平文検出の混在: epoch を持つ最新検出が優先される（#416 Req 1.4 二重 escalation 抑止）
# 期待: rc=99、reset_file は numeric epoch（JSON 1778821200 または平文の現在以降 epoch）
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rc=0
qa_run_claude_stage "TestStage" "$reset_file" -- \
  fake_claude "$FIXTURE_DIR/session-limit-plain-mixed-with-json.txt" 1 >/dev/null 2>&1 || rc=$?
actual_reset=$(cat "$reset_file" 2>/dev/null || true)
rm -f "$reset_file" "${reset_file}.detect"
assert_eq "mixed JSON+plain rc=99 (#416 Req 1.4)" "99" "$rc"
if [[ "$actual_reset" =~ ^[0-9]+$ ]]; then
  echo "PASS: mixed JSON+plain reset_file numeric (#416 Req 1.4 / 二重 escalation 抑止)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: mixed JSON+plain reset_file should be numeric epoch (got '$actual_reset')"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# opt-out で平文セッション上限が来ても素通し（#416 Req 3.2, NFR 2.1）
export QUOTA_AWARE_ENABLED="false"
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rm -f "$reset_file"
rc=0
qa_run_claude_stage "TestStage" "$reset_file" -- \
  fake_claude "$FIXTURE_DIR/session-limit-plain-tokyo-pm.txt" 1 >/dev/null 2>&1 || rc=$?
assert_eq "opt-out session-limit-plain rc=1 (#416 Req 3.2, NFR 2.1)" "1" "$rc"
if [ ! -e "$reset_file" ]; then
  echo "PASS: opt-out session-limit-plain reset_file untouched (#416 Req 3.2, NFR 2.1)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  rm -f "$reset_file"
  echo "FAIL: opt-out session-limit-plain reset_file unexpectedly created"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
# opt-in 状態を元に戻す
export QUOTA_AWARE_ENABLED="true"

echo ""
echo "--- qa_run_claude_stage cases (opt-out) ---"
export QUOTA_AWARE_ENABLED="false"

# NFR 1.1: opt-out 時は tee も解析も走らず素通し
# Req 1.1 / NFR 1.1 で claude_rc を完全透過、reset_file は touch されない
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rm -f "$reset_file"  # opt-out 時は touch されないことを確認するため事前削除
rc=0
qa_run_claude_stage "TestStage" "$reset_file" -- \
  fake_claude "$FIXTURE_DIR/v2-rate-limit-event-rejected.jsonl" 0 >/dev/null 2>&1 || rc=$?
assert_eq "opt-out v2 input rc=0 (NFR 1.1)" "0" "$rc"
if [ ! -e "$reset_file" ]; then
  echo "PASS: opt-out reset_file untouched (NFR 1.1)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: opt-out reset_file unexpectedly created"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# opt-out で claude rc を透過
reset_file=$(mktemp -p "$TMPDIR_TEST" "reset.XXXXXX")
rm -f "$reset_file"
rc=0
qa_run_claude_stage "TestStage" "$reset_file" -- \
  fake_claude "$FIXTURE_DIR/normal-success.jsonl" 7 >/dev/null 2>&1 || rc=$?
assert_eq "opt-out preserves claude rc=7 (NFR 1.1, 1.2)" "7" "$rc"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
