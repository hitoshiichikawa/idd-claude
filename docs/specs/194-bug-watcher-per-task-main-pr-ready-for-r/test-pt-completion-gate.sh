#!/usr/bin/env bash
#
# 用途: Issue #194 で追加した「per-task ループ全 task 完了ゲート」の判定挙動を
#       fixture 付きで検証するスモークスクリプト。`run_per_task_loop` が return 0
#       した直後に tasks.md を再読込し、必須未完了 task が残れば ready-for-review へ
#       進めず resumable 中断する判定の正しさを確認する。
# 配置: docs/specs/194-bug-watcher-per-task-main-pr-ready-for-r/test-pt-completion-gate.sh
# 依存: bash 4+, grep, sed, sort, wc
# セットアップ参照先: docs/specs/194-bug-watcher-per-task-main-pr-ready-for-r/impl-notes.md
#
# 実行:
#   ./docs/specs/194-bug-watcher-per-task-main-pr-ready-for-r/test-pt-completion-gate.sh
# 出力:
#   各ケース: `[OK]` / `[NG]` の prefix で 1 行レポート
#   末尾: `SMOKE_RESULT: pass` / `SMOKE_RESULT: fail`
# 副作用:
#   /tmp/pt-completion-gate-XXXX/ に一時ディレクトリ（tasks.md fixture）を作成し、
#   終了時に削除する

set -euo pipefail

# ─── pt_extract_pending_tasks の参照実装 ───
# 本関数は local-watcher/bin/issue-watcher.sh の `pt_extract_pending_tasks()` と
# **同一ロジック**でなければならない。差分が出た場合は impl 側を本 fixture に再同期すること。
# `- [ ]` (必須未完了) のみ抽出し、`- [ ]*` (deferrable) と `- [x]` (完了) は除外する。
pt_extract_pending_tasks() {
  local tasks_md="$1"
  if [ ! -f "$tasks_md" ]; then
    return 1
  fi
  grep -E '^- \[ \] [0-9]+(\.[0-9]+)*\.? ' "$tasks_md" \
    | sed -E 's/^- \[ \] ([0-9]+(\.[0-9]+)*)\.? .*/\1/' \
    | sort -V
  return 0
}

# ─── 完了ゲート判定の参照実装（issue-watcher.sh の run_impl_pipeline() per-task 分岐から抽出） ───
# `run_per_task_loop` の return 0 後、tasks.md を再読込して必須未完了 task の有無で分岐する。
#
# 引数:
#   $1 = tasks.md の絶対パス
# stdout:
#   "ready-for-review" — 必須未完了 task が 0 件 → Stage A 完了 → Reviewer/PR/ready-for-review へ進む
#   "hold-resumable"   — 必須未完了 task が 1 件以上 → ready-for-review 保留、後続 tick で再開
resolve_pt_completion_gate() {
  local tasks_md="$1"
  local _pt_remaining
  _pt_remaining=$(pt_extract_pending_tasks "$tasks_md" || true)
  if [ -n "$_pt_remaining" ]; then
    echo "hold-resumable"
  else
    echo "ready-for-review"
  fi
}

# ─── テストハーネス ───
WORKDIR="$(mktemp -d /tmp/pt-completion-gate-XXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# fixture 1: 全 task 完了（必須未完了 0 件）→ ready-for-review
F_ALL_DONE="$WORKDIR/all-done.md"
cat > "$F_ALL_DONE" <<'EOF'
- [x] 1. 設計反映
  - _Requirements: 1.1_
- [x] 2. 実装
  - _Requirements: 1.2_
- [x] 2.1 子タスク
  - _Requirements: 1.3_
EOF

# fixture 2: 後続 task 未完了が残る（PR #189 の事故再現: task 1 のみ完了）→ hold-resumable
F_PARTIAL="$WORKDIR/partial.md"
cat > "$F_PARTIAL" <<'EOF'
- [x] 1. task 1 完了
  - _Requirements: 1.1_
- [ ] 2. task 2 未完了
  - _Requirements: 1.2_
- [ ] 3. task 3 未完了
  - _Requirements: 1.3_
EOF

# fixture 3: 必須は全完了で deferrable テストタスクのみ残る → ready-for-review (Req 1.3)
F_DEFERRABLE_ONLY="$WORKDIR/deferrable-only.md"
cat > "$F_DEFERRABLE_ONLY" <<'EOF'
- [x] 1. 実装
  - _Requirements: 1.1_
- [ ]* 1.1 統合テスト追加（deferrable）
  - _Requirements: 1.1_
EOF

# fixture 4: 子タスク 1.1 が未完了で残る → hold-resumable（子タスクも必須 task として数える）
F_CHILD_PENDING="$WORKDIR/child-pending.md"
cat > "$F_CHILD_PENDING" <<'EOF'
- [x] 1. 親タスク
  - _Requirements: 1.1_
- [x] 1.1 子タスク完了
  - _Requirements: 1.1_
- [ ] 1.2 子タスク未完了
  - _Requirements: 1.2_
EOF

FAIL=0
assert_gate() {
  local desc="$1" tasks_md="$2" expected="$3"
  local got
  got=$(resolve_pt_completion_gate "$tasks_md")
  if [ "$got" = "$expected" ]; then
    echo "[OK] $desc (gate=$got)"
  else
    echo "[NG] $desc (expected=$expected got=$got)"
    FAIL=1
  fi
}

assert_count() {
  local desc="$1" tasks_md="$2" expected="$3"
  local pending count
  pending=$(pt_extract_pending_tasks "$tasks_md" || true)
  if [ -z "$pending" ]; then
    count=0
  else
    count=$(printf '%s\n' "$pending" | wc -l | tr -d '[:space:]')
  fi
  if [ "$count" = "$expected" ]; then
    echo "[OK] $desc (count=$count)"
  else
    echo "[NG] $desc (expected=$expected got=$count)"
    FAIL=1
  fi
}

echo "=== Issue #194 per-task ループ全 task 完了ゲート判定スモーク ==="

# Req 1.2 / 2.5: 全 task 完了 → ready-for-review へ進む
assert_gate "Req1.2: 全 task 完了 → ready-for-review" "$F_ALL_DONE" "ready-for-review"
assert_count "Req1.2: 全 task 完了時の必須未完了 count=0" "$F_ALL_DONE" "0"

# Req 1.1 / 1.4 / 1.5: 後続 task 未完了残存（PR #189 再現） → ready-for-review 保留
assert_gate "Req1.1: 後続 task 未完了残存 → hold-resumable" "$F_PARTIAL" "hold-resumable"
assert_count "Req1.5: 後続 task 未完了残存時の件数記録 count=2" "$F_PARTIAL" "2"

# Req 1.3: deferrable のみ残る → ready-for-review へ進む（deferrable は未完了扱いしない）
assert_gate "Req1.3: deferrable のみ残 → ready-for-review" "$F_DEFERRABLE_ONLY" "ready-for-review"
assert_count "Req1.3: deferrable は必須未完了に数えない count=0" "$F_DEFERRABLE_ONLY" "0"

# Req 1.1: 子タスク未完了が残る → 保留（子タスクも必須 task）
assert_gate "Req1.1: 子タスク未完了残 → hold-resumable" "$F_CHILD_PENDING" "hold-resumable"
assert_count "Req1.1: 子タスク未完了の件数 count=1" "$F_CHILD_PENDING" "1"

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "SMOKE_RESULT: pass"
  exit 0
else
  echo "SMOKE_RESULT: fail"
  exit 1
fi
