#!/usr/bin/env bash
# 用途: design-less impl（tasks.md 不在）における stage-a-verify gate の SKIP 挙動 (#230) を
#       回帰検証する。tasks.md を持たない spec dir に対し stage_a_verify_resolve_command が
#       SKIP 経路（return 1）に倒れること、env 残値の影響を受けず常に SKIP すること、
#       SKIP 判定で tasks.md / spec dir を書き換えないことを assert する。
# 配置先: docs/specs/230-feat-watcher-stage-a-verify-design-less/test-fixtures/test-design-less-skip.sh
# 依存: bash 4+, awk。stage-a-verify.sh を source して関数を直接呼ぶ（単体起動扱い）。
# セットアップ参照先: docs/specs/230-feat-watcher-stage-a-verify-design-less/impl-notes.md
#
# Usage:
#   bash docs/specs/230-feat-watcher-stage-a-verify-design-less/test-fixtures/test-design-less-skip.sh
#
# Exit code:
#   0 = すべてのケースが期待どおり SKIP（resolve return 1）かつ副作用なし
#   1 = いずれかのケースが不一致（standard error にどれが失敗したか出力）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# repo root はこの fixture dir から 4 階層上（test-fixtures/<spec>/specs/docs/<root>）。
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
MODULE="$REPO_ROOT/local-watcher/bin/modules/stage-a-verify.sh"

if [ ! -f "$MODULE" ]; then
  echo "[FATAL] module not found: $MODULE" >&2
  exit 1
fi

# sav_log 等が参照するグローバルの最小定義。
export REPO="owner/test-230"

# shellcheck source=/dev/null
source "$MODULE"

fail_count=0
pass_count=0

# ── ヘルパ: tasks.md 不在の spec dir で resolve が SKIP（return 1）になることを検証 ──
# $1 = ケース名, $2 = STAGE_A_VERIFY_COMMAND の値（空文字なら未設定相当）
assert_design_less_skip() {
  local name="$1" env_cmd="$2"
  local tmp rc out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/spec"   # spec dir は作るが tasks.md は **置かない**（design-less impl 相当）

  # 注意: 実行環境（cron / launchd の escape hatch、#230 で整理対象の暫定設定）が
  # STAGE_A_VERIFY_COMMAND を export していることがあるため、env 未設定ケースでは
  # 明示的に unset した上で呼ぶ。これがないと継承値で env-command 経路が採用され、
  # design-less SKIP（return 1）の検証が偽陽性になる。
  set +e
  if [ -n "$env_cmd" ]; then
    out=$(STAGE_A_VERIFY_COMMAND="$env_cmd" REPO_DIR="$tmp" SPEC_DIR_REL="spec" \
      stage_a_verify_resolve_command 2>/dev/null)
    rc=$?
  else
    out=$(unset STAGE_A_VERIFY_COMMAND; REPO_DIR="$tmp" SPEC_DIR_REL="spec" \
      stage_a_verify_resolve_command 2>/dev/null)
    rc=$?
  fi
  set -e

  # env_cmd が非空のケースは「repo-default として env を残す運用」（Req 4.5）であり SKIP しない
  # （env-command が採用され return 0）。env_cmd 空のケースのみ design-less SKIP（return 1）が期待値。
  local expected_rc
  if [ -n "$env_cmd" ]; then
    expected_rc=0
  else
    expected_rc=1
  fi

  # tasks.md を書き換えない / 生成しないこと（Req 1.4）を確認する。
  local tasks_created=0
  [ -e "$tmp/spec/tasks.md" ] && tasks_created=1

  rm -rf "$tmp"

  if [ "$rc" != "$expected_rc" ]; then
    echo "[FAIL] $name: resolve rc=$rc (expected $expected_rc) out=[$out]" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  if [ "$tasks_created" != "0" ]; then
    echo "[FAIL] $name: tasks.md が SKIP 判定で生成/書き換えられた（Req 1.4 違反）" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  echo "[PASS] $name (rc=$rc)"
  pass_count=$((pass_count + 1))
}

# ── ヘルパ: stage_a_verify_run が tasks.md 不在で SKIPPED ログを出し return 0 になることを検証 ──
# Req 1.1 / 1.2（SKIPPED ログ書式）/ 1.3（round counter 不変・失敗扱いにしない）。
assert_run_skipped() {
  local name="$1"
  local tmp rc log_out round_before round_after
  tmp=$(mktemp -d)
  mkdir -p "$tmp/spec"

  round_before="(none)"
  [ -f "$tmp/spec/.stage-a-verify-round" ] && round_before=$(cat "$tmp/spec/.stage-a-verify-round")

  # env escape hatch を unset して design-less（tasks.md 不在 + env 無）の純粋 SKIP を検証する。
  set +e
  log_out=$(unset STAGE_A_VERIFY_COMMAND; \
    STAGE_A_VERIFY_ENABLED=true REPO_DIR="$tmp" SPEC_DIR_REL="spec" NUMBER=230 LOG=/dev/null \
    stage_a_verify_run 2>&1)
  rc=$?
  set -e

  round_after="(none)"
  [ -f "$tmp/spec/.stage-a-verify-round" ] && round_after=$(cat "$tmp/spec/.stage-a-verify-round")

  rm -rf "$tmp"

  if [ "$rc" != "0" ]; then
    echo "[FAIL] $name: run rc=$rc (expected 0)" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  if ! printf '%s\n' "$log_out" | grep -q 'stage-a-verify: SKIPPED reason=no-verify-task-in-tasks-md'; then
    echo "[FAIL] $name: SKIPPED ログ書式が出力されていない (NFR 4.1 / Req 1.2)" >&2
    echo "  log: [$log_out]" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  if [ "$round_before" != "$round_after" ]; then
    echo "[FAIL] $name: round counter が変化した before=$round_before after=$round_after (Req 1.3 違反)" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  echo "[PASS] $name (rc=$rc, SKIPPED ログ出力 + round 不変)"
  pass_count=$((pass_count + 1))
}

# ── ケース 1: tasks.md 不在 + env 未設定 → SKIP（return 1）/ Req 1.1 ──
assert_design_less_skip "design-less + env未設定 → SKIP" ""

# ── ケース 2: tasks.md 不在 + env 未設定（再実行で同一結果）/ NFR 4.1 冪等性 ──
assert_design_less_skip "design-less + env未設定（冪等 2 回目）" ""

# ── ケース 3: tasks.md 不在 + env=repo-default → SKIP せず env 採用（Req 4.5）──
assert_design_less_skip "design-less + env=repo-default → env採用" "make test"

# ── ケース 4: stage_a_verify_run 統合: tasks.md 不在 → SKIPPED ログ + round 不変（Req 1.1/1.2/1.3）──
assert_run_skipped "design-less run → SKIPPED ログ + round 不変"

echo "----"
echo "PASS=$pass_count FAIL=$fail_count"
[ "$fail_count" -eq 0 ]
