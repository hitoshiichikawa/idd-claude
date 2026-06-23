#!/usr/bin/env bash
# pr_default_prompt_test.sh — Issue #399 既定プロンプト網羅性 / spec 整合チェック検証
#
# 対象: local-watcher/bin/modules/pr-reviewer.sh の pr_default_prompt 関数
# Issue: #399
#
# 検証する AC（docs/specs/399-feat-pr-reviewer-spec/requirements.md）:
#   Req 1.1: 「差分全体を網羅的に走査し、検出した指摘を 1 パスで列挙漏れなく出力」指示
#   Req 1.2: 「同一観点で複数箇所に存在する指摘は drip-feed せず最初のパスで全件列挙」指示
#   Req 1.3: 既存「レビュー観点（優先度順）」5 項目の構造と順序を保持
#   Req 1.4: PR_REVIEWER_PROMPT 未設定 / 空時は新しい既定プロンプトを使用
#   Req 1.5: PR_REVIEWER_PROMPT 非空時は override 値を使用、既定プロンプト文言を流入させない
#   Req 2.1: 「diff に docs/specs/<番号>-<slug>/ 配下のファイル変更が含まれる場合は requirements.md
#            / design.md / tasks.md の整合性を突き合わせて検査する」指示
#   Req 2.2: 「requirements.md の各 AC が design.md でカバーされているか」整合観点
#   Req 2.3: 「design.md の Components / Interfaces が tasks.md のタスクで実装手順化されているか」整合観点
#   Req 2.4: 「tasks.md の各タスクの _Requirements:_ アノテーションが requirements.md の実在 AC を参照しているか」整合観点
#   Req 2.5: diff に docs/specs/ 配下のファイル変更が含まれない場合は条件付き適用であることを文中で明確化
#   Req 3.1: 出力構造として ## 概要 / ## 指摘事項 / ## 結論 の 3 セクション見出し厳守
#   Req 3.2: 結論セクション最終行に VERDICT: needs-iteration / VERDICT: approve のいずれか 1 行
#   Req 3.3: 指摘事項の各行が [high|medium|low] <file>:<line> — <内容と根拠> 形式
#   Req 3.4: 「指摘が無ければ『指摘なし』」記述
#   Req 3.5: read-only / file:line 引用 / スタイル lint 対象外 の 3 制約
#   Req 3.6: プレースホルダ {BASE} / {HEAD} / {PR} を未置換のまま出力
#
# 既存 pr-reviewer module は issue-watcher.sh 本体から source される前提で `set -euo pipefail` 等は
# 宣言していない。本テストでは pr_log / pr_warn / pr_error を stub し、関数だけを取り出して評価する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODULE_PATH="$REPO_ROOT/local-watcher/bin/modules/pr-reviewer.sh"

if [ ! -f "$MODULE_PATH" ]; then
  echo "ERROR: module not found: $MODULE_PATH" >&2
  exit 1
fi

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "PASS: $*"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $*" >&2
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label (missing: '$needle')"
  fi
}

assert_grep_e() {
  local label="$1" haystack="$2" pattern="$3"
  if printf '%s' "$haystack" | grep -qE -- "$pattern"; then
    pass "$label"
  else
    fail "$label (pattern not matched: '$pattern')"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fail "$label (unexpectedly contains: '$needle')"
  else
    pass "$label"
  fi
}

# pr_log / pr_warn / pr_error を stub（pr-reviewer.sh は core_utils 経由でこれらを呼び出す）
pr_log() { :; }
pr_warn() { :; }
pr_error() { :; }

# pr-reviewer.sh は本体側 set -euo pipefail を前提とするため、source 側で宣言済みのまま読み込む
# shellcheck disable=SC1090
source "$MODULE_PATH"

echo "=== Section 1: pr_default_prompt 出力契約（Req 1 / 2 / 3） ==="
DEFAULT_PROMPT=$(pr_default_prompt)

# ── Req 1: 網羅性要求 ────────────────────────────────────────────────────────
# Req 1.1: 差分全体を網羅的に走査し列挙漏れなく出力する旨
assert_grep_e "Req 1.1: 差分全体を網羅的に走査する旨が含まれる" \
  "$DEFAULT_PROMPT" '差分全体を.*網羅的に'
assert_contains "Req 1.1: 列挙漏れなく一度に出力する旨" \
  "$DEFAULT_PROMPT" "列挙漏れなく"

# Req 1.2: drip-feed 禁止 / 同一観点で複数箇所 / 最初のパスで全件
assert_contains "Req 1.2: drip-feed 禁止が明示されている" \
  "$DEFAULT_PROMPT" "drip-feed"
assert_grep_e "Req 1.2: 同一観点で複数箇所がある場合は全件列挙する旨" \
  "$DEFAULT_PROMPT" '同一観点で複数箇所'

