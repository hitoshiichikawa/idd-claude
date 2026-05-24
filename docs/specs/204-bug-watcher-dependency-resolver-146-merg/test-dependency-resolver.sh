#!/usr/bin/env bash
# 用途: Dependency Resolver (#146) の merge 判定 (dr_resolve_one) と依存抽出
#       (dr_extract_deps) の回帰テスト（#204 false-block 再発防止）
# 配置先: docs/specs/204-bug-watcher-dependency-resolver-146-merg/test-dependency-resolver.sh
# 依存: bash 4+, jq, sed
# セットアップ参照先: docs/specs/204-bug-watcher-dependency-resolver-146-merg/impl-notes.md
#
# Usage:
#   bash docs/specs/204-bug-watcher-dependency-resolver-146-merg/test-dependency-resolver.sh
#
# Exit code:
#   0 = すべてのケースが期待通り
#   1 = いずれかのケースが不一致（standard error にどれが失敗したか出力）
#
# 設計:
#   - 実 GitHub API を叩かず、`gh api graphql` ラッパ `dr_gh_graphql_closed_by` を
#     テスト側で stub に差し替えて GraphQL レスポンスを mock 注入する。
#   - watcher 本体 issue-watcher.sh は末尾に main 実行コードを持つため source できない。
#     よって `dr_*` 関数定義ブロック（dr_log 〜 dr_check_dependencies）のみを sed で
#     抽出し、本テスト harness 内で source する（Req 5.x）。
#   - dr_warn / dr_log は副作用ログを stderr/stdout に出すため、テスト中は捨てる。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WATCHER="$SCRIPT_DIR/../../../local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER" ]; then
  echo "[FATAL] watcher script not found: $WATCHER" >&2
  exit 1
fi

# ── dr_* 関数ブロックを抽出して source ──
# 先頭 marker: `dr_log() {`、末尾 marker: `dr_check_dependencies` の関数末尾の `}`。
# 関数群は連続して定義されているため、dr_log() の行から dr_check_dependencies() の
# 直後に来る次トップレベル定義の手前までを抽出する。ここでは安全のため
# `dr_log()` 〜 `dr_check_dependencies` 本体終端の `^}` までを抽出する。
EXTRACTED=$(mktemp)
trap 'rm -f "$EXTRACTED"' EXIT

awk '
  /^dr_log\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^dr_check_dependencies\(\) \{/ { in_check = 1 }
  in_check && /^\}$/ { capture = 0; in_check = 0 }
' "$WATCHER" > "$EXTRACTED"

if ! grep -q '^dr_resolve_one() {' "$EXTRACTED"; then
  echo "[FATAL] dr_resolve_one を抽出できませんでした（watcher のリファクタで marker がずれた可能性）" >&2
  exit 1
fi

# テスト用の環境（REPO は owner/repo 形式が前提）。
# これらは source した dr_* 関数内で参照されるため shellcheck は未使用と誤検知する。
# shellcheck disable=SC2034
REPO="owner/repo"
# shellcheck disable=SC2034
DRR_GH_TIMEOUT=60
# shellcheck disable=SC2034
MERGE_QUEUE_GIT_TIMEOUT=60

# shellcheck disable=SC1090
source "$EXTRACTED"

# 抽出ブロックは dr_log / dr_warn / dr_error を定義しているため、source 後に上書きして
# テスト中の副作用ログを捨てる（ログ書式の検証は本テストのスコープ外 / Req 3.4 は
# 書式不変の契約であり、別途 grep ベースで担保される）。
dr_log() { :; }
dr_warn() { :; }
dr_error() { :; }

# ── mock 注入の仕組み ──
# dr_gh_graphql_closed_by を上書きし、グローバル変数 MOCK_RESPONSE / MOCK_RC で
# 振る舞いを制御する。MOCK_RC != 0 のときは gh 失敗を模す。
MOCK_RESPONSE=""
MOCK_RC=0
dr_gh_graphql_closed_by() {
  printf '%s' "$MOCK_RESPONSE"
  return "$MOCK_RC"
}

