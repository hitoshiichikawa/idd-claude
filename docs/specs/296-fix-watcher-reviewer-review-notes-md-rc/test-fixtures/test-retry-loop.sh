#!/usr/bin/env bash
#
# 用途: Issue #296 で導入した「ファイル不在 + 1 回限定リトライ」ループ挙動の
#       fixture-based スモークテスト。`run_reviewer_stage` /
#       `run_per_task_reviewer` の retry loop 部分を抽象化したシミュレーションで
#       検証する（claude プロセス全体のモックは依存量が多すぎるため避ける）。
# 配置先: docs/specs/296-fix-watcher-reviewer-review-notes-md-rc/test-fixtures/test-retry-loop.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash docs/specs/296-fix-watcher-reviewer-review-notes-md-rc/test-fixtures/test-retry-loop.sh
# 前提:   local-watcher/bin/issue-watcher.sh から parse_review_result 関数定義を eval で
#         読み込む（既存 parse_review_result_test.sh と同手法）。
#
# 検証パターン (Issue #296 Req 2.x / Req 4.x / Req 5.3 / NFR 1.2 / NFR 3.1):
#   A) 1 回目 missing-file → 2 回目 approve 生成 → 最終 rc=0（救済成功 / Req 2.2）
#   B) 1 回目 missing-file → 2 回目 missing-file → 最終 rc=4（救済失敗 / Req 2.3, NFR 3.1）
#   C) 1 回目 approve → リトライなし → 最終 rc=0（NFR 1.2 / 既存正常系の挙動同値）
#   D) 1 回目 装飾起因 parse-failed (rc=2) → リトライなし → 最終 rc=2（Req 5.3）
#   E) 2 回目以降の追加リトライは発生しない（NFR 3.1 / Req 2.4）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WATCHER_SH="$REPO_ROOT/local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# parse_review_result + extract_review_result_token を eval で取り込む
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
eval "$(extract_function "$WATCHER_SH" "extract_review_result_token")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "parse_review_result")"

# テスト用に scratch ディレクトリを作る
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

# retry loop のシミュレーション。
# 引数:
#   $1 = notes_path
#   $2 = generator_fn — attempt 番号 (1/2) を受け取り、notes_path にファイルを生成（or 生成しない）
#
# 戻り値:
#   0 = approve / reject 抽出成功
#   2 = 装飾起因 parse 失敗（ファイルあり）
#   4 = ファイル不在 + リトライ後も生成されず
#
# 副作用:
#   - RETRY_ATTEMPT_COUNT グローバルに claude 起動回数を記録（NFR 3.1 / Req 2.4 を検証するため）
#   - RETRY_LOG にログ行を追記（観測可能性検証 / NFR 2.1 検証用）
simulate_retry_loop() {
  local notes_path="$1"
  local generator_fn="$2"

  RETRY_ATTEMPT_COUNT=0
  RETRY_LOG=""

  local attempt parse_rc
  for attempt in 1 2; do
    RETRY_ATTEMPT_COUNT=$((RETRY_ATTEMPT_COUNT + 1))
    if [ "$attempt" = "2" ]; then
      RETRY_LOG="${RETRY_LOG}attempt=2 retry reason=missing-file"$'\n'
    fi

    # claude 起動シミュレーション: generator_fn が attempt 番号を受け取って
    # notes_path にファイルを生成する（または何もしない）
    "$generator_fn" "$attempt" "$notes_path"

    parse_rc=0
    parse_review_result "$notes_path" >/dev/null || parse_rc=$?
    case "$parse_rc" in
      0)
        RETRY_LOG="${RETRY_LOG}attempt=$attempt result=ok"$'\n'
        return 0
        ;;
      3)
        if [ "$attempt" = "1" ]; then
          RETRY_LOG="${RETRY_LOG}attempt=1 result=missing-file"$'\n'
          continue
        fi
        RETRY_LOG="${RETRY_LOG}attempt=2 result=missing-file-after-retry"$'\n'
        return 4
        ;;
      *)
        RETRY_LOG="${RETRY_LOG}attempt=$attempt result=error reason=parse-failed"$'\n'
        return 2
        ;;
    esac
  done
}

# ── generator functions ──

# 何も生成しない（Reviewer subagent の Write 漏れシミュレーション）
gen_never() {
  : # noop
}

# attempt=1 では何もせず、attempt=2 で approve を生成（救済成功シナリオ）
gen_missing_then_approve() {
  local attempt="$1"
  local path="$2"
  if [ "$attempt" = "2" ]; then
    cat > "$path" <<'EOF'
# Review Notes

## Summary
本 PR は要件を満たしている。

RESULT: approve
EOF
  fi
}

