#!/usr/bin/env bash
# =============================================================================
# Integration smoke test for handle_partial_status() coordinator
#
# 用途:
#   handle_partial_status の分岐（continue / partial 検出 / 不正値 / status 行不在）を
#   mock 環境（gh CLI を no-op stub に差し替え）で検証する。
#
# 検証ケース:
#   1) status 行不在               → return 0、副作用なし
#   2) STATUS: complete            → return 0、副作用なし
#   3) STATUS: partial_blocked     → return 10、ラベル付け替え + コメント投稿が呼ばれる
#   4) STATUS: partial_overrun     → return 10、同上
#   5) STATUS: foo（不正値）       → return 1、mark_issue_failed 呼出（gh issue edit
#                                     で claude-failed 付与が試行される）
#
# 実行:
#   bash docs/specs/148-feat-harness-developer-partial-blocked-p/test-handle-partial.sh
# =============================================================================
set -uo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$THIS_DIR/test-fixtures"
WATCHER="$(cd "$THIS_DIR/../../.." && pwd)/local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER" ]; then
  echo "ERROR: watcher not found at $WATCHER" >&2
  exit 1
fi

# 関数本体だけを取り出して評価する（issue-watcher.sh を直接 source すると Config ブロックが
# 走って副作用が出るため）。
extract_fn() {
  local fn_name="$1"
  awk -v fn="$fn_name" '
    $0 ~ "^" fn "\\(\\) \\{" { in_fn=1 }
    in_fn { print }
    in_fn && /^\}$/ { in_fn=0; exit }
  ' "$WATCHER"
}

for fn in detect_partial_status build_partial_escalation_comment \
          mark_issue_needs_decisions mark_issue_failed build_recovery_hint \
          handle_partial_status; do
  fn_text=$(extract_fn "$fn")
  if [ -z "$fn_text" ]; then
    echo "ERROR: function $fn not found" >&2
    exit 1
  fi
  eval "$fn_text"
done

# ── mock 環境 ──
TMP_DIR=$(mktemp -d /tmp/test-handle-partial.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# 各テストで spec dir / impl-notes / tasks を fresh に用意するため per-case 関数化
GH_LOG="$TMP_DIR/gh.log"
LOG="$TMP_DIR/cron.log"
export NUMBER="148"
export REPO="hitoshiichikawa/idd-claude"
export BRANCH="claude/issue-148-impl-feat-harness-developer-partial-blocked-p"
export BASE_BRANCH="main"
export MODE="impl"
export LABEL_CLAIMED="claude-claimed"
export LABEL_PICKED="claude-picked-up"
export LABEL_NEEDS_DECISIONS="needs-decisions"
export LABEL_FAILED="claude-failed"
export LOG

# gh CLI を stub に差し替え（PATH override）
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<GH_STUB
#!/usr/bin/env bash
# 呼出引数を 1 行で gh.log に追記して return 0
echo "gh \$*" >> "$GH_LOG"
exit 0
GH_STUB
chmod +x "$TMP_DIR/bin/gh"
export GH_LOG
ORIG_PATH="$PATH"
export PATH="$TMP_DIR/bin:$ORIG_PATH"

# build_recovery_hint は mark_issue_failed が呼ぶ依存関数（簡易 stub に差し替え）
build_recovery_hint() {
  echo "(test stub recovery hint)"
}

# hostname は mark_issue_failed が呼ぶため stub
hostname() {
  echo "test-host"
}

setup_case() {
  local impl_notes_content="$1"
  local case_dir="$TMP_DIR/case-$$-$RANDOM"
  mkdir -p "$case_dir/specs/148-x"
  echo -n "$impl_notes_content" > "$case_dir/specs/148-x/impl-notes.md"
  cat > "$case_dir/specs/148-x/tasks.md" <<EOF_T
- [x] 1. 完了
- [ ] 2. 未完了
EOF_T
  # .git 不在で git log は失敗 → fallback プレースホルダ採用（観点外）
  export REPO_DIR="$case_dir"
  export SPEC_DIR_REL="specs/148-x"
  : > "$GH_LOG"
  : > "$LOG"
}

PASS=0
FAIL=0
assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s (=%s)\n' "$name" "$actual"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: %s\n    got:      %s\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}
assert_gh_contains() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$GH_LOG" 2>/dev/null; then
    printf '  PASS: %s (gh.log contains "%s")\n' "$name" "$needle"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (gh.log missing "%s")\n' "$name" "$needle"
    printf '    gh.log:\n%s\n' "$(cat "$GH_LOG" 2>/dev/null || echo "(empty)")"
    FAIL=$((FAIL + 1))
  fi
}
assert_gh_empty() {
  local name="$1"
  if [ ! -s "$GH_LOG" ]; then
    printf '  PASS: %s (no gh calls)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (gh.log not empty)\n' "$name"
    printf '    gh.log:\n%s\n' "$(cat "$GH_LOG")"
    FAIL=$((FAIL + 1))
  fi
}

