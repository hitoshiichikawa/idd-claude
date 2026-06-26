#!/usr/bin/env bash
#
# 用途: PR Reviewer Adjudicator (#404) task 6 で追加した orchestrator `adj_run_for_pr` が
#       gate OFF（PR_REVIEWER_ADJUDICATOR_ENABLED != true）時に完全 no-op であることを
#       検証するスモークテスト。
#
#       NFR 2.1 担保: gate OFF 時に
#         - gh / claude / git が 1 度も発火せず（stub の trace file が空）
#         - adj_log / adj_warn による log 行ゼロ
#         - adj_run_for_pr の戻り値が 0
#
#       検証する受入基準（docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md）:
#         - NFR 2.1 gate OFF 時の log diff ゼロ / 副作用ゼロ
#         - NFR 1.1 観測ログ増加抑制（gate OFF で 0 行）
#         - Req 5.2 gate 無効時は本変更前と完全同一フロー
#
#       検証ケース:
#         N.1 unset（既定）→ rc=0, gh/claude/git/log/warn いずれも発火ゼロ
#         N.2 PR_REVIEWER_ADJUDICATOR_ENABLED=false → 同上
#         N.3 PR_REVIEWER_ADJUDICATOR_ENABLED=true_typo / True / 1 → 同上（安全側正規化）
#         N.4 gate ON（=true）+ review_text 空 → codex 失敗経路に進み 1 行サマリログ
#             （対照群: gate ON 時のみ log 行が発生することを示す）
#
# 配置先: local-watcher/test/adj_integration_no_op_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/adj_integration_no_op_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/modules/adjudicator.sh"
PR_MOD="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi
if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
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

# adj_run_for_pr が依存する関数群を adjudicator.sh から抽出。
# gate OFF 経路では adj_gate_enabled の rc=1 で即 return するため、後続関数は呼ばれない
# 前提だが、関数定義としては読み込んでおき、stub で副作用を捕捉可能にしておく。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_gate_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_run_for_pr")"
# adj_run_for_pr 内部から呼ばれる関数群（gate ON 経路のみ）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_extract_findings")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_log_summary")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_synthesize_all_legitimate_decisions")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$ADJ_SH" "adj_resolve_spec_dir_from_head_ref")"

for fn in adj_gate_enabled adj_run_for_pr adj_extract_findings adj_log_summary \
          adj_synthesize_all_legitimate_decisions adj_resolve_spec_dir_from_head_ref; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

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

