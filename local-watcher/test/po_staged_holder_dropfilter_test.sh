#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/path-overlap.sh の #518 変更を fixture で検証する
#       スモークテスト。
#
#       #221 は dispatch×multi-branch で staged-for-release を holder ラベル集合から
#       「クエリ側減算」で除外するが、staged-for-release と他 holder ラベル（例
#       ready-for-review）を併存する Issue は併存ラベル経由でクエリにマッチし依然 holder に
#       残る。#518 は列挙結果への post-filter で当該 Issue を確実に holder から落とす。
#
#       対象関数:
#         - po_resolve_staged_drop_label（#518 新設 / 純粋関数）
#         - po_collect_inflight_issues（#518 で第 3 引数 drop_staged_label + post-filter 追加）
#
#       検証する AC（docs/specs/518-fix-path-overlap-staged-for-release-hold/requirements.md）:
#         - Req 1.1 / 1.2: dispatch×multi-branch で staged 併存 Issue を holder から除外
#         - Req 2.1 / 2.2 / 2.3 / NFR 1: single-branch / promote / drop なしでは holder 維持（ゼロ差分）
#         - Req 4.1: labels 判定不能な Issue は drop せず holder 維持（fail-safe）
#         - Req 4.2: コンテキスト判定不能なら drop ラベルは空（holder 維持）
#         - NFR 3: 除外を single issue 単位で判別可能にログ出力
#
#       既存 po_apply_awaiting_slot_test.sh と同じ per-test の awk extract_function +
#       gh / po_load_edit_paths / po_log stub イディオムを踏襲する。
#
# 配置先: local-watcher/test/po_staged_holder_dropfilter_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/po_staged_holder_dropfilter_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# extract_function / assert_eq / assert_contains を共有ライブラリから source（#474）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
PATH_OVERLAP_SH="$SCRIPT_DIR/../bin/modules/path-overlap.sh"

if [ ! -f "$PATH_OVERLAP_SH" ]; then
  echo "ERROR: cannot find path-overlap.sh at $PATH_OVERLAP_SH" >&2
  exit 2
fi

# 対象関数 + 実依存 po_build_label_or_clause を実物で読み込む（extract_function は単一関数を
# 隔離抽出するため、依存ヘルパーは明示的に読み込む）。gh / po_load_edit_paths / po_log は
# 後段で stub する。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PATH_OVERLAP_SH" "po_resolve_staged_drop_label")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PATH_OVERLAP_SH" "po_collect_inflight_issues")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PATH_OVERLAP_SH" "po_build_label_or_clause")"

if ! declare -F po_resolve_staged_drop_label >/dev/null; then
  echo "ERROR: po_resolve_staged_drop_label not loaded" >&2
  exit 2
fi
if ! declare -F po_collect_inflight_issues >/dev/null; then
  echo "ERROR: po_collect_inflight_issues not loaded" >&2
  exit 2
fi
if ! declare -F po_build_label_or_clause >/dev/null; then
  echo "ERROR: po_build_label_or_clause not loaded" >&2
  exit 2
fi

# グローバル env（遅延束縛で抽出関数本体から参照される）
# shellcheck disable=SC2034  # po_collect_inflight_issues が --repo "$REPO" で参照
REPO="owner/test-repo"

PASS_COUNT=0
FAIL_COUNT=0

# ─── stub 群 ───
# gh issue list の返す JSON は GH_ISSUE_LIST_JSON で制御。呼び出しは GH_CALL_LOG に記録。
# po_load_edit_paths は issue 番号ごとに固定の edit_paths を返す。
# po_log は LOG_LOG に記録して drop ログを観測する。

reset_stub_state() {
  GH_ISSUE_LIST_JSON="${1:-[]}"
  GH_CALL_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$LOG_LOG"
}

# shellcheck disable=SC2317  # 対象関数から間接的に呼ばれる stub
gh() {
  local sub="${1:-}" sub2="${2:-}"
  case "$sub" in
    issue)
      case "$sub2" in
        list)
          echo "gh issue list $*" >>"$GH_CALL_LOG"
          if [ "${GH_LIST_RC:-0}" -ne 0 ]; then
            return "${GH_LIST_RC}"
          fi
          printf '%s' "${GH_ISSUE_LIST_JSON}"
          return 0
          ;;
        *)
          echo "gh issue $* (unhandled)" >>"$GH_CALL_LOG"
          return 0
          ;;
      esac
      ;;
    *)
      echo "gh $* (unhandled)" >>"$GH_CALL_LOG"
      return 0
      ;;
  esac
}

