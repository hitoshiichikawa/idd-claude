#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #305（per-task retry で Reviewer
#       Findings を Developer prompt に inline 注入する）で追加した
#       `pt_extract_findings_block` 関数を fixture で検証するスモークテスト。
#
#       対象関数:
#         - pt_extract_findings_block (Issue #305 Req 1.1 / 1.3 / 1.5 / 5.1 / 5.5 / NFR 4.1)
#
#       既存 `pi_max_rounds_kind_test.sh` の「awk による関数抽出 + eval 読み込み」
#       パターンを踏襲する。トップレベル副作用は回避する。
#
# 配置先: local-watcher/test/pt_extract_findings_block_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/pt_extract_findings_block_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pt_extract_findings_block"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -d "$FIXTURE_DIR" ]; then
  echo "ERROR: cannot find fixture dir at $FIXTURE_DIR" >&2
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
eval "$(extract_function "$WATCHER_SH" "pt_extract_findings_block")"

if ! declare -F pt_extract_findings_block >/dev/null; then
  echo "ERROR: pt_extract_findings_block not loaded" >&2
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

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle  : $(printf '%q' "$needle")"
    echo "  haystack: $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  forbidden: $(printf '%q' "$needle")"
    echo "  haystack : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─── Case 1: normal-2-findings.md（Req 1.1 / 1.3 / NFR 4.1） ───
echo "--- pt_extract_findings_block: normal-2-findings.md (Req 1.1 / 1.3) ---"

rc=0
out=$(pt_extract_findings_block "$FIXTURE_DIR/normal-2-findings.md") || rc=$?

assert_eq "Req 1.1: return code は 0（抽出成功）" "0" "$rc"
assert_contains "Req 1.1: 出力に '## Findings' 見出しが含まれる" \
  "## Findings" "$out"
assert_contains "Req 1.3: Finding 1 の Target 行が保持される" \
  "**Target**: 1.1" "$out"
assert_contains "Req 1.3: Finding 1 の Category 行が保持される" \
  "**Category**: AC 未カバー" "$out"
assert_contains "Req 1.3: Finding 2 の Target boundary 行が保持される" \
  "**Target**: boundary:Watcher" "$out"
assert_contains "Req 1.3: Finding 2 の Category 行が保持される" \
  "**Category**: boundary 逸脱" "$out"
# NFR 4.1: 次の `## ` 見出し（## Summary）で停止しているため、Summary 本文 / RESULT 行は含まれない
assert_not_contains "NFR 4.1: '## Summary' は含まれない（次セクションで停止）" \
  "## Summary" "$out"
assert_not_contains "NFR 4.1: 'RESULT: reject' は含まれない（次セクション以降）" \
  "RESULT: reject" "$out"

echo ""

# ─── Case 2: no-findings-section.md（Req 1.5 / 5.5） ───
echo "--- pt_extract_findings_block: no-findings-section.md (Req 1.5 / 5.5) ---"

rc=0
out=$(pt_extract_findings_block "$FIXTURE_DIR/no-findings-section.md") || rc=$?

assert_eq "Req 1.5 / 5.5: '## Findings' 見出し不在で return 1" "1" "$rc"
assert_eq "Req 1.5 / 5.5: 不在時 stdout は空文字" "" "$out"

echo ""

# ─── Case 3: findings-with-nested-headers.md（Req 1.3 / NFR 4.1） ───
echo "--- pt_extract_findings_block: findings-with-nested-headers.md (Req 1.3 / NFR 4.1) ---"

rc=0
out=$(pt_extract_findings_block "$FIXTURE_DIR/findings-with-nested-headers.md") || rc=$?

assert_eq "Req 1.3: return code は 0（抽出成功）" "0" "$rc"
assert_contains "Req 1.3: '## Findings' 見出しが含まれる" \
  "## Findings" "$out"
assert_contains "Req 1.3: nested bold 行 '**Target**: 1.3' が含まれる" \
  "**Target**: 1.3" "$out"
assert_contains "Req 1.3: nested 補足箇条書きが含まれる" \
  "補足: 補足箇条書きが Finding 配下にネストされても抽出範囲に含まれることを確認したい" "$out"
assert_contains "Req 1.3: '### Finding 2' h3 見出しが含まれる" \
  "### Finding 2" "$out"
assert_contains "Req 1.3: Finding 2 の Category 行が含まれる" \
  "**Category**: AC 未カバー" "$out"
# NFR 4.1: 次の `## Summary` で停止
assert_not_contains "NFR 4.1: '## Summary' は含まれない" \
  "## Summary" "$out"
assert_not_contains "NFR 4.1: 'RESULT: reject' は含まれない" \
  "RESULT: reject" "$out"

echo ""

# ─── Case 4: ファイル不在（Req 1.5 / 5.5） ───
echo "--- pt_extract_findings_block: missing file (Req 1.5 / 5.5) ---"

rc=0
out=$(pt_extract_findings_block "$FIXTURE_DIR/does-not-exist.md") || rc=$?

assert_eq "Req 1.5 / 5.5: ファイル不在で return 1" "1" "$rc"
assert_eq "Req 1.5 / 5.5: ファイル不在時 stdout は空文字" "" "$out"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
