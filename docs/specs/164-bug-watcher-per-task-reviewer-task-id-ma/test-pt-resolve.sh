#!/usr/bin/env bash
#
# 用途: Issue #164 で改修した `pt_resolve_diff_range` の単記 / 連記 / 誤マッチ抑止
#       挙動を fixture 付きで検証するスモークスクリプト。
# 配置: docs/specs/164-bug-watcher-per-task-reviewer-task-id-ma/test-pt-resolve.sh
# 依存: bash 4+, git, sed, tr
# セットアップ参照先: docs/specs/164-bug-watcher-per-task-reviewer-task-id-ma/impl-notes.md
#
# 実行:
#   ./docs/specs/164-bug-watcher-per-task-reviewer-task-id-ma/test-pt-resolve.sh
# 出力:
#   各ケース: `[OK]` / `[NG]` の prefix で 1 行レポート
#   末尾: `SMOKE_RESULT: pass` / `SMOKE_RESULT: fail`
# 副作用:
#   /tmp/pt-resolve-smoke-XXXX/ に一時 git repo を作成し、終了時に削除する

set -euo pipefail

# ─── pt_resolve_diff_range の参照実装（issue-watcher.sh から抽出 / 検証用） ───
# 本関数は local-watcher/bin/issue-watcher.sh の pt_resolve_diff_range と **同一実装**
# でなければならない。差分が出た場合は impl 側を本 fixture に再同期すること。
BASE_BRANCH="${BASE_BRANCH:-main}"

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

# ─── テストハーネス ───
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

