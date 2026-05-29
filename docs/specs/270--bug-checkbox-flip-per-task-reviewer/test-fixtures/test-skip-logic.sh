#!/usr/bin/env bash
# Issue #270 / Reviewer skip 判定ロジックのスモークテスト
#
# 対象関数:
#   - pt_has_subtasks <tasks_md> <task_id>
#   - pt_is_parent_checkbox_only_diff <task_id> <range_start> <range_end>
#   - pt_should_skip_reviewer <task_id>（dispatcher: pt_resolve_diff_range も内部で利用）
#
# 検証ケース:
#   A. pt_has_subtasks: 親 / 子 / 末端 / deferrable 子 / 完了済み親 / 不在 task_id / file 不在
#   B. pt_is_parent_checkbox_only_diff: 親タスク + tasks.md only / 他ファイル混入 /
#      tasks.md 内に他編集混入 / 空 diff / 範囲不正
#   C. pt_should_skip_reviewer (E2E): 親 + checkbox-only / 子 + checkbox-only /
#      親 + 実装差分混入 / 通常タスク
#
# 使い方: 本リポジトリ root から `bash docs/specs/270--bug-checkbox-flip-per-task-reviewer/test-fixtures/test-skip-logic.sh`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WATCHER_SH="$REPO_ROOT/local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "❌ issue-watcher.sh not found at: $WATCHER_SH" >&2
  exit 1
fi

# 関数定義のみを抽出するための実行スコープ。issue-watcher.sh の冒頭処理（init / claim 等）を
# 起動しないよう、source ではなく awk で関数定義部分のみを抽出して eval する。
# ただし依存関数が多すぎるため、別アプローチで関数を直接実装ファイルから source する。
# 冒頭で main 処理が走ると副作用が大きいため、SOURCE_ONLY モードを使わず、
# 関数を bash subshell で利用するために、`bash -c` でラッパを書く。

# 一時 git repo を作成し、その中で関数を実行する。
TMPDIR_BASE=$(mktemp -d /tmp/idd-270-test.XXXXXX)
HELPERS_SH="/tmp/idd-270-helpers-$$.sh"
LOG="/tmp/idd-270-log-$$.log"
trap 'rm -rf "$TMPDIR_BASE" "$HELPERS_SH" "$LOG"' EXIT

cd "$TMPDIR_BASE"
git init -q .
git config user.email "test@example.com"
git config user.name "Test User"

mkdir -p docs/specs/270-fixture
TASKS_MD_REL="docs/specs/270-fixture/tasks.md"
TASKS_MD_ABS="$TMPDIR_BASE/$TASKS_MD_REL"

# 初期 tasks.md（未完了状態）
cat > "$TASKS_MD_ABS" <<'EOF'
# Tasks

- [ ] 1. 親タスク（子を持つ）
- [ ] 1.1 子タスク A
  - _Requirements: 1.1_
- [ ] 1.2 子タスク B
  - _Requirements: 1.2_
- [ ] 2. 単独タスク（子を持たない）
  - _Requirements: 2.1_
- [ ] 3. もう一つの親タスク
- [ ]* 3.1 deferrable な子タスク
  - _Requirements: 3.1_
EOF

git add -A
git commit -q -m "chore: initial tasks.md"
BASE_SHA=$(git rev-parse HEAD)
git branch -M main
git checkout -q -b work

# ---- ヘルパー関数を抽出して subshell に流し込む ----
# issue-watcher.sh 全体を source すると main が走るので、関数定義のみを抽出する。
# 簡易方針: bash の `set -n` + `compgen` を使う代わりに、必要な関数定義ブロックを sed で抜き出す。
# pt_log / pt_warn / pt_has_subtasks / pt_is_parent_checkbox_only_diff / pt_resolve_diff_range /
# pt_should_skip_reviewer を抽出。

# 関数定義抽出関数: 関数名 → 関数本体（最初の `^<name>() {` から対応する `^}` まで）
extract_fn() {
  local fn="$1"
  awk -v fn="$fn" '
    $0 ~ ("^" fn "\\(\\) \\{$") { capture=1 }
    capture { print }
    capture && /^\}$/ { capture=0; exit }
  ' "$WATCHER_SH"
}