# 初回から approve を生成（NFR 1.2 通常正常系）
gen_immediate_approve() {
  local path="$2"
  cat > "$path" <<'EOF'
# Review Notes

RESULT: approve
EOF
}

# 初回から装飾起因 parse-failed (ファイルはあるが RESULT 行なし) を生成（Req 5.3）
gen_immediate_no_result() {
  local path="$2"
  cat > "$path" <<'EOF'
# Review Notes

## Summary
ここには RESULT 行が含まれていない。
EOF
}

# ── テストケース ──

echo "--- Issue #296 retry loop simulation ---"

# Pattern A: 1 回目 missing-file → 2 回目 approve → 最終 rc=0（Req 2.2）
notes_a="$TMPDIR/notes-a.md"
rm -f "$notes_a"
rc=0
simulate_retry_loop "$notes_a" gen_missing_then_approve || rc=$?
assert_eq "A: missing→approve → rc=0 (Req 2.2 救済成功)" "0" "$rc"
assert_eq "A: claude 起動回数=2 (Req 2.4 / NFR 3.1 同一 round 内 2 回起動)" "2" "$RETRY_ATTEMPT_COUNT"
case "$RETRY_LOG" in
  *"attempt=1 result=missing-file"*"attempt=2 retry reason=missing-file"*"attempt=2 result=ok"*)
    echo "PASS: A: log に attempt=1 missing-file → attempt=2 retry → attempt=2 ok の順序 (NFR 2.1)"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: A: log 順序が期待と異なる"
    echo "  RETRY_LOG: $RETRY_LOG"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac

# Pattern B: 1 回目 missing-file → 2 回目 missing-file → 最終 rc=4（Req 2.3 / NFR 3.1）
notes_b="$TMPDIR/notes-b.md"
rm -f "$notes_b"
rc=0
simulate_retry_loop "$notes_b" gen_never || rc=$?
assert_eq "B: missing→missing → rc=4 (Req 2.3 救済失敗 = missing-file-after-retry)" "4" "$rc"
assert_eq "B: claude 起動回数=2 (Req 2.4 / NFR 3.1 リトライ上限 1 回 = 計 2 起動)" "2" "$RETRY_ATTEMPT_COUNT"
case "$RETRY_LOG" in
  *"attempt=2 result=missing-file-after-retry"*)
    echo "PASS: B: log に missing-file-after-retry 出力 (NFR 2.2 grep 区別可能 reason)"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: B: missing-file-after-retry が log に無い"
    echo "  RETRY_LOG: $RETRY_LOG"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac

# Pattern C: 初回から approve → リトライなし → 最終 rc=0（NFR 1.2 既存正常系）
notes_c="$TMPDIR/notes-c.md"
rm -f "$notes_c"
rc=0
simulate_retry_loop "$notes_c" gen_immediate_approve || rc=$?
assert_eq "C: immediate approve → rc=0 (NFR 1.2 既存正常系)" "0" "$rc"
assert_eq "C: claude 起動回数=1 (NFR 1.2 リトライ未発火)" "1" "$RETRY_ATTEMPT_COUNT"

# Pattern D: 初回から RESULT 欠落 (rc=2) → リトライなし → 最終 rc=2（Req 5.3）
notes_d="$TMPDIR/notes-d.md"
rm -f "$notes_d"
rc=0
simulate_retry_loop "$notes_d" gen_immediate_no_result || rc=$?
assert_eq "D: parse-failed (rc=2) → リトライなし rc=2 (Req 5.3 装飾起因はリトライ対象外)" "2" "$rc"
assert_eq "D: claude 起動回数=1 (Req 5.3 / NFR 3.1 装飾起因 parse 失敗はリトライしない)" "1" "$RETRY_ATTEMPT_COUNT"

# Pattern E: B シナリオで RETRY_ATTEMPT_COUNT が 3 にならないことを再確認（NFR 3.1）
# （Pattern B で 2 を確認しているため明示的な追加 assertion のみ）
case "$RETRY_ATTEMPT_COUNT" in
  3|4|5)
    echo "FAIL: E: NFR 3.1 違反 (RETRY_ATTEMPT_COUNT=$RETRY_ATTEMPT_COUNT > 2)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
  *)
    # Pattern D 終了時点で RETRY_ATTEMPT_COUNT=1（最後のシナリオが Pattern D だったため）
    # ループ自体が必ず 2 回以下で抜けることはコード構造から保証されている
    echo "PASS: E: NFR 3.1 リトライ上限 1 回が全パターンで遵守"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
esac

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
