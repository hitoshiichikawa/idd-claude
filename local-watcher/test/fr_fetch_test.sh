#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した候補選定レイヤ（fr_fetch_failed_issues /
#       fr_fetch_failed_prs）を gh stub で検証するスモークテスト。
#
#       対象関数:
#         - fr_fetch_failed_issues (Issue #359 Req 2.1 / 2.2 / 2.4 / 2.5)
#         - fr_fetch_failed_prs    (Issue #359 Req 2.3 / 2.4 / NFR 3.1)
#
#       検証する AC:
#         - Req 2.1: gh issue list が claude-failed Issue を走査対象として呼ばれる
#         - Req 2.2: label 付与経緯非依存（auto-dev かつ claude-failed のみで対象化）
#         - Req 2.3: gh pr list + gh pr view 連鎖で auto-merge 待ち + CI error PR を選定
#         - Req 2.4: needs-decisions / needs-quota-wait / blocked / awaiting-slot
#                    の除外ラベル群が --search クエリに含まれる
#         - Req 2.5: auto-dev ラベル必須（label:"auto-dev" が --search に含まれる）
#         - NFR 3.1: branch 名 / repo owner を jq --arg 経由で展開
#         - NFR 5.2: 取得失敗時は [] を返し fr_warn が呼ばれる（fail-continue）
#
# 配置先: local-watcher/test/fr_fetch_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/fr_fetch_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（fr_state_test.sh / auto-merge_test.sh）と同じイディオム:
# 対象スクリプトから 1 関数だけを awk で切り出して eval で読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象 2 関数を抽出
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_fetch_failed_issues")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_fetch_failed_prs")"

for fn in fr_fetch_failed_issues fr_fetch_failed_prs; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── グローバル env（遅延束縛で抽出関数本体から参照される） ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
LABEL_TRIGGER="auto-dev"
# shellcheck disable=SC2034
LABEL_NEEDS_DECISIONS="needs-decisions"
# shellcheck disable=SC2034
LABEL_NEEDS_QUOTA_WAIT="needs-quota-wait"
# shellcheck disable=SC2034
LABEL_BLOCKED="blocked"
# shellcheck disable=SC2034
LABEL_AWAITING_SLOT="awaiting-slot"
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_PRS=3
# shellcheck disable=SC2034
FAILED_RECOVERY_GIT_TIMEOUT=60

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
    echo "  file   : $file"
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

# ── stub state（test ごとに reset） ──
GH_CALL_LOG=""
FR_WARN_TRACE=""
GH_PR_LIST_RESPONSE='[]'
GH_ISSUE_LIST_RESPONSE='[]'
GH_PR_VIEW_RESPONSES_FILE=""
GH_PR_LIST_RC=0
GH_ISSUE_LIST_RC=0
GH_PR_VIEW_RC=0

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  FR_WARN_TRACE="$(mktemp)"
  GH_PR_VIEW_RESPONSES_FILE="$(mktemp)"
  GH_PR_LIST_RESPONSE='[]'
  GH_ISSUE_LIST_RESPONSE='[]'
  GH_PR_LIST_RC=0
  GH_ISSUE_LIST_RC=0
  GH_PR_VIEW_RC=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$FR_WARN_TRACE" "$GH_PR_VIEW_RESPONSES_FILE" 2>/dev/null || true
}

# fr_warn を上書きして warn 呼出を観測（実体は core_utils.sh）
# shellcheck disable=SC2317
fr_warn() {
  echo "$*" >> "$FR_WARN_TRACE"
}

# timeout は引数を捨ててコマンドをそのまま実行
# shellcheck disable=SC2317
timeout() {
  shift  # 第 1 引数（秒数）を捨てる
  "$@"
}

