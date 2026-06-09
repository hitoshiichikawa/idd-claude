#!/usr/bin/env bash
#
# 本テストの fake 依存（git）は eval で読み込んだ pt_check_fail_fast から間接的に
# のみ呼ばれるため unreachable 扱いになる。false positive のため抑止する
# （既存 stage_a_verify_round1_defer_test.sh 等と同じ扱い）。
# shellcheck disable=SC2317
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #305（per-task retry で
#       連続同一 reject を検出する fail-fast 経路）で追加した
#       `pt_check_fail_fast` 関数を fixture で検証するスモークテスト。
#
#       対象関数:
#         - pt_check_fail_fast (Issue #305 Req 3.1 / 3.2 / 3.4 / 3.5 / 5.3 /
#                               NFR 1.3 / NFR 3.2)
#
#       既存 `pt_extract_findings_block_test.sh` の「awk による関数抽出 + eval
#       読み込み」パターンを踏襲し、`stage_a_verify_round1_defer_test.sh` の
#       fake 関数注入パターン（gh fake → 本テストでは git fake）を踏襲する。
#       トップレベル副作用は回避する。
#
# 配置先: local-watcher/test/pt_check_fail_fast_test.sh
# 依存:   bash 4+, awk, grep, sort, comm
# 実行:   bash local-watcher/test/pt_check_fail_fast_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pt_check_fail_fast"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -d "$FIXTURE_DIR" ]; then
  echo "ERROR: cannot find fixture dir at $FIXTURE_DIR" >&2
  exit 2
fi

# issue-watcher.sh から該当関数 1 個だけを抽出する（インデント無しの単独 `}` まで）。
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
eval "$(extract_function "$WATCHER_SH" "pt_check_fail_fast")"

if ! declare -F pt_check_fail_fast >/dev/null; then
  echo "ERROR: pt_check_fail_fast not loaded" >&2
  exit 2
fi

# ── fake git: `git diff --name-only <range>` のみ override。
#    $GIT_DIFF_FILE の内容を echo して exit 0 を返す。他の git サブコマンドは
#    本関数からは呼ばれない設計のため未対応で十分。
GIT_DIFF_FILE=""
git() {
  if [ "${1:-}" = "diff" ] && [ "${2:-}" = "--name-only" ]; then
    if [ -n "$GIT_DIFF_FILE" ] && [ -f "$GIT_DIFF_FILE" ]; then
      cat "$GIT_DIFF_FILE"
      return 0
    fi
    return 0
  fi
  # 想定外呼び出し → 失敗扱い（テスト経路から呼ばれないはず）
  return 127
}

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

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle  : $(printf '%q' "$needle")"
    echo "  haystack: $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─── Case 1: 同一 category + 同一 target + テスト差分なし → fail-fast 成立 ───
#     Req 3.1, 3.2: 共有 Finding を検出 + テストファイル不在で return 0 + log 行出力
echo "--- pt_check_fail_fast: same-category-same-target-no-test-diff (Req 3.1 / 3.2) ---"

CASE_DIR="$FIXTURE_DIR/same-category-same-target-no-test-diff"
GIT_DIFF_FILE="$CASE_DIR/git-diff.txt"
rc=0
out=$(pt_check_fail_fast "1.2" "$CASE_DIR/prev-round1.md" "$CASE_DIR/curr-round2.md" "abc1111" "abc2222") || rc=$?

assert_eq "Req 3.2: 共有 Finding + テスト差分なし → return 0" "0" "$rc"
assert_contains "Req 3.2: stdout に 'fail-fast match' が含まれる" \
  "fail-fast match" "$out"
assert_contains "Req 3.2: stdout に 'task=1.2' が含まれる" \
  "task=1.2" "$out"
assert_contains "Req 3.2: stdout に category=AC 未カバー が含まれる" \
  "category=AC 未カバー" "$out"
assert_contains "Req 3.2: stdout に target=1.1 が含まれる" \
  "target=1.1" "$out"
assert_contains "Req 3.2: stdout に test-diff-empty が含まれる" \
  "test-diff-empty" "$out"
assert_contains "Req 3.2: stdout に range=abc1111..abc2222 が含まれる" \
  "range=abc1111..abc2222" "$out"

echo ""