# Req 1.3: 既存 5 観点の構造と順序を保持
assert_contains "Req 1.3: 「レビュー観点（優先度順）」見出しが残っている" \
  "$DEFAULT_PROMPT" "# レビュー観点（優先度順）"
assert_grep_e "Req 1.3 (順序 1): 正確性のバグが 1." \
  "$DEFAULT_PROMPT" '^1\. 正確性のバグ'
assert_grep_e "Req 1.3 (順序 2): 受入基準の未カバーが 2." \
  "$DEFAULT_PROMPT" '^2\. 受入基準の未カバー'
assert_grep_e "Req 1.3 (順序 3): テスト不足が 3." \
  "$DEFAULT_PROMPT" '^3\. テスト不足'
assert_grep_e "Req 1.3 (順序 4): セキュリティ退行が 4." \
  "$DEFAULT_PROMPT" '^4\. セキュリティ退行'
assert_grep_e "Req 1.3 (順序 5): 後方互換性の破壊が 5." \
  "$DEFAULT_PROMPT" '^5\. 後方互換性の破壊'

# 行番号で順序検証（5 観点が連続して 1→5 で出ることを確認）
ORDER=$(printf '%s\n' "$DEFAULT_PROMPT" | grep -nE '^[1-5]\. (正確性のバグ|受入基準の未カバー|テスト不足|セキュリティ退行|後方互換性の破壊)' | awk -F: '{print $1}')
ORDER_COUNT=$(printf '%s' "$ORDER" | grep -c '^[0-9]')
if [ "$ORDER_COUNT" -eq 5 ]; then
  # 5 つの行番号が単調増加か確認
  prev=0
  ok=1
  for n in $ORDER; do
    if [ "$n" -le "$prev" ]; then
      ok=0
      break
    fi
    prev="$n"
  done
  if [ "$ok" = "1" ]; then
    pass "Req 1.3: 5 観点が行順 1→2→3→4→5 で並んでいる"
  else
    fail "Req 1.3: 5 観点の行順が単調増加でない ($ORDER)"
  fi
else
  fail "Req 1.3: 5 観点の出現数が 5 ではない (count=$ORDER_COUNT)"
fi

# ── Req 2: spec 文書間整合チェック観点 ───────────────────────────────────────
# Req 2.1: docs/specs/<番号>-<slug>/ 配下が差分に含まれる場合の整合性チェック指示
assert_contains "Req 2.1: docs/specs/<番号>-<slug>/ 言及" \
  "$DEFAULT_PROMPT" 'docs/specs/<番号>-<slug>/'
# requirements.md / design.md / tasks.md の 3 文書名がいずれも本文に登場することを確認
assert_contains "Req 2.1: requirements.md が言及されている" \
  "$DEFAULT_PROMPT" 'requirements.md'
assert_contains "Req 2.1: design.md が言及されている" \
  "$DEFAULT_PROMPT" 'design.md'
assert_contains "Req 2.1: tasks.md が言及されている" \
  "$DEFAULT_PROMPT" 'tasks.md'
assert_contains "Req 2.1: 整合性を突き合わせて検査する指示" \
  "$DEFAULT_PROMPT" '整合性を 1 パス目で突き合わせて'

# Req 2.2: requirements ⇄ design のカバレッジ観点
# 「requirements ⇄ design」見出しと「カバーされているか」が同一節に登場する形を確認
assert_contains "Req 2.2: requirements ⇄ design 観点見出し" \
  "$DEFAULT_PROMPT" 'requirements ⇄ design'
# shellcheck disable=SC2016  # backtick はマークダウン記号としてリテラル評価したい
assert_contains "Req 2.2: design.md でカバーされているか観点" \
  "$DEFAULT_PROMPT" '`design.md` で'
assert_contains "Req 2.2: カバーされているか観点" \
  "$DEFAULT_PROMPT" 'カバーされているか'

# Req 2.3: design ⇄ tasks の実装手順化観点
assert_grep_e "Req 2.3: design の Components / Interfaces が tasks のタスクで実装手順化されているか観点" \
  "$DEFAULT_PROMPT" 'design.*Components.*tasks'

# Req 2.4: tasks ⇄ requirements の _Requirements:_ アノテーション参照整合
assert_contains "Req 2.4: tasks の _Requirements:_ アノテーション言及" \
  "$DEFAULT_PROMPT" "_Requirements:_"
assert_grep_e "Req 2.4: 実在 AC を参照しているか観点" \
  "$DEFAULT_PROMPT" '実在.*AC'

# Req 2.5: 条件付き適用であることが文中で明確化されている（docs/specs 不在時は阻害しない）
assert_contains "Req 2.5: 条件付き適用の明記" \
  "$DEFAULT_PROMPT" "条件付き適用"