# shellcheck disable=SC2317  # 対象関数から間接的に呼ばれる stub
po_load_edit_paths() {
  case "$1" in
    40) echo '["local-watcher/"]' ;;
    41) echo '["README.md"]' ;;
    42) echo '["docs/"]' ;;
    99) echo '["candidate-only/"]' ;;
    *) echo '[]' ;;
  esac
}

# shellcheck disable=SC2317  # 対象関数から間接的に呼ばれる stub
po_log() { echo "$*" >>"$LOG_LOG"; }

# union 配列を sort 済み CSV で取り出すヘルパー
union_csv() {
  printf '%s' "$1" | jq -r '.union | sort | join(",")' 2>/dev/null || echo "PARSE_ERR"
}
# 指定 path の holders を sort 済み CSV で取り出すヘルパー
holders_csv() {
  printf '%s' "$1" | jq -r --arg p "$2" '(.holders[$p] // []) | sort | join(",")' 2>/dev/null || echo "PARSE_ERR"
}

echo "--- po_resolve_staged_drop_label（純粋関数 / Req 1.1 / 3.1 / 4.2 / NFR 1.1） ---"

# Case 1: dispatch×multi-branch（BASE_BRANCH=develop / PROMOTION_TARGET_BRANCH=main）→ staged-for-release
actual=$(BASE_BRANCH="develop" PROMOTION_TARGET_BRANCH="main" po_resolve_staged_drop_label "dispatch")
assert_eq "Req 1.1: dispatch×multi-branch は staged-for-release を drop 対象に返す" \
  "staged-for-release" "$actual"

# Case 2: single-branch（両方 main）→ 空文字（drop しない / NFR 1.1）
actual=$(BASE_BRANCH="main" PROMOTION_TARGET_BRANCH="main" po_resolve_staged_drop_label "dispatch")
assert_eq "NFR 1.1: single-branch（main/main）は空文字（drop しない）" "" "$actual"

# Case 3: single-branch（両方未設定 → :-main で main/main）→ 空文字
actual=$(unset BASE_BRANCH PROMOTION_TARGET_BRANCH; po_resolve_staged_drop_label "dispatch")
assert_eq "NFR 1.1: branch 未設定（default main/main）は空文字" "" "$actual"

# Case 4: promote context（multi-branch でも）→ 空文字（Req 2 / holder 維持）
actual=$(BASE_BRANCH="develop" PROMOTION_TARGET_BRANCH="main" po_resolve_staged_drop_label "promote")
assert_eq "Req 2: promote context は multi-branch でも空文字（holder 維持）" "" "$actual"

# Case 5: 不明 context → 空文字（Req 4.2 / fail-safe）
actual=$(BASE_BRANCH="develop" PROMOTION_TARGET_BRANCH="main" po_resolve_staged_drop_label "garbage")
assert_eq "Req 4.2: 不明 context は空文字（fail-safe / holder 維持）" "" "$actual"

# Case 6: context 引数省略 → 空文字（Req 4.2）
actual=$(BASE_BRANCH="develop" PROMOTION_TARGET_BRANCH="main" po_resolve_staged_drop_label)
assert_eq "Req 4.2: context 省略は空文字（fail-safe）" "" "$actual"

# Case 7: LABEL_STAGED_FOR_RELEASE override を尊重する
actual=$(BASE_BRANCH="develop" PROMOTION_TARGET_BRANCH="main" LABEL_STAGED_FOR_RELEASE="sfr-custom" po_resolve_staged_drop_label "dispatch")
assert_eq "override: LABEL_STAGED_FOR_RELEASE の override を尊重する" "sfr-custom" "$actual"

echo ""
echo "--- po_collect_inflight_issues の drop 挙動（副作用関数 / Req 1.1 / 1.2 / 4.1 / NFR 1 / NFR 3） ---"

# 共通 fixture: issue 40（staged + ready 併存, path=local-watcher/）,
#               issue 41（claude-claimed のみ, path=README.md）
LIST_STAGED_COEXIST='[
  {"number":40,"labels":[{"name":"staged-for-release"},{"name":"ready-for-review"}]},
  {"number":41,"labels":[{"name":"claude-claimed"}]}
]'

# ── Case A: drop_label 指定 → staged 併存 Issue 40 が union / holders から除外される（Req 1.1 / 1.2） ──
reset_stub_state "$LIST_STAGED_COEXIST"
out=$(po_collect_inflight_issues 99 "claude-claimed,claude-picked-up,awaiting-design-review,ready-for-review,needs-iteration,needs-rebase" "staged-for-release")
assert_eq "Req 1.1: staged 併存 Issue 除外後の union は README.md のみ" \
  "README.md" "$(union_csv "$out")"
