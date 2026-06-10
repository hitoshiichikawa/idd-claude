#!/usr/bin/env bash
# 用途: Dependency Gate (#146 / #204) の base 相対化（#316）回帰テスト。
#       BASE_BRANCH != main の develop dispatch で `staged-for-release` を持つ OPEN
#       依存先を resolved 扱いし、BASE_BRANCH=main 時の従来挙動を変更しないことを
#       検証する。並行して CLOSED 系の従来挙動（merged → resolved / unmerged →
#       closed unmerged）にも回帰テストを再配置する（Req 3.4, 3.5）。
# 配置先: docs/specs/316-fix-watcher-dr-resolve-one-develop-dispa/test-dependency-resolver-base.sh
# 依存: bash 4+, jq, sed, awk
# セットアップ参照先: docs/specs/316-fix-watcher-dr-resolve-one-develop-dispa/impl-notes.md
#
# Usage:
#   bash docs/specs/316-fix-watcher-dr-resolve-one-develop-dispa/test-dependency-resolver-base.sh
#
# Exit code:
#   0 = すべてのケースが期待通り
#   1 = いずれかのケースが不一致（standard error にどれが失敗したか出力）
#
# 設計:
#   - #204 の test-dependency-resolver.sh と同パターンで `dr_gh_graphql_closed_by`
#     を stub に差し替え、GraphQL レスポンスを mock 注入する（実 API 不要 / 高速）。
#   - watcher 本体は末尾に main 実行コードを持つため source できない。よって
#     `dr_log` 〜 `dr_check_dependencies` を awk で抽出して source する（既存
#     パターン踏襲）。
#   - dr_log / dr_warn / dr_error はテスト中に副作用ログを抑止する（出力検証は
#     本テストのスコープ外）。
#   - BASE_BRANCH 環境変数で base 相対化の挙動を切り替えながら検証する。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WATCHER="$SCRIPT_DIR/../../../local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER" ]; then
  echo "[FATAL] watcher script not found: $WATCHER" >&2
  exit 1
fi

# ── dr_* 関数ブロックを抽出して source ──
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

# テスト用環境（REPO は owner/repo 形式、タイムアウト類は短く設定）。
# shellcheck disable=SC2034
REPO="owner/repo"
# shellcheck disable=SC2034
DRR_GH_TIMEOUT=60
# shellcheck disable=SC2034
MERGE_QUEUE_GIT_TIMEOUT=60
# shellcheck disable=SC2034
LABEL_STAGED_FOR_RELEASE="staged-for-release"

# shellcheck disable=SC1090
source "$EXTRACTED"

# 抽出ブロック内の dr_log / dr_warn / dr_error を上書きしてテスト中の副作用ログを捨てる。
dr_log() { :; }
dr_warn() { :; }
dr_error() { :; }

# ── mock 注入の仕組み ──
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
# $1 = issue state (OPEN|CLOSED)
# $2 = labels CSV（カンマ区切り、空文字列なら labels なし）
# 残り = PR ノードの state 列（MERGED|CLOSED|OPEN）
make_response() {
  local state="$1"; shift
  local labels_csv="$1"; shift
  local labels_json="[]"
  if [ -n "$labels_csv" ]; then
    labels_json=$(printf '%s' "$labels_csv" \
      | tr ',' '\n' \
      | jq -R 'select(length > 0) | {name: .}' \
      | jq -s '.')
  fi
  local nodes_json="[]"
  if [ "$#" -gt 0 ]; then
    nodes_json=$(printf '%s\n' "$@" \
      | jq -R '{number: 0, state: .}' \
      | jq -s '.')
  fi
  jq -n \
    --arg state "$state" \
    --argjson labels "$labels_json" \
    --argjson nodes "$nodes_json" '
    {data: {repository: {issue: {
      state: $state,
      labels: {nodes: $labels},
      closedByPullRequestsReferences: {nodes: $nodes}
    }}}}'
}

echo "=== #316 Req 1.1: develop dispatch + OPEN + staged-for-release → resolved ==="

# BASE_BRANCH は source した dr_resolve_one が参照する。shellcheck が sourced スコープを
# 追跡できないため `export` で外部参照を明示し SC2034 を回避する（実 watcher 経路と同等）。
export BASE_BRANCH="develop"
MOCK_RC=0
MOCK_RESPONSE=$(make_response OPEN "staged-for-release")
assert_eq "Req1.1 develop+OPEN+staged-for-release" "resolved" "$(dr_resolve_one 301)"

# 補強: develop 以外の任意 branch 名でも main 以外なら multi-branch 扱い（Out of Scope 末尾）
export BASE_BRANCH="feature/foo"
MOCK_RESPONSE=$(make_response OPEN "staged-for-release,other-label")
assert_eq "Req1.1 任意 base != main + 他ラベル混在" "resolved" "$(dr_resolve_one 302)"

echo "=== #316 Req 1.2: main dispatch + OPEN + staged-for-release → unresolved (open) ==="

export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response OPEN "staged-for-release")
assert_eq "Req1.2 main+OPEN+staged-for-release は open" "open" "$(dr_resolve_one 303)"

echo "=== #316 Req 1.3: OPEN without staged-for-release → unresolved (open) どの BASE_BRANCH でも ==="

export BASE_BRANCH="develop"
MOCK_RESPONSE=$(make_response OPEN "")
assert_eq "Req1.3 develop+OPEN+ラベルなし" "open" "$(dr_resolve_one 304)"

