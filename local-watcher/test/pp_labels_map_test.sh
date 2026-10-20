#!/usr/bin/env bash
#
# 用途: Issue #535 で追加した「リンク Issue ラベル確認 API の N 非依存化」を検証する
#       近接テスト。`pp_collect_merged_issues` が per-Issue に 2 回発火していたラベル
#       確認 API（`gh issue view --json labels` × 2）を、1 回の `gh api graphql`
#       一括取得（`pp_fetch_issue_labels_map` が構築する in-memory マップ）へ置き換え、
#       ラベル確認 API 呼び出し回数を N 非依存の定数に抑えることを呼び出しトレースで
#       観測する。同時にラベル遷移結果・ログ書式の現行等価性（Req 5.1）と graphql
#       取得失敗時のフォールバック（Req 4.1）を検証する。
#
#       対象関数:
#         - pp_fetch_issue_labels_map（#535 GraphQL 一括取得 + マップ構築）
#         - pp_issue_has_label（#535 マップ優先 + gh issue view フォールバック）
#         - pp_remove_ready_for_review_if_present（#413 経路 / マップ経由確認）
#         - pp_collect_merged_issues（per-Issue ループ統合）
#         - pp_extract_linked_issues（純関数 / 依存）
#
#       検証する AC (docs/specs/535-fix-promote-pipeline-issue-issue-gh-issu/requirements.md):
#         - Req 1.1 / NFR 2.1: ラベル確認 API 呼び出しを N に比例させず定数に抑える
#         - Req 1.2: 同一 Issue のラベルを 1 サイクル内で重複取得しない
#         - Req 1.5: リンク Issue 全件を欠落なく反映（取りこぼしなし）
#         - Req 2.1〜2.3 / 2.5: staged-for-release 自動付与の結果・ログ・サマリ等価
#         - Req 3.1〜3.3: ready-for-review 除去の結果・ログ等価
#         - Req 4.1: 一括取得失敗時 WARN + per-Issue フォールバックで継続
#         - Req 4.3 / NFR 3.2: 数値 ID `^[0-9]+$` 再検証
#         - Req 5.1: ラベル遷移結果の現行等価性
#         - Req 5.2: N を変えても確認系 API 呼び出しが N に比例しない
#
#       既存テスト（pp_remove_ready_for_review_test.sh 等）と同じ extract_function
#       イディオムを踏襲。gh / timeout / pp_log / pp_warn を stub して呼び出しトレース・
#       ログ出力を観測する。
#
# 配置先: local-watcher/test/pp_labels_map_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/pp_labels_map_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# extract_function / assert_eq / assert_contains / assert_rc を共有ライブラリから source（#474）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
PP_MOD="$SCRIPT_DIR/../bin/modules/promote-pipeline.sh"

if [ ! -f "$PP_MOD" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PP_MOD" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for this test" >&2
  exit 2
fi

# 対象関数とその依存ヘルパーを 1 関数ずつ隔離抽出して読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PP_MOD" "pp_collect_merged_issues")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PP_MOD" "pp_fetch_issue_labels_map")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PP_MOD" "pp_issue_has_label")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PP_MOD" "pp_remove_ready_for_review_if_present")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PP_MOD" "pp_extract_linked_issues")"

for fn in pp_collect_merged_issues pp_fetch_issue_labels_map pp_issue_has_label \
          pp_remove_ready_for_review_if_present pp_extract_linked_issues; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で extract_function 経由の関数本体から参照される）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
BASE_BRANCH="develop"
# shellcheck disable=SC2034
LABEL_READY="ready-for-review"
# shellcheck disable=SC2034
LABEL_STAGED_FOR_RELEASE="staged-for-release"
# shellcheck disable=SC2034
PROMOTE_GIT_TIMEOUT=60

PASS_COUNT=0
FAIL_COUNT=0

# ─── stub 状態 ───
# TEST_LABELS[issue]   : Issue のラベル CSV（例 "ready-for-review,staged-for-release"）
# TEST_MISSING[issue]  : graphql の null alias（存在しない Issue）にしたい番号を "1" で登録
# GRAPHQL_RC           : gh api graphql の戻り値（既定 0 / 1 で取得失敗を模擬）
# $GH_CALL_LOG         : gh 呼び出しを 1 行ずつ記録（grep でカウント）
# $WARN_LOG / $LOG_LOG : pp_warn / pp_log 出力を記録

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  declare -gA TEST_LABELS=()
  declare -gA TEST_MISSING=()
  declare -gA TEST_EDIT_RC=()
  GRAPHQL_RC=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
  unset TEST_LABELS TEST_MISSING TEST_EDIT_RC
}

