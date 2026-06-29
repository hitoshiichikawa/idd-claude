#!/usr/bin/env bash
#
# 用途: PR Reviewer out-of-scope 第 3 判定 (#437) の adjudicator prompt 注入を検証する。
#       adjudicator-prompt.tmpl の {OOS_INSTRUCTIONS} placeholder が、
#         - gate ON  (adj_oos_enabled=ON)  : OOS 分類規約ブロックに置換される
#         - gate OFF (adj_oos_enabled=OFF) : placeholder 行ごと除去され既存 prompt と byte 等価
#       であることを確認する。
#
#       対象関数 / 成果物:
#         - adj_oos_enabled        (opt-in gate / 既定 OFF)
#         - adj_oos_prompt_block   (gate ON 時に注入する分類規約ブロック)
#         - adjudicator-prompt.tmpl の {OOS_INSTRUCTIONS} placeholder と置換ロジック
#
#       検証する受入基準（docs/specs/437-pr-iteration-pr-design-spec-max-rounds/requirements.md）:
#         - Req 1.2 矛盾時に legitimate-out-of-scope へ分類する指示が prompt に入る
#         - Req 1.4 判定根拠（確定事項との矛盾理由）を reason に含める指示が入る
#         - Req 1.5 「迷ったら legitimate」原則が prompt に入る
#         - Req 4.2 Adjudicator 裁定指針（design/spec 確定事項変更を要する指摘は OOS）の明文化
#         - NFR 1.1 gate OFF（既定）で OOS 指示が prompt に入らない（既存 prompt と byte 等価）
#
# 配置先: local-watcher/test/adj_oos_prompt_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/adj_oos_prompt_test.sh

# PR_REVIEWER_OOS_ENABLED は source した adj_oos_enabled が間接参照する gate 変数。
# source 先を追わない静的解析からは未使用に見えるが、テスト全体で gate 切り替えのために
# 繰り返し代入する。SC2034 をファイル全体で抑止する（adj_out_of_scope_test.sh と同方針 /
# 間接参照の false-positive）。本ディレクティブはファイル先頭（最初のコマンドの前）に置く。
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/modules/adjudicator.sh"
TMPL="$SCRIPT_DIR/../bin/adjudicator-prompt.tmpl"

for f in "$ADJ_SH" "$TMPL"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: cannot find $f" >&2
    exit 2
  fi
done

# adj_oos_prompt_block は heredoc 内に行頭 `}`（JSON 例の閉じ括弧）を含むため、
# 既存テストの `$0 == "}"` 終端判定の extract_function では正しく切り出せない。
# adjudicator.sh は module 規約上トップレベル副作用を持たない関数定義のみのため、
# 依存ロガーを stub したうえでファイル全体を source して関数を取り込む。
# shellcheck disable=SC2317
adj_warn()  { :; }
# shellcheck disable=SC2317
adj_error() { :; }
# shellcheck disable=SC2317
adj_log()   { :; }
# shellcheck disable=SC1090
source "$ADJ_SH"

for fn in adj_oos_enabled adj_oos_prompt_block; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected to contain: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "FAIL: $label"
    echo "  expected NOT to contain: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# adj_classify_findings の placeholder 置換ロジックを再現するヘルパー（テスト隔離用）。
# 本体 adj_classify_findings は claude を呼ぶため隔離できないが、置換は単純な bash
# パラメータ展開なので本体と同一式をここで再現して検証する（本体側は同じ式を使用）。
render_oos_placeholder() {
  local prompt_body="$1"
  local rendered="$prompt_body"
  if adj_oos_enabled; then
    local oos_instructions
    oos_instructions=$(adj_oos_prompt_block)
    rendered="${rendered//\{OOS_INSTRUCTIONS\}/$oos_instructions}"
  else
    rendered="${rendered//\{OOS_INSTRUCTIONS\}$'\n'/}"
  fi
  printf '%s' "$rendered"
}

# ─── テンプレに {OOS_INSTRUCTIONS} placeholder が存在することの前提確認 ──────────
echo "--- 前提: テンプレに {OOS_INSTRUCTIONS} placeholder が存在する ---"
TMPL_BODY=$(cat "$TMPL")
assert_contains "adjudicator-prompt.tmpl に {OOS_INSTRUCTIONS} placeholder がある" \
  "{OOS_INSTRUCTIONS}" "$TMPL_BODY"
echo ""

# ─── adj_oos_prompt_block の内容（Req 1.2 / 1.4 / 1.5 / 4.2） ──────────────────
echo "--- adj_oos_prompt_block の規約内容 (Req 1.2 / 1.4 / 1.5 / 4.2) ---"
BLOCK=$(adj_oos_prompt_block)

# Req 1.2: 矛盾時に legitimate-out-of-scope へ分類する条件
assert_contains "Req 1.2: legitimate-out-of-scope の語が含まれる" \
  "legitimate-out-of-scope" "$BLOCK"
assert_contains "Req 1.2: 確定事項と矛盾 + 是正できない旨が含まれる" \
  "権限では是正できない" "$BLOCK"

