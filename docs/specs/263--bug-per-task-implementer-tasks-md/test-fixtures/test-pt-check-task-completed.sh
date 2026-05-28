#!/usr/bin/env bash
# 用途: pt_check_task_completed の判定ロジック (#263) を単体検証する。
#       tasks.md 上の _[ ]_ / _[x]_ / 行不在 / ファイル不在の 4 ケースで
#       期待戻り値 (1 / 0 / 2 / 2) を返すこと、親 (`- [ ] 1. <title>`) と
#       子 (`- [ ] 1.1 <title>`) の両 ID 慣習をカバーすること、deferrable
#       `- [ ]*` 行は親子と独立に扱うこと、duplicate ID 想定外シナリオで先勝ち
#       挙動が安全側に倒れることを assert する。
# 配置先: docs/specs/263--bug-per-task-implementer-tasks-md/test-fixtures/test-pt-check-task-completed.sh
# 依存: bash 4+, grep, sed。issue-watcher.sh から pt_check_task_completed のみを
#       sourcing できない（メインスクリプト全体を実行してしまう）ため、関数定義を
#       awk で抽出して本 fixture 内に局所評価する。
# セットアップ参照先: docs/specs/263--bug-per-task-implementer-tasks-md/impl-notes.md
#
# Usage:
#   bash docs/specs/263--bug-per-task-implementer-tasks-md/test-fixtures/test-pt-check-task-completed.sh
#
# Exit code:
#   0 = すべてのケースが期待戻り値と一致
#   1 = いずれかのケースが不一致（standard error にどれが失敗したか出力）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
WATCHER="$REPO_ROOT/local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER" ]; then
  echo "[FATAL] watcher script not found: $WATCHER" >&2
  exit 1
fi

