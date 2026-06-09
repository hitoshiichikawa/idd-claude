#!/usr/bin/env bash
#
# 用途: Issue #304 で導入する `pt_detect_post_marker_commits` /
#       `pt_handle_post_marker_commits` の挙動を、idd-codex #14 と同型の
#       「marker + 後続修正 commit」shape を持つ一時 git repo で検証するスモーク
#       スクリプト。silent range truncation（marker で range_end を止めると
#       post-marker commit が Reviewer から見えなくなる挙動）の予防策が
#       期待どおり機能することを assert で確認する。
# 配置: docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/
#       test-post-marker-detect.sh
# 依存: bash 4+, git
# セットアップ参照先:
#   docs/specs/304--bug-per-task-commit-task-marker-review/impl-notes.md
#
# 実行:
#   ./docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/test-post-marker-detect.sh
# 出力:
#   各ケース: `[OK]` / `[NG]` の prefix で 1 行レポート
#   末尾: `SMOKE_RESULT: pass` / `SMOKE_RESULT: fail`
# 副作用:
#   /tmp/post-marker-smoke-XXXX/ に一時 git repo を作成し、終了時に削除する

set -euo pipefail

BASE_BRANCH="${BASE_BRANCH:-main}"

# ─── pt_resolve_diff_range の参照実装（既存 #164 fixture と同一実装） ─────────
# silent truncate 不許容 case (case-5) の前提として、本関数のみでは marker で
# range_end が止まることを示すために必要。本関数は
# local-watcher/bin/issue-watcher.sh の pt_resolve_diff_range と同一実装で
# なければならない（既存 #164 fixture と byte 一致）。
pt_resolve_diff_range() {
  local task_id="$1"
  local base="${BASE_BRANCH:-main}"

  local all_pairs
  all_pairs=$(git log --grep="^docs(tasks): mark " --format='%H%x09%s' --reverse "${base}..HEAD" 2>/dev/null || true)
  if [ -z "$all_pairs" ]; then
    return 1
  fi

  local current_mark="" via="" sha subject id_list tok found
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if [ "$subject" = "docs(tasks): mark ${task_id} as done" ]; then
      current_mark="$sha"
      via="single-id-marker"
    fi
  done <<<"$all_pairs"

  if [ -z "$current_mark" ]; then
    while IFS=$'\t' read -r sha subject; do
      [ -n "$sha" ] || continue
      id_list=$(printf '%s' "$subject" | sed -nE 's/^docs\(tasks\): mark (.+) as done$/\1/p')
      [ -n "$id_list" ] || continue
      found=false
      for tok in $(printf '%s' "$id_list" | tr '/,' '  '); do
        if [ "$tok" = "$task_id" ]; then
          found=true
          break
        fi
      done
      if [ "$found" = "true" ]; then
        current_mark="$sha"
        via="multi-id-marker"
      fi
    done <<<"$all_pairs"
  fi

  if [ -z "$current_mark" ]; then
    return 1
  fi

  local prev_mark=""
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if [ "$sha" = "$current_mark" ]; then
      break
    fi
    prev_mark="$sha"
  done <<<"$all_pairs"

  local range_start
  if [ -n "$prev_mark" ]; then
    range_start="$prev_mark"
  else
    range_start=$(git rev-parse "$base" 2>/dev/null || true)
    if [ -z "$range_start" ]; then
      return 1
    fi
  fi

  if [ "$via" = "multi-id-marker" ]; then
    echo "[smoke] diff-range resolved via=multi-id-marker task_id=${task_id} sha=${current_mark}" >&2
  fi

  printf '%s\t%s\n' "$range_start" "$current_mark"
  return 0
}