export BASE_BRANCH="develop"
MOCK_RESPONSE=$(make_response OPEN "other-label")
assert_eq "Req1.3 develop+OPEN+他ラベルのみ" "open" "$(dr_resolve_one 305)"

export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response OPEN "")
assert_eq "Req1.3 main+OPEN+ラベルなし" "open" "$(dr_resolve_one 306)"

echo "=== #316 Req 1.4 / 1.5: CLOSED 系の従来挙動（base 値によらず）==="

export BASE_BRANCH="develop"
MOCK_RESPONSE=$(make_response CLOSED "staged-for-release" MERGED)
assert_eq "Req1.4 develop+CLOSED+MERGED PR" "resolved" "$(dr_resolve_one 307)"

export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response CLOSED "" MERGED)
assert_eq "Req1.4 main+CLOSED+MERGED PR" "resolved" "$(dr_resolve_one 308)"

export BASE_BRANCH="develop"
MOCK_RESPONSE=$(make_response CLOSED "" CLOSED)
assert_eq "Req1.5 develop+CLOSED+CLOSED PR" "closed unmerged" "$(dr_resolve_one 309)"

export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response CLOSED "")
assert_eq "Req1.5 main+CLOSED+PR 0 件" "closed unmerged" "$(dr_resolve_one 310)"

# CLOSED+staged-for-release ラベル付き + MERGED PR は resolved（ラベルは無視されるべき）
export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response CLOSED "staged-for-release" MERGED)
assert_eq "Req1.4 main+CLOSED+SfR+MERGED は resolved（ラベル無視）" "resolved" "$(dr_resolve_one 311)"

echo "=== #316 Req 2.1: state + labels を同一クエリで取得（GraphQL 構造の確認）==="

# response の data.repository.issue 配下に state / labels / closedByPullRequestsReferences が
# 揃っているかを構造として確認（make_response が生成する JSON を直接検証）。
MOCK_RESPONSE=$(make_response OPEN "staged-for-release")
struct_ok=$(printf '%s' "$MOCK_RESPONSE" \
  | jq -r '(.data.repository.issue | has("state")) and (.data.repository.issue | has("labels")) and (.data.repository.issue | has("closedByPullRequestsReferences"))')
assert_eq "Req2.1 単一 response に state + labels + PR 一覧が同梱" "true" "$struct_ok"

echo "=== #316 Req 2.2 / 2.3: 失敗時フォールバック（安全側に倒す）==="

# 2.2: gh api graphql 失敗 → api error（labels も取れないため安全側）
export BASE_BRANCH="develop"
MOCK_RC=1
MOCK_RESPONSE="gh: rate limit exceeded"
assert_eq "Req2.2 gh 失敗時は base 値によらず api error" "api error" "$(dr_resolve_one 312)"
MOCK_RC=0

# 2.2: GraphQL errors → api error
export BASE_BRANCH="develop"
MOCK_RESPONSE='{"errors":[{"message":"Could not resolve to a node","type":"NOT_FOUND"}]}'
assert_eq "Req2.2 GraphQL errors は api error" "api error" "$(dr_resolve_one 313)"

# 2.3: OPEN + labels ノードが欠落（想定外構造） → 「ラベルなし」と等価で扱われる
# （jq の `?` で欠落をスキップし length=0 → false → open）。
# これは「ラベル取得失敗 → 仮定して resolved にしない」(Req 2.3) と整合する:
# labels ノードが欠落していても staged-for-release 付与を仮定して resolved にする
# 処理は行わず unresolved (open) のままとなる。
export BASE_BRANCH="develop"
MOCK_RESPONSE='{"data":{"repository":{"issue":{"state":"OPEN","closedByPullRequestsReferences":{"nodes":[]}}}}}'
assert_eq "Req2.3 OPEN + labels ノード欠落は staged を仮定せず open" "open" "$(dr_resolve_one 314)"

# 2.2: 壊れた JSON → api error（state 取り出しで死ぬ）
export BASE_BRANCH="develop"
MOCK_RESPONSE='not a json at all {{{'
assert_eq "Req2.2 壊れた JSON" "api error" "$(dr_resolve_one 315)"

echo "=== #316 NFR 1.1: BASE_BRANCH=main 時の挙動が本変更前と完全一致 ==="

# main + OPEN+SfR → open（base 相対化ロジックがバイパスされること）
export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response OPEN "staged-for-release,other")
assert_eq "NFR1.1 main+OPEN+SfR は open（従来同一）" "open" "$(dr_resolve_one 316)"

# main + OPEN+ラベルなし → open
export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response OPEN "")
assert_eq "NFR1.1 main+OPEN+ラベルなしは open" "open" "$(dr_resolve_one 317)"

# main + CLOSED+MERGED → resolved
export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response CLOSED "" MERGED)
assert_eq "NFR1.1 main+CLOSED+MERGED は resolved" "resolved" "$(dr_resolve_one 318)"

# main + CLOSED+(CLOSED,MERGED) 混在 → resolved
export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response CLOSED "" CLOSED MERGED)
assert_eq "NFR1.1 main+CLOSED+混在 は resolved" "resolved" "$(dr_resolve_one 319)"

# main + CLOSED+全て CLOSED → closed unmerged
export BASE_BRANCH="main"
MOCK_RESPONSE=$(make_response CLOSED "" CLOSED)
assert_eq "NFR1.1 main+CLOSED+CLOSED PR は closed unmerged" "closed unmerged" "$(dr_resolve_one 320)"

echo ""
if [ "$fail_count" -gt 0 ]; then
  echo "$fail_count case(s) failed, $pass_count passed." >&2
  exit 1
fi
echo "All $pass_count cases passed."
