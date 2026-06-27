#!/usr/bin/env bash
#
# 用途: PR Reviewer Adjudicator (#404) の opt-in gate 判定関数 `adj_gate_enabled` の
#       安全側正規化挙動を検証するスモークテスト。
#
#       検証する受入基準（docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md）:
#         - Req 5.1 opt-in gate（Issue #412 で既定 OFF → 既定 ON / opt-out に反転後も
#                  adj_gate_enabled の厳密 `=true` 判定契約は不変）
#         - Req 5.5 既存 exit code・ログ stderr/stdout 契約の不変性（adj_gate_enabled は副作用なし）
#
#       前提: `PR_REVIEWER_ADJUDICATOR_ENABLED` は issue-watcher.sh の Config ブロックで
#             既に `case false) :;; *) true`（#412 で既定反転 / 既定 ON）+ 後段の
#             「デフォルト有効化フラグの値正規化」ループにより `true` / `false` の 2 値に
#             正規化済みである。本テストは正規化後の env を受け取った adj_gate_enabled が
#             **厳密 `=true` 一致のみで ON** を返し、それ以外（typo / 空 / unset / 大文字違い /
#             `false` 明示）すべてで OFF を返すことを直接検証する（重複正規化はしない契約 /
#             正規化前の値での既定挙動（unset → ON）は別途
#             `pr_reviewer_adjudicator_default_on_test.sh` で検証）。
#
# 配置先: local-watcher/test/adj_resolve_gate_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/adj_resolve_gate_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADJ_SH="$SCRIPT_DIR/../bin/modules/adjudicator.sh"

if [ ! -f "$ADJ_SH" ]; then
  echo "ERROR: cannot find adjudicator.sh at $ADJ_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して eval。
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
eval "$(extract_function "$ADJ_SH" "adj_gate_enabled")"

if ! declare -F adj_gate_enabled >/dev/null; then
  echo "ERROR: adj_gate_enabled not loaded" >&2
  exit 2
fi

# adj_gate_enabled は eval で動的に source されるため、shellcheck は
# `PR_REVIEWER_ADJUDICATOR_ENABLED` の参照を静的に追えない。SC2034 を test 全体で抑止する。
# shellcheck disable=SC2034

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

# adjudicator.sh 内の adj_gate_enabled は `$PR_REVIEWER_ADJUDICATOR_ENABLED` を読むため、
# 各ケースで export して env として渡す（test の中の関数呼び出しでも env として可視）。

# ─── adj_gate_enabled の厳密一致判定（Req 5.1） ───

echo "--- adj_gate_enabled cases (Issue #404 Req 5.1) ---"

# Req 5.1: 厳密 `=true` で ON (rc=0)
export PR_REVIEWER_ADJUDICATOR_ENABLED="true"
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1: PR_REVIEWER_ADJUDICATOR_ENABLED=true は ON (rc=0)" "0" "$rc"

# Req 5.1 安全側: 大文字違い (`True`) は OFF (rc=1)
# （issue-watcher.sh:687-690 が正規化済み env を渡すが、本関数は重複正規化せず厳密一致のみ判定する契約）
export PR_REVIEWER_ADJUDICATOR_ENABLED="True"
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1 安全側: PR_REVIEWER_ADJUDICATOR_ENABLED=True (大文字違い) は OFF (rc=1)" "1" "$rc"

# Req 5.1 安全側: 空文字は OFF (rc=1)
export PR_REVIEWER_ADJUDICATOR_ENABLED=""
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1 安全側: PR_REVIEWER_ADJUDICATOR_ENABLED='' (空文字) は OFF (rc=1)" "1" "$rc"

# Req 5.1 安全側: typo は OFF (rc=1)
export PR_REVIEWER_ADJUDICATOR_ENABLED="trrue"
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1 安全側: PR_REVIEWER_ADJUDICATOR_ENABLED=trrue (typo) は OFF (rc=1)" "1" "$rc"

# Req 5.1 既定: false は OFF (rc=1)
export PR_REVIEWER_ADJUDICATOR_ENABLED="false"
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1 既定: PR_REVIEWER_ADJUDICATOR_ENABLED=false は OFF (rc=1)" "1" "$rc"

# Req 5.1 既定: unset は OFF (rc=1)
unset PR_REVIEWER_ADJUDICATOR_ENABLED
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1 既定: PR_REVIEWER_ADJUDICATOR_ENABLED unset は OFF (rc=1)" "1" "$rc"

# Req 5.1 安全側: 数値風 "1" は OFF (rc=1)（正規化済み env を厳密判定）
export PR_REVIEWER_ADJUDICATOR_ENABLED="1"
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1 安全側: PR_REVIEWER_ADJUDICATOR_ENABLED=1 は OFF (rc=1)" "1" "$rc"

# Req 5.1 安全側: 別の合法 ON 風 `enabled` は OFF (rc=1)
export PR_REVIEWER_ADJUDICATOR_ENABLED="enabled"
rc=0
adj_gate_enabled || rc=$?
assert_eq "Req 5.1 安全側: PR_REVIEWER_ADJUDICATOR_ENABLED=enabled は OFF (rc=1)" "1" "$rc"

# ─── サマリ ───

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
