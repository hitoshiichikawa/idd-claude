#!/usr/bin/env bash
# 用途: stage-a-verify 構造化 verify ブロック抽出 (#224) の fixture 回帰検証。
#       stage_a_verify_extract_verify_block の well-formed/malformed 判定と、
#       stage_a_verify_resolve_command の 4 段 fallback 連鎖（source 確定含む）を assert する。
# 配置先: docs/specs/224-feat-watcher-stage-a-verify-verify-archi/test-fixtures/test-extract.sh
# 依存: bash 4+, awk（POSIX ERE）。stage-a-verify.sh を source して関数を直接呼ぶ。
# セットアップ参照先: docs/specs/224-feat-watcher-stage-a-verify-verify-archi/impl-notes.md
#
# Usage:
#   bash docs/specs/224-feat-watcher-stage-a-verify-verify-archi/test-fixtures/test-extract.sh
#
# Exit code:
#   0 = すべての fixture が期待抽出コマンド / 期待 return code / 期待 source と一致
#   1 = いずれかの fixture が不一致（standard error にどれが失敗したか出力）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FIXTURE_DIR="$SCRIPT_DIR"
# repo root はこの fixture dir から 4 階層上（test-fixtures/<spec>/specs/docs/<root>）。
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
MODULE="$REPO_ROOT/local-watcher/bin/modules/stage-a-verify.sh"

if [ ! -f "$MODULE" ]; then
  echo "[FATAL] module not found: $MODULE" >&2
  exit 1
fi

# sav_log 等が参照するグローバルの最小定義。STAGE_A_VERIFY_COMMAND は各ケースで明示制御する。
export REPO="owner/test-224"

# shellcheck source=/dev/null
source "$MODULE"

fail_count=0
pass_count=0

# 一時 spec dir を作り、fixture を tasks.md として配置して関数を呼ぶ設計（REPO_DIR /
# SPEC_DIR_REL を fixture ごとに一時ディレクトリへ向ける）。各 assert ヘルパが個別に行う。

# ── ヘルパ: extract_verify_block の期待 rc と期待 stdout を検証 ──
assert_block() {
  # $1 = fixture, $2 = expected_rc, $3 = expected_stdout（rc=0 時のみ、改行は \n で表現）
  local fixture="$1" expected_rc="$2" expected_out="${3:-}"
  local tmp out rc
  tmp=$(mktemp -d)
  mkdir -p "$tmp/spec"
  cp "$FIXTURE_DIR/$fixture" "$tmp/spec/tasks.md"
  set +e
  out=$(REPO_DIR="$tmp" SPEC_DIR_REL="spec" stage_a_verify_extract_verify_block)
  rc=$?
  set -e
  rm -rf "$tmp"

  if [ "$rc" != "$expected_rc" ]; then
    echo "[FAIL] $fixture: extract rc=$rc (expected $expected_rc)" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  if [ "$expected_rc" = "0" ]; then
    local expected_decoded
    expected_decoded=$(printf '%b' "$expected_out")
    if [ "$out" != "$expected_decoded" ]; then
      echo "[FAIL] $fixture: extract stdout mismatch" >&2
      echo "  expected: [$expected_decoded]" >&2
      echo "  actual:   [$out]" >&2
      fail_count=$((fail_count + 1))
      return
    fi
  fi
  echo "[OK]   $fixture: extract rc=$rc"
  pass_count=$((pass_count + 1))
}

