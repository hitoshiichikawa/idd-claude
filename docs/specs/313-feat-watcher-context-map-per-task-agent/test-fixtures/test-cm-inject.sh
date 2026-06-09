#!/usr/bin/env bash
# 用途: build_per_task_implementer_prompt / build_per_task_reviewer_prompt の heredoc 末尾に
#       Context Map ブロックが flag-on のときだけ embed されることを fixture ベースで検証する
#       （Req 6.2, 3.1, 3.2, 3.5, NFR 1.1）。
# 配置先: docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/test-cm-inject.sh
# 依存: bash 4+, awk。issue-watcher.sh 本体は副作用付き（_dispatcher_run まで実行する）の
#       ため source できない。代わりに awk で関数定義のみを切り出して一時ファイルから source
#       する。modules/context-map.sh は直接 source して併用する。
# セットアップ参照先: docs/specs/313-feat-watcher-context-map-per-task-agent/impl-notes.md
#
# Usage:
#   bash docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/test-cm-inject.sh
#
# Exit code: 0 = pass / 1 = いずれかの assert が fail

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FIXTURE_DIR="$SCRIPT_DIR"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
WATCHER="$REPO_ROOT/local-watcher/bin/issue-watcher.sh"
MODULE="$REPO_ROOT/local-watcher/bin/modules/context-map.sh"

for f in "$WATCHER" "$MODULE"; do
  if [ ! -f "$f" ]; then
    echo "[FATAL] file not found: $f" >&2
    exit 1
  fi
done

export REPO="owner/test-313"

# context-map.sh を直接 source。
# shellcheck source=/dev/null
source "$MODULE"

# ── issue-watcher.sh から関数定義のみを awk で抽出して source する ──
# 抽出対象:
#   - pt_log / pt_warn （logger; prompt builder 内では非呼出だが redo 経路の build に必要）
#   - pt_extract_learnings  （Implementer の learnings inline 注入）
#   - pt_extract_findings_block / pt_extract_debugger_section（redo 経路用）
#   - build_per_task_implementer_prompt / build_per_task_reviewer_prompt
extract_fn() {
  # $1 = function name (suffix of "() {")
  awk -v fname="$1" '
    BEGIN { flag = 0 }
    {
      if (!flag && index($0, fname "()") == 1) { flag = 1 }
      if (flag) { print }
      if (flag && $0 == "}") { exit }
    }
  ' "$WATCHER"
}

extracted=$(mktemp)
{
  extract_fn "pt_log"
  echo ""
  extract_fn "pt_warn"
  echo ""
  extract_fn "pt_extract_learnings"
  echo ""
  extract_fn "pt_extract_findings_block"
  echo ""
  extract_fn "pt_extract_debugger_section"
  echo ""
  extract_fn "build_per_task_implementer_prompt"
  echo ""
  extract_fn "build_per_task_reviewer_prompt"
} > "$extracted"

# 抽出した関数定義に build_per_task_* が含まれていることを最低限確認する。
if ! grep -q "^build_per_task_implementer_prompt()" "$extracted"; then
  echo "[FATAL] extraction failed: build_per_task_implementer_prompt missing" >&2
  rm -f "$extracted"
  exit 1
fi
if ! grep -q "^build_per_task_reviewer_prompt()" "$extracted"; then
  echo "[FATAL] extraction failed: build_per_task_reviewer_prompt missing" >&2
  rm -f "$extracted"
  exit 1
fi

# heredoc が参照するグローバル変数を最小限定義する。
tmp_spec=$(mktemp -d)
mkdir -p "$tmp_spec/spec"
cp "$FIXTURE_DIR/tasks-sample.md" "$tmp_spec/spec/tasks.md"
cp "$FIXTURE_DIR/design-sample.md" "$tmp_spec/spec/design.md"

# fake LOG（pt_log >> "$LOG" を redo 経路で使うため）。
LOG=$(mktemp)
export LOG

export REPO_DIR="$tmp_spec"
export SPEC_DIR_REL="spec"
export NUMBER="313"
export TITLE="fixture title"
export URL="https://example.com/issue/313"
export BODY="fixture body"
export BRANCH="claude/issue-313-fixture"
export BASE_BRANCH="main"

# shellcheck source=/dev/null
source "$extracted"
rm -f "$extracted"

fail_count=0
pass_count=0

assert_contains_str() {
  # $1 = label, $2 = haystack (string), $3 = needle (literal)
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "[OK]   $label"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] $label: '$needle' not found in stdout" >&2
    fail_count=$((fail_count + 1))
  fi
}

assert_not_contains_str() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "[FAIL] $label: '$needle' should NOT be present" >&2
    fail_count=$((fail_count + 1))
  else
    echo "[OK]   $label"
    pass_count=$((pass_count + 1))
  fi
}

# ── Implementer / Reviewer prompt を flag-on / flag-off の 2 通りで生成 ──

