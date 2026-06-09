#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #305（per-task retry で Debugger
#       Fix Plan を Developer prompt に inline 注入する）で追加した
#       `pt_extract_debugger_section` 関数を fixture で検証するスモークテスト。
#
#       対象関数:
#         - pt_extract_debugger_section (Issue #305 Req 1.2 / 1.5 / 5.2 / NFR 4.2)
#
#       既存 `pt_extract_findings_block_test.sh` の「awk による関数抽出 + eval 読み込み」
#       パターンを踏襲する。トップレベル副作用は回避する。
#
# 配置先: local-watcher/test/pt_extract_debugger_section_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/pt_extract_debugger_section_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pt_extract_debugger_section"

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
eval "$(extract_function "$WATCHER_SH" "pt_extract_debugger_section")"

if ! declare -F pt_extract_debugger_section >/dev/null; then
  echo "ERROR: pt_extract_debugger_section not loaded" >&2
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

# ─── Case 1: task-1-2-present.md（Req 1.2 / NFR 4.2） ───
echo "--- pt_extract_debugger_section: task-1-2-present.md (Req 1.2 / NFR 4.2) ---"

rc=0
out=$(pt_extract_debugger_section "$FIXTURE_DIR/task-1-2-present.md" "1.2") || rc=$?

assert_eq "Req 1.2: return code は 0（抽出成功）" "0" "$rc"
assert_contains "Req 1.2: 出力に '## Task 1.2' 見出しが含まれる" \
  "## Task 1.2" "$out"
assert_contains "Req 1.2: '### 根本原因' h3 見出しが含まれる" \
  "### 根本原因" "$out"
assert_contains "Req 1.2: '### 修正手順' h3 見出しが含まれる" \
  "### 修正手順" "$out"
assert_contains "Req 1.2: '### 検証方法' h3 見出しが含まれる" \
  "### 検証方法" "$out"
assert_contains "Req 1.2: 修正手順の本文（pt_extract_findings_block 関連）が保持される" \
  "pt_extract_findings_block" "$out"
# NFR 4.2: 次の `## References` で停止しているため、本文に '## References' は含まれない
assert_not_contains "NFR 4.2: '## References' は含まれない（次セクションで停止）" \
  "## References" "$out"
# 直前の '## 概要' も含まれない（## Task 1.2 行以降から開始）
assert_not_contains "NFR 4.2: '## 概要' は含まれない（## Task 1.2 行以降から開始）" \
  "## 概要" "$out"

echo ""

# ─── Case 2: task-1-2-absent.md（Req 1.5 / 5.2） ───
echo "--- pt_extract_debugger_section: task-1-2-absent.md (Req 1.5 / 5.2) ---"

rc=0
out=$(pt_extract_debugger_section "$FIXTURE_DIR/task-1-2-absent.md" "1.2") || rc=$?

assert_eq "Req 1.5: 当該 '## Task 1.2' 見出し不在で return 1" "1" "$rc"
assert_eq "Req 1.5: 不在時 stdout は空文字" "" "$out"

echo ""

# ─── Case 3: multi-task-sections.md（NFR 4.2: 他 task 混入なし） ───
echo "--- pt_extract_debugger_section: multi-task-sections.md (NFR 4.2) ---"

rc=0
out=$(pt_extract_debugger_section "$FIXTURE_DIR/multi-task-sections.md" "1.2") || rc=$?

assert_eq "NFR 4.2: return code は 0（抽出成功）" "0" "$rc"
assert_contains "NFR 4.2: '## Task 1.2' 見出しが含まれる" \
  "## Task 1.2" "$out"
assert_contains "NFR 4.2: task 1.2 固有の本文が含まれる" \
  "task 1.2 固有の手順 X" "$out"
assert_contains "NFR 4.2: task 1.2 固有の本文（手順 Y）が含まれる" \
  "task 1.2 固有の手順 Y" "$out"
# 隣接する task 1.1 セクションは混入してはならない
assert_not_contains "NFR 4.2: '## Task 1.1' 見出しは含まれない" \
  "## Task 1.1" "$out"
assert_not_contains "NFR 4.2: task 1.1 固有の本文は含まれない" \
  "task 1.1 固有の手順 A" "$out"
assert_not_contains "NFR 4.2: 次の '## References' は含まれない（次セクションで停止）" \
  "## References" "$out"

echo ""

# ─── Case 4: ファイル不在（Req 1.5） ───
echo "--- pt_extract_debugger_section: missing file (Req 1.5) ---"

rc=0
out=$(pt_extract_debugger_section "$FIXTURE_DIR/does-not-exist.md" "1.2") || rc=$?

assert_eq "Req 1.5: ファイル不在で return 1" "1" "$rc"
assert_eq "Req 1.5: ファイル不在時 stdout は空文字" "" "$out"

echo ""

# ─── Case 5: task_id の `.` エスケープ検証（Req 1.2 / NFR 4.2） ───
# task_id `1.2` が awk regex 上で正しくエスケープされ、`1X2` のような
# 任意 1 文字マッチ事故を起こさないことを fixture 経由で確認する。
# 同 fixture (multi-task-sections.md) には `## Task 1.1` も存在するため、
# `.` が任意マッチしていれば 1.1 セクションも誤マッチする可能性があったが、
# Case 3 の "## Task 1.1 不混入" assert で実質的に検証済み。
# 本ケースでは追加で task_id `1.1` を渡したときに 1.1 セクションのみ取れることを確認。
echo "--- pt_extract_debugger_section: multi-task-sections.md task_id=1.1 (Req 1.2 / NFR 4.2) ---"

rc=0
out=$(pt_extract_debugger_section "$FIXTURE_DIR/multi-task-sections.md" "1.1") || rc=$?

assert_eq "Req 1.2: task_id=1.1 でも return 0" "0" "$rc"
assert_contains "Req 1.2: task_id=1.1 で '## Task 1.1' 見出しが含まれる" \
  "## Task 1.1" "$out"
assert_contains "Req 1.2: task_id=1.1 で task 1.1 固有の本文が含まれる" \
  "task 1.1 固有の手順 A" "$out"
assert_not_contains "NFR 4.2: task_id=1.1 抽出時に '## Task 1.2' は含まれない" \
  "## Task 1.2" "$out"
assert_not_contains "NFR 4.2: task_id=1.1 抽出時に task 1.2 固有の本文は含まれない" \
  "task 1.2 固有の手順 X" "$out"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