fail_count=0
pass_count=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "[OK]   $label -> '$actual'"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] $label: expected '$expected', got '$actual'" >&2
    fail_count=$((fail_count + 1))
  fi
}

# GraphQL レスポンス生成ヘルパ。
# $1 = issue state (OPEN|CLOSED), 残り = PR ノードの state 列（MERGED|CLOSED|OPEN）。
make_response() {
  local state="$1"; shift
  local nodes_json="[]"
  if [ "$#" -gt 0 ]; then
    nodes_json=$(printf '%s\n' "$@" \
      | jq -R '{number: 0, state: .}' \
      | jq -s '.')
  fi
  jq -n --arg state "$state" --argjson nodes "$nodes_json" '
    {data: {repository: {issue: {state: $state, closedByPullRequestsReferences: {nodes: $nodes}}}}}'
}

echo "=== dr_resolve_one: merge 判定 ==="

# Req 5.1: CLOSED + merge 済み PR → resolved
MOCK_RC=0
MOCK_RESPONSE=$(make_response CLOSED MERGED)
assert_eq "Req1.1 CLOSED+MERGED PR" "resolved" "$(dr_resolve_one 177)"

# Req 5.1 補強: CLOSED + (CLOSED PR, MERGED PR 混在) → resolved（1 件でも MERGED なら）
MOCK_RESPONSE=$(make_response CLOSED CLOSED MERGED)
assert_eq "Req1.1 CLOSED+(CLOSED,MERGED) 混在" "resolved" "$(dr_resolve_one 178)"

# Req 5.2: CLOSED + 未 merge（手動 close, PR が CLOSED のみ） → closed unmerged
MOCK_RESPONSE=$(make_response CLOSED CLOSED)
assert_eq "Req1.2 CLOSED+CLOSED PR(未merge)" "closed unmerged" "$(dr_resolve_one 179)"

# Req 1.3: CLOSED + 紐づく PR が 0 件 → closed unmerged
MOCK_RESPONSE=$(make_response CLOSED)
assert_eq "Req1.3 CLOSED+PR 0件" "closed unmerged" "$(dr_resolve_one 180)"

# Req 5.3: OPEN → open
MOCK_RESPONSE=$(make_response OPEN)
assert_eq "Req1.4 OPEN issue" "open" "$(dr_resolve_one 181)"

echo "=== dr_resolve_one: 安全側挙動 (Req 2) ==="

# Req 2.1: gh api graphql 失敗（非 0 rc） → api error
MOCK_RC=1
MOCK_RESPONSE="gh: rate limit exceeded"
assert_eq "Req2.1 gh 失敗 rc!=0" "api error" "$(dr_resolve_one 999)"
MOCK_RC=0

# Req 2.1: GraphQL HTTP200 + errors → api error
MOCK_RESPONSE='{"errors":[{"message":"Could not resolve to a node","type":"NOT_FOUND"}]}'
assert_eq "Req2.1 GraphQL errors" "api error" "$(dr_resolve_one 998)"

# Req 2.2: 想定外構造（issue が null） → api error
MOCK_RESPONSE='{"data":{"repository":{"issue":null}}}'
assert_eq "Req2.2 issue=null 想定外構造" "api error" "$(dr_resolve_one 997)"

# Req 2.2: jq parse 不能（壊れた JSON） → api error
MOCK_RESPONSE='not a json at all {{{'
assert_eq "Req2.2 壊れた JSON" "api error" "$(dr_resolve_one 996)"

# 未知の state → api error（安全側）
MOCK_RESPONSE=$(make_response WEIRD_STATE)
assert_eq "未知の issue state" "api error" "$(dr_resolve_one 995)"

