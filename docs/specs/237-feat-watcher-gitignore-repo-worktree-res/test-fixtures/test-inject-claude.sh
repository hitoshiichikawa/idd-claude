#!/usr/bin/env bash
# test-inject-claude.sh — _worktree_inject_claude のロジック隔離スモークテスト（Issue #237）
#
# 用途:
#   core_utils.sh の _worktree_inject_claude を単体 source して、要件 R1〜R4 の
#   観測可能な振る舞いを検証する。watcher 本体の起動は行わず、関数ロジックのみを
#   隔離して回帰確認する。
#
# 配置先:
#   docs/specs/237-feat-watcher-gitignore-repo-worktree-res/test-fixtures/
#
# 依存:
#   - bash 4+ / cp / mktemp / git（core_utils.sh source 時の他関数定義ロード用）
#   - core_utils.sh の前方参照 slot_log / slot_warn は本スクリプトで stub 定義する
#
# 実行:
#   bash docs/specs/237-feat-watcher-gitignore-repo-worktree-res/test-fixtures/test-inject-claude.sh
#   全ケース pass で exit 0 / いずれか失敗で非ゼロ exit。

set -euo pipefail

# ── テスト対象モジュールの解決 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE="$REPO_ROOT/local-watcher/bin/modules/core_utils.sh"

if [ ! -f "$MODULE" ]; then
  echo "FATAL: モジュールが見つかりません: $MODULE" >&2
  exit 1
fi

# ── 前方参照スタブ（core_utils.sh が呼び出し時に解決する関数群）──
# 注入実行 / warn のログを変数に捕捉し、後段の検証で参照できるようにする。
LAST_LOG=""
LAST_WARN=""
# これらの stub は core_utils.sh から間接的に呼ばれる（source 経由の前方参照解決）。
# 静的解析は直接呼び出しを検出できず unreachable と誤判定するため SC2317 を抑制する。
# shellcheck disable=SC2317
slot_log() { LAST_LOG="$*"; }
# shellcheck disable=SC2317
slot_warn() { LAST_WARN="$*"; }
# core_utils.sh は本体から source される前提のため、source 時に他関数の定義のみを
# ロードする（即時実行コードは無いので副作用なし）。
# shellcheck disable=SC1090
source "$MODULE"

# ── テストハーネス ──
PASS=0
FAIL=0
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
ok() { echo "  ok: $*"; PASS=$((PASS + 1)); }

# 各ケースで使う一時領域を作る。SRC=注入元 REPO_DIR / WT=注入先 worktree。
make_tmp() {
  local base
  base="$(mktemp -d -t inject-claude-XXXXXX)"
  echo "$base"
}

# 注入元の `.claude/` を agents / rules 込みで作る。
seed_src_claude() {
  local src="$1"
  mkdir -p "$src/.claude/agents" "$src/.claude/rules"
  echo "developer agent def" >"$src/.claude/agents/developer.md"
  echo "ears rule" >"$src/.claude/rules/ears-format.md"
}

# ── Case (a): worktree に `.claude/` 無し + REPO_DIR に `.claude/` 有り → 注入される（R1.1, R1.2, R1.4）──
echo "Case (a): inject when worktree lacks .claude and REPO_DIR has it"
{
  TMP="$(make_tmp)"
  SRC="$TMP/repo"
  WT="$TMP/wt"
  mkdir -p "$SRC" "$WT"
  seed_src_claude "$SRC"
  LAST_LOG=""; LAST_WARN=""
  _worktree_inject_claude "$SRC" "$WT"
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "(a) 戻り値が 0 でない: $rc"; else ok "(a) 戻り値 0"; fi
  if [ -f "$WT/.claude/agents/developer.md" ] && [ -f "$WT/.claude/rules/ears-format.md" ]; then
    ok "(a) .claude/agents .claude/rules が worktree に現れた"
  else
    fail "(a) .claude/agents または .claude/rules が注入されていない"
  fi
  if [ -n "$LAST_LOG" ]; then ok "(a) 注入ログが出力された: $LAST_LOG"; else fail "(a) 注入ログが出力されていない"; fi
  rm -rf "$TMP"
}

