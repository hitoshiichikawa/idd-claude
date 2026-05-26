#!/usr/bin/env bash
# test-scaffolding-health.sh — scaffolding-health.sh の境界スモークテスト (#238 task 5)
#
# 用途:
#   `local-watcher/bin/modules/scaffolding-health.sh` の検査純関数 sh_inspect_scaffolding /
#   preflight gate sh_preflight_gate / HALT 値正規化を、一時 worktree fixture（full / missing /
#   empty / indeterminate）に対して単体実行し、期待戻り値・ログ出力・read-only を検証する。
#   gh は呼ばせないよう stub で差し替える（可視シグナルの副作用を局所化）。
#
# 実行:
#   bash docs/specs/238-feat-watcher-scaffolding-health-gate-wor/test-fixtures/test-scaffolding-health.sh
#
# 依存: bash 4+ / find / mktemp。gh は stub で差し替えるため不要。
#
# 対応 AC: Req 1.1 / 1.5 / 2.1 / 2.2 / 2.3 / 3.1 / 5.1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$SCRIPT_DIR/../../../../local-watcher/bin/modules/scaffolding-health.sh"

if [ ! -f "$MODULE" ]; then
  echo "ERROR: module が見つかりません: $MODULE" >&2
  exit 1
fi

# 本体側で宣言される前提のグローバル / set -e はテストでは個別判定するため宣言しない。
# REPO / NUMBER は source した scaffolding-health.sh の logger / 可視シグナルが遅延束縛で参照する
# （本テストファイル内では直接参照しないため SC2034 を局所抑止する）。
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
NUMBER="999"
# shellcheck source=/dev/null
. "$MODULE"

# gh stub: 可視シグナルが本物の gh を叩かないよう差し替える。
# `gh issue view ... --json comments` は空コメント（マーカー未存在）を返す。
# `gh issue comment ...` は呼ばれたことを sentinel ファイルに記録するだけで投稿しない。
# sh_preflight_gate は command substitution のサブシェルで呼ばれることがあり、シェル変数の
# インクリメントは親に伝播しないため、副作用の有無は sentinel ファイルで観測する。
GH_COMMENT_SENTINEL="$(mktemp)"
gh() {
  case "$1 $2" in
    "issue view")
      echo ""        # 既存コメントなし（重複抑止に当たらない）
      return 0
      ;;
    "issue comment")
      echo "called" >> "$GH_COMMENT_SENTINEL"
      return 0
      ;;
  esac
  return 0
}
gh_comment_count() { wc -l < "$GH_COMMENT_SENTINEL" | tr -d ' '; }
gh_comment_reset() { : > "$GH_COMMENT_SENTINEL"; }

PASS=0
FAIL=0
assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label (rc=$actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected rc=$expected, got rc=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$GH_COMMENT_SENTINEL"' EXIT

# ── fixture 構築 ──
# full: agents/rules 双方に非空ファイル
mkdir -p "$TMP/full/.claude/agents" "$TMP/full/.claude/rules"
echo "agent" > "$TMP/full/.claude/agents/a.md"
echo "rule"  > "$TMP/full/.claude/rules/r.md"

# missing-agents: agents 不在 / rules のみ非空
mkdir -p "$TMP/missing-agents/.claude/rules"
echo "rule" > "$TMP/missing-agents/.claude/rules/r.md"

# empty: 双方ディレクトリは在るが空（degraded delivery のサイン）
mkdir -p "$TMP/empty/.claude/agents" "$TMP/empty/.claude/rules"

# zero-byte: 双方 0 バイトファイルのみ（非空判定で missing 扱い）
mkdir -p "$TMP/zerobyte/.claude/agents" "$TMP/zerobyte/.claude/rules"
: > "$TMP/zerobyte/.claude/agents/a.md"
: > "$TMP/zerobyte/.claude/rules/r.md"

# indeterminate: .claude が通常ファイル（dir でない）= 真の I/O 異常
mkdir -p "$TMP/indeterminate"
echo "not a dir" > "$TMP/indeterminate/.claude"

echo "=== sh_inspect_scaffolding（Req 1.1 / 1.5 / 3.1 / 5.1）==="
sh_inspect_scaffolding "$TMP/full" >/dev/null; assert_rc "full → 0" 0 $?
sh_inspect_scaffolding "$TMP/missing-agents" >/dev/null; assert_rc "missing(agents 不在) → 1" 1 $?
sh_inspect_scaffolding "$TMP/empty" >/dev/null; assert_rc "empty(空 dir) → 1" 1 $?
sh_inspect_scaffolding "$TMP/zerobyte" >/dev/null; assert_rc "zero-byte のみ → 1" 1 $?
sh_inspect_scaffolding "$TMP/indeterminate" >/dev/null; assert_rc ".claude が非 dir → 2" 2 $?
sh_inspect_scaffolding "" >/dev/null; assert_rc "空パス → 2" 2 $?

# missing サマリの中身確認
summary="$(sh_inspect_scaffolding "$TMP/missing-agents")"
if [ "$summary" = "agents=missing rules=ok" ]; then
  echo "  PASS: missing サマリ = '$summary'"
  PASS=$((PASS + 1))
else
  echo "  FAIL: missing サマリ expected 'agents=missing rules=ok' got '$summary'"
  FAIL=$((FAIL + 1))
fi

echo "=== sh_preflight_gate full（Req 1.5 / 5.1 / NFR 1.1: NO-OP・WARN/コメント 0）==="
gh_comment_reset
out="$(SCAFFOLDING_HEALTH_HALT=off sh_preflight_gate "$TMP/full" 2>/tmp/sh_err_$$)"; rc=$?
err="$(cat /tmp/sh_err_$$; rm -f /tmp/sh_err_$$)"
assert_rc "full gate → 0(継続)" 0 "$rc"
if [ "$(gh_comment_count)" -eq 0 ] && [ -z "$err" ]; then
  echo "  PASS: full は WARN なし・コメントなし（NO-OP）"
  PASS=$((PASS + 1))
else
  echo "  FAIL: full で WARN/comment が発生（comment=$GH_COMMENT_CALLED err='$err'）"
  FAIL=$((FAIL + 1))
fi
case "$out" in
  *"outcome=pass"*) echo "  PASS: full は outcome=pass をログ"; PASS=$((PASS + 1));;
  *) echo "  FAIL: full の outcome=pass ログ欠落（out='$out'）"; FAIL=$((FAIL + 1));;