assert_fail() {
  local label="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    echo "[OK]   ${label} (rc=${rc} as expected)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "[NG]   ${label} (expected non-zero rc but got 0)" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# ─── fixture セットアップ ───
TMPDIR=$(mktemp -d /tmp/pt-resolve-smoke-XXXX)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
git init -q -b main
git config user.email smoke@example.com
git config user.name smoke

# main の初期 commit
echo init > README.md
git add README.md
git commit -q -m "initial commit"
MAIN_SHA=$(git rev-parse main)

# ─── ケース 1: 単記 marker のみのリポジトリ（既存挙動 / Req 3.1 後方互換） ───
git checkout -q -b case1-single-only
echo a > task1.txt && git add task1.txt && git commit -q -m "feat: task 1 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1 as done"
C1_M1=$(git rev-parse HEAD)
echo b > task1_1.txt && git add task1_1.txt && git commit -q -m "feat: task 1.1 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1.1 as done"
C1_M11=$(git rev-parse HEAD)
echo c > task1_2.txt && git add task1_2.txt && git commit -q -m "feat: task 1.2 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1.2 as done"
C1_M12=$(git rev-parse HEAD)

# task 1 → range_start=MAIN, range_end=C1_M1
RES=$(pt_resolve_diff_range "1")
assert_eq "case1: task=1 (first single-id)" "${MAIN_SHA}	${C1_M1}" "$RES"

# task 1.1 → range_start=C1_M1, range_end=C1_M11
RES=$(pt_resolve_diff_range "1.1")
assert_eq "case1: task=1.1 (single-id chain middle)" "${C1_M1}	${C1_M11}" "$RES"

# task 1.2 → range_start=C1_M11, range_end=C1_M12
RES=$(pt_resolve_diff_range "1.2")
assert_eq "case1: task=1.2 (single-id chain tail)" "${C1_M11}	${C1_M12}" "$RES"

# 存在しない task 2 → rc=1
RC=0
pt_resolve_diff_range "2" > /dev/null 2>&1 || RC=$?
assert_fail "case1: task=2 (no marker found)" "$RC"

# ─── ケース 2: 連記 marker (` / ` 区切り) を含むリポジトリ (Req 2.2) ───
git checkout -q main
git checkout -q -b case2-multi-slash
echo a > t1.txt && git add t1.txt && git commit -q -m "feat: task 1 impl"
echo b > t11.txt && git add t11.txt && git commit -q -m "feat: task 1.1 impl"
echo c > t12.txt && git add t12.txt && git commit -q -m "feat: task 1.2 impl"
# 連記 marker (slash 区切り)
git commit -q --allow-empty -m "docs(tasks): mark 1 / 1.1 / 1.2 as done"
C2_MULTI=$(git rev-parse HEAD)

# 連記 marker に含まれる各 task ID が同一 SHA を返すこと (Req 2.3)
RES=$(pt_resolve_diff_range "1")
assert_eq "case2: task=1 via multi-id (slash)" "${MAIN_SHA}	${C2_MULTI}" "$RES"

RES=$(pt_resolve_diff_range "1.1")
assert_eq "case2: task=1.1 via multi-id (slash)" "${MAIN_SHA}	${C2_MULTI}" "$RES"

RES=$(pt_resolve_diff_range "1.2")
assert_eq "case2: task=1.2 via multi-id (slash)" "${MAIN_SHA}	${C2_MULTI}" "$RES"

# False positive 抑止: task=11 / task=2 は不在 (Req 2.5)
RC=0
pt_resolve_diff_range "11" > /dev/null 2>&1 || RC=$?
assert_fail "case2: task=11 (false positive guard: '11' should NOT match '1' or '1.1')" "$RC"

RC=0
pt_resolve_diff_range "2" > /dev/null 2>&1 || RC=$?
assert_fail "case2: task=2 (absent ID)" "$RC"

# ─── ケース 3: 連記 marker (`, ` 区切り) を含むリポジトリ (Req 2.2 alternate sep) ───
git checkout -q main
git checkout -q -b case3-multi-comma
echo a > a.txt && git add a.txt && git commit -q -m "feat: task 1 + 1.1 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1, 1.1 as done"
C3_MULTI=$(git rev-parse HEAD)

RES=$(pt_resolve_diff_range "1")
assert_eq "case3: task=1 via multi-id (comma)" "${MAIN_SHA}	${C3_MULTI}" "$RES"

RES=$(pt_resolve_diff_range "1.1")
assert_eq "case3: task=1.1 via multi-id (comma)" "${MAIN_SHA}	${C3_MULTI}" "$RES"

# False positive: task=1.2 (含まれていない)
RC=0
pt_resolve_diff_range "1.2" > /dev/null 2>&1 || RC=$?
assert_fail "case3: task=1.2 (absent in '1, 1.1')" "$RC"

# ─── ケース 4: 単記 + 連記 混在 (単記優先 / Req 2.4 deterministic) ───
git checkout -q main
git checkout -q -b case4-mixed
echo a > x.txt && git add x.txt && git commit -q -m "feat: task 1 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1 as done"
C4_SINGLE_1=$(git rev-parse HEAD)
echo b > y.txt && git add y.txt && git commit -q -m "feat: task 1.1 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1.1 as done"
C4_SINGLE_11=$(git rev-parse HEAD)
# その後に連記 marker (本来あってはならないが、混在ケースを意図的に作成)
echo c > z.txt && git add z.txt && git commit -q -m "feat: task 1.2 + 1.3 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1.2 / 1.3 as done"
C4_MULTI=$(git rev-parse HEAD)

# task=1: 単記マーカ優先で C4_SINGLE_1 を返す（連記マーカに `1` も含まれないが念のため確認）
RES=$(pt_resolve_diff_range "1")
assert_eq "case4: task=1 single-id-prefer (first single)" "${MAIN_SHA}	${C4_SINGLE_1}" "$RES"

# task=1.1: 単記マーカで C4_SINGLE_11
RES=$(pt_resolve_diff_range "1.1")
assert_eq "case4: task=1.1 single-id-prefer (mid single)" "${C4_SINGLE_1}	${C4_SINGLE_11}" "$RES"

# task=1.2: 連記マーカでヒット (C4_MULTI), range_start=C4_SINGLE_11
RES=$(pt_resolve_diff_range "1.2")
assert_eq "case4: task=1.2 via multi-id (fallback)" "${C4_SINGLE_11}	${C4_MULTI}" "$RES"

# task=1.3: 連記マーカでヒット (同一 SHA), range_start=C4_SINGLE_11
RES=$(pt_resolve_diff_range "1.3")
assert_eq "case4: task=1.3 via multi-id (fallback same SHA)" "${C4_SINGLE_11}	${C4_MULTI}" "$RES"

# ─── ケース 5: marker commit 全く無し ───
git checkout -q main
git checkout -q -b case5-empty
echo a > only.txt && git add only.txt && git commit -q -m "feat: task without marker"

RC=0
pt_resolve_diff_range "1" > /dev/null 2>&1 || RC=$?
assert_fail "case5: no marker commit at all (diff-range-resolve-failed expected)" "$RC"

# ─── ケース 6: 単記 + 連記 で当該 task ID が両方に出現する場合 (Req 2.4) ───
git checkout -q main
git checkout -q -b case6-overlap
echo a > o1.txt && git add o1.txt && git commit -q -m "feat: task 1 impl"
git commit -q --allow-empty -m "docs(tasks): mark 1 as done"
C6_SINGLE_1=$(git rev-parse HEAD)
echo b > o11.txt && git add o11.txt && git commit -q -m "feat: task 1.1 impl"
# 後から重複した連記マーカが入った仮定: `1, 1.1` (1 が連記マーカにも出現)
git commit -q --allow-empty -m "docs(tasks): mark 1, 1.1 as done"
C6_MULTI=$(git rev-parse HEAD)

# task=1: 単記が優先採用される (Req 2.4 deterministic)
# 単記は C6_SINGLE_1 で先に出現、range_start=MAIN_SHA, range_end=C6_SINGLE_1
RES=$(pt_resolve_diff_range "1")
assert_eq "case6: task=1 overlap (single preferred over multi)" "${MAIN_SHA}	${C6_SINGLE_1}" "$RES"

# task=1.1: 単記不在のため連記マーカで解決 (C6_MULTI)
RES=$(pt_resolve_diff_range "1.1")
assert_eq "case6: task=1.1 (multi-id fallback after overlap)" "${C6_SINGLE_1}	${C6_MULTI}" "$RES"

# ─── 結果集計 ───
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
