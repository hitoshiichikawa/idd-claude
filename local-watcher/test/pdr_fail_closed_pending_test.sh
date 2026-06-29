#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407 / #433) の pdr_run_review_for_pr が、spec 本文取得不能
#       （pdr_invoke_reviewer rc=3 / fail-closed）を既存 pending 据え置き経路（rc=2）へ
#       写像し、判定 marker / コメント / status publish を一切行わないことを検証する。
#
#       検証する受入基準（docs/specs/433-fix-pr-design-reviewer-pr-spec-pr-none-a/requirements.md）:
#         - Req 2.4  fail-closed 経路で marker / コメントを投稿せず pending 据え置き、status を
#                    publish しない。既存 exec 失敗時 rc=2 経路と同一の status / ラベル契約。
#         - Req 2.1  spec 本文を 1 つも取得できない → approve を publish しない
#         - NFR 1.4  pdr_run_review_for_pr の exit code 意味（0/1/2）は不変（fail-closed は rc=2）
#         - NFR 3.1  fail-closed で pending 据え置きとなった旨を 1 行のログで観測可能にする
#
#       検証ケース:
#         1. pdr_invoke_reviewer が rc=3 → pdr_run_review_for_pr が rc=2 を返す
#         2. fail-closed 時、pdr_apply_status_decision / pdr_post_decision_comment /
#            pdr_apply_label_decision が **一切呼ばれない**（marker / コメント / status 不投稿）
#         3. fail-closed 時、pdr_log に pending 据え置きの観測ログが 1 行出る（NFR 3.1）
#         4. 非回帰: pdr_invoke_reviewer が rc=0（取得成功・approve 本文）→ 従来どおり
#            status / label / comment 3 系統が呼ばれ rc=0（Req 4.3 境界）
#
# 配置先: local-watcher/test/pdr_fail_closed_pending_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pdr_fail_closed_pending_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"

if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
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

# 被テスト関数 + 内部で呼ぶ純粋 helper（pdr_parse_verdict / pdr_validate_verdict）を抽出。
# 副作用を伴う依存（pdr_invoke_reviewer / pdr_classify_design_pr / pdr_already_processed /
# pdr_resolve_spec_dir_from_head_ref / pdr_apply_* / pdr_post_decision_comment / loggers）は
# テスト側で stub する（隔離抽出の特性上、明示的に上書き定義する）。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_run_review_for_pr")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_parse_verdict")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_validate_verdict")"

if ! declare -F pdr_run_review_for_pr >/dev/null; then
  echo "ERROR: pdr_run_review_for_pr not loaded" >&2
  exit 2
fi

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

# ── 観測ファイル（subshell をまたいでも残す） ──
SIDE_LOG=""        # 副作用系（status/label/comment）の呼び出しトレース
PDR_LOG_FILE=""    # pdr_log 出力
reset_state() {
  SIDE_LOG="$(mktemp)"
  PDR_LOG_FILE="$(mktemp)"
}

# ── 依存 stub ──
INVOKE_RC=0          # pdr_invoke_reviewer の戻り値を制御
INVOKE_BODY=""       # pdr_invoke_reviewer の stdout を制御
pdr_invoke_reviewer() {
  printf '%s' "$INVOKE_BODY"
  return "$INVOKE_RC"
}
pdr_classify_design_pr() { return 0; }   # 常に design とみなす
pdr_already_processed()  { return 1; }   # 常に未処理（dedup hit しない）
pdr_resolve_spec_dir_from_head_ref() { printf '%s\n' "docs/specs/433-fix-foo"; }

pdr_apply_status_decision()  { printf 'status:%s\n' "${3:-}" >> "$SIDE_LOG"; return 0; }
pdr_apply_label_decision()   { printf 'label:%s\n' "${2:-}" >> "$SIDE_LOG"; return 0; }
pdr_post_decision_comment()  { printf 'comment\n' >> "$SIDE_LOG"; return 0; }

pdr_log()  { printf '%s\n' "$*" >> "$PDR_LOG_FILE"; }
pdr_warn() { :; }

# ── グローバル env ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
DESIGN_REVIEWER_OUTPUT_FORMAT="text"
# shellcheck disable=SC2034
BASE_BRANCH="main"

PR_JSON='{"number":433,"headRefName":"claude/issue-433-design-foo","baseRefName":"main","headRefOid":"abcdef1234567890abcdef1234567890abcdef12","url":"https://example.test/pr/433"}'

echo "--- pdr_run_review_for_pr fail-closed → pending (Issue #433 Req 2.4 / NFR 1.4 / 3.1) ---"

# ── ケース 1+2+3: pdr_invoke_reviewer rc=3（fail-closed）→ pending 据え置き rc=2 / 副作用ゼロ ──
reset_state
INVOKE_RC=3
INVOKE_BODY=""
rc=0
pdr_run_review_for_pr "$PR_JSON" || rc=$?
assert_eq "Req 2.4 / NFR 1.4: fail-closed rc=3 → pdr_run_review_for_pr rc=2（pending 据え置き）" "2" "$rc"
side_body=$(cat "$SIDE_LOG")
assert_eq "Req 2.1/2.4: fail-closed で status/label/comment を一切呼ばない（副作用ゼロ）" "" "$side_body"
log_body=$(cat "$PDR_LOG_FILE")
assert_contains "NFR 3.1: fail-closed pending 据え置きの観測ログが出る" "$log_body" "fail-closed"
assert_contains "NFR 3.1: 観測ログに pending 据え置きの旨" "$log_body" "pending 据え置き"

# ── ケース 4: 非回帰 / pdr_invoke_reviewer rc=0（取得成功・approve 本文）→ 3 系統が呼ばれ rc=0 ──
reset_state
INVOKE_RC=0
INVOKE_BODY=$(printf '## Design Review\n\n### AC カバレッジ\n- 該当: approve\n- 根拠: 全 numeric ID がカバー済み\n\n### design⇄tasks 整合\n- 該当: approve\n- 根拠: Components が _Boundary:_ に反映\n\n### Traceability\n- 該当: approve\n- 根拠: _Requirements:_ は requirements.md に実在\n\n## Verdict\nVERDICT: approve\n')
rc=0
pdr_run_review_for_pr "$PR_JSON" || rc=$?
assert_eq "Req 4.3 非回帰: 取得成功 approve → pdr_run_review_for_pr rc=0" "0" "$rc"
side_body=$(cat "$SIDE_LOG")
assert_contains "Req 4.3 非回帰: status publish が呼ばれる" "$side_body" "status:approve"
assert_contains "Req 4.3 非回帰: 判定コメント投稿が呼ばれる" "$side_body" "comment"

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
