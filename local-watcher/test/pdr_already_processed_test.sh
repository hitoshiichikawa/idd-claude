#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の hidden marker per-sha dedup 関数
#       pdr_already_processed の挙動を、stub gh 経由で検証するスモークテスト。
#
#       検証する受入基準（docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/requirements.md）:
#         - Req 1.4 同一 sha への重複起動回避（per-sha dedup）
#         - Req 5.3 hidden marker prefix が PI self-filter `idd-claude:pr-iteration` 非衝突
#
#       検証ケース:
#         1. 同 sha の marker が既存コメントに存在 → 処理済み (rc=0)
#         2. 異なる sha の marker が存在 → 未処理 (rc=1)
#         3. marker 不在（空配列）→ 未処理 (rc=1)
#         4. PR 番号不正 → 安全側で skip (rc=0) + WARN
#         5. sha 空 → 安全側で skip (rc=0) + WARN
#         6. gh API 失敗 → 安全側で skip (rc=0) + WARN（重複投稿回避）
#         7. marker prefix が pr-iteration / pr-reviewer 等と非衝突であることを scan
#
# 配置先: local-watcher/test/pdr_already_processed_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pdr_already_processed_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"

if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して eval。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_already_processed")"

if ! declare -F pdr_already_processed >/dev/null; then
  echo "ERROR: pdr_already_processed not loaded" >&2
  exit 2
fi

# グローバル env（抽出関数本体から参照される）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"

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

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  expected NOT to contain: $(printf '%q' "$needle")"
      echo "  actual                 : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
}

# ── stub state ──
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  GH_API_BODY="[]"
  GH_API_RC=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" 2>/dev/null || true
}

# pdr_warn stub: 観測用 file に追記
# shellcheck disable=SC2317
pdr_warn() { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 最初の引数（秒数）を捨てて残りを実行
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: api 経由の GET だけ実装
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "${1:-}" in
    api)
      printf '%s' "$GH_API_BODY"
      return "$GH_API_RC"
      ;;
    *)
      return 0
      ;;
  esac
}

VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
OTHER_SHA="0000000000000000000000000000000000000000"
VALID_PR="407"

# ============================================================
# Case 1: 同 sha の marker が既存コメントに存在 → 処理済み (rc=0)
# ============================================================
echo "--- Case 1: 同 sha marker 存在 → 処理済み (rc=0) ---"
reset_stub_state
GH_API_BODY=$(jq -nc --arg sha "$VALID_SHA" \
  '[{"body": ("## Design Review\n\n<!-- idd-claude:pr-design-reviewer sha=" + $sha + " kind=decision -->")}]')
local_rc=0
pdr_already_processed "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "Req 1.4: 同 sha marker 存在 → 処理済み (rc=0)" "0" "$local_rc"
cleanup_stub_state

# ============================================================
# Case 2: 異なる sha の marker → 未処理 (rc=1)
# ============================================================
echo ""
echo "--- Case 2: 異なる sha marker → 未処理 (rc=1) ---"
reset_stub_state
GH_API_BODY=$(jq -nc --arg sha "$OTHER_SHA" \
  '[{"body": ("## Design Review\n\n<!-- idd-claude:pr-design-reviewer sha=" + $sha + " kind=decision -->")}]')
local_rc=0
pdr_already_processed "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "Req 1.4: 異なる sha marker → 未処理 (rc=1)" "1" "$local_rc"
cleanup_stub_state

# ============================================================
# Case 3: marker 不在（空配列）→ 未処理 (rc=1)
# ============================================================
echo ""
echo "--- Case 3: marker 不在 → 未処理 (rc=1) ---"
reset_stub_state
GH_API_BODY="[]"
local_rc=0
pdr_already_processed "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "Req 1.4: marker 不在 → 未処理 (rc=1)" "1" "$local_rc"
cleanup_stub_state

# ============================================================
# Case 4: PR 番号不正 → 安全側で skip (rc=0) + WARN
# ============================================================
echo ""
echo "--- Case 4: PR 番号不正 → 安全側 skip (rc=0) ---"
reset_stub_state
local_rc=0
pdr_already_processed "invalid" "$VALID_SHA" || local_rc=$?
assert_eq "Case 4: 不正 PR 番号 → 安全側 skip (rc=0)" "0" "$local_rc"
warn_log=$(cat "$WARN_LOG")
assert_contains "Case 4: WARN ログに不正 PR 番号" "$warn_log" "無効な PR 番号"
cleanup_stub_state

# ============================================================
# Case 5: sha 空 → 安全側 skip (rc=0) + WARN
# ============================================================
echo ""
echo "--- Case 5: sha 空 → 安全側 skip (rc=0) ---"
reset_stub_state
local_rc=0
pdr_already_processed "$VALID_PR" "" || local_rc=$?
assert_eq "Case 5: 空 sha → 安全側 skip (rc=0)" "0" "$local_rc"
warn_log=$(cat "$WARN_LOG")
assert_contains "Case 5: WARN ログに sha が空" "$warn_log" "sha が空"
cleanup_stub_state

# ============================================================
# Case 6: gh API 失敗 → 安全側 skip (rc=0) + WARN
# ============================================================
echo ""
echo "--- Case 6: gh API 失敗 → 安全側 skip (rc=0) ---"
reset_stub_state
GH_API_BODY=""
GH_API_RC=1
local_rc=0
pdr_already_processed "$VALID_PR" "$VALID_SHA" || local_rc=$?
assert_eq "Case 6: gh API 失敗 → 安全側 skip (rc=0)" "0" "$local_rc"
warn_log=$(cat "$WARN_LOG")
assert_contains "Case 6: WARN ログに取得失敗" "$warn_log" "コメント取得に失敗"
cleanup_stub_state

# ============================================================
# Case 7: marker prefix が pi self-filter / pr-reviewer 非衝突であることを scan
# Req 5.3 / NFR 1.2: prefix `pr-design-reviewer` は `pr-iteration` / `pr-reviewer` /
# `pr-adjudicator` のいずれとも前方一致しない
# ============================================================
echo ""
echo "--- Case 7: marker prefix の self-filter 非衝突 scan ---"
PDR_MARKER="idd-claude:pr-design-reviewer"
PI_PREFIX="idd-claude:pr-iteration"
PR_PREFIX="idd-claude:pr-reviewer"
PA_PREFIX="idd-claude:pr-adjudicator"

# substring 非含有を確認
assert_not_contains "Req 5.3: pr-design-reviewer は pr-iteration の prefix を含まない" "$PDR_MARKER" "$PI_PREFIX"
assert_not_contains "Req 5.3: pr-design-reviewer は pr-reviewer prefix を前方一致で含まない（後続文字 -d により分岐）" "${PDR_MARKER:0:24}" "${PR_PREFIX}"
assert_not_contains "Req 5.3: pr-design-reviewer は pr-adjudicator prefix を含まない" "$PDR_MARKER" "$PA_PREFIX"

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