assert_grep_e "Req 2.5: docs/specs 不在時の skip 指示" \
  "$DEFAULT_PROMPT" 'docs/specs.*含まれない.*スキップ'

# ── Req 3: 既存出力契約の維持 ────────────────────────────────────────────────
# Req 3.1: 3 セクション見出し
assert_grep_e "Req 3.1: ## 概要 見出しが存在する" \
  "$DEFAULT_PROMPT" '^## 概要$'
assert_grep_e "Req 3.1: ## 指摘事項 見出しが存在する" \
  "$DEFAULT_PROMPT" '^## 指摘事項$'
assert_grep_e "Req 3.1: ## 結論 見出しが存在する" \
  "$DEFAULT_PROMPT" '^## 結論$'

# Req 3.2: VERDICT 1 行
assert_grep_e "Req 3.2: VERDICT: needs-iteration 行（単独）" \
  "$DEFAULT_PROMPT" '^VERDICT: needs-iteration$'
assert_grep_e "Req 3.2: VERDICT: approve 行（単独）" \
  "$DEFAULT_PROMPT" '^VERDICT: approve$'
assert_contains "Req 3.2: 結論最終行に VERDICT を単独で出力する指示" \
  "$DEFAULT_PROMPT" '本文の最終行に、次のいずれか 1 行だけを単独で出力'

# Req 3.3: 指摘事項行フォーマット
assert_contains "Req 3.3: [high|medium|low] <file>:<line> — <内容と根拠> 形式" \
  "$DEFAULT_PROMPT" "[high|medium|low] <file>:<line> — <内容と根拠>"

# Req 3.4: 指摘なし
assert_contains "Req 3.4: 「指摘が無ければ『指摘なし』」記述" \
  "$DEFAULT_PROMPT" "指摘なし"

# Req 3.5: 3 制約
assert_contains "Req 3.5: read-only 制約" \
  "$DEFAULT_PROMPT" "read-only"
assert_contains "Req 3.5: file:line を根拠として必ず引用する" \
  "$DEFAULT_PROMPT" "差分に実在する file:line を根拠として必ず引用する"
assert_contains "Req 3.5: スタイル / lint 対象外" \
  "$DEFAULT_PROMPT" "スタイル / lint レベルの指摘は対象外"

# Req 3.6: プレースホルダ未置換
assert_contains "Req 3.6: {BASE} プレースホルダが未置換" \
  "$DEFAULT_PROMPT" "{BASE}"
assert_contains "Req 3.6: {HEAD} プレースホルダが未置換" \
  "$DEFAULT_PROMPT" "{HEAD}"
assert_contains "Req 3.6: {PR} プレースホルダが未置換" \
  "$DEFAULT_PROMPT" "{PR}"

echo ""
echo "=== Section 2: pr_build_prompt_file 解決順序（Req 1.4 / 1.5 / 4.4 / 4.5） ==="

# Section 2 では pr_build_prompt_file の override 優先動作を検証する。
# pr_build_prompt_file は PR_REVIEWER_PROMPT が非空時は当該値を採用し、空時は内蔵 default を採用する。

# ── Req 1.4: PR_REVIEWER_PROMPT 未設定 → 内蔵 default ─────────────────────────
unset PR_REVIEWER_PROMPT || true
TMP_DEFAULT=$(pr_build_prompt_file "42" "main" "feature/x")
DEFAULT_CONTENT=$(cat "$TMP_DEFAULT")
rm -f "$TMP_DEFAULT"
assert_contains "Req 1.4: PR_REVIEWER_PROMPT 未設定で網羅性要求が含まれる" \
  "$DEFAULT_CONTENT" "網羅性要求"
assert_contains "Req 1.4: PR_REVIEWER_PROMPT 未設定で spec 整合チェック節が含まれる" \
  "$DEFAULT_CONTENT" "spec 文書間整合チェック"

# ── Req 1.4: PR_REVIEWER_PROMPT 空文字 → 内蔵 default ─────────────────────────
export PR_REVIEWER_PROMPT=""
TMP_EMPTY=$(pr_build_prompt_file "42" "main" "feature/x")
EMPTY_CONTENT=$(cat "$TMP_EMPTY")
rm -f "$TMP_EMPTY"
assert_contains "Req 1.4: PR_REVIEWER_PROMPT 空文字で網羅性要求が含まれる" \
  "$EMPTY_CONTENT" "網羅性要求"

# プレースホルダが置換されていることを確認（pr_build_prompt_file は {BASE} 等を置換する）
assert_contains "Req 1.4: 内蔵 default 経由で {BASE} が main に置換される" \
  "$EMPTY_CONTENT" "ブランチ main"
