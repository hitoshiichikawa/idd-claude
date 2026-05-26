#!/usr/bin/env bash
# 用途: stage-a-verify (#125) の round counter が worktree reset で消えない場所に永続化され、
#       Issue 番号 + branch で一意化されることを回帰検証する (#246)。
#       本 Issue の core 回帰は「verify が連続失敗しても round が毎回 1 にリセットされ
#       round=2（escalate）へ到達しない無限 round=1 ループ」であり、これを
#       「bump → worktree dir 削除（worktree reset 相当）→ bump → read が 2 を返す」で検証する。
# 配置先: docs/specs/246-bug-watcher-stage-a-verify-round-counter/test-fixtures/test-round-counter-persistence.sh
# 依存: bash 4+。stage-a-verify.sh を source して round counter 関数を直接呼ぶ（単体起動扱い）。
# セットアップ参照先: docs/specs/246-bug-watcher-stage-a-verify-round-counter/impl-notes.md
#
# Usage:
#   bash docs/specs/246-bug-watcher-stage-a-verify-round-counter/test-fixtures/test-round-counter-persistence.sh
#
# Exit code:
#   0 = すべてのケースが期待どおり
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

# sav_log / sav_error 等が参照するグローバルの最小定義。
export REPO="owner/test-246"
export REPO_SLUG="owner-test-246"

# shellcheck source=/dev/null
source "$MODULE"

fail_count=0
pass_count=0

assert_eq() {
  # $1 = ケース名, $2 = 実測値, $3 = 期待値
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "[PASS] $name (=$actual)"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] $name: actual=[$actual] expected=[$expected]" >&2
    fail_count=$((fail_count + 1))
  fi
}

# テスト用の隔離環境を作る。STATE_DIR（永続化先）と WORKTREE（reset で消える領域）を
# 別ディレクトリに置くことで、worktree reset を WORKTREE の rm -rf で模擬できる。
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE_DIR="$TMP_ROOT/state"        # worktree 外の永続化先（reset で消えない想定）
WORKTREE="$TMP_ROOT/worktree"      # worktree（毎サイクル git clean -fdx で消える）
mkdir -p "$WORKTREE/docs/specs/246-bug-watcher-stage-a-verify-round-counter"

export STAGE_A_VERIFY_STATE_DIR="$STATE_DIR"
export NUMBER=246
export BRANCH="claude/issue-246-impl-bug-watcher-stage-a-verify-round-counter"
export SLUG="bug-watcher-stage-a-verify-round-counter"
export REPO_DIR="$WORKTREE"
export SPEC_DIR_REL="docs/specs/246-bug-watcher-stage-a-verify-round-counter"

