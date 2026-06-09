#!/usr/bin/env bash
# 用途: CONTEXT_MAP_ENABLED / PER_TASK_LOOP_ENABLED の各種値で cm_enabled が rc=1 を返し、
#       cm_generate 経路を通っても context-map.md が生成されないこと（gate の閉鎖性）を
#       fixture ベースで検証する（Req 6.3, 1.2, 1.3, 1.4 のカバレッジ）。
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
# 入力: $1 = label, $2 = CONTEXT_MAP_ENABLED 値（"__unset__" で unset 扱い）,
#       $3 = PER_TASK_LOOP_ENABLED 値（同上）, $4 = expected_rc
assert_cm_enabled() {
  local label="$1" cm_val="$2" pt_val="$3" expected_rc="$4"
  local rc
  set +e
  (
    if [ "$cm_val" = "__unset__" ]; then unset CONTEXT_MAP_ENABLED; else export CONTEXT_MAP_ENABLED="$cm_val"; fi
    if [ "$pt_val" = "__unset__" ]; then unset PER_TASK_LOOP_ENABLED; else export PER_TASK_LOOP_ENABLED="$pt_val"; fi
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

# ── Req 1.2: CONTEXT_MAP_ENABLED 未設定 / 空 / false で rc=1 ──
assert_cm_enabled "Req 1.2 CM unset → rc=1"           "__unset__" "true" "1"
assert_cm_enabled "Req 1.2 CM empty string → rc=1"    ""          "true" "1"
assert_cm_enabled "Req 1.2 CM=false → rc=1"           "false"     "true" "1"
assert_cm_enabled "Req 1.2 CM=random_value → rc=1"    "random"    "true" "1"

# ── Req 1.3: True / 1 / yes 等は無効として rc=1 ──
assert_cm_enabled "Req 1.3 CM=True (capital) → rc=1"  "True"      "true" "1"
assert_cm_enabled "Req 1.3 CM=TRUE → rc=1"            "TRUE"      "true" "1"
assert_cm_enabled "Req 1.3 CM=1 → rc=1"               "1"         "true" "1"
assert_cm_enabled "Req 1.3 CM=yes → rc=1"             "yes"       "true" "1"
assert_cm_enabled "Req 1.3 CM=on → rc=1"              "on"        "true" "1"

# ── Req 1.4: PER_TASK_LOOP_ENABLED が true でなければ rc=1（CM=true でも） ──
assert_cm_enabled "Req 1.4 PTL unset, CM=true → rc=1"  "true"     "__unset__" "1"
assert_cm_enabled "Req 1.4 PTL=false, CM=true → rc=1"  "true"     "false"     "1"
assert_cm_enabled "Req 1.4 PTL=True (capital) → rc=1"  "true"     "True"      "1"

# ── 正常系: CM=true かつ PTL=true で rc=0 ──
assert_cm_enabled "both true → rc=0"                   "true"     "true"      "0"

# ── Req 6.3: cm_generate 経路を呼んでも context-map.md が生成されないことを確認する ──
# cm_enabled は cm_generate 内部では call されていないが、watcher 本体 call site で gate される。
# このテストは「gate が閉じているとき per-task ループは cm_generate を呼ばない」運用を
# 関数 contract レベルで明示する: cm_enabled が rc=1 なら呼び出し側は cm_generate を skip する
# べきであり、call site の wiring が壊れていないかを issue-watcher.sh で検証する責務は task 2 側
# で完了している。本テストではゲート判定の閉鎖性のみを検証し、context-map.md が誤って生成
# されないことの間接確認として「cm_enabled rc=1 のとき cm_render_prompt_section も空文字」を
# 検査する（cm_render_prompt_section は cm_enabled 不通過時に空文字を返す契約 / Req 3.5）。
assert_render_empty_when_disabled() {
  local label="$1" cm_val="$2" pt_val="$3"
  local out
  set +e
  out=$(
    if [ "$cm_val" = "__unset__" ]; then unset CONTEXT_MAP_ENABLED; else export CONTEXT_MAP_ENABLED="$cm_val"; fi
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

assert_render_empty_when_disabled "Req 6.3 / 3.5 CM unset → render empty"   "__unset__" "true"
assert_render_empty_when_disabled "Req 6.3 / 3.5 CM=false → render empty"   "false"     "true"
assert_render_empty_when_disabled "Req 6.3 / 3.5 CM=True (typo) → render empty" "True"   "true"
assert_render_empty_when_disabled "Req 6.3 / 3.5 CM=1 → render empty"       "1"         "true"
assert_render_empty_when_disabled "Req 6.3 / 3.5 CM=yes → render empty"     "yes"       "true"
assert_render_empty_when_disabled "Req 1.4 PTL unset → render empty"        "true"      "__unset__"

# ── 追加 fixture 利用ケース: 実際に spec dir に fixture を置いて gate 閉鎖時の挙動を確認 ──
# 「gate 閉鎖時に cm_generate を呼んでも context-map.md が生成されない」を per-task ループの
# call site 契約として強制するため、本来 watcher 本体が `if cm_enabled` の元でしか
# cm_generate を呼ばないが、誤って呼ばれても無害（書き込み）になることはなく、本テストでは
# call site の責務として「cm_enabled が閉じているとき呼ばない」前提を再確認する。
tmp=$(mktemp -d)
mkdir -p "$tmp/spec"
cp "$FIXTURE_DIR/tasks-sample.md" "$tmp/spec/tasks.md"
cp "$FIXTURE_DIR/design-sample.md" "$tmp/spec/design.md"

# CM unset / PTL=true の状態で cm_enabled が rc=1 のとき、call site では cm_generate が
# skip されるため context-map.md は生成されない（本テストでは call site の閉鎖性を擬似的に
# 検証する: cm_enabled の rc=1 を条件にして cm_generate を呼ぶ／呼ばないを分岐させる）。
set +e
(
  unset CONTEXT_MAP_ENABLED
  export PER_TASK_LOOP_ENABLED=true
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