esac

echo "=== sh_preflight_gate missing + HALT 値正規化（Req 2.1 / 2.2 / 2.3）==="
# off（既定）→ continue (rc 0)
SCAFFOLDING_HEALTH_HALT=off sh_preflight_gate "$TMP/missing-agents" >/dev/null 2>&1; assert_rc "missing + HALT=off → 0(継続)" 0 $?
# 未設定 → continue (rc 0)
( unset SCAFFOLDING_HEALTH_HALT; sh_preflight_gate "$TMP/missing-agents" >/dev/null 2>&1 ); assert_rc "missing + HALT 未設定 → 0(継続)" 0 $?
# 空 → continue
SCAFFOLDING_HEALTH_HALT="" sh_preflight_gate "$TMP/missing-agents" >/dev/null 2>&1; assert_rc "missing + HALT='' → 0(継続)" 0 $?
# typo "On" → continue（厳密一致のみ HALT）
SCAFFOLDING_HEALTH_HALT=On sh_preflight_gate "$TMP/missing-agents" >/dev/null 2>&1; assert_rc "missing + HALT=On(typo) → 0(継続)" 0 $?
# "true" → continue
SCAFFOLDING_HEALTH_HALT=true sh_preflight_gate "$TMP/missing-agents" >/dev/null 2>&1; assert_rc "missing + HALT=true → 0(継続)" 0 $?
# "on" 厳密一致 → HALT (rc 1)
SCAFFOLDING_HEALTH_HALT=on sh_preflight_gate "$TMP/missing-agents" >/dev/null 2>&1; assert_rc "missing + HALT=on → 1(HALT)" 1 $?

echo "=== sh_preflight_gate missing は WARN + 可視シグナルを出す（Req 1.2 / 1.3）==="
gh_comment_reset
SCAFFOLDING_HEALTH_HALT=off sh_preflight_gate "$TMP/missing-agents" >/dev/null 2>/tmp/sh_err_$$
err="$(cat /tmp/sh_err_$$; rm -f /tmp/sh_err_$$)"
case "$err" in
  *"WARN: 足場欠落を検出"*) echo "  PASS: missing で loud WARN を出力"; PASS=$((PASS + 1));;
  *) echo "  FAIL: missing で WARN 欠落（err='$err'）"; FAIL=$((FAIL + 1));;
esac
if [ "$(gh_comment_count)" -ge 1 ]; then
  echo "  PASS: missing で可視シグナル（gh issue comment）を呼ぶ"
  PASS=$((PASS + 1))
else
  echo "  FAIL: missing で可視シグナルが呼ばれない"
  FAIL=$((FAIL + 1))
fi

echo "=== sh_preflight_gate indeterminate は HALT opt-in でも継続（Req 3.1 / 3.3）==="
# indeterminate は HALT=on でも継続（rc 0）
SCAFFOLDING_HEALTH_HALT=on sh_preflight_gate "$TMP/indeterminate" >/dev/null 2>&1; assert_rc "indeterminate + HALT=on → 0(fail-open 継続)" 0 $?

echo "=== _sh_emit_visibility_signal 冪等（既存マーカーあり → 投稿抑止 / Req 5.3 / NFR 5.1）==="
# gh issue view が既存マーカーを返す stub に差し替えて、投稿が抑止されることを確認する。
gh_comment_reset
gh() {
  case "$1 $2" in
    "issue view")
      echo '<!-- scaffolding-health:missing -->'   # 既存マーカーあり
      return 0
      ;;
    "issue comment")
      echo "called" >> "$GH_COMMENT_SENTINEL"
      return 0
      ;;
  esac
  return 0
}
_sh_emit_visibility_signal "agents=missing rules=ok" >/dev/null 2>&1
if [ "$(gh_comment_count)" -eq 0 ]; then
  echo "  PASS: 既存マーカー検出時はコメント投稿を抑止（冪等）"
  PASS=$((PASS + 1))
else
  echo "  FAIL: 既存マーカーがあるのに重複投稿した"
  FAIL=$((FAIL + 1))
fi

echo "=== read-only 確認: fixture が検査で変化しないこと ==="
before="$(find "$TMP/full" -type f | sort | xargs md5sum 2>/dev/null | md5sum)"
sh_inspect_scaffolding "$TMP/full" >/dev/null
SCAFFOLDING_HEALTH_HALT=off sh_preflight_gate "$TMP/full" >/dev/null 2>&1
after="$(find "$TMP/full" -type f | sort | xargs md5sum 2>/dev/null | md5sum)"
if [ "$before" = "$after" ]; then
  echo "  PASS: 検査前後で fixture 不変（read-only）"
  PASS=$((PASS + 1))
else
  echo "  FAIL: 検査で fixture が変化した"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