# ─── pt_detect_post_marker_commits の参照実装 ───────────────────────────────
# 本関数は task 2 で local-watcher/bin/issue-watcher.sh に追加される実装と
# 同一実装でなければならない。差分が出た場合は impl 側を本 fixture に再同期
# すること（既存 #164 fixture と同じ参照実装ミラー方針）。
#
# Contract:
#   引数: <marker_sha>
#   stdout: post-marker SHA list（newline 区切り、空の場合は出力なし）
#   stderr: 警告ログ（NFR 2.1 / git エラー時）
#   rc=0: 1 件以上検出
#   rc=1: 0 件（fall-through OK）
#   rc=2: git エラー（fail-safe）
pt_detect_post_marker_commits() {
  local marker_sha="$1"
  local post_list
  if ! post_list=$(git log --format=%H "${marker_sha}..HEAD" 2>/dev/null); then
    echo "[smoke] post-marker-commits-detect: git log error marker=${marker_sha}" >&2
    return 2
  fi
  if [ -z "$post_list" ]; then
    return 1
  fi
  printf '%s\n' "$post_list"
  return 0
}

# ─── pt_handle_post_marker_commits の参照実装 ───────────────────────────────
# 本関数は task 3 で local-watcher/bin/issue-watcher.sh に追加される実装と
# 同一実装でなければならない。差分が出た場合は impl 側を本 fixture に再同期
# すること。
#
# Contract:
#   引数: <task_id> <round> <range_start> <marker_sha> <post_marker_list>
#   env: POST_MARKER_RECOVERY_MODE (default=fail-with-diagnostic, 不正値も default 化)
#   stdout: extend-range 時のみ <new_range_start>\t<new_range_end>（HEAD まで拡張）
#   stderr: NFR 2.1 準拠の単一行ログ
#   rc=0: extend-range で続行
#   rc=5: fail-with-diagnostic で停止
pt_handle_post_marker_commits() {
  local task_id="$1"
  local round="$2"
  local range_start="$3"
  local marker_sha="$4"
  local post_marker_list="$5"

  local mode="${POST_MARKER_RECOVERY_MODE:-fail-with-diagnostic}"
  case "$mode" in
    extend-range|fail-with-diagnostic) ;;
    *)
      echo "[smoke] post-marker-commits-detect: invalid POST_MARKER_RECOVERY_MODE='${mode}', falling back to fail-with-diagnostic" >&2
      mode="fail-with-diagnostic"
      ;;
  esac

  local ts post_csv
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  post_csv=$(printf '%s' "$post_marker_list" | tr '\n' ',' | sed 's/,$//')
  echo "[${ts}] per-task: post-marker-commits-detected task_id=${task_id} round=${round} marker=${marker_sha} post_marker_shas=${post_csv} recovery=${mode}" >&2

  if [ "$mode" = "extend-range" ]; then
    local head_sha
    if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
      echo "[smoke] post-marker-commits-detect: git rev-parse HEAD failed (range_start=${range_start})" >&2
      return 5
    fi
    printf '%s\t%s\n' "$range_start" "$head_sha"
    return 0
  fi

  # fail-with-diagnostic
  return 5
}