# 必要な関数群を一時ファイルに集約
HELPERS_SH="/tmp/idd-270-helpers-$$.sh"
{
  echo "#!/usr/bin/env bash"
  echo "set -euo pipefail"
  extract_fn pt_log
  extract_fn pt_warn
  extract_fn pt_has_subtasks
  extract_fn pt_resolve_diff_range
  extract_fn pt_is_parent_checkbox_only_diff
  extract_fn pt_should_skip_reviewer
} > "$HELPERS_SH"

# 抽出確認
for fn in pt_log pt_warn pt_has_subtasks pt_resolve_diff_range pt_is_parent_checkbox_only_diff pt_should_skip_reviewer; do
  if ! grep -q "^${fn}() {" "$HELPERS_SH"; then
    echo "❌ extract failed: $fn" >&2
    exit 1
  fi
done

# 共通環境変数
export REPO_DIR="$TMPDIR_BASE"
export SPEC_DIR_REL="docs/specs/270-fixture"
export BASE_BRANCH="main"
export LOG
: > "$LOG"

# ==========================================================================
# テストフレームワーク
# ==========================================================================
PASS=0
FAIL=0
run_test() {
  local name="$1"
  local expected_rc="$2"
  shift 2
  local actual_rc=0
  # shellcheck disable=SC2086
  ( bash -c "set -euo pipefail; source '$HELPERS_SH'; $*" ) >/dev/null 2>&1 || actual_rc=$?
  if [ "$actual_rc" = "$expected_rc" ]; then
    echo "  ✅ $name (rc=$actual_rc)"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name (expected rc=$expected_rc, got rc=$actual_rc)"
    FAIL=$((FAIL + 1))
  fi
}

# ==========================================================================
# A. pt_has_subtasks のテスト
# ==========================================================================
echo "=== A. pt_has_subtasks ==="
run_test "親タスク '1' は子を持つ → rc=0" 0 \
  "pt_has_subtasks '$TASKS_MD_ABS' '1'"
run_test "親タスク '3' は deferrable 子を持つ → rc=0" 0 \
  "pt_has_subtasks '$TASKS_MD_ABS' '3'"
run_test "単独タスク '2' は子なし → rc=1" 1 \
  "pt_has_subtasks '$TASKS_MD_ABS' '2'"
run_test "子タスク '1.1' は孫なし → rc=1" 1 \
  "pt_has_subtasks '$TASKS_MD_ABS' '1.1'"
run_test "存在しない task_id '99' → rc=1" 1 \
  "pt_has_subtasks '$TASKS_MD_ABS' '99'"
run_test "tasks.md 不在 → rc=2 (fail-safe)" 2 \
  "pt_has_subtasks '/nonexistent/tasks.md' '1'"
run_test "task_id 空文字 → rc=2 (fail-safe)" 2 \
  "pt_has_subtasks '$TASKS_MD_ABS' ''"

# false positive チェック: task_id `1` が `11` や `1.1` を誤検出しないこと
cat > "/tmp/idd-270-false-pos-$$.md" <<'EOF'
- [ ] 1. 親 1
- [ ] 11. 別の親
EOF
run_test "false positive 防止: '1' は '11.' を子と認識しない → rc=1" 1 \
  "pt_has_subtasks '/tmp/idd-270-false-pos-$$.md' '1'"

# 完了済み子タスクも検出されること
cat > "/tmp/idd-270-mixed-$$.md" <<'EOF'
- [ ] 5. 親
- [x] 5.1 完了済み子
EOF
run_test "完了済み子タスクでも親判定成立 → rc=0" 0 \
  "pt_has_subtasks '/tmp/idd-270-mixed-$$.md' '5'"

# ==========================================================================
# B. pt_is_parent_checkbox_only_diff のテスト
# ==========================================================================
echo
echo "=== B. pt_is_parent_checkbox_only_diff ==="

# B-1: 親タスク 1 を `- [x]` 化する commit を作る（tasks.md only / checkbox flip のみ）
sed -i 's/^- \[ \] 1\. 親タスク（子を持つ）$/- [x] 1. 親タスク（子を持つ）/' "$TASKS_MD_ABS"
git add -A
git commit -q -m "docs(tasks): mark 1 as done"
SHA_FLIP_ONLY=$(git rev-parse HEAD)

run_test "B-1: 親 task_id=1 の checkbox flip のみ → rc=0 (skip)" 0 \
  "pt_is_parent_checkbox_only_diff '1' '$BASE_SHA' '$SHA_FLIP_ONLY'"

# B-2: 範囲不正
run_test "B-2: range_start 空 → rc=1" 1 \
  "pt_is_parent_checkbox_only_diff '1' '' '$SHA_FLIP_ONLY'"