# ── ヘルパ: resolve_command の期待 source と期待 stdout を検証 ──
assert_resolve() {
  # $1 = fixture, $2 = env_command（空文字なら unset 扱い）, $3 = expected_rc,
  # $4 = expected_source（rc=0 時）, $5 = expected_stdout（rc=0 時、改行は \n）
  local fixture="$1" env_cmd="$2" expected_rc="$3" expected_source="${4:-}" expected_out="${5:-}"
  local tmp out rc src
  tmp=$(mktemp -d)
  mkdir -p "$tmp/spec"
  cp "$FIXTURE_DIR/$fixture" "$tmp/spec/tasks.md"
  # env_cmd が空文字のケースでは、実行環境に STAGE_A_VERIFY_COMMAND が漏れていても
  # 確実に「env 空」を再現するため、サブシェル内で明示 unset して呼ぶ（外部環境非依存）。
  set +e
  if [ -n "$env_cmd" ]; then
    out=$(REPO_DIR="$tmp" SPEC_DIR_REL="spec" STAGE_A_VERIFY_COMMAND="$env_cmd" stage_a_verify_resolve_command 2>/dev/null)
    rc=$?
  else
    out=$(unset STAGE_A_VERIFY_COMMAND; REPO_DIR="$tmp" SPEC_DIR_REL="spec" stage_a_verify_resolve_command 2>/dev/null)
    rc=$?
  fi
  src=$(REPO_DIR="$tmp" SPEC_DIR_REL="spec" _sav_read_resolved_source)
  set -e
  rm -rf "$tmp"

  if [ "$rc" != "$expected_rc" ]; then
    echo "[FAIL] resolve($fixture, env='$env_cmd'): rc=$rc (expected $expected_rc)" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  if [ "$expected_rc" = "0" ]; then
    if [ "$src" != "$expected_source" ]; then
      echo "[FAIL] resolve($fixture, env='$env_cmd'): source=$src (expected $expected_source)" >&2
      fail_count=$((fail_count + 1))
      return
    fi
    local expected_decoded
    expected_decoded=$(printf '%b' "$expected_out")
    if [ "$out" != "$expected_decoded" ]; then
      echo "[FAIL] resolve($fixture, env='$env_cmd'): stdout mismatch" >&2
      echo "  expected: [$expected_decoded]" >&2
      echo "  actual:   [$out]" >&2
      fail_count=$((fail_count + 1))
      return
    fi
  fi
  echo "[OK]   resolve($fixture, env='$env_cmd'): rc=$rc source=${src:-none}"
  pass_count=$((pass_count + 1))
}

echo "=== extract_verify_block: well-formed 群 ==="
assert_block "block-well-formed.md"  0 "shellcheck local-watcher/bin/modules/*.sh"
assert_block "block-multiline.md"    0 "shellcheck install.sh setup.sh &&\n  actionlint .github/workflows/*.yml"
assert_block "block-with-lang-tag.md" 0 "npm test"
assert_block "block-multiple.md"     0 "echo first-block"

echo
echo "=== extract_verify_block: malformed 群（return 1, stdout 空） ==="
assert_block "block-no-fence.md"       1
assert_block "block-unclosed-fence.md" 1
assert_block "block-empty.md"          1
assert_block "no-block-heuristic.md"   1   # センチネル無し → ブロック無扱い

echo
echo "=== resolve_command: 4 段 fallback 連鎖 ==="
# 第 1 段: 構造化ブロックあり → env があっても structured-block 優先
assert_resolve "block-well-formed.md" "env-should-be-ignored" 0 "structured-block" "shellcheck local-watcher/bin/modules/*.sh"
# 第 2 段: ブロック無し + env 非空 → env-command
assert_resolve "no-block-heuristic.md" "my-env-cmd" 0 "env-command" "my-env-cmd"
# 第 3 段: ブロック無し + env 空 + heuristic ヒット（#160 散文 + backtick 回帰）→ heuristic
assert_resolve "no-block-heuristic.md" "" 0 "heuristic" "shellcheck local-watcher/bin/issue-watcher.sh"
# malformed ブロック + env 空 → heuristic に後退。block-no-fence はセンチネル直後の散文行
# `shellcheck local-watcher/bin/modules/*.sh` が heuristic の行頭 keyword 一致で拾われるため、
# resolve は heuristic 採用となる（malformed ブロックが env/heuristic への後退を妨げない実証）。
assert_resolve "block-no-fence.md" "" 0 "heuristic" "shellcheck local-watcher/bin/modules/*.sh"
# malformed ブロック + env 設定 → env に後退
assert_resolve "block-unclosed-fence.md" "fallback-env" 0 "env-command" "fallback-env"
# 構造化ブロックも env も heuristic 該当行も無い → SKIPPED (rc 1)
assert_resolve "block-empty.md" "" 1

echo
if [ "$fail_count" -gt 0 ]; then
  echo "$fail_count case(s) failed (passed: $pass_count)." >&2
  exit 1
fi
echo "All $pass_count cases passed."
