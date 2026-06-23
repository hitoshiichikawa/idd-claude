#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-reviewer.sh の Issue #374 で追加した
#       `pr_publish_claude_status_from_branch` を fixture と stub で検証する
#       スモークテスト。per-task 経路で publish_claude_review_status が PR 作成前に
#       発火して WARN skip した分を、PR が存在する時点で catch-up publish する経路の
#       回帰固定。
#
#       対象関数:
#         - pr_publish_claude_status_from_branch (Issue #374 Req 1.4 / 3.x / 4.x / 5.x)
#
#       検証する AC（docs/specs/374-fix-pr-reviewer-claude-review-status-per/requirements.md）:
#         - Req 1.4: PR 作成完了後の claude-review publish 成立
#         - Req 3.1: PR 未解決 → WARN + skip（本テストでは上位 process_pr_reviewer から
#                    呼ばれる経路を前提とするため、PR は head_ref 由来。直接の PR 未解決
#                    シナリオは対象外。spec-dir-not-found を準ずる skip 経路で検証）
#         - Req 3.2: review-notes.md 不在 → WARN + skip
#         - Req 3.3: parse 失敗 → WARN + skip
#         - Req 3.4: skip 時もパイプライン継続（戻り値 0）
#         - Req 3.5: WARN ログに branch 名・PR 番号・skip 理由を含む
#         - Req 4.1: approve → state=success の publish 発火
#         - Req 4.2: reject → state=failure の publish 発火
#         - Req 5.1 / 5.2: AND 二重 opt-in OFF 時は publish 関連 API 呼び出しゼロ
#         - NFR 4.1 / 4.3: publish 呼び出し位置が PR 存在状態（process_pr_reviewer から
#                          引かれた pr_json）で成立することを再現
#
# 配置先: local-watcher/test/pr_publish_claude_status_from_branch_test.sh
# 依存:   bash 4+, awk, grep, git, mktemp
# 実行:   bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh

set -euo pipefail

# 抽出関数（pr_publish_claude_status_from_branch など）と stub から indirect 参照される
# 変数が多く、shellcheck からは未使用に見える。本ファイル全体で SC2034 を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MOD="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"

if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
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

# 対象関数群を読み込む（pr_status_check_enabled / pr_publish_claude_status /
# pr_publish_commit_status / pr_detect_iteration_keyword は本テスト stub 経由で
# 呼ばれるため一緒に読み込み、外部副作用（gh）を stub で受ける）。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_status_check_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_commit_status")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_detect_iteration_keyword")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_claude_status")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_claude_status_from_branch")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "process_claude_review_status_catchup")"

for fn in pr_status_check_enabled pr_publish_commit_status pr_publish_claude_status pr_publish_claude_status_from_branch process_claude_review_status_catchup; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される）。
# 抽出関数（extract_function + eval）経由で参照されるため shellcheck からは未使用に見える。
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

# ── stub state ──
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  GIT_CALL_LOG="$(mktemp)"
  GH_NEXT_RC="${GH_NEXT_RC:-0}"
  # shellcheck disable=SC2034 # pr_publish_commit_status 抽出関数経由で参照される
  PR_STATUS_GATE_SUPPRESS_LOGGED=0

  # Test fixture state for git stub
  # GIT_TREE_OUT: ls-tree の出力（spec dir 列挙シナリオ用）
  # GIT_CATFILE_RC: cat-file -e の戻り値（file 存在/不在を切り替え）
  # GIT_SHOW_PATH: git show の content として cat する fixture file パス
  # GIT_SHOW_RC: git show の戻り値
  # GIT_LSTREE_RC: git ls-tree の戻り値
  # 各テストケース間で前の値が残らないよう、reset_stub_state では必ず初期化する
  # （シナリオごとに必要な値はテストケース本体で都度上書きする）。
  GIT_TREE_OUT=""
  GIT_CATFILE_RC=0
  GIT_SHOW_PATH=""
  GIT_SHOW_RC=0
  GIT_LSTREE_RC=0

  # PARSE_REVIEW_RESULT_RC: parse_review_result の擬似戻り値
  # PARSE_REVIEW_RESULT_OUT: parse_review_result の stdout TSV
  PARSE_REVIEW_RESULT_RC=0
  PARSE_REVIEW_RESULT_OUT=""
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG" "$GIT_CALL_LOG" 2>/dev/null || true
}

