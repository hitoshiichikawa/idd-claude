#!/usr/bin/env bash
#
# 用途: Issue #412 で追加した Merge Gate Visibility Processor の各判定ヘルパー
#       （mgv_claude_review_required / mgv_pr_has_claude_review_status /
#       mgv_pr_has_adjudicator_marker）の挙動を gh stub で検証するスモークテスト。
#
#       検証する受入基準（docs/specs/412-enhancement-pr-reviewer-404-adjudicator/requirements.md）:
#         - Req 4.1 停滞検知の判定要素（claude-review required + marker 不在 + status 未 publish）
#         - Req 4.3 解消（adjudicator 発火 / catch-up 発火）時の冪等取り消し判定要素
#         - Req 4.4 fallback 経路と本可視化の発火順序を構成する各 read-only ヘルパー
#         - NFR 1.1 required でない repo は API 1 回呼び以外副作用なし
#
# 配置先: local-watcher/test/mgv_merge_gate_visibility_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/mgv_merge_gate_visibility_test.sh

set -euo pipefail

# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_SH="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"

if [ ! -f "$PR_SH" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を読み込む（mgv_* と依存先 pr_warn / timeout はテスト内で stub）。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_SH" "mgv_claude_review_required")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_SH" "mgv_pr_has_claude_review_status")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_SH" "mgv_pr_has_adjudicator_marker")"

REPO="owner/test-repo"
PR_REVIEWER_GIT_TIMEOUT=10

PASS_COUNT=0
FAIL_COUNT=0

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  local actual_rc="$3"
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

# ─── stubs ─────────────────────────────────────────────────────────────────────
# - timeout: 引数の `timeout SECS gh ...` を `gh ...` だけに転送（実 timeout は使わない）
# - gh: $MGV_GH_SCRIPT で振る舞いを切り替える stub。各テストケース冒頭で MGV_GH_SCRIPT を設定。
# - jq: 本物を呼ぶ（jq は外部 CLI として依存登録済み）

# shellcheck disable=SC2317
timeout() {
  shift  # 秒数を捨てる
  "$@"
}

# 各テストで上書きする gh stub の振る舞い名
MGV_GH_SCRIPT=""

# shellcheck disable=SC2317
gh() {
  case "$MGV_GH_SCRIPT" in
    protection_with_claude_review)
      # branch protection に claude-review が含まれる
      printf '%s\n' '["ci","claude-review","codex-review"]'
      return 0
      ;;
    protection_without_claude_review)
      # branch protection に claude-review が含まれない（required は ci のみ）
      printf '%s\n' '["ci"]'
      return 0
      ;;
    protection_empty)
      # required_status_checks 自体は存在するが contexts が空
      printf '%s\n' '[]'
      return 0
      ;;
    protection_not_found)
      # branch protection 未設定 → 404
      return 1
      ;;
    statuses_with_claude_review)
      printf '%s\n' '["ci","claude-review"]'
      return 0
      ;;
    statuses_without_claude_review)
      printf '%s\n' '["ci"]'
      return 0
      ;;
    statuses_api_fail)
      return 1
      ;;
    comments_with_marker)
      cat <<'EOF'
First comment unrelated
<!-- idd-claude:pr-adjudicator sha=abc1234 -->
Adjudicator decision summary
EOF
      return 0
      ;;
    comments_without_marker)
      cat <<'EOF'
Random comment
Another random comment
EOF
      return 0
      ;;
    comments_with_marker_wrong_sha)
      cat <<'EOF'
<!-- idd-claude:pr-adjudicator sha=deadbee -->
EOF
      return 0
      ;;
    comments_api_fail)
      return 1
      ;;
    *)
      echo "ERROR: unknown MGV_GH_SCRIPT=${MGV_GH_SCRIPT}" >&2
      return 99
      ;;
  esac
}

