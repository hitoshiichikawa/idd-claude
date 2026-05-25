#!/usr/bin/env bash
# 用途: #221 holder ラベル集合決定（po_resolve_holder_labels）と動的 search_query 構築
#       （po_collect_inflight_issues 第 2 引数省略時のゼロ差分）のユニット/スモークテスト。
# 配置先: docs/specs/221-feat-watcher-path-overlap-holder-base-de/test-fixtures/
# 依存: bash 4+, gh（本テストではスタブ化して実 API 呼び出しを避ける）, jq（同 module が
#       source 時に他関数で参照するが本テストの検証経路では未使用）
# セットアップ参照先: docs/specs/221-feat-watcher-path-overlap-holder-base-de/design.md
#                     の Testing Strategy 節
#
# 実行: bash test-holder-labels.sh
#   全ケース PASS で exit 0、いずれか失敗で非ゼロ exit。
#
# shellcheck disable=SC2034  # LABEL_* / BASE_BRANCH 等は source した module 内の関数が参照する
# shellcheck disable=SC2317  # gh() スタブは module 内の関数から間接的に呼ばれる
set -euo pipefail

# ─── テスト対象モジュールの source ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${SCRIPT_DIR}/../../../../local-watcher/bin/modules/promote-pipeline.sh"

if [ ! -f "$MODULE" ]; then
  echo "FATAL: 対象モジュールが見つかりません: $MODULE" >&2
  exit 2
fi

# ─── テスト用のラベル定数（本体 Config ブロック相当 / issue-watcher.sh と同値）───
LABEL_CLAIMED="claude-claimed"
LABEL_PICKED="claude-picked-up"
LABEL_AWAITING_DESIGN="awaiting-design-review"
LABEL_READY="ready-for-review"
LABEL_NEEDS_ITERATION="needs-iteration"
LABEL_NEEDS_REBASE="needs-rebase"
LABEL_STAGED_FOR_RELEASE="staged-for-release"
LABEL_AWAITING_SLOT="awaiting-slot"
REPO="owner/test"

# module を source（関数定義のみ取り込む。本体側 set -euo pipefail 宣言は本ファイル冒頭で済）
# shellcheck source=/dev/null
. "$MODULE"

# ─── 期待値（design.md D3 真理値表 / 現行固定クエリ）───
FULL_CSV="claude-claimed,claude-picked-up,awaiting-design-review,ready-for-review,needs-iteration,needs-rebase,staged-for-release"
SIX_CSV="claude-claimed,claude-picked-up,awaiting-design-review,ready-for-review,needs-iteration,needs-rebase"
# 現行固定クエリ（変更前 po_collect_inflight_issues のヒアドキュメントと完全一致）
EXPECTED_QUERY='is:open is:issue (label:"claude-claimed" OR label:"claude-picked-up" OR label:"awaiting-design-review" OR label:"ready-for-review" OR label:"needs-iteration" OR label:"needs-rebase" OR label:"staged-for-release") -label:"st-failed" -label:"awaiting-slot"'

# ─── アサーションヘルパー ───
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name" >&2
    echo "  expected: [$expected]" >&2
    echo "  actual:   [$actual]" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─── Case 1: po_resolve_holder_labels "dispatch" × multi-branch → 6 ラベル CSV（Req 1.1）───
BASE_BRANCH="develop"
PROMOTION_TARGET_BRANCH="main"
assert_eq "Req1.1 dispatch×multi-branch は staged-for-release を除外した 6 ラベル CSV" \
  "$SIX_CSV" "$(po_resolve_holder_labels "dispatch")"

# ─── Case 2: po_resolve_holder_labels "dispatch" × single-branch → full 7 ラベル CSV（NFR 1.1）───
BASE_BRANCH="main"
PROMOTION_TARGET_BRANCH="main"
assert_eq "NFR1.1 dispatch×single-branch は full 7 ラベル CSV（ゼロ差分）" \
  "$FULL_CSV" "$(po_resolve_holder_labels "dispatch")"