assert_eq "Req 1.2: 除外された Issue 40 は holders[local-watcher/] に計上されない" \
  "" "$(holders_csv "$out" "local-watcher/")"
assert_eq "Req 1.2: 残った Issue 41 は holders[README.md] に計上される" \
  "41" "$(holders_csv "$out" "README.md")"
# NFR 3: 除外ログが single issue 単位で出る
log_out="$(cat "$LOG_LOG")"
assert_contains "NFR 3: 除外ログに issue=#40 が含まれる" "$log_out" "issue=#40"
assert_contains "NFR 3: 除外ログに label=staged-for-release が含まれる" "$log_out" "label=staged-for-release"
# NFR 2.3: gh issue list は 1 回のみ（追加 API を発生させない）
list_count=$( { grep -c "gh issue list" "$GH_CALL_LOG" 2>/dev/null || true; } )
assert_eq "NFR 2.3: gh issue list は 1 回のみ" "1" "$list_count"
cleanup_stub_state

# ── Case B: drop_label 空（第 3 引数省略）→ staged 併存 Issue 40 が従来どおり holder 計上（NFR 1） ──
reset_stub_state "$LIST_STAGED_COEXIST"
out=$(po_collect_inflight_issues 99 "claude-claimed,claude-picked-up,awaiting-design-review,ready-for-review,needs-iteration,needs-rebase,staged-for-release")
assert_eq "NFR 1: drop なしでは union に local-watcher/ と README.md の両方が残る" \
  "README.md,local-watcher/" "$(union_csv "$out")"
assert_eq "NFR 1: drop なしでは Issue 40 が holders[local-watcher/] に計上される" \
  "40" "$(holders_csv "$out" "local-watcher/")"
# drop なし経路では除外ログを出さない（single-branch ゼロ差分）
log_out="$(cat "$LOG_LOG")"
assert_eq "NFR 1: drop なし経路では除外ログを出さない" "" "$log_out"
cleanup_stub_state

# ── Case C: 候補自身が引き続き除外される（Req 4.3 相当 / 既存挙動維持） ──
LIST_WITH_CANDIDATE='[
  {"number":99,"labels":[{"name":"claude-claimed"}]},
  {"number":41,"labels":[{"name":"claude-claimed"}]}
]'
reset_stub_state "$LIST_WITH_CANDIDATE"
out=$(po_collect_inflight_issues 99 "claude-claimed" "staged-for-release")
assert_eq "候補自身 99 は除外され union は README.md のみ（candidate-only/ を含まない）" \
  "README.md" "$(union_csv "$out")"
cleanup_stub_state

# ── Case D: fail-safe — labels 判定不能（labels キー欠落）Issue は drop されず holder に残る（Req 4.1） ──
LIST_LABELS_MISSING='[
  {"number":42},
  {"number":41,"labels":[{"name":"claude-claimed"}]}
]'
reset_stub_state "$LIST_LABELS_MISSING"
out=$(po_collect_inflight_issues 99 "claude-claimed" "staged-for-release")
assert_eq "Req 4.1: labels 欠落の Issue 42 は drop されず holders[docs/] に残る" \
  "42" "$(holders_csv "$out" "docs/")"
assert_eq "Req 4.1: union には docs/ と README.md の両方が残る" \
  "README.md,docs/" "$(union_csv "$out")"
# 判定不能で drop していないため除外ログは出さない
log_out="$(cat "$LOG_LOG")"
assert_eq "Req 4.1: 判定不能では除外ログを出さない" "" "$log_out"
cleanup_stub_state

# ── Case E: drop_label 指定でも staged を持たない Issue は holder 維持（NFR 1.2） ──
LIST_NO_STAGED='[
  {"number":40,"labels":[{"name":"ready-for-review"}]},
  {"number":41,"labels":[{"name":"claude-claimed"}]}
]'
reset_stub_state "$LIST_NO_STAGED"
out=$(po_collect_inflight_issues 99 "ready-for-review,claude-claimed" "staged-for-release")
assert_eq "NFR 1.2: staged を持たない Issue は drop_label 指定でも全て holder に残る" \
  "README.md,local-watcher/" "$(union_csv "$out")"
log_out="$(cat "$LOG_LOG")"
assert_eq "NFR 1.2: staged 不在では除外ログを出さない" "" "$log_out"
cleanup_stub_state

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