assert_file_empty() {
  local label="$1"
  local file="$2"
  if [ ! -s "$file" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (file=$file is non-empty)"
    echo "  ----- content -----"
    cat "$file"
    echo "  -------------------"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_non_empty() {
  local label="$1"
  local file="$2"
  if [ -s "$file" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (file=$file is empty / expected non-empty)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ── stub state（PATH 注入で gh / claude / git / timeout を捕捉） ──
# 各 stub は呼び出されたら trace file に 1 行記録する。本テストは NFR 2.1 の
# 「gate OFF で副作用ゼロ」を担保するため、gate OFF 経路ではすべての trace file が
# 空であることを assert する。
TMP_BIN=$(mktemp -d)
trap 'rm -rf "$TMP_BIN" 2>/dev/null || true' EXIT

# trace file パス（env で stub に渡す）
export GH_TRACE_FILE="$TMP_BIN/gh.trace"
export CLAUDE_TRACE_FILE="$TMP_BIN/claude.trace"
export GIT_TRACE_FILE="$TMP_BIN/git.trace"

cat > "$TMP_BIN/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${GH_TRACE_FILE:-/dev/null}"
# adj_run_for_pr 内部で gh pr edit / gh pr comment / gh api を呼ぶ可能性に備え、
# 標準出力には empty を、戻り値 0 を返す。
exit 0
STUB_EOF
chmod +x "$TMP_BIN/gh"

cat > "$TMP_BIN/claude" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "${CLAUDE_TRACE_FILE:-/dev/null}"
# claude --output-format json の expected output に近い空 result を返す
printf '%s\n' '{"type":"result","subtype":"success","result":"{}"}'
exit 0
STUB_EOF
chmod +x "$TMP_BIN/claude"

cat > "$TMP_BIN/git" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${GIT_TRACE_FILE:-/dev/null}"
# git ls-tree / git show / git status --porcelain いずれも空 stdout を返す
exit 0
STUB_EOF
chmod +x "$TMP_BIN/git"

cat > "$TMP_BIN/timeout" <<'STUB_EOF'
#!/usr/bin/env bash
# 第 1 引数（秒数）を捨てて残りを exec
shift
exec "$@"
STUB_EOF
chmod +x "$TMP_BIN/timeout"

PATH="$TMP_BIN:$PATH"
export PATH

# adj_log / adj_warn を stub で trace（観測専用）
LOG_TRACE_FILE="$TMP_BIN/log.trace"
WARN_TRACE_FILE="$TMP_BIN/warn.trace"

# shellcheck disable=SC2317
adj_log()  { echo "$*" >>"$LOG_TRACE_FILE"; }
# shellcheck disable=SC2317
adj_warn() { echo "$*" >>"$WARN_TRACE_FILE"; }

# adj_run_for_pr 内部で参照される関数群（呼ばれた場合は trace に痕跡を残す）。
# gate OFF 経路では絶対に呼ばれてはならない。
ADJ_LABEL_TRACE="$TMP_BIN/adj_label.trace"
ADJ_STATUS_TRACE="$TMP_BIN/adj_status.trace"
ADJ_COMMENT_TRACE="$TMP_BIN/adj_comment.trace"
ADJ_CLASSIFY_TRACE="$TMP_BIN/adj_classify.trace"

# shellcheck disable=SC2317
adj_apply_label_decision()   { echo "$*" >>"$ADJ_LABEL_TRACE"; return 0; }
# shellcheck disable=SC2317
adj_apply_status_decision()  { echo "$*" >>"$ADJ_STATUS_TRACE"; return 0; }
# shellcheck disable=SC2317
adj_post_decision_comment()  { echo "$*" >>"$ADJ_COMMENT_TRACE"; return 0; }
# shellcheck disable=SC2317
adj_classify_findings()      { echo "$*" >>"$ADJ_CLASSIFY_TRACE"; return 0; }

# グローバル env（adj_run_for_pr / pr-reviewer.sh 経路から参照される）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"
# shellcheck disable=SC2034
BASE_BRANCH="main"

reset_traces() {
  : > "$GH_TRACE_FILE"
  : > "$CLAUDE_TRACE_FILE"
  : > "$GIT_TRACE_FILE"
  : > "$LOG_TRACE_FILE"
  : > "$WARN_TRACE_FILE"
  : > "$ADJ_LABEL_TRACE"
  : > "$ADJ_STATUS_TRACE"
  : > "$ADJ_COMMENT_TRACE"
  : > "$ADJ_CLASSIFY_TRACE"
}

# 共通 fixture
VALID_PR="404"
VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
HEAD_REF="claude/issue-404-impl-foo"
PR_URL="https://github.com/owner/test-repo/pull/404"
SAMPLE_REVIEW_TEXT=$(cat <<'REVIEW_EOF'
## 概要

レビュー本文。

## 指摘事項

- [high] src/foo.ts:10 — 既存契約と整合しない
- [medium] src/bar.ts:42 — 同一観点の重複指摘

## 結論

VERDICT: needs-iteration
REVIEW_EOF
)

# ============================================================
# Section N: gate OFF 完全 no-op（NFR 2.1）
# ============================================================
echo "--- Section N: gate OFF 完全 no-op (NFR 2.1) ---"

# N.1: unset（既定）
reset_traces
unset PR_REVIEWER_ADJUDICATOR_ENABLED || true
local_rc=0
adj_run_for_pr "$VALID_PR" "$VALID_SHA" "$SAMPLE_REVIEW_TEXT" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "N.1 (unset): rc=0" "0" "$local_rc"
assert_file_empty "N.1 (unset): gh trace 空" "$GH_TRACE_FILE"
assert_file_empty "N.1 (unset): claude trace 空" "$CLAUDE_TRACE_FILE"
assert_file_empty "N.1 (unset): git trace 空" "$GIT_TRACE_FILE"
assert_file_empty "N.1 (unset): adj_log trace 空" "$LOG_TRACE_FILE"
assert_file_empty "N.1 (unset): adj_warn trace 空" "$WARN_TRACE_FILE"
assert_file_empty "N.1 (unset): adj_apply_label trace 空" "$ADJ_LABEL_TRACE"
assert_file_empty "N.1 (unset): adj_apply_status trace 空" "$ADJ_STATUS_TRACE"
assert_file_empty "N.1 (unset): adj_post_decision_comment trace 空" "$ADJ_COMMENT_TRACE"

# N.2: =false（既定値の明示）
reset_traces
export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
local_rc=0
adj_run_for_pr "$VALID_PR" "$VALID_SHA" "$SAMPLE_REVIEW_TEXT" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "N.2 (=false): rc=0" "0" "$local_rc"
assert_file_empty "N.2 (=false): gh trace 空" "$GH_TRACE_FILE"
assert_file_empty "N.2 (=false): claude trace 空" "$CLAUDE_TRACE_FILE"
assert_file_empty "N.2 (=false): git trace 空" "$GIT_TRACE_FILE"
assert_file_empty "N.2 (=false): adj_log trace 空" "$LOG_TRACE_FILE"
assert_file_empty "N.2 (=false): adj_warn trace 空" "$WARN_TRACE_FILE"

# N.3: typo / 大文字違い / 数値（issue-watcher.sh Config 正規化で `true` 厳密以外は `false`
#      に倒される前提。本テストでは直接 env を渡すため、adj_gate_enabled の判定もまた
#      `=true` 厳密一致のみを ON とする規約を踏襲して安全側に倒れることを確認）
for typo_val in "True" "TRUE" "1" "yes" "on" "tru"; do
  reset_traces
  export PR_REVIEWER_ADJUDICATOR_ENABLED="$typo_val"
  local_rc=0
  adj_run_for_pr "$VALID_PR" "$VALID_SHA" "$SAMPLE_REVIEW_TEXT" "$PR_URL" "$HEAD_REF" || local_rc=$?
  assert_eq "N.3 (typo='$typo_val'): rc=0" "0" "$local_rc"
  assert_file_empty "N.3 (typo='$typo_val'): gh trace 空" "$GH_TRACE_FILE"
  assert_file_empty "N.3 (typo='$typo_val'): claude trace 空" "$CLAUDE_TRACE_FILE"
  assert_file_empty "N.3 (typo='$typo_val'): adj_log trace 空" "$LOG_TRACE_FILE"
done

# N.4: gate ON（=true）+ review_text 空 → 対照群として「gate ON 時のみ adj_log が出る」ことを確認
reset_traces
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
local_rc=0
adj_run_for_pr "$VALID_PR" "$VALID_SHA" "" "$PR_URL" "$HEAD_REF" || local_rc=$?
assert_eq "N.4 (gate ON + review_text 空): rc=0" "0" "$local_rc"
# gate ON + codex 失敗経路: adj_apply_label_decision / adj_apply_status_decision が呼ばれ、
# adj_log_summary も 1 行出力する（NFR 1.1 観測ログ ≤10 行の経路）
assert_file_non_empty "N.4 (gate ON + 空 review): adj_log trace 非空（codex 失敗経路の summary 行）" "$LOG_TRACE_FILE"
assert_file_non_empty "N.4 (gate ON + 空 review): adj_apply_label trace 非空" "$ADJ_LABEL_TRACE"
assert_file_non_empty "N.4 (gate ON + 空 review): adj_apply_status trace 非空" "$ADJ_STATUS_TRACE"

# 観測ログが 10 行以内に収まることも併せて確認（NFR 1.1）
log_lines=$(wc -l < "$LOG_TRACE_FILE" | tr -d '[:space:]')
if [ "$log_lines" -le 10 ]; then
  echo "PASS: N.4 (gate ON + 空 review): adj_log 行数 ${log_lines} <= 10 (NFR 1.1)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: N.4 (gate ON + 空 review): adj_log 行数 ${log_lines} > 10 (NFR 1.1 違反)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# クリーンアップ
unset PR_REVIEWER_ADJUDICATOR_ENABLED || true

# ============================================================
echo ""
echo "================================================================"
echo "Test summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "================================================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
