#!/usr/bin/env bash
# 用途: PER_TASK_LOOP_ENABLED の各種値で cm_enabled が gate（active / inactive）を正しく判定し、
#       inactive 時は cm_render_prompt_section が空文字 / cm_generate 経路でも context-map.md が
#       生成されないこと（gate の閉鎖性）を fixture ベースで検証する（Req 1.4, 6.3, 3.5）。
#       #313 標準化により opt-in gate `CONTEXT_MAP_ENABLED` は削除されたため、本テストでは
#       「PER_TASK_LOOP_ENABLED のみが gate を制御する」「旧 CONTEXT_MAP_ENABLED は無影響」を
#       回帰として明示的に検証する。
# 配置先: docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/test-cm-disabled.sh
# 依存: bash 4+, modules/context-map.sh を source して呼ぶ。
# セットアップ参照先: docs/specs/313-feat-watcher-context-map-per-task-agent/impl-notes.md
#
# Usage:
#   bash docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/test-cm-disabled.sh
#
# Exit code: 0 = pass / 1 = いずれかの assert が fail

# SC2030 / SC2031 (info): 本ファイル中の env 改変はすべて意図的にサブシェル内で完結させて
# 親シェルへ漏洩させない設計（gate のクリーンテストのため）。`( ... )` 内の export は
# 当該テストのみで有効になるべきで、shellcheck 警告は false-positive として info レベルで
# 抑止する。
# shellcheck disable=SC2030,SC2031

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FIXTURE_DIR="$SCRIPT_DIR"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
MODULE="$REPO_ROOT/local-watcher/bin/modules/context-map.sh"

if [ ! -f "$MODULE" ]; then
  echo "[FATAL] module not found: $MODULE" >&2
  exit 1
fi

export REPO="owner/test-313"

# shellcheck source=/dev/null
source "$MODULE"

fail_count=0
pass_count=0

# ── cm_enabled の rc を assert するヘルパ ──
# 入力: $1 = label, $2 = PER_TASK_LOOP_ENABLED 値（"__unset__" で unset 扱い）,
#       $3 = expected_rc, $4 = CONTEXT_MAP_ENABLED 値（任意。省略時 unset。削除済み旧 env が
#            gate に無影響であることを示すため明示的に渡せるようにしている）
assert_cm_enabled() {
  local label="$1" pt_val="$2" expected_rc="$3" cm_val="${4:-__unset__}"
  local rc
  set +e
  (
    if [ "$pt_val" = "__unset__" ]; then unset PER_TASK_LOOP_ENABLED; else export PER_TASK_LOOP_ENABLED="$pt_val"; fi
    if [ "$cm_val" = "__unset__" ]; then unset CONTEXT_MAP_ENABLED; else export CONTEXT_MAP_ENABLED="$cm_val"; fi
    cm_enabled
  )
  rc=$?
  set -e
  if [ "$rc" = "$expected_rc" ]; then
    echo "[OK]   $label (rc=$rc)"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] $label: rc=$rc (expected $expected_rc)" >&2
    fail_count=$((fail_count + 1))
  fi
}

# ── Req 1.4: PER_TASK_LOOP_ENABLED が true でなければ rc=1（gate inactive） ──
assert_cm_enabled "Req 1.4 PTL unset → rc=1"          "__unset__" "1"
assert_cm_enabled "Req 1.4 PTL empty string → rc=1"   ""          "1"
assert_cm_enabled "Req 1.4 PTL=false → rc=1"          "false"     "1"
assert_cm_enabled "Req 1.4 PTL=random_value → rc=1"   "random"    "1"
assert_cm_enabled "Req 1.4 PTL=True (capital) → rc=1" "True"      "1"
assert_cm_enabled "Req 1.4 PTL=TRUE → rc=1"           "TRUE"      "1"
assert_cm_enabled "Req 1.4 PTL=1 → rc=1"              "1"         "1"
assert_cm_enabled "Req 1.4 PTL=yes → rc=1"            "yes"       "1"
assert_cm_enabled "Req 1.4 PTL=on → rc=1"             "on"        "1"

# ── 正常系: PTL=true で rc=0（gate active / 標準機能として常時有効） ──
assert_cm_enabled "PTL=true → rc=0"                   "true"      "0"

# ── #313 標準化回帰: 削除済み CONTEXT_MAP_ENABLED は gate に一切影響しない ──
# 旧 opt-in env を任意値で渡しても、gate 判定は PER_TASK_LOOP_ENABLED のみで決まる。
assert_cm_enabled "removed CM=false has no effect (PTL=true → rc=0)" "true"  "0" "false"
assert_cm_enabled "removed CM unset has no effect (PTL=true → rc=0)" "true"  "0" "__unset__"
assert_cm_enabled "removed CM=true cannot enable when PTL=false"     "false" "1" "true"
assert_cm_enabled "removed CM=true cannot enable when PTL unset"     "__unset__" "1" "true"

# ── Req 6.3 / 3.5: gate inactive のとき cm_render_prompt_section が空文字を返す ──
# cm_render_prompt_section は cm_enabled が rc=1 のとき早期 return で空文字を返す契約（Req 3.5）。
assert_render_empty_when_disabled() {
  local label="$1" pt_val="$2"
  local out
  set +e
  out=$(
    if [ "$pt_val" = "__unset__" ]; then unset PER_TASK_LOOP_ENABLED; else export PER_TASK_LOOP_ENABLED="$pt_val"; fi
    # 適当な spec dir を渡す（cm_render_prompt_section は cm_enabled が false なら早期 return）。
    REPO_DIR=/tmp SPEC_DIR_REL=spec cm_render_prompt_section "1"
  )
  set -e
  if [ -z "$out" ]; then
    echo "[OK]   $label (render output empty)"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] $label: render output not empty: [$out]" >&2
    fail_count=$((fail_count + 1))
  fi
}

assert_render_empty_when_disabled "Req 6.3 / 3.5 PTL unset → render empty"        "__unset__"
assert_render_empty_when_disabled "Req 6.3 / 3.5 PTL=false → render empty"        "false"
assert_render_empty_when_disabled "Req 6.3 / 3.5 PTL=True (typo) → render empty"  "True"
assert_render_empty_when_disabled "Req 6.3 / 3.5 PTL=1 → render empty"            "1"
assert_render_empty_when_disabled "Req 6.3 / 3.5 PTL=yes → render empty"          "yes"

# ── Req 6.3: gate 閉鎖時に call site で cm_generate を skip → context-map.md 非生成 ──
# watcher 本体は `if cm_enabled` の元でのみ cm_generate を呼ぶ。gate が閉じているとき
# （PTL not true）に call site の分岐を擬似再現し、context-map.md が生成されないことを確認する。
tmp=$(mktemp -d)
mkdir -p "$tmp/spec"
cp "$FIXTURE_DIR/tasks-sample.md" "$tmp/spec/tasks.md"
cp "$FIXTURE_DIR/design-sample.md" "$tmp/spec/design.md"

set +e
(
  unset PER_TASK_LOOP_ENABLED
  if cm_enabled; then
    REPO_DIR="$tmp" SPEC_DIR_REL=spec cm_generate "1" >/dev/null
  fi
)
set -e
if [ ! -f "$tmp/spec/context-map.md" ]; then
  echo "[OK]   Req 6.3 gate-closed call site → context-map.md not generated"
  pass_count=$((pass_count + 1))
else
  echo "[FAIL] Req 6.3 gate-closed but context-map.md was generated" >&2
  fail_count=$((fail_count + 1))
fi
rm -rf "$tmp"

echo "---"
echo "PASS: $pass_count / FAIL: $fail_count"
if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