# gh stub: gh issue list / gh pr list / gh pr view の呼び出しを観測。
# 引数列を call log に append し、固定の JSON を返す。
# gh pr view は PR 番号ごとに `$GH_PR_VIEW_RESPONSES_FILE` の対応行から返す
# （簡易: 全 PR で同一 JSON を返してよいケースは GH_PR_VIEW_RESPONSE 1 つで運用）。
# shellcheck disable=SC2317
gh() {
  # 全引数を 1 行で記録（assert_grep で引数列を検証する）
  echo "gh $*" >> "$GH_CALL_LOG"
  case "${1:-}" in
    issue)
      case "${2:-}" in
        list)
          if [ "$GH_ISSUE_LIST_RC" != "0" ]; then
            return "$GH_ISSUE_LIST_RC"
          fi
          printf '%s' "$GH_ISSUE_LIST_RESPONSE"
          return 0
          ;;
      esac
      ;;
    pr)
      case "${2:-}" in
        list)
          if [ "$GH_PR_LIST_RC" != "0" ]; then
            return "$GH_PR_LIST_RC"
          fi
          printf '%s' "$GH_PR_LIST_RESPONSE"
          return 0
          ;;
        view)
          if [ "$GH_PR_VIEW_RC" != "0" ]; then
            return "$GH_PR_VIEW_RC"
          fi
          local pr_number="${3:-}"
          # $GH_PR_VIEW_RESPONSES_FILE に `<pr_number>:<json>` 形式で記録した
          # 行があれば対応 JSON を返す。無ければ空 PR view（auto-merge なし /
          # CI 全 green 相当）を返す。
          local resp=""
          if [ -f "$GH_PR_VIEW_RESPONSES_FILE" ]; then
            resp=$(awk -F':' -v n="$pr_number" '$1 == n { sub(/^[^:]+:/, ""); print; exit }' "$GH_PR_VIEW_RESPONSES_FILE")
          fi
          if [ -z "$resp" ]; then
            resp='{"mergeStateStatus":"CLEAN","autoMergeRequest":null,"statusCheckRollup":[]}'
          fi
          printf '%s' "$resp"
          return 0
          ;;
      esac
      ;;
  esac
  return 0
}

# Helper: gh pr view 用の固定 JSON を $GH_PR_VIEW_RESPONSES_FILE に登録する
register_pr_view() {
  local pr_number="$1"
  local json="$2"
  echo "${pr_number}:${json}" >> "$GH_PR_VIEW_RESPONSES_FILE"
}

# Helper: auto-merge 有効 + CI error の view JSON ビルダー
build_view_failing() {
  echo '{"mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"2026-06-01T00:00:00Z"},"statusCheckRollup":[{"name":"ci","state":"FAILURE","conclusion":"FAILURE"}]}'
}
build_view_auto_pending() {
  # auto-merge 有効だが CI は pending（FAILURE/TIMED_OUT を含まない）
  echo '{"mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"2026-06-01T00:00:00Z"},"statusCheckRollup":[{"name":"ci","state":"PENDING","conclusion":null}]}'
}
build_view_no_automerge_failing() {
  # auto-merge 未有効化 + CI error（条件 AND を満たさない）
  echo '{"mergeStateStatus":"CLEAN","autoMergeRequest":null,"statusCheckRollup":[{"name":"ci","state":"FAILURE","conclusion":"FAILURE"}]}'
}

# ============================================================
# Section 1: fr_fetch_failed_issues — 検索クエリの引数列を verify（Req 2.1 / 2.2 / 2.4 / 2.5）
# ============================================================
echo "--- Section 1: fr_fetch_failed_issues 検索クエリ verify ---"

reset_stub_state
trap 'cleanup_stub_state' EXIT

# 1 件返す JSON 配列を仕込んで成功 path を通す
GH_ISSUE_LIST_RESPONSE='[{"number":123,"title":"failed issue","url":"https://example/123","labels":[{"name":"claude-failed"},{"name":"auto-dev"}],"body":"..."}]'
out=$(fr_fetch_failed_issues)

# 戻り値は配列のまま透過すること（jq で type=array 検証）
type=$(printf '%s' "$out" | jq -r 'type' 2>/dev/null || echo "")
assert_eq "Req 2.1: fr_fetch_failed_issues は JSON 配列を stdout に返す" "array" "$type"
n=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo "")
assert_eq "Req 2.1: 1 件取得時に length=1 が透過する" "1" "$n"