# Req 1.4: 判定根拠を reason に含める
assert_contains "Req 1.4: 判定根拠（矛盾理由）を reason に明記させる指示がある" \
  "reason" "$BLOCK"
assert_contains "Req 1.4: なぜ当該 PR で是正不能か を出力させる" \
  "なぜ当該 PR で是正不能か" "$BLOCK"

# Req 1.5: 迷ったら legitimate
assert_contains "Req 1.5: 迷ったら legitimate 原則が含まれる" \
  "迷ったら legitimate" "$BLOCK"

# Req 4.2: summary.legitimate_out_of_scope 出力契約
assert_contains "Req 4.2: summary.legitimate_out_of_scope 出力契約が含まれる" \
  "legitimate_out_of_scope" "$BLOCK"
assert_contains "Req 4.2: 不変条件 legitimate + excessive + legitimate_out_of_scope == total" \
  "legitimate + excessive + legitimate_out_of_scope == total" "$BLOCK"
echo ""

# OOS 規約ブロック本文だけに現れる一意な見出し（ヘッダコメントには現れない）。
# ヘッダコメントにも `{OOS_INSTRUCTIONS}` / `legitimate-out-of-scope` の語が出現するため、
# 「注入されたか」の検証は body 限定の一意見出しで行う（comment との混同を避ける）。
OOS_SECTION_HEADING="## out-of-scope（第 3 判定 / legitimate-out-of-scope）の分類規約（本機能が有効です）"
OOS_DOUBT_PHRASE="out-of-scope か否か確信が持てない場合"

# placeholder 行（単独行 `{OOS_INSTRUCTIONS}`）が rendered に残っていないことを行単位で検査。
assert_placeholder_line_absent() {
  local label="$1" haystack="$2"
  if printf '%s\n' "$haystack" | grep -qxF "{OOS_INSTRUCTIONS}"; then
    echo "FAIL: $label"
    echo "  placeholder 行 {OOS_INSTRUCTIONS} が rendered に残存している"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"; PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ─── gate ON: placeholder が OOS 規約に置換される（Req 1.2 / 1.4 / 1.5 / 4.2） ──
echo "--- gate ON: {OOS_INSTRUCTIONS} が OOS 規約に置換される ---"
PR_REVIEWER_OOS_ENABLED="true"
RENDERED_ON=$(render_oos_placeholder "$TMPL_BODY")
assert_placeholder_line_absent "gate ON: 置換後 placeholder 行は残らない" "$RENDERED_ON"
assert_contains "gate ON: OOS 規約見出しが prompt body に入る" \
  "$OOS_SECTION_HEADING" "$RENDERED_ON"
assert_contains "gate ON: 迷ったら legitimate（OOS 版）の追加文が入る" \
  "$OOS_DOUBT_PHRASE" "$RENDERED_ON"
assert_contains "gate ON: summary.legitimate_out_of_scope 出力契約が入る" \
  "legitimate + excessive + legitimate_out_of_scope == total" "$RENDERED_ON"
unset PR_REVIEWER_OOS_ENABLED
echo ""

# ─── gate OFF: placeholder 行ごと除去 + 既存 prompt と byte 等価（NFR 1.1） ─────
echo "--- gate OFF: {OOS_INSTRUCTIONS} 行ごと除去 / 既存 prompt と byte 等価 (NFR 1.1) ---"
PR_REVIEWER_OOS_ENABLED="false"
RENDERED_OFF=$(render_oos_placeholder "$TMPL_BODY")
assert_placeholder_line_absent "gate OFF: placeholder 行は残らない" "$RENDERED_OFF"
assert_not_contains "gate OFF: OOS 規約見出しは prompt body に入らない" \
  "$OOS_SECTION_HEADING" "$RENDERED_OFF"
assert_not_contains "gate OFF: 迷ったら legitimate（OOS 版）の追加文は入らない" \
  "$OOS_DOUBT_PHRASE" "$RENDERED_OFF"

# placeholder 行を含まない「期待される既存 prompt」を awk で生成して byte 比較する。
# （placeholder 行は `{OOS_INSTRUCTIONS}` 単独行。これを丸ごと除去したものが既存 prompt）
EXPECTED_OFF=$(awk '$0 != "{OOS_INSTRUCTIONS}"' "$TMPL")
assert_eq "gate OFF: placeholder 行除去後の prompt と byte 等価" \
  "$EXPECTED_OFF" "$RENDERED_OFF"
unset PR_REVIEWER_OOS_ENABLED
echo ""

# ─── gate 未設定（既定）も OFF と同一挙動（NFR 1.1） ──────────────────────────
echo "--- gate 未設定（既定）: OFF と同一（OOS 指示なし / NFR 1.1） ---"
unset PR_REVIEWER_OOS_ENABLED 2>/dev/null || true
RENDERED_DEFAULT=$(render_oos_placeholder "$TMPL_BODY")
assert_not_contains "gate 未設定: OOS 規約見出しは prompt body に入らない" \
  "$OOS_SECTION_HEADING" "$RENDERED_DEFAULT"
assert_eq "gate 未設定: placeholder 行除去後の prompt と byte 等価" \
  "$EXPECTED_OFF" "$RENDERED_DEFAULT"
echo ""

echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