# pp_log / pp_warn stub
# shellcheck disable=SC2317
pp_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pp_warn() { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 秒数引数を捨ててコマンドを実行
# shellcheck disable=SC2317
timeout() { shift; "$@"; }

# CSV → jq nodes 配列
# shellcheck disable=SC2317
csv_to_nodes() {
  local csv="$1"
  if [ -z "$csv" ]; then
    printf '[]'
  else
    printf '%s' "$csv" | jq -R -s -c \
      'rtrimstr("\n") | split(",") | map({name: (. | gsub("^\\s+|\\s+$";""))})'
  fi
}

# merged PR 一覧 JSON を Issue 番号群から生成（closingIssuesReferences 経路）
# shellcheck disable=SC2317
build_pr_list() {
  local num idx=0 inner=""
  for num in "$@"; do
    inner+="{\"number\": $((900 + idx)), \"headRefName\": \"claude/issue-${num}-impl-x\", \"headRepositoryOwner\": {\"login\": \"owner\"}, \"closingIssuesReferences\": [ {\"number\": ${num}} ] },"
    idx=$((idx + 1))
  done
  inner="${inner%,}"
  printf '[%s]' "$inner"
}

# GraphQL レスポンスを、query から抽出した Issue 番号群 + TEST_LABELS/TEST_MISSING から生成
# shellcheck disable=SC2317
build_graphql_response() {
  local idx=0 num inner=""
  for num in "$@"; do
    if [ "${TEST_MISSING[$num]:-}" = "1" ]; then
      inner+="\"i${idx}\": null,"
    else
      local nodes
      nodes=$(csv_to_nodes "${TEST_LABELS[$num]:-}")
      inner+="\"i${idx}\": {\"number\": ${num}, \"labels\": {\"nodes\": ${nodes}}},"
    fi
    idx=$((idx + 1))
  done
  inner="${inner%,}"
  printf '{"data":{"repository":{%s}}}' "$inner"
}

# gh stub: サブコマンドを判定して記録 + 制御された出力 / 戻り値
# shellcheck disable=SC2317
gh() {
  local sub="${1:-}" sub2="${2:-}"
  echo "gh $*" >>"$GH_CALL_LOG"
  case "$sub $sub2" in
    "pr list")
      # merged PR 一覧は本テストで PR_LIST_NUMS から生成
      # shellcheck disable=SC2086
      build_pr_list ${PR_LIST_NUMS:-}
      return 0
      ;;
    "api graphql")
      # query 引数から issue(number:N) を抽出して応答生成
      local a q="" nums
      for a in "$@"; do
        case "$a" in query=*) q="${a#query=}";; esac
      done
      nums=$(printf '%s' "$q" | grep -oE 'number:[0-9]+' | grep -oE '[0-9]+' | tr '\n' ' ')
      if [ "${GRAPHQL_RC:-0}" != "0" ]; then
        return "${GRAPHQL_RC}"
      fi
      # shellcheck disable=SC2086
      build_graphql_response $nums
      return 0
      ;;
    "issue view")
      # フォールバック経路: --json labels を返す
      local issue="${3:-}"
      local nodes
      nodes=$(csv_to_nodes "${TEST_LABELS[$issue]:-}")
      printf '{"labels": %s}' "$nodes"
      return 0
      ;;
    "issue edit")
      local issue="${3:-}"
      return "${TEST_EDIT_RC[$issue]:-0}"
      ;;
    "issue list")
      # 最終 stdout: staged-for-release 付き open Issue 一覧
      # 意図的な word-splitting（空白区切りの番号を 1 行 1 件にする）
      # shellcheck disable=SC2086
      printf '%s\n' ${OPEN_STAGED_NUMS:-}
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