# ─── Case 3: po_resolve_holder_labels "promote" → full 7 ラベル CSV（Req 2.1）───
# promote 文脈は branch 構成に依らず full（staged-for-release 維持）
BASE_BRANCH="develop"
PROMOTION_TARGET_BRANCH="main"
assert_eq "Req2.1 promote は full 7 ラベル CSV（staged-for-release 維持）" \
  "$FULL_CSV" "$(po_resolve_holder_labels "promote")"

# ─── Case 4: po_resolve_holder_labels "garbage"（不明 context）→ full 7 ラベル CSV（Req 4.1）───
BASE_BRANCH="develop"
PROMOTION_TARGET_BRANCH="main"
assert_eq "Req4.1 不明 context は full 7 ラベル CSV（fail-safe）" \
  "$FULL_CSV" "$(po_resolve_holder_labels "garbage")"

# ─── Case 4b: 空 context → full 7 ラベル CSV（Req 4.1 補強）───
assert_eq "Req4.1 空 context は full 7 ラベル CSV（fail-safe）" \
  "$FULL_CSV" "$(po_resolve_holder_labels "")"

# ─── Case 5: po_collect_inflight_issues 第 2 引数省略時の search_query が現行固定クエリと一致 ───
# gh をスタブ化して、po_collect_inflight_issues が組み立てた search_query を捕捉する。
# スタブは `--search <query>` の次引数を CAPTURED_QUERY に書き出し、空の JSON 配列を返す。
CAPTURED_QUERY_FILE="$(mktemp)"
trap 'rm -f "$CAPTURED_QUERY_FILE"' EXIT

gh() {
  # 期待呼び出し: gh issue list --repo "$REPO" --search "<query>" --json number --limit 50
  local prev=""
  local arg
  for arg in "$@"; do
    if [ "$prev" = "--search" ]; then
      printf '%s' "$arg" > "$CAPTURED_QUERY_FILE"
    fi
    prev="$arg"
  done
  # in-flight 0 件の空配列を返す（捕捉が目的なので列挙結果は不要）
  echo '[]'
  return 0
}

# 第 2 引数を省略して呼ぶ（default = 現行 7 ラベル集合 → 現行固定クエリと一致すべき / NFR 1.1）
po_collect_inflight_issues "999" >/dev/null
CAPTURED_QUERY="$(cat "$CAPTURED_QUERY_FILE")"
assert_eq "NFR1.1 引数省略時 search_query が現行固定クエリと文字列一致（ゼロ差分）" \
  "$EXPECTED_QUERY" "$CAPTURED_QUERY"

# ─── Case 5b: holder_labels に 6 ラベル CSV を渡すと staged-for-release を含まないクエリになる ───
EXPECTED_QUERY_SIX='is:open is:issue (label:"claude-claimed" OR label:"claude-picked-up" OR label:"awaiting-design-review" OR label:"ready-for-review" OR label:"needs-iteration" OR label:"needs-rebase") -label:"st-failed" -label:"awaiting-slot"'
po_collect_inflight_issues "999" "$SIX_CSV" >/dev/null
CAPTURED_QUERY="$(cat "$CAPTURED_QUERY_FILE")"
assert_eq "Req1.2 6 ラベル CSV では staged-for-release を含まない search_query を組み立てる" \
  "$EXPECTED_QUERY_SIX" "$CAPTURED_QUERY"

# ─── Case 5c: 空 CSV を渡すと full 集合へ fallback（Req 4.2）───
po_collect_inflight_issues "999" "" >/dev/null
CAPTURED_QUERY="$(cat "$CAPTURED_QUERY_FILE")"
assert_eq "Req4.2 空 CSV は full 集合へ fallback した search_query を組み立てる" \
  "$EXPECTED_QUERY" "$CAPTURED_QUERY"

# ─── 結果サマリ ───
echo "----"
echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
