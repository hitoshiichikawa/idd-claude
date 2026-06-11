#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/promote-pipeline.sh の #320（sticky comment の
#       URL/ID パース純粋関数抽出）で新設した 2 ヘルパーを fixture で検証する
#       スモークテスト。
#
#       対象関数:
#         - po_extract_comment_id_from_url（URL 末尾 #issuecomment-<id> から数値 ID 抽出）
#         - po_find_sticky_comment_url（comments JSON から marker 一致コメントの URL 抽出）
#
#       両者は副作用のない純粋関数（gh / git を呼ばず状態を変更しない）。抽出前に
#       3 箇所（po_persist_edit_paths / po_apply_awaiting_slot / po_apply_busy_wait_signal）
#       で同一だったロジックを共通化したため、入出力の差分等価を本テストで固定する。
#
# 配置先: local-watcher/test/po_sticky_comment_helpers_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/po_sticky_comment_helpers_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE_PIPELINE_SH="$SCRIPT_DIR/../bin/modules/promote-pipeline.sh"

if [ ! -f "$PROMOTE_PIPELINE_SH" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PROMOTE_PIPELINE_SH" >&2
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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "po_extract_comment_id_from_url")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "po_find_sticky_comment_url")"

if ! declare -F po_extract_comment_id_from_url >/dev/null; then
  echo "ERROR: po_extract_comment_id_from_url not loaded" >&2
  exit 2
fi
if ! declare -F po_find_sticky_comment_url >/dev/null; then
  echo "ERROR: po_find_sticky_comment_url not loaded" >&2
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

echo "--- po_extract_comment_id_from_url cases ---"

# 正常系: GitHub の issue comment URL 末尾から数値 ID を抽出
assert_eq "末尾 #issuecomment-<id> から数値 ID を抽出する" \
  "123456789" \
  "$(po_extract_comment_id_from_url "https://github.com/owner/repo/issues/42#issuecomment-123456789")"

# 異常系: 空入力 → 空文字（return 0）
assert_eq "空 URL のとき空文字を返す" \
  "" \
  "$(po_extract_comment_id_from_url "")"

# 異常系: marker パターンを含まない URL → 空文字
assert_eq "#issuecomment- を含まない URL のとき空文字を返す" \
  "" \
  "$(po_extract_comment_id_from_url "https://github.com/owner/repo/issues/42")"

# 境界値: 末尾が数値で終わらない（#issuecomment-abc）→ 空文字（数値のみ許容）
assert_eq "#issuecomment- の後が非数値のとき空文字を返す" \
  "" \
  "$(po_extract_comment_id_from_url "https://github.com/owner/repo/issues/42#issuecomment-abc")"

echo "--- po_find_sticky_comment_url cases ---"

MARKER="<!-- idd-claude:awaiting-slot:v1 -->"

# 正常系: marker を含む最初のコメントの URL を返す
JSON_HIT='{"comments":[{"body":"無関係","url":"https://x/issues/1#issuecomment-1"},{"body":"待機中\n<!-- idd-claude:awaiting-slot:v1 -->","url":"https://x/issues/1#issuecomment-222"}]}'
assert_eq "marker 一致コメントの URL を返す" \
  "https://x/issues/1#issuecomment-222" \
  "$(po_find_sticky_comment_url "$JSON_HIT" "$MARKER")"

# 異常系: marker 不在 → 空文字
JSON_MISS='{"comments":[{"body":"無関係","url":"https://x/issues/1#issuecomment-1"}]}'
assert_eq "marker 不在のとき空文字を返す" \
  "" \
  "$(po_find_sticky_comment_url "$JSON_MISS" "$MARKER")"

# 境界値: comments が空配列 → 空文字
assert_eq "comments 空配列のとき空文字を返す" \
  "" \
  "$(po_find_sticky_comment_url '{"comments":[]}' "$MARKER")"

# 異常系: comments キー不在 → 空文字（fail-safe）
assert_eq "comments キー不在のとき空文字を返す" \
  "" \
  "$(po_find_sticky_comment_url '{}' "$MARKER")"

# 異常系: 不正 JSON → 空文字（jq 失敗 fail-safe）
assert_eq "不正 JSON 入力のとき空文字を返す（jq 失敗 fail-safe）" \
  "" \
  "$(po_find_sticky_comment_url 'not-json' "$MARKER")"

# 複数 marker 一致時は最初の 1 件のみ
JSON_MULTI='{"comments":[{"body":"a <!-- idd-claude:awaiting-slot:v1 -->","url":"https://x#issuecomment-10"},{"body":"b <!-- idd-claude:awaiting-slot:v1 -->","url":"https://x#issuecomment-20"}]}'
assert_eq "複数 marker 一致のとき最初の 1 件の URL を返す" \
  "https://x#issuecomment-10" \
  "$(po_find_sticky_comment_url "$JSON_MULTI" "$MARKER")"

echo ""
echo "================================"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