count_calls() {
  local pattern="$1" n
  n=$( { grep -E "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

echo "--- pp_labels_map cases (Issue #535 Req 1.1/1.2/1.5, 2, 3, 4.1, 5.1, 5.2) ---"
echo ""

# ============================================================
# Case 1 (Req 5.2 / 1.1): N=3、全件 staged 付与済 / ready 無し
#   → graphql=1, issue view=0, issue edit=0, skipped=3
# ============================================================
echo "--- Case 1: N=3 全件 staged 付与済（確認系 API=定数 1 / view 0） ---"
reset_stub_state
PR_LIST_NUMS="11 12 13"
OPEN_STAGED_NUMS="11 12 13"
TEST_LABELS[11]="staged-for-release"
TEST_LABELS[12]="staged-for-release"
TEST_LABELS[13]="staged-for-release"
out3=$(pp_collect_merged_issues)
gql3=$(count_calls "gh api graphql")
view3=$(count_calls "gh issue view")
edit3=$(count_calls "gh issue edit")
assert_eq "Case 1: gh api graphql は 1 回のみ（N 非依存の確認系 API）" "1" "$gql3"
assert_eq "Case 1: gh issue view は 0 回（マップ経由で per-Issue 取得しない）" "0" "$view3"
assert_eq "Case 1: 全件既付与なので gh issue edit は 0 回" "0" "$edit3"
log3="$(cat "$LOG_LOG")"
assert_contains "Case 1: サマリは added=0, skipped=3" \
  "$log3" "auto-label サマリ: staged-for-release-added=0, already-labeled-skipped=3"
assert_eq "Case 1: stdout に staged 付き open Issue を出力" "11
12
13" "$out3"
cleanup_stub_state

# ============================================================
# Case 2 (Req 5.2 / 1.1): N=6、同条件 → 確認系 API は Case 1 と同一の定数 1
# ============================================================
echo ""
echo "--- Case 2: N=6 全件 staged 付与済（確認系 API 呼び出し回数が N に比例しない） ---"
reset_stub_state
PR_LIST_NUMS="11 12 13 14 15 16"
OPEN_STAGED_NUMS="11 12 13 14 15 16"
for i in 11 12 13 14 15 16; do TEST_LABELS[$i]="staged-for-release"; done
pp_collect_merged_issues >/dev/null
gql6=$(count_calls "gh api graphql")
view6=$(count_calls "gh issue view")
assert_eq "Case 2: N=6 でも gh api graphql は 1 回（N=3 と同一定数）" "1" "$gql6"
assert_eq "Case 2: N=3($gql3) と N=6($gql6) で確認系 graphql 呼び出しが定数一致" "$gql3" "$gql6"
assert_eq "Case 2: gh issue view は 0 回（N に比例しない）" "0" "$view6"
log6="$(cat "$LOG_LOG")"
assert_contains "Case 2: 6 件全件 skip されるサマリ" \
  "$log6" "already-labeled-skipped=6"
cleanup_stub_state

# ============================================================
# Case 3 (Req 5.1 / 2 / 3): 混合ケースで結果・ログ等価
#   #21 : ラベル無し           → staged 付与ログ
#   #22 : staged 付与済        → skip
#   #23 : ready+staged 付与済  → ready 除去ログ + staged skip
#   #24 : ready のみ           → ready 除去ログ + staged 付与ログ
# ============================================================
echo ""
echo "--- Case 3: 混合ケースでラベル遷移結果・ログ書式が現行等価（Req 5.1 / 2 / 3） ---"
reset_stub_state
PR_LIST_NUMS="21 22 23 24"
OPEN_STAGED_NUMS="21 22 23 24"
TEST_LABELS[21]=""
TEST_LABELS[22]="staged-for-release"
TEST_LABELS[23]="ready-for-review,staged-for-release"
TEST_LABELS[24]="ready-for-review"
pp_collect_merged_issues >/dev/null
gql_mix=$(count_calls "gh api graphql")
view_mix=$(count_calls "gh issue view")
assert_eq "Case 3: graphql 1 回のみ（確認系は定数）" "1" "$gql_mix"
assert_eq "Case 3: issue view 0 回（全件マップ判定）" "0" "$view_mix"
log_mix="$(cat "$LOG_LOG")"
# staged 付与ログ（#21, #24）
assert_contains "Case 3: #21 に staged 付与ログ" \
  "$log_mix" "issue=#21 action=label-add label=staged-for-release source=auto"
assert_contains "Case 3: #24 に staged 付与ログ" \
  "$log_mix" "issue=#24 action=label-add label=staged-for-release source=auto"
# ready 除去ログ（#23, #24）
assert_contains "Case 3: #23 に ready-for-review 除去ログ" \
  "$log_mix" "issue=#23 action=label-remove label=ready-for-review source=auto"
assert_contains "Case 3: #24 に ready-for-review 除去ログ" \
  "$log_mix" "issue=#24 action=label-remove label=ready-for-review source=auto"
# サマリ: added=2 (#21,#24), skipped=2 (#22,#23)
assert_contains "Case 3: サマリ added=2, skipped=2" \
  "$log_mix" "auto-label サマリ: staged-for-release-added=2, already-labeled-skipped=2"
# #22 は付与/除去いずれの edit も呼ばれない（既付与 skip / ready 無し）
add_22=$(count_calls "gh issue edit 22 .*--add-label")
rem_22=$(count_calls "gh issue edit 22 .*--remove-label")
assert_eq "Case 3: #22 に add-label は発火しない（既付与 skip）" "0" "$add_22"
assert_eq "Case 3: #22 に remove-label は発火しない（ready 無し）" "0" "$rem_22"
# #21 は staged add のみ、ready remove 無し
add_21=$(count_calls "gh issue edit 21 .*--add-label staged-for-release")
assert_eq "Case 3: #21 の staged add-label が 1 回発火する" "1" "$add_21"
assert_eq "Case 3: #21 の remove(ready) は発火しない" "0" "$(count_calls "gh issue edit 21 .*--remove-label ready-for-review")"
cleanup_stub_state

# ============================================================
# Case 4 (Req 1.3 / 3.5 自己修復): 人間が staged を外した Issue は再付与、
#   ready を付け直した Issue は再除去（当該サイクルの実ラベル状態から再導出）
# ============================================================
echo ""
echo "--- Case 4: 手動でラベル操作された Issue が翌サイクルで自己修復（Req 1.3/1.4/3.5） ---"
reset_stub_state
PR_LIST_NUMS="31 32"
OPEN_STAGED_NUMS="32"
# #31: 人間が staged を外した（未付与）→ 再付与されるべき
TEST_LABELS[31]=""
# #32: 人間が ready を付け直した + staged 付与済 → ready 再除去 + staged skip
TEST_LABELS[32]="ready-for-review,staged-for-release"
pp_collect_merged_issues >/dev/null
log4="$(cat "$LOG_LOG")"
assert_contains "Case 4: 外された #31 に staged を再付与" \
  "$log4" "issue=#31 action=label-add label=staged-for-release source=auto"
assert_contains "Case 4: 付け直された #32 の ready を再除去" \
  "$log4" "issue=#32 action=label-remove label=ready-for-review source=auto"
cleanup_stub_state

# ============================================================
# Case 5 (Req 4.1): graphql 一括取得失敗時は WARN + per-Issue フォールバック継続
# ============================================================
echo ""
echo "--- Case 5: graphql 一括取得失敗で WARN + gh issue view フォールバック（Req 4.1） ---"
reset_stub_state
PR_LIST_NUMS="41 42"
OPEN_STAGED_NUMS="42"
GRAPHQL_RC=1  # 一括取得失敗を模擬
TEST_LABELS[41]=""                    # 未付与 → フォールバック view 経由で付与
TEST_LABELS[42]="staged-for-release"  # 付与済 → skip
pp_collect_merged_issues >/dev/null
warn5="$(cat "$WARN_LOG")"
assert_contains "Case 5: 一括取得失敗 WARN を 1 行残す" \
  "$warn5" "リンク Issue のラベル一括取得に失敗"
# フォールバックで gh issue view が Issue ごとに呼ばれる（N に比例するが取得失敗時の退避）
view5=$(count_calls "gh issue view")
assert_eq "Case 5: graphql 失敗時は per-Issue view にフォールバック（41,42 の ready + staged 確認）" "4" "$view5"
log5="$(cat "$LOG_LOG")"
assert_contains "Case 5: フォールバックでも #41 に staged 付与（結果継続）" \
  "$log5" "issue=#41 action=label-add label=staged-for-release source=auto"
cleanup_stub_state

# ============================================================
# Case 6 (Req 4.3 / NFR 3.2): 不正な Issue 番号は alias 埋め込み前に除外
#   （closingIssuesReferences 側の異常を想定した防御層）
# ============================================================
echo ""
echo "--- Case 6: pp_fetch_issue_labels_map の数値 ID 再検証 + マップ構築（Req 1.5 / 4.3） ---"
reset_stub_state
# 呼び出し元スコープの local -A を宣言してから fetch する（動的スコープ契約）
run_fetch_probe() {
  local -A PP_ISSUE_LABELS=()
  # 51: ready+staged / 52: 無ラベル / 53: null alias(存在しない) / -1: 不正値
  TEST_LABELS[51]="ready-for-review,staged-for-release"
  TEST_LABELS[52]=""
  TEST_MISSING[53]="1"
  # here-string で渡す（パイプだとサブシェル化して local -A が失われる。本番の
  # pp_collect_merged_issues も `<<< "$linked_issues"` の here-string で呼ぶ）。
  pp_fetch_issue_labels_map <<< $'51\n52\n53\n-1'
  # 検証: has_label がマップ経由で判定できる
  pp_issue_has_label 51 staged-for-release && echo "51-staged=YES" || echo "51-staged=NO"
  pp_issue_has_label 51 ready-for-review   && echo "51-ready=YES"  || echo "51-ready=NO"
  pp_issue_has_label 52 staged-for-release && echo "52-staged=YES" || echo "52-staged=NO"
  # 52 は key set（空ラベル）→ フォールバックしないことを確認
  [ "${PP_ISSUE_LABELS[52]+set}" = "set" ] && echo "52-key=SET" || echo "52-key=UNSET"
  # 53 は null alias → 未 set
  [ "${PP_ISSUE_LABELS[53]+set}" = "set" ] && echo "53-key=SET" || echo "53-key=UNSET"
  # -1 は検証で除外され alias に埋め込まれない → 未 set
  [ "${PP_ISSUE_LABELS['-1']+set}" = "set" ] && echo "neg-key=SET" || echo "neg-key=UNSET"
}
probe_out=$(run_fetch_probe)
gql6=$(count_calls "gh api graphql")
assert_eq "Case 6: 一括取得は 1 回のみ" "1" "$gql6"
assert_contains "Case 6: #51 staged をマップ判定" "$probe_out" "51-staged=YES"
assert_contains "Case 6: #51 ready をマップ判定" "$probe_out" "51-ready=YES"
assert_contains "Case 6: #52 staged 無しをマップ判定" "$probe_out" "52-staged=NO"
assert_contains "Case 6: #52 は空ラベルでも key set（フォールバック抑止）" "$probe_out" "52-key=SET"
assert_contains "Case 6: #53 null alias は未 set" "$probe_out" "53-key=UNSET"
assert_contains "Case 6: 不正値 -1 は alias 埋め込み前に除外され未 set" "$probe_out" "neg-key=UNSET"
# -1 が query に混入していないこと（number:-1 が存在しない）
neg_in_query=$( { grep -E 'number:-1|number: -1' "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
assert_eq "Case 6: 不正値 -1 は GraphQL query に埋め込まれない（NFR 3.2）" "0" "$((neg_in_query))"
cleanup_stub_state

# ============================================================
# Case 7 (Req 4.4 相当): リンク Issue 0 件なら graphql を呼ばない
# ============================================================
echo ""
echo "--- Case 7: リンク Issue 0 件では gh api graphql を発火しない ---"
reset_stub_state
PR_LIST_NUMS=""          # merged PR にリンク Issue が無い
OPEN_STAGED_NUMS=""
pp_collect_merged_issues >/dev/null
gql7=$(count_calls "gh api graphql")
assert_eq "Case 7: リンク Issue 0 件で graphql 呼び出し 0（無駄打ちしない）" "0" "$gql7"
cleanup_stub_state

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
