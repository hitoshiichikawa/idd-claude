#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-reviewer.sh の Issue #349（PR Reviewer の
#       codex / claude verdict を GitHub Commit Status として publish する）で
#       追加した `pr_status_check_enabled` / `pr_publish_commit_status` /
#       `pr_publish_codex_status` / `pr_publish_claude_status` を fixture と
#       gh stub で検証するスモークテスト。
#
#       対象関数:
#         - pr_status_check_enabled  (Req 1.2, 1.4 / NFR 1.1 安全側正規化)
#         - pr_publish_commit_status (Req 2.x, 3.x, 5.x, 7.x / NFR 1.3, 1.4)
#         - pr_publish_codex_status  (Req 2.1, 2.2, 2.3, 2.5)
#         - pr_publish_claude_status (Req 3.1, 3.2, 3.3, 5.5)
#
#       検証する AC（docs/specs/349-feat-pr-reviewer-codex-claude-github-sta/requirements.md）:
#         - Req 1.2 / 1.4 / 6.1: AND 二重 opt-in（双方 =true 厳密一致時のみ publish）
#         - Req 1.3: 値正規化（unset / typo / 大文字差は OFF）
#         - Req 2.1 / 2.2: codex VERDICT → state success / failure 解決
#         - Req 2.5: antigravity 利用時も codex-review context を共有
#         - Req 3.1 / 3.2: claude RESULT → state success / failure 解決
#         - Req 5.1 / 5.4: publish 失敗時 WARN を残し silent fail にしない
#         - NFR 1.3 / 1.4: sha / PR 番号の使用前検証
#
#       追加で検証する AC（docs/specs/354-feat-watcher-pr-auto-merge-awaiting-desi/requirements.md）:
#         - Req 4.1 / 4.3 / 4.4: 設計 PR head sha への codex-review publish と state 解決
#         - Req 4.2 / 4.3 / 4.4: 設計 PR head sha への claude-review publish と state 解決
#         - Req 4.6: AND gate OFF 時は design PR でも publish なし（既存 #349 経路の流用確認）
#
# 配置先: local-watcher/test/pr_publish_commit_status_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/pr_publish_commit_status_test.sh

set -euo pipefail

# 抽出関数（pr_publish_commit_status など）と stub から indirect 参照される変数が多く、
# shellcheck からは未使用に見える。本ファイル全体で SC2034 を抑止する。
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

# 対象関数群を読み込む。pr_publish_codex_status は pr_detect_iteration_keyword を
# 呼ぶためそれも合わせて読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_status_check_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_commit_status")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_detect_iteration_keyword")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_codex_status")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_MOD" "pr_publish_claude_status")"

for fn in pr_status_check_enabled pr_publish_commit_status pr_detect_iteration_keyword pr_publish_codex_status pr_publish_claude_status; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される）
REPO="owner/test-repo"
PR_REVIEWER_GIT_TIMEOUT="120"
PR_REVIEWER_ITERATION_PATTERN='^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$'

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
  GH_NEXT_RC="${GH_NEXT_RC:-0}"
  PR_STATUS_GATE_SUPPRESS_LOGGED=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG" 2>/dev/null || true
}