# pr_log / pr_warn / pr_error stub
# shellcheck disable=SC2317
pr_log()   { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pr_warn()  { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
pr_error() { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 最初の引数（秒数）を捨て、残りを実行する。
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: pr_publish_commit_status の gh api -X POST を記録する。
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  return "${GH_NEXT_RC:-0}"
}

# git stub: ls-tree / cat-file -e / show の挙動を fixture から制御する。
# 引数を全件 GIT_CALL_LOG に記録し、grep で呼び出し痕跡を検査できる。
# shellcheck disable=SC2317
git() {
  echo "git $*" >>"$GIT_CALL_LOG"
  case "$1" in
    ls-tree)
      printf '%s' "$GIT_TREE_OUT"
      return "${GIT_LSTREE_RC:-0}"
      ;;
    cat-file)
      return "${GIT_CATFILE_RC:-0}"
      ;;
    show)
      if [ -n "$GIT_SHOW_PATH" ] && [ -f "$GIT_SHOW_PATH" ]; then
        cat "$GIT_SHOW_PATH"
      fi
      return "${GIT_SHOW_RC:-0}"
      ;;
    *)
      return 0
      ;;
  esac
}

# parse_review_result stub（pr_publish_claude_status_from_branch は本関数の存在を
# `declare -F` で確認してから呼ぶ）
# shellcheck disable=SC2317
parse_review_result() {
  if [ "$PARSE_REVIEW_RESULT_RC" -eq 0 ]; then
    printf '%s\n' "$PARSE_REVIEW_RESULT_OUT"
  fi
  return "${PARSE_REVIEW_RESULT_RC:-0}"
}