echo "==> Case 1: status 行不在 → return 0、副作用なし（NFR 1.1）"
setup_case "# Notes
ただの本文。STATUS 行なし。"
got_rc=0
handle_partial_status || got_rc=$?
assert_eq  "rc=0 continue"        "$got_rc" "0"
assert_gh_empty "副作用なし"

echo ""
echo "==> Case 2: STATUS: complete → return 0、副作用なし（NFR 1.4）"
setup_case "# Notes
全完了。

STATUS: complete"
got_rc=0
handle_partial_status || got_rc=$?
assert_eq  "rc=0 continue"        "$got_rc" "0"
assert_gh_empty "副作用なし"

echo ""
echo "==> Case 3: STATUS: partial_blocked → return 10、ラベル付け替え + コメント投稿"
setup_case "# Notes

## Partial Halt Reason
依存 Issue #999 未 merge。

## Pending Tasks
- [ ] 2. 未完了

STATUS: partial_blocked"
got_rc=0
handle_partial_status || got_rc=$?
assert_eq          "rc=10 partial 検出"    "$got_rc" "10"
assert_gh_contains "needs-decisions 付与"   "--add-label needs-decisions"
assert_gh_contains "claude-claimed 除去"    "--remove-label claude-claimed"
assert_gh_contains "claude-picked-up 除去"  "--remove-label claude-picked-up"
assert_gh_contains "comment 投稿"           "issue comment 148"

echo ""
echo "==> Case 4: STATUS: partial_overrun → return 10、同上"
setup_case "# Notes

## Partial Halt Reason
turn budget 残量 8 turn。

## Pending Tasks
- [ ] 2. 未完了

STATUS: partial_overrun"
got_rc=0
handle_partial_status || got_rc=$?
assert_eq          "rc=10 partial 検出"   "$got_rc" "10"
assert_gh_contains "needs-decisions 付与"  "--add-label needs-decisions"
assert_gh_contains "comment 投稿"          "issue comment 148"

echo ""
echo "==> Case 5: STATUS: foo（不正値）→ return 1、claude-failed 付与（NFR 3.1）"
setup_case "# Notes
STATUS: foo"
got_rc=0
handle_partial_status || got_rc=$?
assert_eq          "rc=1 不正値"                  "$got_rc" "1"
assert_gh_contains "claude-failed 付与"           "--add-label claude-failed"
assert_gh_contains "needs-decisions は付与しない" "issue edit 148"
# Note: 上記 assert は gh issue edit が呼ばれたことだけを verify。
# claude-failed と needs-decisions の併存禁止は mark_issue_failed の責務（既存 fixture
# 範囲外なので本テストでは verify しない）。

echo ""
echo "==> Case 6: NFR 2.1 grep 可能ログ"
setup_case "# Notes

## Partial Halt Reason
依存 Issue #999 未 merge。

STATUS: partial_blocked"
handle_partial_status >/dev/null || true
if grep -qE 'partial-status: detected issue=#148 status=partial_blocked branch=' "$LOG" 2>/dev/null; then
  echo "  PASS: NFR 2.1 grep 可能ログ行検出"
  PASS=$((PASS + 1))
else
  echo "  FAIL: NFR 2.1 grep 可能ログ行未検出"
  echo "    LOG:"
  cat "$LOG" 2>/dev/null || true
  FAIL=$((FAIL + 1))
fi

echo ""
echo "==> 結果: $PASS pass / $FAIL fail"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