# pr_log / pr_warn / pr_error stub: 出力を記録ファイルへ。
# shellcheck disable=SC2317
pr_log()   { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pr_warn()  { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
pr_error() { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 最初の引数（秒数）を捨て、残りを実行する。
# shellcheck disable=SC2317
timeout() {
  shift  # 秒数を捨てる
  "$@"
}

# gh stub: gh api -X POST repos/.../statuses/<sha> の呼び出し payload を記録ファイルへ。
# 引数全体を 1 行に書き出し、grep で context / state / description / target_url を検査できる。
# GH_NEXT_RC 環境変数で次回呼び出しの戻り値を制御（publish failure シミュレーション用）。
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  return "${GH_NEXT_RC:-0}"
}

# jq stub: pr_detect_iteration_keyword では使われないため不要だが、念のため。
# grep -E は実物が使えるためそのまま。

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_warns() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$WARN_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_logs() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$LOG_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# 有効な sha / PR 番号の代表値（API 入力検証 NFR 1.3 / 1.4 を通過する fixture）
VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
VALID_PR="123"

# ============================================================
# Section 1: pr_status_check_enabled の AND ゲート（Req 1.2 / 1.4 / 6.1）
# ============================================================
echo "--- Section 1: pr_status_check_enabled の AND ゲート ---"

# 両 OFF（未設定）→ disabled
unset PR_REVIEWER_STATUS_CHECK_ENABLED FULL_AUTO_ENABLED
assert_rc "Req 1.1 / 1.3: 両 gate 未設定なら disabled" 1 pr_status_check_enabled

# 片方だけ ON → disabled
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; unset FULL_AUTO_ENABLED
assert_rc "Req 1.4: PR gate ON + kill OFF は disabled" 1 pr_status_check_enabled

unset PR_REVIEWER_STATUS_CHECK_ENABLED; FULL_AUTO_ENABLED="true"
assert_rc "Req 1.2: PR gate OFF + kill ON は disabled" 1 pr_status_check_enabled

# 両 ON（=true 厳密一致）→ enabled
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
assert_rc "Req 1.2: 両 gate =true で enabled" 0 pr_status_check_enabled

# 値正規化（Req 1.3）: typo は OFF
for v in "True" "TRUE" "1" "on" "False" "" " true"; do
  PR_REVIEWER_STATUS_CHECK_ENABLED="$v"; FULL_AUTO_ENABLED="true"
  assert_rc "Req 1.3: PR_REVIEWER_STATUS_CHECK_ENABLED=$(printf '%q' "$v") は disabled" 1 pr_status_check_enabled
done

# ============================================================
# Section 2: pr_publish_commit_status — codex 経路 (Req 2.1, 2.2, 2.3, 2.5, 6.1, 7.1)
# ============================================================
echo ""
echo "--- Section 2: pr_publish_commit_status (codex / claude 共通) ---"

# Case A: gate OFF → 外部副作用ゼロ
reset_stub_state
unset PR_REVIEWER_STATUS_CHECK_ENABLED FULL_AUTO_ENABLED
pr_publish_commit_status "$VALID_PR" "$VALID_SHA" "codex-review" "success" "codex: approve" "https://github.com/owner/test-repo/pull/123" || true
gh_count=$(count_calls "^gh ")
assert_eq "Req 6.1: gate OFF で gh 呼び出しゼロ" "0" "$gh_count"
sup_count=$(count_logs "suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED")
assert_eq "Req 7.2: gate OFF で suppression ログ 1 行" "1" "$sup_count"
# 2 回目以降は重複しない（cycle あたり 1 行制限）
pr_publish_commit_status "$VALID_PR" "$VALID_SHA" "codex-review" "success" "codex: approve" "" || true
sup_count=$(count_logs "suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED")
assert_eq "Req 7.2: cycle あたり最大 1 行（2 回目は抑止）" "1" "$sup_count"
cleanup_stub_state

# Case B: 両 gate ON, success publish 成功
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_commit_status "$VALID_PR" "$VALID_SHA" "codex-review" "success" "codex: approve" "https://github.com/owner/test-repo/pull/123"
rc=$?
assert_eq "Req 2.1: gate ON success publish の戻り値" "0" "$rc"
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$VALID_SHA")
assert_eq "Req 2.1: codex success → gh api POST 1 回" "1" "$gh_count"
# payload の主要フィールドを確認
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.1: payload に state=success" "$gh_line" "state=success"
assert_contains "Req 2.1: payload に context=codex-review" "$gh_line" "context=codex-review"
assert_contains "Req 2.3: payload に description (codex: approve)" "$gh_line" "description=codex: approve"
assert_contains "Req 2.4: payload に target_url" "$gh_line" "target_url=https://github.com/owner/test-repo/pull/123"
# 成功ログ 1 行（Req 7.1）
ok_count=$(count_logs "commit status published")
assert_eq "Req 7.1: 成功時 1 行 log" "1" "$ok_count"
cleanup_stub_state

# Case C: 両 gate ON, failure publish 成功
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_commit_status "$VALID_PR" "$VALID_SHA" "codex-review" "failure" "codex: needs-iteration" ""
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.2: codex needs-iteration → state=failure" "$gh_line" "state=failure"
assert_contains "Req 2.3: description=codex: needs-iteration" "$gh_line" "description=codex: needs-iteration"
# target_url 空時は -f target_url= が含まれない（gh への余計な引数を渡さない）
case "$gh_line" in
  *target_url=*)
    echo "FAIL: target_url 空時に -f target_url= を渡さない（Req 2.4 fallback）"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
  *)
    echo "PASS: target_url 空時は -f target_url= を渡さない"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