run_test "B-3: task_id 空 → rc=1" 1 \
  "pt_is_parent_checkbox_only_diff '' '$BASE_SHA' '$SHA_FLIP_ONLY'"

# B-4: 別 task_id の checkbox flip（誤マッチしないこと）
run_test "B-4: task_id=2 を渡すと task_id=1 の flip にはマッチしない → rc=1" 1 \
  "pt_is_parent_checkbox_only_diff '2' '$BASE_SHA' '$SHA_FLIP_ONLY'"

# B-5: tasks.md 以外のファイル変更を含む（実装差分混入）
echo "implementation" > "$TMPDIR_BASE/src.txt"
git add -A
git commit -q -m "feat: 実装差分追加"
SHA_WITH_IMPL=$(git rev-parse HEAD)
run_test "B-5: tasks.md + src.txt 混在 → rc=1 (skip しない)" 1 \
  "pt_is_parent_checkbox_only_diff '1' '$BASE_SHA' '$SHA_WITH_IMPL'"

# B-6: tasks.md 内に他編集を含む（子タスクの flip 同居 = 親完了 + 子完了の連記レベル相当）
sed -i 's/^- \[ \] 1\.1 子タスク A$/- [x] 1.1 子タスク A/' "$TASKS_MD_ABS"
git add -A
git commit -q -m "docs(tasks): mark 1.1 as done"
SHA_MULTI_FLIP=$(git rev-parse HEAD)
# 範囲: SHA_WITH_IMPL..SHA_MULTI_FLIP は tasks.md のみだが、task_id=1 の flip は含まれず 1.1 のみ。
# task_id=1 のスキップ判定としては不成立。
run_test "B-6: task_id=1 を渡すが diff は 1.1 の flip のみ → rc=1" 1 \
  "pt_is_parent_checkbox_only_diff '1' '$SHA_WITH_IMPL' '$SHA_MULTI_FLIP'"

# B-7: 空 diff（同一 SHA 範囲）
run_test "B-7: 空 diff (同一 SHA) → rc=1" 1 \
  "pt_is_parent_checkbox_only_diff '1' '$SHA_FLIP_ONLY' '$SHA_FLIP_ONLY'"

# ==========================================================================
# C. pt_should_skip_reviewer (E2E dispatcher)
# ==========================================================================
echo
echo "=== C. pt_should_skip_reviewer (E2E) ==="