# pr_warn は本テストで stderr に出すだけのダミーにする（観測対象ではない）。
# shellcheck disable=SC2317
pr_warn() {
  printf 'pr_warn (stub): %s\n' "$*" >&2
}

# ─── Req 4.1 / 4.3 / NFR 1.1 の判定マトリクス ───

echo "--- mgv_claude_review_required (#412 Req 4.1 / NFR 1.1) ---"

MGV_GH_SCRIPT="protection_with_claude_review"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "Req 4.1: branch protection に claude-review 含 → rc=0 (required)" "0" "$rc"

MGV_GH_SCRIPT="protection_without_claude_review"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "Req 4.1: branch protection に claude-review 不含 → rc=1 (not required)" "1" "$rc"

MGV_GH_SCRIPT="protection_empty"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "Req 4.1: branch protection の contexts 空 → rc=1 (not required)" "1" "$rc"

MGV_GH_SCRIPT="protection_not_found"
rc=0
mgv_claude_review_required "main" || rc=$?
assert_rc "NFR 1.1: branch protection 未設定 (gh api 404) → rc=2 (fail-safe / 呼び出し元 skip)" "2" "$rc"

# 入力検証: 不正な branch 名は rc=1（path traversal / option injection の予防）
MGV_GH_SCRIPT="protection_with_claude_review"  # 呼ばれない想定
rc=0
mgv_claude_review_required "--option-injection" || rc=$?
assert_rc "Req 5.x / 安全側: 不正な branch 名は rc=1 (gh 呼び出し前 reject)" "1" "$rc"

rc=0
mgv_claude_review_required "" || rc=$?
assert_rc "安全側: 空 branch 名は rc=1" "1" "$rc"

echo ""
echo "--- mgv_pr_has_claude_review_status (#412 Req 4.3) ---"

MGV_GH_SCRIPT="statuses_with_claude_review"
rc=0
mgv_pr_has_claude_review_status "abc1234" || rc=$?
assert_rc "Req 4.3: claude-review status 既 publish → rc=0 (clear 対象)" "0" "$rc"

MGV_GH_SCRIPT="statuses_without_claude_review"
rc=0
mgv_pr_has_claude_review_status "abc1234" || rc=$?
assert_rc "Req 4.3: claude-review status 未 publish → rc=1 (stalled 候補)" "1" "$rc"

MGV_GH_SCRIPT="statuses_api_fail"
rc=0
mgv_pr_has_claude_review_status "abc1234" || rc=$?
assert_rc "fail-safe: API 失敗 → rc=2 (呼び出し元で安全側に倒す)" "2" "$rc"

rc=0
mgv_pr_has_claude_review_status "not-a-sha" || rc=$?
assert_rc "安全側: 不正な sha → rc=1 (gh 呼び出し前 reject)" "1" "$rc"

echo ""
echo "--- mgv_pr_has_adjudicator_marker (#412 Req 4.3 / 4.4) ---"

MGV_GH_SCRIPT="comments_with_marker"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "Req 4.3: adjudicator marker (sha 一致) あり → rc=0 (clear 対象)" "0" "$rc"

MGV_GH_SCRIPT="comments_without_marker"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "Req 4.3: marker 不在 → rc=1 (stalled 候補)" "1" "$rc"

MGV_GH_SCRIPT="comments_with_marker_wrong_sha"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "Req 4.4: marker あるが sha 不一致 → rc=1 (別 sha の marker は対象外)" "1" "$rc"

MGV_GH_SCRIPT="comments_api_fail"
rc=0
mgv_pr_has_adjudicator_marker "123" "abc1234" || rc=$?
assert_rc "fail-safe: gh comments fetch 失敗 → rc=2" "2" "$rc"

rc=0
mgv_pr_has_adjudicator_marker "not-a-number" "abc1234" || rc=$?
assert_rc "安全側: 不正な PR 番号 → rc=1" "1" "$rc"

# ─── サマリ ───

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