# CASE A: flag-off（CONTEXT_MAP_ENABLED 未設定）
unset CONTEXT_MAP_ENABLED
unset PER_TASK_LOOP_ENABLED
impl_off=$(build_per_task_implementer_prompt "1" 2>/dev/null)
# Reviewer は 5 引数必須: <task_id> <range_start> <range_end> <round> <prev_result>
rev_off=$(build_per_task_reviewer_prompt "1" "abc123" "def456" "1" "approve" 2>/dev/null)

# CASE B: flag-on（both env true）。事前に context-map.md を生成しておく。
export CONTEXT_MAP_ENABLED=true
export PER_TASK_LOOP_ENABLED=true
cm_generate "1" >/dev/null 2>&1
impl_on=$(build_per_task_implementer_prompt "1" 2>/dev/null)
rev_on=$(build_per_task_reviewer_prompt "1" "abc123" "def456" "1" "approve" 2>/dev/null)

# ── Req 3.1 / 6.2: flag-on Implementer prompt に "## Context Map" が含まれる ──
assert_contains_str "Req 3.1 Implementer flag-on contains '## Context Map'" "$impl_on" "## Context Map"
assert_contains_str "Req 3.1 Implementer flag-on contains spec path" "$impl_on" "spec/context-map.md"

# ── Req 3.2 / 6.2: flag-on Reviewer prompt にも "## Context Map" が含まれる ──
assert_contains_str "Req 3.2 Reviewer flag-on contains '## Context Map'" "$rev_on" "## Context Map"

# ── Req 3.5 / NFR 1.1: flag-off Implementer / Reviewer prompt に "## Context Map" が含まれない ──
assert_not_contains_str "Req 3.5 Implementer flag-off has no '## Context Map'" "$impl_off" "## Context Map"
assert_not_contains_str "Req 3.5 Reviewer flag-off has no '## Context Map'" "$rev_off" "## Context Map"

# ── Req 3.5 / NFR 1.1 強化: flag-off prompt は flag-on の Context Map block を除いた残りと一致する ──
# 厳密な byte 等価ではなく、Context Map ブロック以外が等価であることを示すため、
# 「flag-off prompt」が「flag-on prompt から '## Context Map' 以降を削除したもの」と一致する
# ことを確認する。先頭 EOF までは共通であるべき（Implementer side は EOF が最後に来る）。
# 実装側で Context Map ブロックの直前は ${closure_matrix_section} で終わる ${context_map_block_section}
# の連結のため、Context Map ブロックは prompt 末尾近傍にしか現れない。これを利用して
# strip 後の比較で off 系統と一致するか検証する。
impl_on_stripped=$(printf '%s' "$impl_on" | awk '/^## Context Map/{f=1} !f{print}')
impl_off_normalized=$(printf '%s' "$impl_off")
# 末尾改行差を吸収するため、両者を改行で正規化してから比較する。
impl_on_stripped_norm=$(printf '%s\n' "$impl_on_stripped")
impl_off_normalized_norm=$(printf '%s\n' "$impl_off_normalized")
if [ "$impl_on_stripped_norm" = "$impl_off_normalized_norm" ]; then
  echo "[OK]   NFR 1.1 Implementer flag-off matches flag-on with Context Map stripped"
  pass_count=$((pass_count + 1))
else
  # diff を short summary で出す（debug 補助）。
  diff_summary=$(diff <(printf '%s' "$impl_off_normalized_norm") <(printf '%s' "$impl_on_stripped_norm") | head -5 || true)
  echo "[FAIL] NFR 1.1 Implementer flag-off does not match flag-on with Context Map stripped" >&2
  echo "  diff (first 5 lines):" >&2
  echo "$diff_summary" >&2
  fail_count=$((fail_count + 1))
fi

rev_on_stripped=$(printf '%s' "$rev_on" | awk '/^## Context Map/{f=1} !f{print}')
rev_off_norm=$(printf '%s\n' "$rev_off")
rev_on_stripped_norm=$(printf '%s\n' "$rev_on_stripped")
if [ "$rev_off_norm" = "$rev_on_stripped_norm" ]; then
  echo "[OK]   NFR 1.1 Reviewer flag-off matches flag-on with Context Map stripped"
  pass_count=$((pass_count + 1))
else
  diff_summary=$(diff <(printf '%s' "$rev_off_norm") <(printf '%s' "$rev_on_stripped_norm") | head -5 || true)
  echo "[FAIL] NFR 1.1 Reviewer flag-off does not match flag-on with Context Map stripped" >&2
  echo "  diff (first 5 lines):" >&2
  echo "$diff_summary" >&2
  fail_count=$((fail_count + 1))
fi

# ── cleanup ──
rm -rf "$tmp_spec"
rm -f "$LOG"

echo "---"
echo "PASS: $pass_count / FAIL: $fail_count"
if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