# C 用に新 worktree シナリオを構築。
# シナリオ:
#   - main: 初期 tasks.md（全 [ ]）
#   - work branch:
#     1. mark 1.1 as done (子タスク完了マーク)
#     2. mark 1.2 as done (子タスク完了マーク)
#     3. mark 1 as done (親タスク完了マーク = 本機能のスキップ対象)
#     4. mark 2 as done (単独タスク完了マーク = スキップ対象外)
TMPDIR_E2E=$(mktemp -d /tmp/idd-270-e2e.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE" "$TMPDIR_E2E" "$HELPERS_SH" "$LOG" "/tmp/idd-270-false-pos-$$.md" "/tmp/idd-270-mixed-$$.md"' EXIT

cd "$TMPDIR_E2E"
git init -q .
git config user.email "test@example.com"
git config user.name "Test User"

mkdir -p "docs/specs/270-fixture"
TASKS_E2E="$TMPDIR_E2E/docs/specs/270-fixture/tasks.md"
cat > "$TASKS_E2E" <<'EOF'
# Tasks

- [ ] 1. 親タスク（子を持つ）
- [ ] 1.1 子タスク A
  - _Requirements: 1.1_
- [ ] 1.2 子タスク B
  - _Requirements: 1.2_
- [ ] 2. 単独タスク（子を持たない）
  - _Requirements: 2.1_
EOF
git add -A
git commit -q -m "chore: initial"
git branch -M main
git checkout -q -b work

# 子 1.1 を完了 + 実装差分
echo "impl 1.1" > "$TMPDIR_E2E/impl-1-1.txt"
git add -A
git commit -q -m "feat: 子 1.1 実装"
sed -i 's/^- \[ \] 1\.1 子タスク A$/- [x] 1.1 子タスク A/' "$TASKS_E2E"
git add -A
git commit -q -m "docs(tasks): mark 1.1 as done"

# 子 1.2 を完了 + 実装差分
echo "impl 1.2" > "$TMPDIR_E2E/impl-1-2.txt"
git add -A
git commit -q -m "feat: 子 1.2 実装"
sed -i 's/^- \[ \] 1\.2 子タスク B$/- [x] 1.2 子タスク B/' "$TASKS_E2E"
git add -A
git commit -q -m "docs(tasks): mark 1.2 as done"

# 親 1 を完了（checkbox flip のみ）→ 本機能のスキップ対象
sed -i 's/^- \[ \] 1\. 親タスク（子を持つ）$/- [x] 1. 親タスク（子を持つ）/' "$TASKS_E2E"
git add -A
git commit -q -m "docs(tasks): mark 1 as done"

# 単独タスク 2 を完了 + 実装差分（スキップ対象外）
echo "impl 2" > "$TMPDIR_E2E/impl-2.txt"
git add -A
git commit -q -m "feat: 単独 2 実装"
sed -i 's/^- \[ \] 2\. 単独タスク（子を持たない）$/- [x] 2. 単独タスク（子を持たない）/' "$TASKS_E2E"
git add -A
git commit -q -m "docs(tasks): mark 2 as done"

export REPO_DIR="$TMPDIR_E2E"
export SPEC_DIR_REL="docs/specs/270-fixture"
export BASE_BRANCH="main"
export LOG
: > "$LOG"

cd "$TMPDIR_E2E"

run_test "C-1: 親タスク '1' (checkbox-only diff) → rc=0 (skip)" 0 \
  "cd '$TMPDIR_E2E' && pt_should_skip_reviewer '1'"
run_test "C-2: 子タスク '1.1' (実装差分混入) → rc=1 (run reviewer)" 1 \
  "cd '$TMPDIR_E2E' && pt_should_skip_reviewer '1.1'"
run_test "C-3: 子タスク '1.2' (実装差分混入) → rc=1 (run reviewer)" 1 \
  "cd '$TMPDIR_E2E' && pt_should_skip_reviewer '1.2'"
run_test "C-4: 単独タスク '2' (子なし) → rc=1 (run reviewer)" 1 \
  "cd '$TMPDIR_E2E' && pt_should_skip_reviewer '2'"

# C-5: 親タスクだが diff range 解決失敗（存在しない task_id）
run_test "C-5: 存在しない marker '99' → rc=1 (fail-safe)" 1 \
  "cd '$TMPDIR_E2E' && pt_should_skip_reviewer '99'"

# C-6: ログ出力確認: スキップ成立時のみログが出ること
LOG_BEFORE=$(wc -l < "$LOG" | tr -d '[:space:]')
( bash -c "set -euo pipefail; source '$HELPERS_SH'; cd '$TMPDIR_E2E'; pt_should_skip_reviewer '1' >> '$LOG'" ) || true
LOG_AFTER=$(wc -l < "$LOG" | tr -d '[:space:]')
if [ "$LOG_AFTER" -gt "$LOG_BEFORE" ] && grep -q "task=1 reviewer skipped reason=parent-task-checkbox-only-diff" "$LOG"; then
  echo "  ✅ C-6: スキップ成立時に grep 可能ログ出力"
  PASS=$((PASS + 1))
else
  echo "  ❌ C-6: ログ出力が期待形式と異なる"
  echo "    LOG_BEFORE=$LOG_BEFORE LOG_AFTER=$LOG_AFTER"
  echo "    LOG 内容:"
  cat "$LOG"
  FAIL=$((FAIL + 1))
fi

# C-7: スキップ不成立時はログを増やさない（NFR 2.3）
LOG_BEFORE2=$(wc -l < "$LOG" | tr -d '[:space:]')
( bash -c "set -euo pipefail; source '$HELPERS_SH'; cd '$TMPDIR_E2E'; pt_should_skip_reviewer '2' >> '$LOG'" ) || true
LOG_AFTER2=$(wc -l < "$LOG" | tr -d '[:space:]')
if [ "$LOG_AFTER2" = "$LOG_BEFORE2" ]; then
  echo "  ✅ C-7: スキップ不成立時にログ増えない (NFR 2.3)"
  PASS=$((PASS + 1))
else
  echo "  ❌ C-7: スキップ不成立時に新規ログが出ている"
  diff <(head -n "$LOG_BEFORE2" "$LOG") "$LOG" || true
  FAIL=$((FAIL + 1))
fi

# ==========================================================================
echo
echo "=========================================="
echo "Results: PASS=$PASS FAIL=$FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