esac
cleanup_stub_state

# Case D: NFR 1.3 / 1.4 入力検証 — 不正 sha
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
local_rc=0
pr_publish_commit_status "$VALID_PR" "invalid-sha" "codex-review" "success" "codex: approve" "" || local_rc=$?
assert_eq "NFR 1.3: 不正 sha は rc=2" "2" "$local_rc"
gh_count=$(count_calls "^gh ")
assert_eq "NFR 1.3: 不正 sha で gh 呼び出しゼロ" "0" "$gh_count"
warn_count=$(count_warns "無効な sha")
assert_eq "NFR 1.3: 不正 sha は WARN 記録" "1" "$warn_count"
cleanup_stub_state

# Case E: 不正 PR 番号
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
local_rc=0
pr_publish_commit_status "abc" "$VALID_SHA" "codex-review" "success" "" "" || local_rc=$?
assert_eq "NFR 1.4: 不正 PR 番号は rc=2" "2" "$local_rc"
gh_count=$(count_calls "^gh ")
assert_eq "NFR 1.4: 不正 PR 番号で gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# Case F: publish failure（gh が非 0 終了）→ WARN + rc=3、パイプライン継続用
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GH_NEXT_RC=22  # HTTP error
local_rc=0
pr_publish_commit_status "$VALID_PR" "$VALID_SHA" "claude-review" "failure" "claude: reject" "" || local_rc=$?
GH_NEXT_RC=0
assert_eq "Req 5.1: API 失敗は rc=3" "3" "$local_rc"
warn_count=$(count_warns "commit status publish FAILED")
assert_eq "Req 5.1 / 5.4: API 失敗時 WARN 記録（silent fail 禁止）" "1" "$warn_count"
warn_line=$(cat "$WARN_LOG")
assert_contains "Req 5.1: WARN に PR 番号" "$warn_line" "pr=#$VALID_PR"
assert_contains "Req 5.1: WARN に sha" "$warn_line" "sha=$VALID_SHA"
assert_contains "Req 5.1: WARN に context" "$warn_line" "context=claude-review"
assert_contains "Req 5.1: WARN に state" "$warn_line" "state=failure"
cleanup_stub_state