# gh issue list が呼ばれたこと
assert_grep "Req 2.1: gh issue list が呼ばれる" "^gh issue list" "$GH_CALL_LOG"
# --search クエリに必要なラベル群が含まれていること（必須 + 除外 6 種）
assert_grep "Req 2.1: --search に label:claude-failed 必須" 'label:"claude-failed"' "$GH_CALL_LOG"
assert_grep "Req 2.5: --search に label:auto-dev 必須（auto-dev 未付与除外）" 'label:"auto-dev"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:needs-decisions 除外" '-label:"needs-decisions"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:needs-quota-wait 除外" '-label:"needs-quota-wait"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:blocked 除外" '-label:"blocked"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:awaiting-slot 除外" '-label:"awaiting-slot"' "$GH_CALL_LOG"
# --limit が FAILED_RECOVERY_MAX_PRS で渡されること
assert_grep "Req 2.1: --limit が FAILED_RECOVERY_MAX_PRS(3) で渡される" '--limit 3' "$GH_CALL_LOG"
# --repo が REPO で渡されること
assert_grep "Req 2.1: --repo owner/test-repo が渡される" '--repo owner/test-repo' "$GH_CALL_LOG"

cleanup_stub_state

# ============================================================
# Section 2: fr_fetch_failed_issues — 取得失敗時 [] + fr_warn（NFR 5.2 / fail-continue）
# ============================================================
echo ""
echo "--- Section 2: fr_fetch_failed_issues 取得失敗時の fail-continue ---"

reset_stub_state
GH_ISSUE_LIST_RC=1
out=$(fr_fetch_failed_issues)
assert_eq "NFR 5.2: gh 失敗時に [] を返す" "[]" "$out"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
assert_eq "NFR 5.2: fr_warn が 1 件呼ばれる" "1" "$warn_count"

cleanup_stub_state

# ============================================================
# Section 3: fr_fetch_failed_prs — 検索クエリの引数列を verify（Req 2.3 / 2.4）
# ============================================================
echo ""
echo "--- Section 3: fr_fetch_failed_prs 検索クエリ verify ---"

reset_stub_state
# 1 件返す（auto-merge 有効 + CI FAILURE）
GH_PR_LIST_RESPONSE='[{"number":200,"headRefName":"claude/issue-1-impl-foo","headRepositoryOwner":{"login":"owner"},"url":"https://example/200","labels":[{"name":"claude-failed"}]}]'
register_pr_view "200" "$(build_view_failing)"
out=$(fr_fetch_failed_prs)
type=$(printf '%s' "$out" | jq -r 'type' 2>/dev/null || echo "")
assert_eq "Req 2.3: fr_fetch_failed_prs は JSON 配列を stdout に返す" "array" "$type"
n=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo "")
assert_eq "Req 2.3: auto-merge 有効 + CI FAILURE PR が 1 件残る" "1" "$n"

# gh pr list 呼出を verify
assert_grep "Req 2.3: gh pr list が呼ばれる" "^gh pr list" "$GH_CALL_LOG"
assert_grep "Req 2.3: --search に label:claude-failed 必須" 'label:"claude-failed"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:needs-decisions 除外" '-label:"needs-decisions"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:needs-quota-wait 除外" '-label:"needs-quota-wait"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:blocked 除外" '-label:"blocked"' "$GH_CALL_LOG"
assert_grep "Req 2.4: --search に -label:awaiting-slot 除外" '-label:"awaiting-slot"' "$GH_CALL_LOG"
assert_grep "Req 2.3: --search に -draft:true 除外" '-draft:true' "$GH_CALL_LOG"

# gh pr view 呼出があり --json で mergeStateStatus / autoMergeRequest / statusCheckRollup を要求
assert_grep "Req 2.3: gh pr view が呼ばれる" "^gh pr view 200" "$GH_CALL_LOG"
assert_grep "Req 2.3: pr view --json に mergeStateStatus" "mergeStateStatus" "$GH_CALL_LOG"
assert_grep "Req 2.3: pr view --json に autoMergeRequest" "autoMergeRequest" "$GH_CALL_LOG"
assert_grep "Req 2.3: pr view --json に statusCheckRollup" "statusCheckRollup" "$GH_CALL_LOG"

