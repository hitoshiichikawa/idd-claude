#!/usr/bin/env bash
# =============================================================================
# Smoke test for build_partial_escalation_comment() helper
#
# 用途:
#   `build_partial_escalation_comment` の出力が Req 4.1〜4.5 / NFR 2.2 をすべて
#   満たすことを fixture ベースで検証する。
#
# 検証観点:
#   - 識別 HTML コメント `<!-- idd-claude:partial-status:STATUS -->` が **先頭** にある
#   - Halt 理由 / commit 一覧 / 残タスク / 推奨アクション / status code がすべて含まれる
#   - branch 名 / Issue 番号が埋め込まれている
#   - partial_blocked / partial_overrun の両 status code で組み立て可能
#
# 実行:
#   bash docs/specs/148-feat-harness-developer-partial-blocked-p/test-build-comment.sh
# =============================================================================
set -uo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$THIS_DIR/test-fixtures"
WATCHER="$(cd "$THIS_DIR/../../.." && pwd)/local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER" ]; then
  echo "ERROR: watcher not found at $WATCHER" >&2
  exit 1
fi

# build_partial_escalation_comment と依存変数 (BASE_BRANCH / NUMBER / REPO_DIR / SPEC_DIR_REL)
# を関数だけ抽出して評価する。最も簡単な方法は、依存環境変数を渡しつつ awk で関数本体を
# 取り出して eval すること。今回は test 用に直接 source して関数を pickup する。
# 副作用を避けるため、source の前に `return` を仕掛けて Config ブロック以降を実行しない
# ……のは難しいため、依存変数をすべて override + dry-run モードで動作させる。
# ここでは関数本体を bash subshell で awk 抽出 → 読み込みで safety を確保する。
fn_text=$(awk '/^build_partial_escalation_comment\(\) \{/,/^}/' "$WATCHER")
if [ -z "$fn_text" ]; then
  echo "ERROR: function build_partial_escalation_comment not found" >&2
  exit 1
fi

eval "$fn_text"

PASS=0
FAIL=0
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf '  PASS: %s contains "%s"\n' "$name" "$needle"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s missing "%s"\n' "$name" "$needle"
    FAIL=$((FAIL + 1))
  fi
}
assert_first_line() {
  local name="$1" haystack="$2" expected_first_line="$3"
  local got_first
  got_first=$(printf '%s' "$haystack" | head -n 1)
  if [ "$got_first" = "$expected_first_line" ]; then
    printf '  PASS: %s first line = "%s"\n' "$name" "$expected_first_line"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s first line\n    expected: "%s"\n    got:      "%s"\n' \
      "$name" "$expected_first_line" "$got_first"
    FAIL=$((FAIL + 1))
  fi
}

# テスト時の env override（build_partial_escalation_comment は env var 経由で NUMBER /
# REPO_DIR / BASE_BRANCH / SPEC_DIR_REL を参照する）。
export NUMBER="148"
export BASE_BRANCH="main"
export REPO_DIR="$(cd "$THIS_DIR/../../.." && pwd)"
export SPEC_DIR_REL="docs/specs/148-feat-harness-developer-partial-blocked-p"

echo "==> Case 1: partial_blocked"
out_blocked=$(build_partial_escalation_comment \
  "partial_blocked" \
  "$FIXTURES_DIR/status-partial-blocked.md" \
  "$FIXTURES_DIR/tasks-pending-sample.md" \
  "claude/issue-148-impl-feat-harness-developer-partial-blocked-p")

# 識別 HTML コメント先頭固定
assert_first_line "Req 4.5 / NFR 2.2 識別 HTML コメント先頭" \
  "$out_blocked" \
  "<!-- idd-claude:partial-status:partial_blocked -->"

assert_contains "Req 4.1 Halt 理由"       "$out_blocked" "依存 Issue #999 が未 merge"
assert_contains "Req 4.2 branch 名"       "$out_blocked" "claude/issue-148-impl-feat-harness-developer-partial-blocked-p"
assert_contains "Req 4.2 Issue 番号"      "$out_blocked" "#148"
assert_contains "Req 4.3 残タスク見出し"  "$out_blocked" "## 残タスク一覧"
assert_contains "Req 4.4 推奨アクション"  "$out_blocked" "## 推奨アクション"
assert_contains "Req 4.4 依存 Issue 先行" "$out_blocked" "依存 Issue を先に進める"
assert_contains "Req 4.4 Issue 分割"      "$out_blocked" "Issue を分割する"
assert_contains "Req 4.4 手動続行"        "$out_blocked" "手動で続行する"
assert_contains "Req 4.5 status code"     "$out_blocked" "partial_blocked"
assert_contains "footer #148 由来"         "$out_blocked" "Partial Status Gate (#148)"

echo ""
echo "==> Case 2: partial_overrun"
out_overrun=$(build_partial_escalation_comment \
  "partial_overrun" \
  "$FIXTURES_DIR/status-partial-overrun.md" \
  "$FIXTURES_DIR/tasks-pending-sample.md" \
  "claude/issue-148-impl-feat-harness-developer-partial-blocked-p")

assert_first_line "Req 4.5 / NFR 2.2 識別 HTML コメント先頭" \
  "$out_overrun" \
  "<!-- idd-claude:partial-status:partial_overrun -->"
assert_contains "Req 4.1 Halt 理由 (overrun)" "$out_overrun" "turn budget 残量が 8 turn"
assert_contains "Req 4.5 status code (overrun)" "$out_overrun" "partial_overrun"

echo ""
echo "==> Case 3: Pending Tasks セクション fallback（impl-notes に Pending Tasks なし → tasks.md から抽出）"
# Pending Tasks セクションを含まない fixture を一時的に作る
tmp_impl=$(mktemp /tmp/impl-notes-no-pending.XXXXXX.md)
trap 'rm -f "$tmp_impl"' EXIT
cat > "$tmp_impl" <<EOF_TMP
# Implementation Notes

## Partial Halt Reason

依存解消が必要。

STATUS: partial_blocked
EOF_TMP

out_fallback=$(build_partial_escalation_comment \
  "partial_blocked" \
  "$tmp_impl" \
  "$FIXTURES_DIR/tasks-pending-sample.md" \
  "claude/issue-148-impl-feat-harness-developer-partial-blocked-p")

assert_contains "残タスク fallback: tasks.md から抽出" \
  "$out_fallback" \
  "- [ ] 3. タスク 3"

echo ""
echo "==> 結果: $PASS pass / $FAIL fail"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