echo "=== Red->Green ガード (Req 5.4) ==="
# 旧実装相当: gh issue view --json closedByPullRequestsReferences の PR ノードは
# `merged` フィールドを持たず `state` のみ持つ。旧 jq は `.merged == true` で集計して
# いたため、CLOSED+MERGED ケースでも 0 件 → "closed unmerged" を誤って返していた。
# 本テストは「旧 jq 式が誤判定すること」を明示的に固定し、新実装(.state=="MERGED")が
# 正すことを保証する。
OLD_JQ_FILTER='[.data.repository.issue.closedByPullRequestsReferences.nodes[]? | select(.merged == true)] | length'
NEW_JQ_FILTER='[.data.repository.issue.closedByPullRequestsReferences.nodes[]? | select(.state == "MERGED")] | length'
MERGED_RESP=$(make_response CLOSED MERGED)
old_count=$(printf '%s' "$MERGED_RESP" | jq "$OLD_JQ_FILTER")
new_count=$(printf '%s' "$MERGED_RESP" | jq "$NEW_JQ_FILTER")
assert_eq "Req5.4 旧 .merged 式は誤って 0 件" "0" "$old_count"
assert_eq "Req5.4 新 .state 式は正しく 1 件" "1" "$new_count"

echo "=== dr_extract_deps: 誤検出防止 (Req 4) ==="

# Req 4.1: 実依存宣言行から #N を抽出
body_real=$'依存関係:\n\n- Depends on: #12 #34\n- 前提依存: #56\n'
expected_real=$'12\n34\n56'
assert_eq "Req4.1 実依存行から抽出" "$expected_real" "$(dr_extract_deps "$body_real")"

# Req 4.2: コードフェンス内の依存マーカーは抽出しない
body_fence=$'説明:\n\n```markdown\nDepends on: #999\n```\n\n- Depends on: #12\n'
assert_eq "Req4.2 コードフェンス内は除外" "12" "$(dr_extract_deps "$body_fence")"

# Req 4.2 補強: コードフェンスのみ（実依存なし） → 空
body_fence_only=$'例:\n\n```\nBlocked by: #999\n```\n'
assert_eq "Req4.2 フェンスのみ→空" "" "$(dr_extract_deps "$body_fence_only")"

# Req 4.2 補強: チルダフェンス (~~~) も除外
body_tilde=$'~~~\nDepends on: #888\n~~~\n- Depends on: #7\n'
assert_eq "Req4.2 チルダフェンス除外" "7" "$(dr_extract_deps "$body_tilde")"

# Req 4.3: 引用ブロック（行頭 >）内の依存マーカーは抽出しない
body_quote=$'> Depends on: #999\n\n- Depends on: #21\n'
assert_eq "Req4.3 引用ブロック除外" "21" "$(dr_extract_deps "$body_quote")"

# Req 4.3 補強: 引用 + 先頭スペース付きの引用記号
body_quote_indent=$'   > 前提依存: #777\nDepends on: #5\n'
assert_eq "Req4.3 インデント引用除外" "5" "$(dr_extract_deps "$body_quote_indent")"

# Req 4.4: 重複排除 + 決定的順序（数値昇順）
body_dup=$'- Depends on: #34 #12\n- Blocked by: #12\n- Depends on: #5\n'
expected_dup=$'5\n12\n34'
assert_eq "Req4.4 重複排除+昇順" "$expected_dup" "$(dr_extract_deps "$body_dup")"

# Req 4.5: 依存記法が抽出対象行に無い → 空（フェンス/引用のみ）
body_none=$'通常の本文。依存はありません。\n'
assert_eq "Req4.5 依存なし→空" "" "$(dr_extract_deps "$body_none")"

# NFR: 空入力 → 空
assert_eq "空入力→空" "" "$(dr_extract_deps "")"

echo ""
if [ "$fail_count" -gt 0 ]; then
  echo "$fail_count case(s) failed, $pass_count passed." >&2
  exit 1
fi
echo "All $pass_count cases passed."
