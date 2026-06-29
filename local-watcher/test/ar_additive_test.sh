#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/auto-rebase.sh の #438（加算的衝突緩和）で追加した:
#         - 純粋判定関数 ar_classify_additive（gate ON 時の二次判定）
#         - ar_classify_diff への二次判定フック（gate ON 加算的成立で mechanical 昇格）
#       を diff fixture で検証するスモークテスト。
#
#       検証する AC（docs/specs/438--bootstrap-cmd-main-di-issue-merge-confl/requirements.md）:
#         - Req 1.1: gate OFF で従来判定（二次判定を呼ばない / no-op）
#         - Req 1.4: bootstrap allowlist 空で二次判定 skip
#         - Req 2.1: 全 path 閉 + 全 hunk 追加のみ → additive(=mechanical)
#         - Req 2.2 / NFR2.2: 削除/変更 hunk を含むと not-additive（semantic 側）
#         - Req 2.3: allowlist 外 path 混在で not-additive
#         - Req 2.4 / NFR2.1: git diff 取得失敗で not-additive + return 1
#         - Req 2.5 / NFR3.1: additive 判定時に根拠ログを発火
#         - Req 1.2, 1.3, NFR1.1, NFR1.3: ar_classify_diff の結線（従来 semantic /
#           MECHANICAL_PATHS 全一致 mechanical / gate ON 加算的成立 mechanical 昇格）
#
# 配置先: local-watcher/test/ar_additive_test.sh
# 依存:   bash 4+, awk, mktemp
# 実行:   bash local-watcher/test/ar_additive_test.sh

set -euo pipefail

# 抽出関数（ar_classify_additive / ar_classify_diff）は AUTO_REBASE_ADDITIVE /
# AUTO_REBASE_ADDITIVE_PATHS / MECHANICAL_PATHS / AUTO_REBASE_GIT_TIMEOUT 等の
# グローバル env を遅延束縛で参照するため、static 解析（shellcheck）からは未使用に
# 見える。本ファイル全体で SC2034 を抑止する。
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/auto-rebase.sh"
FIXTURE_DIR="$SCRIPT_DIR/../../docs/specs/438--bootstrap-cmd-main-di-issue-merge-confl/test-fixtures"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find auto-rebase.sh at $MODULE_SH" >&2
  exit 2
fi
if [ ! -d "$FIXTURE_DIR" ]; then
  echo "ERROR: cannot find fixture dir at $FIXTURE_DIR" >&2
  exit 2
fi

# 既存テスト（ar_semantic_test.sh）と同じイディオム: 対象スクリプトから 1 関数だけを
# awk で切り出して eval で読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# ar_classify_diff は内部で ar_classify_additive を呼ぶため、隔離抽出の特性上
# 依存関数も明示 source する必要がある。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_classify_additive")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_classify_diff")"

for fn in ar_classify_additive ar_classify_diff; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ─── stub: env / ロガー / git / timeout ───
# shellcheck disable=SC2034
AUTO_REBASE_GIT_TIMEOUT=60

# ar_log の発火を記録する stub（実体は core_utils.sh）。
AR_LOG_TRACE="$(mktemp)"
trap 'rm -f "$AR_LOG_TRACE"' EXIT
# shellcheck disable=SC2317
ar_log() {
  echo "$*" >> "$AR_LOG_TRACE"
}

# git stub の挙動を制御するグローバル:
#   GIT_NAMES_FIXTURE  : `git diff --name-only` が返すファイル（空なら空出力）
#   GIT_DIFF_FIXTURE   : `git diff`（unified）が返すファイル（空なら空出力）
#   GIT_NAMES_RC       : `git diff --name-only` の exit code
#   GIT_DIFF_RC        : `git diff`（unified）の exit code
GIT_NAMES_FIXTURE=""
GIT_DIFF_FIXTURE=""
GIT_NAMES_RC=0
GIT_DIFF_RC=0

# timeout stub: 第 1 引数（秒数）を捨てて残りを実行する。
# shellcheck disable=SC2317
timeout() { shift; "$@"; }

# git stub: --name-only の有無で 2 種類の呼び出しを分岐する。
# shellcheck disable=SC2317
git() {
  if [ "${1:-}" != "diff" ]; then
    return 0
  fi
  local is_name_only=false arg
  for arg in "$@"; do
    [ "$arg" = "--name-only" ] && is_name_only=true
  done
  if [ "$is_name_only" = "true" ]; then
    if [ -n "$GIT_NAMES_FIXTURE" ] && [ -f "$GIT_NAMES_FIXTURE" ]; then
      cat "$GIT_NAMES_FIXTURE"
    fi
    return "$GIT_NAMES_RC"
  fi
  if [ -n "$GIT_DIFF_FIXTURE" ] && [ -f "$GIT_DIFF_FIXTURE" ]; then
    cat "$GIT_DIFF_FIXTURE"
  fi
  return "$GIT_DIFF_RC"
}