# ── ケース 0: round_path が worktree 外を指すこと（本 Issue の修正の中心 / Req 2.1）──
ROUND_PATH=$(stage_a_verify_round_path)
case "$ROUND_PATH" in
  "$STATE_DIR"/*)
    echo "[PASS] round_path が STATE_DIR（worktree 外）配下を指す (=$ROUND_PATH)"
    pass_count=$((pass_count + 1))
    ;;
  *)
    echo "[FAIL] round_path が STATE_DIR 配下を指していない (=$ROUND_PATH)" >&2
    fail_count=$((fail_count + 1))
    ;;
esac
case "$ROUND_PATH" in
  "$WORKTREE"/*)
    echo "[FAIL] round_path が WORKTREE（reset で消える領域）配下を指している (=$ROUND_PATH)" >&2
    fail_count=$((fail_count + 1))
    ;;
  *)
    echo "[PASS] round_path は WORKTREE 配下を指さない（reset で消えない）"
    pass_count=$((pass_count + 1))
    ;;
esac

# ── ケース 1: 初回 bump で round=1 / Req 1.2 ──
stage_a_verify_reset_round   # クリーンな状態から開始
assert_eq "初回 read（不在）→ round=0（NFR 1.4）" "$(stage_a_verify_read_round)" "0"
stage_a_verify_bump_round
assert_eq "初回 bump → round=1（Req 1.2）" "$(stage_a_verify_read_round)" "1"

# ── ケース 2: worktree reset を挟んでも round が単調増加（core 回帰 / Req 1.1, 1.4, 2.2）──
# worktree reset 相当: worktree 配下を丸ごと削除して再作成する（git clean -fdx の模擬）。
rm -rf "$WORKTREE"
mkdir -p "$WORKTREE/docs/specs/246-bug-watcher-stage-a-verify-round-counter"
# reset 後も counter が生存し、前回値（1）を読めること。
assert_eq "worktree reset 後 read → round=1（リセットされない / Req 2.2）" \
  "$(stage_a_verify_read_round)" "1"
# 連続失敗 2 回目の bump → round=2（escalate 到達 / Req 1.1）。
stage_a_verify_bump_round
assert_eq "worktree reset 後 bump → round=2（単調増加 / Req 1.1, 1.4）" \
  "$(stage_a_verify_read_round)" "2"

# ── ケース 3: Issue / slot 一意化（異なる NUMBER / 異なる BRANCH で path が異なる / Req 3.1）──
PATH_A=$(stage_a_verify_round_path)
PATH_DIFF_NUMBER=$(NUMBER=999 stage_a_verify_round_path)
PATH_DIFF_BRANCH=$(BRANCH="claude/issue-246-impl-other-slug" stage_a_verify_round_path)
if [ "$PATH_A" != "$PATH_DIFF_NUMBER" ]; then
  echo "[PASS] 異なる NUMBER で round_path が異なる（衝突しない / Req 3.1）"
  pass_count=$((pass_count + 1))
else
  echo "[FAIL] 異なる NUMBER でも round_path が同一（衝突 / Req 3.1）: $PATH_A" >&2
  fail_count=$((fail_count + 1))
fi
if [ "$PATH_A" != "$PATH_DIFF_BRANCH" ]; then
  echo "[PASS] 異なる BRANCH で round_path が異なる（衝突しない / Req 3.1）"
  pass_count=$((pass_count + 1))
else
  echo "[FAIL] 異なる BRANCH でも round_path が同一（衝突 / Req 3.1）: $PATH_A" >&2
  fail_count=$((fail_count + 1))
fi

# ── ケース 3b: 複数 repo（REPO_SLUG）で path が異なる（slot/repo 跨ぎで共有しない / Req 3.3）──
# REPO_SLUG はデフォルトの state base（$HOME/.issue-watcher/state/$REPO_SLUG）に含まれる。
# 本ケースは env override（STAGE_A_VERIFY_STATE_DIR）を **使わず** デフォルト経路で検証する
# 必要があるため、HOME を tmp へ差し替え STAGE_A_VERIFY_STATE_DIR を unset して比較する。
PATH_REPO_A=$(unset STAGE_A_VERIFY_STATE_DIR; HOME="$TMP_ROOT/home" REPO_SLUG="owner-repo-a" stage_a_verify_round_path)
PATH_REPO_B=$(unset STAGE_A_VERIFY_STATE_DIR; HOME="$TMP_ROOT/home" REPO_SLUG="owner-repo-b" stage_a_verify_round_path)
if [ "$PATH_REPO_A" != "$PATH_REPO_B" ]; then
  echo "[PASS] 異なる REPO_SLUG で round_path が異なる（repo 跨ぎ非共有 / Req 3.3）"
  pass_count=$((pass_count + 1))
else
  echo "[FAIL] 異なる REPO_SLUG でも round_path が同一（Req 3.3 違反）: $PATH_REPO_A" >&2
  fail_count=$((fail_count + 1))
fi
# デフォルト state base が worktree 外（$HOME/.issue-watcher/ 配下）を指すこと（Req 2.1）。
case "$PATH_REPO_A" in
  "$TMP_ROOT/home/.issue-watcher/"*)
    echo "[PASS] デフォルト state base が \$HOME/.issue-watcher/ 配下（worktree 外 / Req 2.1）"
    pass_count=$((pass_count + 1))
    ;;
  *)
    echo "[FAIL] デフォルト state base が \$HOME/.issue-watcher/ 配下でない: $PATH_REPO_A" >&2
    fail_count=$((fail_count + 1))
    ;;
esac

# ── ケース 3c: BRANCH のスラッシュがファイル名に使えるようサニタイズされる ──
case "$(basename "$PATH_A")" in
  */*)
    echo "[FAIL] round_path の basename に '/' が残っている: $(basename "$PATH_A")" >&2
    fail_count=$((fail_count + 1))
    ;;
  *)
    echo "[PASS] BRANCH のスラッシュがサニタイズされ basename に '/' を含まない"
    pass_count=$((pass_count + 1))
    ;;
esac

# ── ケース 4: reset の冪等性（不在に対しても no-op / Req 4.3, NFR 2.2）──
stage_a_verify_reset_round
assert_eq "reset 後 read → round=0（Req 4.1/4.2）" "$(stage_a_verify_read_round)" "0"
# 不在に対する 2 回目 reset でもエラーにならず冪等（set -e 下で実行できれば pass）。
stage_a_verify_reset_round
assert_eq "不在に対する 2 回目 reset 後 read → round=0（冪等 / Req 4.3, NFR 2.2）" \
  "$(stage_a_verify_read_round)" "0"

# ── ケース 5: 書き込み失敗時の安全側（bump return 1 / read は 0 のまま / Req 2.3）──
# STATE_DIR を書き込み不能なパス（既存ファイルを親に持つ）へ向けて bump を失敗させる。
NOWRITE_BASE="$TMP_ROOT/nowrite-file"
: > "$NOWRITE_BASE"   # ファイルを作る → これを base dir に使うと mkdir/書き込みが失敗する
set +e
( STAGE_A_VERIFY_STATE_DIR="$NOWRITE_BASE" stage_a_verify_bump_round ) 2>/dev/null
bump_rc=$?
set -e
assert_eq "書き込み不能時の bump → return 1（安全側 / Req 2.3）" "$bump_rc" "1"
read_after_fail=$(STAGE_A_VERIFY_STATE_DIR="$NOWRITE_BASE" stage_a_verify_read_round)
assert_eq "書き込み失敗後 read → round=0 のまま（差し戻し挙動へ倒れる / Req 2.3）" \
  "$read_after_fail" "0"

echo "----"
echo "PASS=$pass_count FAIL=$fail_count"
[ "$fail_count" -eq 0 ]