# ─── テストハーネス ─────────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "[OK]   ${label} (expected=${expected}, actual=${actual})"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "[NG]   ${label} (expected=${expected}, actual=${actual})" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_rc() {
  local label="$1" expected_rc="$2" actual_rc="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "[OK]   ${label} (rc=${actual_rc} as expected)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "[NG]   ${label} (expected rc=${expected_rc} but got rc=${actual_rc})" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_fail() {
  local label="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    echo "[OK]   ${label} (rc=${rc} as expected non-zero)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "[NG]   ${label} (expected non-zero rc but got 0)" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# ─── fixture セットアップ ─────────────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/post-marker-smoke-XXXX)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
git init -q -b main
git config user.email smoke@example.com
git config user.name smoke

echo init > README.md
git add README.md
git commit -q -m "initial commit"
MAIN_SHA=$(git rev-parse main)

# ─── case-1: marker 後に commit 無し（既存挙動温存 / NFR 1.3 / Req 5.2 normal） ───
git checkout -q -b case1-no-post-marker
echo a > task1.txt && git add task1.txt && git commit -q -m "feat: task 1 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1 as done"
C1_MARKER=$(git rev-parse HEAD)

# pt_detect_post_marker_commits は rc=1（0 件）、stdout 空を返すべき
DETECT_OUT=""
DETECT_RC=0
DETECT_OUT=$(pt_detect_post_marker_commits "$C1_MARKER" 2>/dev/null) || DETECT_RC=$?
assert_rc "case-1: pt_detect_post_marker_commits rc (no post-marker)" "1" "$DETECT_RC"
assert_eq "case-1: pt_detect_post_marker_commits stdout (empty)" "" "$DETECT_OUT"

# ─── case-2: idd-codex #14 同型 commit shape ────────────────────────────────
# marker commit + 修正 commit 2 件（push 後の Reviewer reject → Implementer 再実行で
# 修正 commit を marker 後ろに残してしまったケース）
git checkout -q main
git checkout -q -b case2-codex-14-shape
echo a > task2.txt && git add task2.txt && git commit -q -m "feat: task 2 impl"
git commit -q --allow-empty -m "docs(tasks): mark 2 as done"
C2_MARKER=$(git rev-parse HEAD)
# Reviewer reject 後の修正 commit 2 件（marker 後ろに残置）
echo fix1 > fix1.txt && git add fix1.txt && git commit -q -m "fix: address reviewer round 1 feedback"
C2_FIX1=$(git rev-parse HEAD)
echo fix2 > fix2.txt && git add fix2.txt && git commit -q -m "test: add regression for case found in review"
C2_FIX2=$(git rev-parse HEAD)

DETECT_OUT=$(pt_detect_post_marker_commits "$C2_MARKER")
DETECT_RC=$?
assert_rc "case-2: pt_detect_post_marker_commits rc (2 post-marker)" "0" "$DETECT_RC"
# git log は新しい順（HEAD 側が先頭）
EXPECTED_POST=$(printf '%s\n%s' "$C2_FIX2" "$C2_FIX1")
assert_eq "case-2: pt_detect_post_marker_commits stdout (2 SHA, newest first)" "$EXPECTED_POST" "$DETECT_OUT"

# ─── case-3: fail-with-diagnostic で rc=5 (abort) ───────────────────────────
# case-2 と同じリポジトリ状態をそのまま流用（同 branch / 同 HEAD）。
HANDLE_RC=0
POST_LIST_CASE3="$DETECT_OUT"
RANGE_START_CASE3="$MAIN_SHA"
# default 値（env 未設定）でも fail-with-diagnostic にフォールバックする想定。
# 明示設定でも同じ rc になることを確認するため明示する。
HANDLE_STDOUT=$(POST_MARKER_RECOVERY_MODE=fail-with-diagnostic \
  pt_handle_post_marker_commits "2" "1" "$RANGE_START_CASE3" "$C2_MARKER" "$POST_LIST_CASE3" \
  2>/dev/null) || HANDLE_RC=$?
assert_rc "case-3: pt_handle_post_marker_commits rc (fail-with-diagnostic)" "5" "$HANDLE_RC"
assert_eq "case-3: pt_handle_post_marker_commits stdout (no range emitted on abort)" "" "$HANDLE_STDOUT"

# default 値での挙動も同じ rc=5 であることを確認（env 未設定 / 不正値の default 化）
HANDLE_RC=0
HANDLE_STDOUT=$(unset POST_MARKER_RECOVERY_MODE; \
  pt_handle_post_marker_commits "2" "1" "$RANGE_START_CASE3" "$C2_MARKER" "$POST_LIST_CASE3" \
  2>/dev/null) || HANDLE_RC=$?
assert_rc "case-3: pt_handle_post_marker_commits rc (env unset → default fail-with-diagnostic)" "5" "$HANDLE_RC"

HANDLE_RC=0
HANDLE_STDOUT=$(POST_MARKER_RECOVERY_MODE=garbage-value \
  pt_handle_post_marker_commits "2" "1" "$RANGE_START_CASE3" "$C2_MARKER" "$POST_LIST_CASE3" \
  2>/dev/null) || HANDLE_RC=$?
assert_rc "case-3: pt_handle_post_marker_commits rc (invalid env → default fail-with-diagnostic)" "5" "$HANDLE_RC"

# ─── case-4: extend-range で rc=0 + 新 range pair ───────────────────────────
HANDLE_RC=0
HANDLE_STDOUT=$(POST_MARKER_RECOVERY_MODE=extend-range \
  pt_handle_post_marker_commits "2" "1" "$RANGE_START_CASE3" "$C2_MARKER" "$POST_LIST_CASE3" \
  2>/dev/null) || HANDLE_RC=$?
assert_rc "case-4: pt_handle_post_marker_commits rc (extend-range)" "0" "$HANDLE_RC"
# 新 range = <range_start>\t<HEAD>（HEAD = C2_FIX2）
EXPECTED_RANGE_CASE4=$(printf '%s\t%s' "$RANGE_START_CASE3" "$C2_FIX2")
assert_eq "case-4: pt_handle_post_marker_commits stdout (new range = range_start TAB HEAD)" \
  "$EXPECTED_RANGE_CASE4" "$HANDLE_STDOUT"

# ─── case-5: silent truncate を許容しない expectation ───────────────────────
# Req 5.3: pt_resolve_diff_range のみで stop した場合、post-marker commit は
# range_end の外に置かれる（silent truncate 状態）。本 case は以下を assert
# として明示することで、将来 hook が外された場合に test が fail するように
# 設計されている:
#   (a) pt_resolve_diff_range の range_end が marker と一致すること
#       （silent truncate の証拠）
#   (b) post-marker commit が `range_start..range_end` の外側にあること
#       （hook なしでは漏れていた）
#   (c) pt_detect_post_marker_commits hook を併用すれば post-marker commit を
#       検出できること（rc=0 + SHA list 返却）
# (a) と (b) は「silent truncate が起きうる証拠」であり、(c) で hook が
# 検出することを assert する。hook が将来外されると (c) が fail し、本 test
# 全体が SMOKE_RESULT: fail で終了する。
git checkout -q main
git checkout -q -b case5-silent-truncate-guard
echo a > task5.txt && git add task5.txt && git commit -q -m "feat: task 5 impl"
git commit -q --allow-empty -m "docs(tasks): mark 5 as done"
C5_MARKER=$(git rev-parse HEAD)
echo fix > fix5.txt && git add fix5.txt && git commit -q -m "fix: late correction not covered by marker"
C5_LATE=$(git rev-parse HEAD)

# (a) pt_resolve_diff_range の range_end が marker と一致（silent truncate の証拠）
RESOLVED=$(pt_resolve_diff_range "5")
RESOLVED_END=$(printf '%s' "$RESOLVED" | cut -f2)
assert_eq "case-5(a): pt_resolve_diff_range range_end == marker (silent truncate evidence)" \
  "$C5_MARKER" "$RESOLVED_END"

# (b) post-marker commit (C5_LATE) は range_start..range_end の外にある
#     git log で range 内に C5_LATE が含まれないことを確認
RESOLVED_START=$(printf '%s' "$RESOLVED" | cut -f1)
RANGE_CONTENTS=$(git log --format=%H "${RESOLVED_START}..${RESOLVED_END}" 2>/dev/null)
CONTAINS_LATE=no
if printf '%s\n' "$RANGE_CONTENTS" | grep -qx "$C5_LATE"; then
  CONTAINS_LATE=yes
fi
assert_eq "case-5(b): C5_LATE is NOT in range_start..range_end (would be silently truncated)" \
  "no" "$CONTAINS_LATE"

# (c) pt_detect_post_marker_commits hook を使えば C5_LATE を検出できる
DETECT_OUT=$(pt_detect_post_marker_commits "$C5_MARKER")
DETECT_RC=$?
assert_rc "case-5(c): pt_detect_post_marker_commits detects post-marker commit (rc=0)" "0" "$DETECT_RC"
assert_eq "case-5(c): pt_detect_post_marker_commits stdout == C5_LATE (single post-marker)" \
  "$C5_LATE" "$DETECT_OUT"

# ─── 結果集計 ───────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo " PASSED: ${TESTS_PASSED}"
echo " FAILED: ${TESTS_FAILED}"
echo "============================================="
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "SMOKE_RESULT: pass"
  exit 0
else
  echo "SMOKE_RESULT: fail"
  exit 1
fi