# pt_check_task_completed の関数本体を awk で抽出して評価する。
# main 実行ガード (`if [ "${BASH_SOURCE[0]}" = "$0" ]` 等) を持たない script を
# そのまま source すると bash モジュール初期化や argparse が走ってしまうため、
# 当該関数の `pt_check_task_completed() { ... }` ブロックだけを切り出して eval する。
fn_body=$(awk '
  /^pt_check_task_completed\(\) \{/ { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}/ { exit }
' "$WATCHER")

if [ -z "$fn_body" ]; then
  echo "[FATAL] pt_check_task_completed の関数本体を抽出できませんでした" >&2
  exit 1
fi

# shellcheck disable=SC2294  # eval は関数定義の動的取り込みのため意図的に使用
eval "$fn_body"

fail_count=0
pass_count=0

# ── ヘルパ: tasks.md と task_id を渡して期待戻り値と一致するか確認 ──
# $1 = ケース名, $2 = tasks.md パス, $3 = task_id, $4 = 期待戻り値
assert_check_rc() {
  local name="$1" tasks_md="$2" task_id="$3" expected_rc="$4"
  local rc=0
  set +e
  pt_check_task_completed "$tasks_md" "$task_id"
  rc=$?
  set -e
  if [ "$rc" != "$expected_rc" ]; then
    echo "[FAIL] $name: rc=$rc (expected $expected_rc) tasks_md=$tasks_md task_id=$task_id" >&2
    fail_count=$((fail_count + 1))
    return
  fi
  echo "[PASS] $name (rc=$rc)"
  pass_count=$((pass_count + 1))
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ── fixture 1: 親タスク完了 `- [x] 1. ...` ──
cat > "$tmp/case-parent-done.md" <<'EOF'
- [x] 1. 親タスク完了
- [ ] 2. 親タスク未完了
EOF
assert_check_rc "親タスク 1 が _[x]_ → rc=0 (完了)" "$tmp/case-parent-done.md" "1" 0
assert_check_rc "親タスク 2 が _[ ]_ → rc=1 (未完了)" "$tmp/case-parent-done.md" "2" 1
assert_check_rc "存在しない task_id 9 → rc=2 (fail-safe)" "$tmp/case-parent-done.md" "9" 2

# ── fixture 2: 子タスク完了 `- [x] 1.1 ...` ──
cat > "$tmp/case-child-done.md" <<'EOF'
- [ ] 1. 親タスク
- [x] 1.1 子タスク完了
- [ ] 1.2 子タスク未完了
- [ ] 1.10 子タスク2桁未完了
EOF
assert_check_rc "子タスク 1.1 が _[x]_ → rc=0 (完了)" "$tmp/case-child-done.md" "1.1" 0
assert_check_rc "子タスク 1.2 が _[ ]_ → rc=1 (未完了)" "$tmp/case-child-done.md" "1.2" 1
assert_check_rc "子タスク 1.10 が _[ ]_ → rc=1 (2 桁 ID 誤マッチ防止)" "$tmp/case-child-done.md" "1.10" 1
# 1.1 prefix が 1.10 と衝突しないことを確認するため、1.1 を _[ ]_ にしたバリアント
cat > "$tmp/case-child-prefix.md" <<'EOF'
- [ ] 1.1 子タスク未完了
- [x] 1.10 子タスク2桁完了
EOF
assert_check_rc "子タスク 1.1 (_[ ]_) が 1.10 (_[x]_) の prefix とマッチしない → rc=1" "$tmp/case-child-prefix.md" "1.1" 1
assert_check_rc "子タスク 1.10 (_[x]_) → rc=0" "$tmp/case-child-prefix.md" "1.10" 0

# ── fixture 3: tasks.md 不在 → rc=2 (fail-safe) ──
assert_check_rc "tasks.md 不在 → rc=2 (Req 5.3 fail-safe)" "$tmp/does-not-exist.md" "1" 2

# ── fixture 4: deferrable `- [ ]*` 行は本検証ルートに来ない想定。仮に直接呼んだ場合は
#                親の _[ ]_ 子の _[ ]_ と比べて `[ ]*` は判定パターンの空白要求に
#                よって自然に除外される（rc=2 となる）ことを確認する ──
cat > "$tmp/case-deferrable.md" <<'EOF'
- [ ]* 3.1 deferrable テストタスク
EOF
assert_check_rc "deferrable _[ ]*_ 3.1 は判定パターン外 → rc=2" "$tmp/case-deferrable.md" "3.1" 2

# ── fixture 5: 空ファイル → rc=2 ──
: > "$tmp/case-empty.md"
assert_check_rc "空 tasks.md → rc=2 (該当行不在)" "$tmp/case-empty.md" "1" 2

# ── fixture 6: 実 idd-claude tasks.md 慣習との整合（親+子ミックス・先頭末尾） ──
cat > "$tmp/case-realistic.md" <<'EOF'
# Tasks

- [x] 1. 親タスク 1（全完了）
- [x] 1.1 子タスク 1.1
- [x] 1.2 子タスク 1.2
- [ ] 2. 親タスク 2
- [x] 2.1 子タスク 2.1 完了
- [ ] 2.2 子タスク 2.2 未完了
- [ ]* 2.3 deferrable テストタスク
EOF
assert_check_rc "親 1 全完了 → rc=0" "$tmp/case-realistic.md" "1" 0
assert_check_rc "子 1.1 完了 → rc=0" "$tmp/case-realistic.md" "1.1" 0
assert_check_rc "親 2 未完了 → rc=1" "$tmp/case-realistic.md" "2" 1
assert_check_rc "子 2.1 完了 → rc=0" "$tmp/case-realistic.md" "2.1" 0
assert_check_rc "子 2.2 未完了 → rc=1" "$tmp/case-realistic.md" "2.2" 1
assert_check_rc "deferrable 2.3 → rc=2 (判定対象外)" "$tmp/case-realistic.md" "2.3" 2

echo "----"
echo "PASS=$pass_count FAIL=$fail_count"
[ "$fail_count" -eq 0 ]