cleanup_stub_state

# ============================================================
# Section 4: PR list が空 → []（候補 0 件）
# ============================================================
echo ""
echo "--- Section 4: PR list 空 → 候補 0 件 ---"

reset_stub_state
GH_PR_LIST_RESPONSE='[]'
out=$(fr_fetch_failed_prs)
assert_eq "Req 2.3: 候補 0 件で [] を返す" "[]" "$out"
# gh pr view は呼ばれないこと（無駄な API call を避ける）
assert_not_grep "Req 2.3: 候補 0 件時に gh pr view を呼ばない" "^gh pr view " "$GH_CALL_LOG"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
assert_eq "Req 2.3: 候補 0 件時に fr_warn を呼ばない" "0" "$warn_count"

cleanup_stub_state

# ============================================================
# Section 5: gh pr list 失敗 → [] + fr_warn（NFR 5.2 fail-continue）
# ============================================================
echo ""
echo "--- Section 5: gh pr list 失敗時の fail-continue ---"

reset_stub_state
GH_PR_LIST_RC=1
out=$(fr_fetch_failed_prs)
assert_eq "NFR 5.2: pr list 失敗時に [] を返す" "[]" "$out"
warn_count=$(wc -l < "$FR_WARN_TRACE" 2>/dev/null || echo "0")
assert_eq "NFR 5.2: pr list 失敗時に fr_warn が 1 件呼ばれる" "1" "$warn_count"

cleanup_stub_state

# ============================================================
# Section 6: head pattern `^claude/` 以外を client-side filter で除外
# ============================================================
echo ""
echo "--- Section 6: head pattern が ^claude/ 以外の PR を除外 ---"

reset_stub_state
# claude/ 始まり 1 件 + feature/ 始まり 1 件
GH_PR_LIST_RESPONSE='[
  {"number":201,"headRefName":"claude/issue-1-impl-foo","headRepositoryOwner":{"login":"owner"},"url":"https://example/201","labels":[{"name":"claude-failed"}]},
  {"number":202,"headRefName":"feature/manual-branch","headRepositoryOwner":{"login":"owner"},"url":"https://example/202","labels":[{"name":"claude-failed"}]}
]'
register_pr_view "201" "$(build_view_failing)"
register_pr_view "202" "$(build_view_failing)"
out=$(fr_fetch_failed_prs)
n=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo "")
assert_eq "Req 2.3: head ^claude/ のみ残る（feature/ は除外）" "1" "$n"
remaining_number=$(printf '%s' "$out" | jq -r '.[0].number' 2>/dev/null || echo "")
assert_eq "Req 2.3: 残った PR は 201（claude/ 始まり）" "201" "$remaining_number"
# feature/ branch については gh pr view すら呼ばれないこと（client-side filter を 1 次絞り後にかける）
assert_not_grep "Req 2.3: 除外 PR (202/feature/) は gh pr view を呼ばない" "^gh pr view 202" "$GH_CALL_LOG"

cleanup_stub_state

# ============================================================
# Section 7: autoMergeRequest == null の PR を除外
# ============================================================
echo ""
echo "--- Section 7: autoMergeRequest == null の PR を除外 ---"

reset_stub_state
GH_PR_LIST_RESPONSE='[
  {"number":300,"headRefName":"claude/issue-1-impl-a","headRepositoryOwner":{"login":"owner"},"url":"https://example/300","labels":[{"name":"claude-failed"}]},
  {"number":301,"headRefName":"claude/issue-2-impl-b","headRepositoryOwner":{"login":"owner"},"url":"https://example/301","labels":[{"name":"claude-failed"}]}
]'
register_pr_view "300" "$(build_view_failing)"               # auto-merge 有効 + FAILURE → 残す
register_pr_view "301" "$(build_view_no_automerge_failing)"  # auto-merge null + FAILURE → 除外
out=$(fr_fetch_failed_prs)
n=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo "")
assert_eq "Req 2.3: auto-merge 未有効化 PR を除外（1 件のみ残る）" "1" "$n"
remaining=$(printf '%s' "$out" | jq -r '.[0].number' 2>/dev/null || echo "")
assert_eq "Req 2.3: 残った PR は 300（auto-merge 有効）" "300" "$remaining"