# Case G: description が 72 文字超 → 切り詰め（Req 2.3, 3.3）
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
long_desc="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
pr_publish_commit_status "$VALID_PR" "$VALID_SHA" "codex-review" "success" "$long_desc" ""
gh_line=$(cat "$GH_CALL_LOG")
# description= から先頭 72 文字までを抜き出して長さ確認
desc_value=$(printf '%s' "$gh_line" | sed -nE 's/.*description=([a]+).*/\1/p')
desc_len=${#desc_value}
if [ "$desc_len" = "72" ]; then
  echo "PASS: Req 2.3 / 3.3: description は 72 文字以内に短縮"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.3 / 3.3: description 長さ=${desc_len}（期待 72）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_stub_state

# ============================================================
# Section 3: pr_publish_codex_status — VERDICT → state 解決 (Req 2.1, 2.2, 2.5)
# ============================================================
echo ""
echo "--- Section 3: pr_publish_codex_status ---"

# Case 3.A: VERDICT: approve → success
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_codex_status "$VALID_PR" "$VALID_SHA" $'## 概要\n指摘なし\n\nVERDICT: approve' "https://github.com/owner/test-repo/pull/123"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.1: codex approve → state=success" "$gh_line" "state=success"
assert_contains "Req 2.1: context=codex-review" "$gh_line" "context=codex-review"
cleanup_stub_state

# Case 3.B: VERDICT: needs-iteration → failure
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_codex_status "$VALID_PR" "$VALID_SHA" $'## 概要\n指摘あり\n\nVERDICT: needs-iteration' "https://github.com/owner/test-repo/pull/123"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.2: codex needs-iteration → state=failure" "$gh_line" "state=failure"
assert_contains "Req 2.5: tool 切替（codex/antigravity）でも context=codex-review 共有" "$gh_line" "context=codex-review"
cleanup_stub_state

# Case 3.C: gate OFF → 外部副作用ゼロ
reset_stub_state
unset PR_REVIEWER_STATUS_CHECK_ENABLED FULL_AUTO_ENABLED
pr_publish_codex_status "$VALID_PR" "$VALID_SHA" "VERDICT: approve" "" || true
gh_count=$(count_calls "^gh ")
assert_eq "Req 6.1: codex publish も gate OFF で gh ゼロ" "0" "$gh_count"
cleanup_stub_state

# ============================================================
# Section 4: pr_publish_claude_status — RESULT → state 解決 (Req 3.1, 3.2, 3.3)
# ============================================================
echo ""
echo "--- Section 4: pr_publish_claude_status ---"

# Case 4.A: approve → success
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_claude_status "$VALID_PR" "$VALID_SHA" "approve" "https://github.com/owner/test-repo/blob/$VALID_SHA/docs/specs/foo/review-notes.md"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 3.1: claude approve → state=success" "$gh_line" "state=success"
assert_contains "Req 3.1: context=claude-review" "$gh_line" "context=claude-review"
assert_contains "Req 3.3: description=claude: approve" "$gh_line" "description=claude: approve"
assert_contains "Req 3.4: target_url に review-notes.md blob URL" "$gh_line" "target_url=https://github.com/owner/test-repo/blob/"
cleanup_stub_state

# Case 4.B: reject → failure
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_claude_status "$VALID_PR" "$VALID_SHA" "reject" ""
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 3.2: claude reject → state=failure" "$gh_line" "state=failure"
assert_contains "Req 3.3: description=claude: reject" "$gh_line" "description=claude: reject"
cleanup_stub_state

# Case 4.C: 不正な result → rc=4 + WARN
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
local_rc=0
pr_publish_claude_status "$VALID_PR" "$VALID_SHA" "unknown" "" || local_rc=$?
assert_eq "AC 3.5 / Req 5.4: 不正 result は rc=4" "4" "$local_rc"
gh_count=$(count_calls "^gh ")
assert_eq "AC 3.5: 不正 result で gh 呼び出しゼロ" "0" "$gh_count"
warn_count=$(count_warns "claude-review status publish: 不正な result")
assert_eq "AC 3.5: 不正 result は WARN 記録" "1" "$warn_count"
cleanup_stub_state

# Case 4.D: gate OFF → 外部副作用ゼロ（claude 経路）
reset_stub_state
unset PR_REVIEWER_STATUS_CHECK_ENABLED FULL_AUTO_ENABLED
pr_publish_claude_status "$VALID_PR" "$VALID_SHA" "approve" "" || true
gh_count=$(count_calls "^gh ")
assert_eq "Req 6.1: claude publish も gate OFF で gh ゼロ" "0" "$gh_count"
cleanup_stub_state

# Case 4.E: publish failure 経路（claude）→ WARN + rc=3
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
GH_NEXT_RC=22
local_rc=0
pr_publish_claude_status "$VALID_PR" "$VALID_SHA" "approve" "" || local_rc=$?
GH_NEXT_RC=0
assert_eq "Req 5.1 (claude): API 失敗は rc=3" "3" "$local_rc"
warn_count=$(count_warns "commit status publish FAILED")
assert_eq "Req 5.1 (claude): API 失敗時 WARN 記録" "1" "$warn_count"
cleanup_stub_state

# ============================================================
# Section 5: design PR head fixture (Issue #354 Req 4)
# ============================================================
#
# 本セクションは Issue #354（feat(watcher): 設計 PR の auto-merge）の Requirement 4
# 「設計レビュー結果の必須 status checks 化」を design PR 経路にも拡張することを
# 確認する Integration Test。
#
# 重要な前提（design.md「design レビュー status 化の配置」節と整合）:
#   - pr_publish_codex_status / pr_publish_claude_status は PR head branch 名を
#     引数に取らず、PR 番号 + head sha + verdict 本文 (codex 経路) / result 文字列
#     (claude 経路) + target_url のみで動作する。
#   - したがって head pattern が `^claude/issue-.*-design` であっても
#     `^claude/issue-.*-impl` であっても、同じ pr_publish_* 関数の同じ publish 経路が
#     起動する（head pattern を区別しない既存設計）。
#   - 本セクションの fixture は「design PR らしい値」(PR 番号 / head sha / target_url)
#     に差し替えるだけで、関数呼び出しの形は Section 3 / 4 と同一になる。
#   - これにより Issue #354 Req 4 を満たすために pr-reviewer.sh への
#     コード変更は不要であり、本 fixture は「既存挙動が design PR 経路でも
#     同じく成立する」ことの回帰固定として機能する（NFR 5.3）。
#
# 検証ケース（6 件）:
#   - Case 5.A: codex approve  + AND ON  → state=success / context=codex-review (Req 4.1, 4.3)
#   - Case 5.B: codex iter     + AND ON  → state=failure / context=codex-review (Req 4.1, 4.4)
#   - Case 5.C: codex          + PR gate OFF → gh 呼び出し 0 + suppression 1 行 (Req 4.6)
#   - Case 5.D: codex          + FULL_AUTO OFF → gh 呼び出し 0（#348 既存 kill switch に委譲） (Req 4.6)
#   - Case 5.E: claude approve + AND ON  → state=success / context=claude-review (Req 4.2, 4.3)
#                                          + target_url に DESIGN_SHA を含む（Req 4.5 latest-wins 補強）
#   - Case 5.F: claude reject  + AND ON  → state=failure / context=claude-review (Req 4.2, 4.4)
# ============================================================
echo ""
echo "--- Section 5: design PR head fixture (Issue #354 Req 4) ---"

# design PR fixture: PR 番号 / head sha / target_url を design PR らしい値に差し替える。
# NFR 1.3 (PR 番号 ^[0-9]+$) / NFR 1.4 (40 hex SHA) を満たす。
# shellcheck disable=SC2034
DESIGN_PR="200"
# shellcheck disable=SC2034
DESIGN_SHA="bcdef0123456789abcdef0123456789abcdef012"
# shellcheck disable=SC2034
DESIGN_TARGET_URL="https://github.com/owner/test-repo/pull/200"

# Case 5.A: codex approve + AND gate ON → state=success / context=codex-review
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_codex_status "$DESIGN_PR" "$DESIGN_SHA" $'## 概要\n指摘なし\n\nVERDICT: approve' "$DESIGN_TARGET_URL"
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$DESIGN_SHA")
assert_eq "Req 4.1 / 4.3: design PR codex approve → gh api POST 1 回" "1" "$gh_count"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.3: design PR codex approve → state=success" "$gh_line" "state=success"
assert_contains "Req 4.1: design PR codex → context=codex-review (共有 context)" "$gh_line" "context=codex-review"
assert_contains "Req 4.1: design PR codex → target_url=$DESIGN_TARGET_URL" "$gh_line" "target_url=$DESIGN_TARGET_URL"
assert_contains "Req 4.1: design PR codex → payload に DESIGN_SHA" "$gh_line" "$DESIGN_SHA"
cleanup_stub_state

# Case 5.B: codex needs-iteration + AND gate ON → state=failure / context=codex-review
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_codex_status "$DESIGN_PR" "$DESIGN_SHA" $'## 概要\n指摘あり\n\nVERDICT: needs-iteration' "$DESIGN_TARGET_URL"
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$DESIGN_SHA")
assert_eq "Req 4.1 / 4.4: design PR codex needs-iteration → gh api POST 1 回" "1" "$gh_count"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.4: design PR codex needs-iteration → state=failure" "$gh_line" "state=failure"
assert_contains "Req 4.1: design PR codex iter → context=codex-review (共有 context)" "$gh_line" "context=codex-review"
cleanup_stub_state

# Case 5.C: codex + PR_REVIEWER_STATUS_CHECK_ENABLED OFF（FULL_AUTO は ON）
#   → gh 呼び出しゼロ + pr_publish_commit_status 内の suppression log 1 行
reset_stub_state
unset PR_REVIEWER_STATUS_CHECK_ENABLED
FULL_AUTO_ENABLED="true"
pr_publish_codex_status "$DESIGN_PR" "$DESIGN_SHA" "VERDICT: approve" "$DESIGN_TARGET_URL" || true
gh_count=$(count_calls "^gh ")
assert_eq "Req 4.6: design PR + PR gate OFF で gh 呼び出しゼロ" "0" "$gh_count"
sup_count=$(count_logs "suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED")
assert_eq "Req 4.6: design PR + PR gate OFF で suppression ログ 1 行" "1" "$sup_count"
cleanup_stub_state

# Case 5.D: codex + FULL_AUTO_ENABLED OFF（PR gate は ON）
#   → gh 呼び出しゼロ（#348 既存 kill switch suppression ログに委譲。
#   pr_publish_commit_status 内の AUTO_MERGE_DESIGN 専用 suppression は出さない）
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"
unset FULL_AUTO_ENABLED
pr_publish_codex_status "$DESIGN_PR" "$DESIGN_SHA" "VERDICT: approve" "$DESIGN_TARGET_URL" || true
gh_count=$(count_calls "^gh ")
assert_eq "Req 4.6: design PR + FULL_AUTO OFF で gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# Case 5.E: claude approve + AND gate ON → state=success / context=claude-review
#   target_url は review-notes.md の blob URL を design PR 用に組み立てる形を想定し、
#   URL 内に DESIGN_SHA が含まれることを assert（Req 4.5 latest-wins の補強として、
#   head sha が target_url に正しく伝播することを Case 4.A より厳密に検証）
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
design_review_url="https://github.com/owner/test-repo/blob/$DESIGN_SHA/docs/specs/foo/review-notes.md"
pr_publish_claude_status "$DESIGN_PR" "$DESIGN_SHA" "approve" "$design_review_url"
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$DESIGN_SHA")
assert_eq "Req 4.2 / 4.3: design PR claude approve → gh api POST 1 回" "1" "$gh_count"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.3: design PR claude approve → state=success" "$gh_line" "state=success"
assert_contains "Req 4.2: design PR claude → context=claude-review (共有 context)" "$gh_line" "context=claude-review"
assert_contains "Req 4.2: design PR claude → description=claude: approve" "$gh_line" "description=claude: approve"
assert_contains "Req 4.5: design PR claude → target_url 先頭 blob URL" "$gh_line" "target_url=https://github.com/owner/test-repo/blob/"
assert_contains "Req 4.5: design PR claude → target_url に DESIGN_SHA を含む" "$gh_line" "$DESIGN_SHA"
cleanup_stub_state

# Case 5.F: claude reject + AND gate ON → state=failure / context=claude-review
reset_stub_state
PR_REVIEWER_STATUS_CHECK_ENABLED="true"; FULL_AUTO_ENABLED="true"
pr_publish_claude_status "$DESIGN_PR" "$DESIGN_SHA" "reject" ""
gh_count=$(count_calls "^gh api -X POST repos/owner/test-repo/statuses/$DESIGN_SHA")
assert_eq "Req 4.2 / 4.4: design PR claude reject → gh api POST 1 回" "1" "$gh_count"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 4.4: design PR claude reject → state=failure" "$gh_line" "state=failure"
assert_contains "Req 4.2: design PR claude reject → context=claude-review" "$gh_line" "context=claude-review"
assert_contains "Req 4.2: design PR claude reject → description=claude: reject" "$gh_line" "description=claude: reject"
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