# ── Case (b): worktree に `.claude/` 既存（tracked 運用相当）→ 上書きされない（NO-OP / R2.1）──
echo "Case (b): NO-OP when worktree already has .claude (tracked repo)"
{
  TMP="$(make_tmp)"
  SRC="$TMP/repo"
  WT="$TMP/wt"
  mkdir -p "$SRC" "$WT/.claude/agents"
  seed_src_claude "$SRC"
  # worktree 側 .claude に「tracked 運用の既存内容」を置く（注入元と区別できる印）。
  echo "TRACKED-ORIGINAL" >"$WT/.claude/agents/developer.md"
  LAST_LOG=""; LAST_WARN=""
  _worktree_inject_claude "$SRC" "$WT"
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "(b) 戻り値が 0 でない: $rc"; else ok "(b) 戻り値 0"; fi
  content="$(cat "$WT/.claude/agents/developer.md")"
  if [ "$content" = "TRACKED-ORIGINAL" ]; then
    ok "(b) 既存 .claude が上書きされていない（NO-OP）"
  else
    fail "(b) 既存 .claude が上書きされた: $content"
  fi
  # rules は注入元にしか無い → NO-OP なので worktree に現れないはず
  if [ ! -e "$WT/.claude/rules" ]; then
    ok "(b) 注入元の rules が混入していない（完全 NO-OP）"
  else
    fail "(b) NO-OP のはずが rules が混入した"
  fi
  if [ -z "$LAST_LOG" ]; then ok "(b) 注入ログが出ていない（NO-OP）"; else fail "(b) NO-OP のはずがログが出た: $LAST_LOG"; fi
  rm -rf "$TMP"
}

# ── Case (c): REPO_DIR に `.claude/` 無し → NO-OP（R2.2）──
echo "Case (c): NO-OP when REPO_DIR has no .claude"
{
  TMP="$(make_tmp)"
  SRC="$TMP/repo"
  WT="$TMP/wt"
  mkdir -p "$SRC" "$WT"
  # SRC に .claude を作らない
  LAST_LOG=""; LAST_WARN=""
  _worktree_inject_claude "$SRC" "$WT"
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "(c) 戻り値が 0 でない: $rc"; else ok "(c) 戻り値 0（fail-open）"; fi
  if [ ! -e "$WT/.claude" ]; then ok "(c) worktree に .claude が作られていない（NO-OP）"; else fail "(c) NO-OP のはずが .claude が作られた"; fi
  if [ -z "$LAST_WARN" ]; then ok "(c) warn が出ていない（正常な NO-OP）"; else fail "(c) NO-OP のはずが warn が出た: $LAST_WARN"; fi
  rm -rf "$TMP"
}

# ── Case (d): symlink / 実行権限が保持される（R4 / cp -a）──
echo "Case (d): symlink and exec bit preserved (cp -a)"
{
  TMP="$(make_tmp)"
  SRC="$TMP/repo"
  WT="$TMP/wt"
  mkdir -p "$SRC/.claude/agents" "$WT"
  echo "exec script" >"$SRC/.claude/agents/hook.sh"
  chmod +x "$SRC/.claude/agents/hook.sh"
  # symlink を作る（相対リンク）
  ln -s "agents/hook.sh" "$SRC/.claude/link-to-hook"
  LAST_LOG=""; LAST_WARN=""
  _worktree_inject_claude "$SRC" "$WT"
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "(d) 戻り値が 0 でない: $rc"; else ok "(d) 戻り値 0"; fi
  if [ -x "$WT/.claude/agents/hook.sh" ]; then ok "(d) 実行権限が保持された"; else fail "(d) 実行権限が失われた"; fi
  if [ -L "$WT/.claude/link-to-hook" ]; then ok "(d) symlink が symlink のまま保持された"; else fail "(d) symlink が実体化された / 失われた"; fi
  rm -rf "$TMP"
}

# ── Case (e): 冪等性（R4.1）— 2 回実行しても結果が同じ ──
echo "Case (e): idempotent across repeated runs"
{
  TMP="$(make_tmp)"
  SRC="$TMP/repo"
  WT="$TMP/wt"
  mkdir -p "$SRC" "$WT"
  seed_src_claude "$SRC"
  _worktree_inject_claude "$SRC" "$WT"  # 1 回目: 注入
  first="$(cat "$WT/.claude/agents/developer.md")"
  # 1 回目で worktree に .claude が出来たので 2 回目は auto-detect で NO-OP のはず
  echo "MUTATED-AFTER-FIRST" >"$WT/.claude/agents/developer.md"
  LAST_LOG=""
  _worktree_inject_claude "$SRC" "$WT"  # 2 回目: NO-OP（上書きしない）
  second="$(cat "$WT/.claude/agents/developer.md")"
  if [ "$first" = "developer agent def" ] && [ "$second" = "MUTATED-AFTER-FIRST" ]; then
    ok "(e) 2 回目は NO-OP（worktree 既存 .claude を上書きしない = 冪等）"
  else
    fail "(e) 冪等性が崩れた first=$first second=$second"
  fi
  rm -rf "$TMP"
}

# ── 集計 ──
echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "ALL CASES PASSED"
exit 0