cleanup_stub_state

# ============================================================
# Section 8: CI に FAILURE/TIMED_OUT が含まれない PR を除外
# ============================================================
echo ""
echo "--- Section 8: CI rollup に FAILURE/TIMED_OUT を含まない PR を除外 ---"

reset_stub_state
GH_PR_LIST_RESPONSE='[
  {"number":400,"headRefName":"claude/issue-1-impl-a","headRepositoryOwner":{"login":"owner"},"url":"https://example/400","labels":[{"name":"claude-failed"}]},
  {"number":401,"headRefName":"claude/issue-2-impl-b","headRepositoryOwner":{"login":"owner"},"url":"https://example/401","labels":[{"name":"claude-failed"}]}
]'
register_pr_view "400" "$(build_view_failing)"        # auto-merge 有効 + FAILURE → 残す
register_pr_view "401" "$(build_view_auto_pending)"   # auto-merge 有効 + PENDING のみ → 除外
out=$(fr_fetch_failed_prs)
n=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo "")
assert_eq "Req 2.3: CI rollup に FAILURE/TIMED_OUT を含まない PR は除外" "1" "$n"
remaining=$(printf '%s' "$out" | jq -r '.[0].number' 2>/dev/null || echo "")
assert_eq "Req 2.3: 残った PR は 400（CI FAILURE 有り）" "400" "$remaining"

# 追加: TIMED_OUT のみのケースも残ること
reset_stub_state
GH_PR_LIST_RESPONSE='[
  {"number":410,"headRefName":"claude/issue-1-impl-a","headRepositoryOwner":{"login":"owner"},"url":"https://example/410","labels":[{"name":"claude-failed"}]}
]'
register_pr_view "410" '{"mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"2026-06-01T00:00:00Z"},"statusCheckRollup":[{"name":"ci","state":"COMPLETED","conclusion":"TIMED_OUT"}]}'
out=$(fr_fetch_failed_prs)
n=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo "")
assert_eq "Req 2.3: conclusion=TIMED_OUT も CI error として残る" "1" "$n"

cleanup_stub_state

# ============================================================
# Section 9: headRepositoryOwner != REPO owner の fork PR を除外（NFR 3.1 関連）
# ============================================================
echo ""
echo "--- Section 9: fork PR (headRepositoryOwner mismatch) を除外 ---"

reset_stub_state
GH_PR_LIST_RESPONSE='[
  {"number":500,"headRefName":"claude/issue-1-impl-a","headRepositoryOwner":{"login":"owner"},"url":"https://example/500","labels":[{"name":"claude-failed"}]},
  {"number":501,"headRefName":"claude/issue-2-impl-b","headRepositoryOwner":{"login":"attacker"},"url":"https://example/501","labels":[{"name":"claude-failed"}]}
]'
register_pr_view "500" "$(build_view_failing)"
register_pr_view "501" "$(build_view_failing)"
out=$(fr_fetch_failed_prs)
n=$(printf '%s' "$out" | jq -r 'length' 2>/dev/null || echo "")
assert_eq "NFR 3.1: headRepositoryOwner mismatch（fork）を除外（1 件のみ残る）" "1" "$n"
remaining=$(printf '%s' "$out" | jq -r '.[0].number' 2>/dev/null || echo "")
assert_eq "NFR 3.1: 残った PR は 500（owner と一致）" "500" "$remaining"
# fork PR (501) については gh pr view すら呼ばれないこと
assert_not_grep "NFR 3.1: fork PR (501) は gh pr view を呼ばない" "^gh pr view 501" "$GH_CALL_LOG"

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