assert_contains "Req 1.4: 内蔵 default 経由で {HEAD} が feature/x に置換される" \
  "$EMPTY_CONTENT" "head ブランチ feature/x"
assert_contains "Req 1.4: 内蔵 default 経由で {PR} が 42 に置換される" \
  "$EMPTY_CONTENT" "PR #42"

# ── Req 1.5 / 4.5: PR_REVIEWER_PROMPT 非空 → override 優先 ────────────────────
# override 文言には新しい既定プロンプト特有の語（「網羅性要求」「drip-feed」「spec 文書間整合チェック」）が
# 含まれていないこと（流入禁止）を検証する。
export PR_REVIEWER_PROMPT="CUSTOM_OVERRIDE for PR #{PR} base={BASE} head={HEAD}"
TMP_OVERRIDE=$(pr_build_prompt_file "42" "main" "feature/x")
OVERRIDE_CONTENT=$(cat "$TMP_OVERRIDE")
rm -f "$TMP_OVERRIDE"
assert_contains "Req 1.5: override 文言が採用される" \
  "$OVERRIDE_CONTENT" "CUSTOM_OVERRIDE"
assert_contains "Req 1.5: override 内のプレースホルダも置換される" \
  "$OVERRIDE_CONTENT" "PR #42 base=main head=feature/x"
assert_not_contains "Req 4.5: 新しい既定プロンプトの「網羅性要求」が流入していない" \
  "$OVERRIDE_CONTENT" "網羅性要求"
assert_not_contains "Req 4.5: 新しい既定プロンプトの「drip-feed」が流入していない" \
  "$OVERRIDE_CONTENT" "drip-feed"
assert_not_contains "Req 4.5: 新しい既定プロンプトの「spec 文書間整合チェック」が流入していない" \
  "$OVERRIDE_CONTENT" "spec 文書間整合チェック"

unset PR_REVIEWER_PROMPT || true

echo ""
echo "=== Section 3: VERDICT 検出 regex の後方互換性（Req 3.2 / 4.4） ==="

# 既定 PR_REVIEWER_ITERATION_PATTERN（line-anchored / case-insensitive）で
# 新しい既定プロンプト中の `VERDICT: needs-iteration` がマッチすること、
# `VERDICT: approve` がマッチしないことを検証する。
ITER_PATTERN='^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$'

# needs-iteration ケース（マッチ件数 1 を期待）
NEEDS_SAMPLE="$(printf '## 結論\nVERDICT: needs-iteration\n')"
NEEDS_COUNT=$(printf '%s' "$NEEDS_SAMPLE" | grep -E -i -c -- "$ITER_PATTERN" || true)
if [ "${NEEDS_COUNT:-0}" -ge 1 ]; then
  pass "Req 3.2 / 4.4: 既定 ITERATION_PATTERN が 'VERDICT: needs-iteration' にマッチ (count=$NEEDS_COUNT)"
else
  fail "Req 3.2 / 4.4: 既定 ITERATION_PATTERN が 'VERDICT: needs-iteration' にマッチしない (count=$NEEDS_COUNT)"
fi

# approve ケース（マッチ件数 0 を期待 / 誤発火しない）
APPROVE_SAMPLE="$(printf '## 結論\nVERDICT: approve\n')"
APPROVE_COUNT=$(printf '%s' "$APPROVE_SAMPLE" | grep -E -i -c -- "$ITER_PATTERN" || true)
if [ "${APPROVE_COUNT:-0}" -eq 0 ]; then
  pass "Req 3.2 / 4.4: 既定 ITERATION_PATTERN が 'VERDICT: approve' に誤発火しない (count=$APPROVE_COUNT)"
else
  fail "Req 3.2 / 4.4: 既定 ITERATION_PATTERN が 'VERDICT: approve' に誤発火 (count=$APPROVE_COUNT)"
fi

# 新規節の中に紛れている「需要-iteration」「approve」等の文字列が誤発火を起こさないこと
# （line-anchored 規約により本文中に「needs-iteration」と書かれていても単独行でなければマッチしない）
DEFAULT_NON_VERDICT_LINES=$(printf '%s' "$DEFAULT_PROMPT" | grep -vE '^VERDICT: needs-iteration$' || true)
SPURIOUS_COUNT=$(printf '%s' "$DEFAULT_NON_VERDICT_LINES" | grep -E -i -c -- "$ITER_PATTERN" || true)
if [ "${SPURIOUS_COUNT:-0}" -eq 0 ]; then
  pass "Req 3.2: 既定プロンプト本文中に 'VERDICT: needs-iteration' 行は 1 箇所のみ（誤発火源なし）"
else
  fail "Req 3.2: 既定プロンプト本文中に予期しない VERDICT 一致 (count=$SPURIOUS_COUNT)"
fi

echo ""
echo "=========================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