count_calls() {
  local pattern="$1"
  local file="$2"
  local n
  n=$( { grep -E -- "$pattern" "$file" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# 有効な sha / PR 番号の代表値（API 入力検証 NFR 1.3 / 1.4 を通過する fixture）
VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
VALID_PR="123"
HEAD_REF="claude/issue-374-impl-foo"
PR_URL="https://github.com/owner/test-repo/pull/123"

# review-notes.md fixture を用意（git show stub 経由で読まれる）。
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

APPROVE_NOTES="$FIXTURE_DIR/approve-review-notes.md"
cat >"$APPROVE_NOTES" <<'EOF'
# Review Notes (round 1)

## 判定

RESULT: approve
EOF

REJECT_NOTES="$FIXTURE_DIR/reject-review-notes.md"
cat >"$REJECT_NOTES" <<'EOF'
# Review Notes (round 1)

## 判定

- **Category**: AC 未カバー
- **Target**: 1.2

RESULT: reject
EOF

# ============================================================
# Section 1: AND 二重 opt-in 早期 return（Req 5.1 / 5.2 / NFR 1.1）
# ============================================================
echo "--- Section 1: AND 二重 opt-in 早期 return ---"

# Case 1.A: 両 gate 未設定 → 外部副作用ゼロ
reset_stub_state
unset PR_REVIEWER_STATUS_CHECK_ENABLED FULL_AUTO_ENABLED
GIT_TREE_OUT="docs/specs/
docs/specs/374-fix-foo/
"
GIT_SHOW_PATH="$APPROVE_NOTES"
PARSE_REVIEW_RESULT_OUT=$'approve\t\t'
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "Req 5.1 / 5.2: AND gate OFF でも rc=0（パイプライン継続）" "0" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 5.1: gate OFF で gh 呼び出しゼロ" "0" "$gh_count"
git_count=$(count_calls "^git ls-tree" "$GIT_CALL_LOG")
assert_eq "Req 5.1: gate OFF で git ls-tree 呼び出しゼロ（早期 return）" "0" "$git_count"
cleanup_stub_state

# Case 1.B: PR_REVIEWER_STATUS_CHECK_ENABLED のみ ON → still disabled
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; unset FULL_AUTO_ENABLED
GIT_TREE_OUT="docs/specs/374-fix-foo/"
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || true
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 5.2: PR gate ON + FULL_AUTO OFF で gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# Case 1.C: FULL_AUTO_ENABLED のみ ON → still disabled
reset_stub_state
unset PR_REVIEWER_STATUS_CHECK_ENABLED; FULL_AUTO_ENABLED="true"
GIT_TREE_OUT="docs/specs/374-fix-foo/"
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || true
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 5.1: PR gate OFF + FULL_AUTO ON で gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# ============================================================
# Section 2: head_ref パターン外 → silent skip
# ============================================================
echo ""
echo "--- Section 2: head_ref パターン外 → silent skip ---"

reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "feature/non-claude-branch" "$PR_URL" || local_rc=$?
assert_eq "head_ref が claude/issue-<N>- 形式でないとき rc=0" "0" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "head_ref パターン外で gh 呼び出しゼロ" "0" "$gh_count"
git_count=$(count_calls "^git " "$GIT_CALL_LOG")
assert_eq "head_ref パターン外で git 呼び出しゼロ（早期 return）" "0" "$git_count"
warn_count=$(count_calls "." "$WARN_LOG")
assert_eq "head_ref パターン外は silent skip（WARN ゼロ）" "0" "$warn_count"
cleanup_stub_state

# ============================================================
# Section 3: approve → publish 成功 (Req 1.4 / 4.1)
# ============================================================
echo ""
echo "--- Section 3: approve → state=success ---"

reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GIT_TREE_OUT="docs/specs/
docs/specs/374-fix-pr-reviewer-claude-review-status-per/
docs/specs/100-some-other-spec/
"
GIT_CATFILE_RC=0
GIT_SHOW_PATH="$APPROVE_NOTES"
PARSE_REVIEW_RESULT_RC=0
PARSE_REVIEW_RESULT_OUT=$'approve\t\t'
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "Req 1.4 / 4.1: approve は rc=0 で正常終了" "0" "$local_rc"

# gh api POST が 1 回呼ばれていること
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$VALID_SHA" "$GH_CALL_LOG")
assert_eq "Req 4.1: approve で gh api POST 1 回" "1" "$gh_count"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.1: state=success" "$gh_line" "state=success"
assert_contains "Req 4.1: context=claude-review" "$gh_line" "context=claude-review"
assert_contains "Req 4.1: description=claude: approve" "$gh_line" "description=claude: approve"
# target_url は review-notes.md の blob URL (PR head sha 指定)
assert_contains "Req 4.1: target_url に blob URL（PR head sha 指定）" "$gh_line" "target_url=https://github.com/owner/test-repo/blob/$VALID_SHA/docs/specs/374-fix-pr-reviewer-claude-review-status-per/review-notes.md"
# catch-up 経路のサマリログ 1 行
log_count=$(count_calls "claude-review status publish .catch-up" "$LOG_LOG")
assert_eq "Req 1.4: catch-up publish サマリログ 1 行" "1" "$log_count"
cleanup_stub_state

# ============================================================
# Section 4: reject → publish 失敗 status (Req 4.2)
# ============================================================
echo ""
echo "--- Section 4: reject → state=failure ---"

reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GIT_TREE_OUT="docs/specs/374-fix-pr-reviewer-claude-review-status-per/"
GIT_CATFILE_RC=0
GIT_SHOW_PATH="$REJECT_NOTES"
PARSE_REVIEW_RESULT_RC=0
PARSE_REVIEW_RESULT_OUT=$'reject\tAC 未カバー\t1.2'
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "Req 4.2: reject も rc=0 で正常終了" "0" "$local_rc"

gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.2: state=failure" "$gh_line" "state=failure"
assert_contains "Req 4.2: context=claude-review" "$gh_line" "context=claude-review"
assert_contains "Req 4.2: description=claude: reject" "$gh_line" "description=claude: reject"
cleanup_stub_state

# ============================================================
# Section 5: skip 経路の WARN ログ（Req 3.1〜3.5）
# ============================================================
echo ""
echo "--- Section 5: skip 経路の WARN ログ ---"

# Case 5.A: spec dir not found
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GIT_TREE_OUT="docs/specs/
docs/specs/100-some-other-spec/
"
GIT_CATFILE_RC=0
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "Req 3.4: spec-dir-not-found でも rc=0（パイプライン継続）" "0" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 3.4: spec-dir-not-found で gh 呼び出しゼロ" "0" "$gh_count"
warn_line=$(cat "$WARN_LOG")
assert_contains "Req 3.5: spec-dir-not-found WARN に reason 識別子" "$warn_line" "reason=spec-dir-not-found"
assert_contains "Req 3.5: WARN に branch 名" "$warn_line" "branch=$HEAD_REF"
assert_contains "Req 3.5: WARN に PR 番号" "$warn_line" "pr=#$VALID_PR"
cleanup_stub_state

# Case 5.B: review-notes.md not found
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GIT_TREE_OUT="docs/specs/374-fix-pr-reviewer-claude-review-status-per/"
GIT_CATFILE_RC=1  # cat-file -e fails => file 不在
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "Req 3.2 / 3.4: file-not-found でも rc=0" "0" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 3.2: file-not-found で gh 呼び出しゼロ" "0" "$gh_count"
warn_line=$(cat "$WARN_LOG")
assert_contains "Req 3.5: file-not-found WARN に reason 識別子" "$warn_line" "reason=file-not-found"
assert_contains "Req 3.5: file-not-found WARN に review-notes.md path" "$warn_line" "review-notes.md"
cleanup_stub_state

# Case 5.C: parse_review_result 失敗
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GIT_TREE_OUT="docs/specs/374-fix-pr-reviewer-claude-review-status-per/"
GIT_CATFILE_RC=0
GIT_SHOW_PATH="$APPROVE_NOTES"
PARSE_REVIEW_RESULT_RC=2  # 装飾起因 parse 失敗
PARSE_REVIEW_RESULT_OUT=""
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "Req 3.3 / 3.4: parse-failed でも rc=0" "0" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 3.3: parse-failed で gh 呼び出しゼロ" "0" "$gh_count"
warn_line=$(cat "$WARN_LOG")
assert_contains "Req 3.5: parse-failed WARN に reason 識別子" "$warn_line" "reason=parse-failed"
cleanup_stub_state

# Case 5.D: ls-tree 失敗
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GIT_LSTREE_RC=128  # network / object not found 等
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "Req 3.4: ls-tree-failed でも rc=0" "0" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "ls-tree 失敗で gh 呼び出しゼロ" "0" "$gh_count"
warn_line=$(cat "$WARN_LOG")
assert_contains "ls-tree-failed WARN に reason 識別子" "$warn_line" "reason=ls-tree-failed"
cleanup_stub_state

# Case 5.E: parse_review_result が不正な RESULT 値を返す
reset_stub_state
# shellcheck disable=SC2034 # PR_REVIEWER_STATUS_CHECK_ENABLED / FULL_AUTO_ENABLED は extract_function 経由
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
# shellcheck disable=SC2034 # 同上（FULL_AUTO_ENABLED）
FULL_AUTO_ENABLED="true"
GIT_TREE_OUT="docs/specs/374-fix-pr-reviewer-claude-review-status-per/"
GIT_CATFILE_RC=0
GIT_SHOW_PATH="$APPROVE_NOTES"
PARSE_REVIEW_RESULT_RC=0
PARSE_REVIEW_RESULT_OUT=$'unknown\t\t'  # 不正値
local_rc=0
pr_publish_claude_status_from_branch "$VALID_PR" "$VALID_SHA" "$HEAD_REF" "$PR_URL" || local_rc=$?
assert_eq "不正な RESULT 値でも rc=0" "0" "$local_rc"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "不正な RESULT 値で gh 呼び出しゼロ" "0" "$gh_count"
warn_line=$(cat "$WARN_LOG")
assert_contains "不正 RESULT WARN に reason 識別子" "$warn_line" "reason=invalid-result"
cleanup_stub_state

# ============================================================
# Section 6: NFR 4.3 回帰防止 — publish 呼び出し位置が PR 存在状態で成立する
# ============================================================
#
# 本セクションは「publish 試行が PR 作成前の時間軸に並んでいないこと」を機械的に
# 検出するための回帰固定。`process_claude_review_status_catchup` は `pr_fetch_candidate_prs`
# （open PR スキャン）から引かれた PR を入力に取るため、呼び出し時点で PR が必ず存在する。
# 本テストは catch-up publish の起点が `process_claude_review_status_catchup` 経由で
# 確実に発火することを、pr-reviewer.sh の text 上で grep で確認する。
# ============================================================
echo ""
echo "--- Section 6: publish 呼び出し位置の回帰防止（NFR 4.3）---"

# process_claude_review_status_catchup の存在と、その中で
# `pr_publish_claude_status_from_branch` を呼んでいること
in_catchup=$(awk '
  /^process_claude_review_status_catchup\(\) \{$/ { in_fn=1 }
  in_fn { print }
  in_fn && $0=="}" { exit }
' "$PR_MOD" | grep -c "pr_publish_claude_status_from_branch" || true)
assert_eq "NFR 4.3: process_claude_review_status_catchup 内で catch-up publish が呼ばれる" "1" "$in_catchup"

# pr_fetch_candidate_prs（open PR scan）を入力に取ること
# = PR が必ず存在する状態で呼ばれる経路であることの構造的保証
catchup_uses_fetch=$(awk '
  /^process_claude_review_status_catchup\(\) \{$/ { in_fn=1 }
  in_fn { print }
  in_fn && $0=="}" { exit }
' "$PR_MOD" | grep -c "pr_fetch_candidate_prs" || true)
assert_eq "NFR 4.3: catch-up は pr_fetch_candidate_prs（open PR scan）から入力を取る" "1" "$catchup_uses_fetch"

# AND 二重 opt-in（pr_status_check_enabled）で gate されること
catchup_gated=$(awk '
  /^process_claude_review_status_catchup\(\) \{$/ { in_fn=1 }
  in_fn { print }
  in_fn && $0=="}" { exit }
' "$PR_MOD" | grep -c "pr_status_check_enabled" || true)
assert_eq "Req 5.1 / 5.2: catch-up processor は pr_status_check_enabled で gate される" "1" "$catchup_gated"

# `PR_REVIEWER_ENABLED` には依存しないこと（claude-review 単独有効化維持 / README 既存契約）
catchup_independent=$(awk '
  /^process_claude_review_status_catchup\(\) \{$/ { in_fn=1 }
  in_fn { print }
  in_fn && $0=="}" { exit }
' "$PR_MOD" | grep -c "PR_REVIEWER_ENABLED" || true)
assert_eq "Req 5.x: catch-up processor は PR_REVIEWER_ENABLED に依存しない" "0" "$catchup_independent"

# ============================================================
# Section 7: process_claude_review_status_catchup の orchestration
# ============================================================
#
# 本セクションは catch-up processor の orchestration（gate / PR 列挙 / dispatch）を
# pr_fetch_candidate_prs / jq を stub して直接駆動する。
# ============================================================
echo ""
echo "--- Section 7: process_claude_review_status_catchup orchestration ---"

# pr_fetch_candidate_prs stub: FAKE_PRS_JSON の内容を返す。
FAKE_PRS_JSON="[]"
# shellcheck disable=SC2317
pr_fetch_candidate_prs() {
  echo "$FAKE_PRS_JSON"
}

# Case 7.A: AND gate OFF → 早期 return、pr_fetch_candidate_prs も呼ばれない
reset_stub_state
unset PR_REVIEWER_STATUS_CHECK_ENABLED FULL_AUTO_ENABLED
FAKE_PRS_JSON='[{"number":123,"headRefName":"claude/issue-374-impl-foo","headRefOid":"abcdef0123456789abcdef0123456789abcdef01","url":"https://github.com/owner/test-repo/pull/123"}]'
PR_FETCH_CALLED=0
# 一時的に pr_fetch_candidate_prs を観測 stub に差し替え
_orig_fetch="$(declare -f pr_fetch_candidate_prs)"
# shellcheck disable=SC2317
pr_fetch_candidate_prs() {
  PR_FETCH_CALLED=$((PR_FETCH_CALLED + 1))
  echo "$FAKE_PRS_JSON"
}
process_claude_review_status_catchup
assert_eq "Req 5.1 / 5.2: gate OFF で pr_fetch_candidate_prs 呼び出しゼロ" "0" "$PR_FETCH_CALLED"
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 5.1: gate OFF で gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# Case 7.B: AND gate ON + 候補 PR 0 件 → no-op で return 0
reset_stub_state
# shellcheck disable=SC2034 # extract_function 経由
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
# shellcheck disable=SC2034 # 同上
FULL_AUTO_ENABLED="true"
FAKE_PRS_JSON="[]"
process_claude_review_status_catchup
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "Req 1.4: 候補 0 件で gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# Case 7.C: AND gate ON + 候補 1 件 → pr_publish_claude_status_from_branch にディスパッチ
# → 内部で git ls-tree → cat-file -e → show → parse_review_result → gh api POST が走る
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
FULL_AUTO_ENABLED="true"
FAKE_PRS_JSON='[{"number":123,"headRefName":"claude/issue-374-impl-foo","headRefOid":"abcdef0123456789abcdef0123456789abcdef01","url":"https://github.com/owner/test-repo/pull/123"}]'
GIT_TREE_OUT="docs/specs/374-fix-pr-reviewer-claude-review-status-per/"
GIT_CATFILE_RC=0
GIT_SHOW_PATH="$APPROVE_NOTES"
PARSE_REVIEW_RESULT_RC=0
PARSE_REVIEW_RESULT_OUT=$'approve\t\t'
process_claude_review_status_catchup
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/abcdef0123456789abcdef0123456789abcdef01" "$GH_CALL_LOG")
assert_eq "Req 1.4 / 4.1: 候補 1 件で gh api POST 1 回（PR head sha 宛て）" "1" "$gh_count"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.1: state=success / context=claude-review" "$gh_line" "context=claude-review"
assert_contains "Req 4.1: state=success" "$gh_line" "state=success"
# サマリログ 1 行（processed=1）
log_count=$(count_calls "claude-review catch-up: サマリ processed=1" "$LOG_LOG")
assert_eq "Req 1.4: catch-up サマリログ 1 行 processed=1" "1" "$log_count"
cleanup_stub_state

# Case 7.D: 候補 2 件（impl PR + design PR） → 各々で publish 試行
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
FULL_AUTO_ENABLED="true"
FAKE_PRS_JSON='[
  {"number":123,"headRefName":"claude/issue-374-impl-foo","headRefOid":"abcdef0123456789abcdef0123456789abcdef01","url":"https://github.com/owner/test-repo/pull/123"},
  {"number":200,"headRefName":"claude/issue-374-design-foo","headRefOid":"bcdef0123456789abcdef0123456789abcdef012","url":"https://github.com/owner/test-repo/pull/200"}
]'
GIT_TREE_OUT="docs/specs/374-fix-pr-reviewer-claude-review-status-per/"
GIT_CATFILE_RC=0
GIT_SHOW_PATH="$APPROVE_NOTES"
PARSE_REVIEW_RESULT_RC=0
PARSE_REVIEW_RESULT_OUT=$'approve\t\t'
process_claude_review_status_catchup
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/" "$GH_CALL_LOG")
assert_eq "Req 1.4 / 4.1: 候補 2 件で gh api POST 2 回（impl + design）" "2" "$gh_count"
log_count=$(count_calls "claude-review catch-up: サマリ processed=2" "$LOG_LOG")
assert_eq "Req 1.4: サマリ processed=2" "1" "$log_count"
cleanup_stub_state

# Case 7.E: 候補 PR の head が claude/issue- パターン外 → silent skip
reset_stub_state
# shellcheck disable=SC2034 # extract_function 経由
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
# shellcheck disable=SC2034 # 同上
FULL_AUTO_ENABLED="true"
FAKE_PRS_JSON='[{"number":300,"headRefName":"feature/other-branch","headRefOid":"cdef0123456789abcdef0123456789abcdef0123","url":"https://github.com/owner/test-repo/pull/300"}]'
process_claude_review_status_catchup
gh_count=$(count_calls "^gh " "$GH_CALL_LOG")
assert_eq "head pattern 外 PR は silent skip（gh 呼び出しゼロ）" "0" "$gh_count"
cleanup_stub_state

# Cleanup（後続 Section が pr_fetch_candidate_prs に依存しないため復元は不要だが、
# stub 残置でテスト推測ミスを防ぐため明示 unset）
unset -f pr_fetch_candidate_prs
unset PR_FETCH_CALLED _orig_fetch FAKE_PRS_JSON

# ============================================================
# 終了
# ============================================================
echo ""
echo "============================================================"
echo "Test summary: PASS=$PASS_COUNT, FAIL=$FAIL_COUNT"
echo "============================================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