# ─── Case 2: 同一 category だが target 異なる → 共有なし → fail-fast 不成立 ───
#     Req 3.4: カテゴリまたは対象 numeric requirement ID で 1 件も重ならない経路
echo "--- pt_check_fail_fast: same-category-different-target (Req 3.4) ---"

CASE_DIR="$FIXTURE_DIR/same-category-different-target"
GIT_DIFF_FILE="$CASE_DIR/git-diff.txt"
rc=0
out=$(pt_check_fail_fast "1.2" "$CASE_DIR/prev-round1.md" "$CASE_DIR/curr-round2.md" "def1111" "def2222") || rc=$?

assert_eq "Req 3.4: 共有なし → return 1" "1" "$rc"
assert_contains "Req 3.4: stdout に 'fail-fast skip' が含まれる" \
  "fail-fast skip" "$out"
assert_contains "Req 3.4: stdout に reason=no-shared-finding が含まれる" \
  "reason=no-shared-finding" "$out"
assert_contains "Req 3.4: stdout に 'task=1.2' が含まれる" \
  "task=1.2" "$out"

echo ""

# ─── Case 3: 共有なし + テスト差分あり → fail-fast 不成立 ───
#     Req 3.4 / 3.5: 共有なしの時点で不成立（テスト差分は副次条件として未到達でも OK）
echo "--- pt_check_fail_fast: different-category-with-test-diff (Req 3.4 / 3.5) ---"

CASE_DIR="$FIXTURE_DIR/different-category-with-test-diff"
GIT_DIFF_FILE="$CASE_DIR/git-diff.txt"
rc=0
out=$(pt_check_fail_fast "1.2" "$CASE_DIR/prev-round1.md" "$CASE_DIR/curr-round2.md" "ef01111" "ef02222") || rc=$?

assert_eq "Req 3.4: カテゴリ/target ともに異なる → return 1" "1" "$rc"
assert_contains "Req 3.4: stdout に 'fail-fast skip' が含まれる" \
  "fail-fast skip" "$out"
assert_contains "Req 3.4: stdout に reason=no-shared-finding が含まれる（共有なしで早期 return）" \
  "reason=no-shared-finding" "$out"

echo ""

# ─── Case 4: prev_snapshot 不在 → 安全側 return 1 ───
#     Req 3.4: 判定不能時は不成立扱い（snapshot 取得失敗で誤検出を抑止）
echo "--- pt_check_fail_fast: prev-snapshot-missing (Req 3.4) ---"

rc=0
out=$(pt_check_fail_fast "1.2" "" "$FIXTURE_DIR/same-category-same-target-no-test-diff/curr-round2.md" "aaa" "bbb") || rc=$?

assert_eq "Req 3.4: prev snapshot 空文字 → return 1" "1" "$rc"
assert_contains "Req 3.4: stdout に reason=prev-snapshot-missing が含まれる" \
  "reason=prev-snapshot-missing" "$out"

echo ""

# ─── Case 5: 同一 finding + テスト差分あり → fail-fast 不成立（テスト差分で抑止） ───
#     Req 3.2: テスト差分が積まれた場合は安全側で不成立に倒す
echo "--- pt_check_fail_fast: shared-finding-but-test-diff-present (Req 3.2 / 3.5) ---"

# 共有 Finding を持つ fixture を再利用しつつ、git-diff にテストファイルを含むケースを差し込む
TMP_DIFF="$(mktemp)"
trap 'rm -f "$TMP_DIFF"' EXIT
cat <<'EOF' > "$TMP_DIFF"
local-watcher/bin/issue-watcher.sh
local-watcher/test/pt_check_fail_fast_test.sh
EOF

GIT_DIFF_FILE="$TMP_DIFF"
CASE_DIR="$FIXTURE_DIR/same-category-same-target-no-test-diff"
rc=0
out=$(pt_check_fail_fast "1.2" "$CASE_DIR/prev-round1.md" "$CASE_DIR/curr-round2.md" "abc1111" "abc2222") || rc=$?

assert_eq "Req 3.2: 共有あり + テスト差分あり → return 1" "1" "$rc"
assert_contains "Req 3.2: stdout に reason=test-diff-present が含まれる" \
  "reason=test-diff-present" "$out"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