reset_git_stub() {
  GIT_NAMES_FIXTURE=""
  GIT_DIFF_FIXTURE=""
  GIT_NAMES_RC=0
  GIT_DIFF_RC=0
  : > "$AR_LOG_TRACE"
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

# 1 行目 / 2 行目を取り出すヘルパ（呼び出しと rc を捕捉）。
LAST_RC=0
LINE1=""
LINE2=""
run_additive() {
  local out rc=0
  out=$(ar_classify_additive "$@") || rc=$?
  LAST_RC="$rc"
  LINE1=$(printf '%s\n' "$out" | sed -n '1p')
  LINE2=$(printf '%s\n' "$out" | sed -n '2p')
}

log_has() {
  grep -qE "$1" "$AR_LOG_TRACE"
}

# ============================================================
# Section 1: ar_classify_additive — 6 ケース（gate-off / paths-empty /
#   additive / non-additive-hunk / path-out / diff-failed）
# ============================================================
echo "--- Section 1: ar_classify_additive の判定（純粋関数） ---"

# 1.1: gate OFF → not-additive / gate-off、ログ未発火（Req 1.1, NFR1.1）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE="off"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
run_additive 100 "main" "claude/feat-x"
assert_eq "Req 1.1: gate OFF で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "Req 1.1: gate OFF で理由 gate-off" "gate-off" "$LINE2"
assert_eq "Req 1.1: gate OFF で return 0" "0" "$LAST_RC"
if log_has "."; then
  echo "FAIL: Req 1.1 (NFR1.1): gate OFF で ar_log を呼ばない (no-op)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: Req 1.1 (NFR1.1): gate OFF で ar_log を呼ばない (no-op)"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# 1.1b: gate 不正値（CLAUDE / on / typo）も OFF 同等（Config 正規化前提）
for v in "CLAUDE" "on" "true" "" "additive"; do
  reset_git_stub
  # shellcheck disable=SC2034
  AUTO_REBASE_ADDITIVE="$v"
  # shellcheck disable=SC2034
  AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
  run_additive 100 "main" "claude/feat-x"
  assert_eq "Req 1.3: AUTO_REBASE_ADDITIVE=$(printf '%q' "$v") は gate-off 扱い" "gate-off" "$LINE2"
done

# 1.2: gate ON + paths 空 → not-additive / paths-empty（Req 1.4）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE="claude"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS=""
run_additive 101 "main" "claude/feat-x"
assert_eq "Req 1.4: paths 空で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "Req 1.4: paths 空で理由 paths-empty" "paths-empty" "$LINE2"
assert_eq "Req 1.4: paths 空で return 0" "0" "$LAST_RC"

# 1.3: gate ON + 全 path 閉 + 追加のみ → additive + 根拠ログ（Req 2.1, 2.5, NFR3.1）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE="claude"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go,internal/**"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_additive 102 "main" "claude/feat-x"
assert_eq "Req 2.1: 追加のみで 1 行目 additive" "additive" "$LINE1"
assert_eq "Req 2.1: additive 時 2 行目なし" "" "$LINE2"
assert_eq "Req 2.1: additive で return 0" "0" "$LAST_RC"
if log_has "additive=additive"; then
  echo "PASS: Req 2.5 (NFR3.1): additive 判定で根拠ログを発火"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.5 (NFR3.1): additive 判定で根拠ログを発火"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
if log_has "paths=cmd/api/main.go"; then
  echo "PASS: Req 2.5 (NFR3.1): 根拠ログに対象 path を含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.5 (NFR3.1): 根拠ログに対象 path を含む"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 1.4: 削除行を含む hunk → not-additive / non-additive-hunk（Req 2.2, NFR2.2）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE="claude"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-with-deletion.txt"
run_additive 103 "main" "claude/feat-x"
assert_eq "Req 2.2: 削除行含みで 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "Req 2.2 (NFR2.2): 理由 non-additive-hunk" "non-additive-hunk" "$LINE2"
assert_eq "Req 2.2: 削除行含みで return 0" "0" "$LAST_RC"

# 1.5: allowlist 外 path 混在 → not-additive / path-out（Req 2.3）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE="claude"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-path-out.txt"
GIT_DIFF_FIXTURE="$FIXTURE_DIR/diff-add-only.txt"
run_additive 104 "main" "claude/feat-x"
assert_eq "Req 2.3: allowlist 外混在で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "Req 2.3: 理由 path-out" "path-out" "$LINE2"
assert_eq "Req 2.3: allowlist 外混在で return 0" "0" "$LAST_RC"

# 1.6: git diff 取得失敗 → not-additive / diff-failed + return 1（Req 2.4, NFR2.1）
# (a) --name-only が非0 exit
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE="claude"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_RC=1
run_additive 105 "main" "claude/feat-x"
assert_eq "Req 2.4: --name-only 失敗で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "Req 2.4: 理由 diff-failed" "diff-failed" "$LINE2"
assert_eq "Req 2.4 (NFR2.1): --name-only 失敗で return 1" "1" "$LAST_RC"

# (b) unified diff が非0 exit（path 照合は通過後に失敗）
reset_git_stub
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE="claude"
# shellcheck disable=SC2034
AUTO_REBASE_ADDITIVE_PATHS="cmd/api/main.go"
GIT_NAMES_FIXTURE="$FIXTURE_DIR/names-add-only.txt"
GIT_DIFF_RC=1
run_additive 106 "main" "claude/feat-x"
assert_eq "Req 2.4: unified diff 失敗で 1 行目 not-additive" "not-additive" "$LINE1"
assert_eq "Req 2.4: 理由 diff-failed" "diff-failed" "$LINE2"
assert_eq "Req 2.4 (NFR2.1): unified diff 失敗で return 1" "1" "$LAST_RC"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
