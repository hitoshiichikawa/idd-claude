#!/usr/bin/env bash
#
# 用途: Issue #166 で追加した「per-task ループ起動判定（tasks.md 不在時の Stage A
#       フォールバック）」の分岐挙動を fixture 付きで検証するスモークスクリプト。
# 配置: docs/specs/166-bug-watcher-per-task-loop-enabled-impl-m/test-pt-fallback.sh
# 依存: bash 4+
# セットアップ参照先: docs/specs/166-bug-watcher-per-task-loop-enabled-impl-m/impl-notes.md
#
# 実行:
#   ./docs/specs/166-bug-watcher-per-task-loop-enabled-impl-m/test-pt-fallback.sh
# 出力:
#   各ケース: `[OK]` / `[NG]` の prefix で 1 行レポート
#   末尾: `SMOKE_RESULT: pass` / `SMOKE_RESULT: fail`
# 副作用:
#   /tmp/pt-fallback-smoke-XXXX/ に一時ディレクトリ（tasks.md fixture）を作成し、
#   終了時に削除する

set -euo pipefail

# ─── 判定ロジックの参照実装（issue-watcher.sh の run_impl_pipeline() Stage A 分岐から抽出） ───
# 本関数は local-watcher/bin/issue-watcher.sh の `case "$START_STAGE" in A)` 分岐の
# per-task ループ起動判定と **同一ロジック**でなければならない。差分が出た場合は impl 側を
# 本 fixture に再同期すること。
#
# 引数:
#   $1 = PER_TASK_LOOP_ENABLED の値（"true" / "false" / "" / 任意文字列）
#   $2 = tasks.md の絶対パス
# stdout:
#   "per-task-loop"       — per-task ループへ入る（tasks.md あり + flag=true）
#   "stage-a-fallback"    — flag=true だが tasks.md 不在 → 従来 Stage A へフォールバック
#   "stage-a-traditional" — flag 未指定 / true 以外 → 従来 Stage A 経路（fallback ログなし）
# 副作用:
#   fallback 経路では stderr に AC5 のフォールバックログ行を出力する
resolve_stage_a_route() {
  local per_task_loop_enabled="$1"
  local tasks_md="$2"

  local _pt_loop_enabled=false
  if [ "${per_task_loop_enabled:-false}" = "true" ]; then
    if [ -f "$tasks_md" ]; then
      _pt_loop_enabled=true
    else
      # AC5: フォールバック発生を判別可能なログ行を出力（claude-failed は付けない）
      echo "--- per-task: tasks.md 不在 → Stage A fallback（$tasks_md）---" >&2
      echo "stage-a-fallback"
      return 0
    fi
  fi

  if [ "$_pt_loop_enabled" = "true" ]; then
    echo "per-task-loop"
  else
    echo "stage-a-traditional"
  fi
}

# ─── テストハーネス ───
WORKDIR="$(mktemp -d /tmp/pt-fallback-smoke-XXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

TASKS_PRESENT="$WORKDIR/with-tasks/tasks.md"
TASKS_ABSENT="$WORKDIR/no-tasks/tasks.md"
mkdir -p "$WORKDIR/with-tasks" "$WORKDIR/no-tasks"
cat > "$TASKS_PRESENT" <<'EOF'
- [ ] 1. サンプルタスク
  - _Requirements: 1.1_
EOF

FAIL=0
assert_route() {
  local desc="$1" enabled="$2" tasks_md="$3" expected="$4"
  local got
  got=$(resolve_stage_a_route "$enabled" "$tasks_md" 2>/dev/null)
  if [ "$got" = "$expected" ]; then
    echo "[OK] $desc (route=$got)"
  else
    echo "[NG] $desc (expected=$expected got=$got)"
    FAIL=1
  fi
}

assert_fallback_log() {
  local desc="$1" enabled="$2" tasks_md="$3"
  local stderr
  stderr=$(resolve_stage_a_route "$enabled" "$tasks_md" 2>&1 >/dev/null)
  if printf '%s' "$stderr" | grep -q 'per-task: tasks.md 不在 → Stage A fallback'; then
    echo "[OK] $desc (fallback ログ行を検出)"
  else
    echo "[NG] $desc (fallback ログ行が出力されていない: '$stderr')"
    FAIL=1
  fi
}

assert_no_fallback_log() {
  local desc="$1" enabled="$2" tasks_md="$3"
  local stderr
  stderr=$(resolve_stage_a_route "$enabled" "$tasks_md" 2>&1 >/dev/null)
  if printf '%s' "$stderr" | grep -q 'Stage A fallback'; then
    echo "[NG] $desc (不要な fallback ログが出力された: '$stderr')"
    FAIL=1
  else
    echo "[OK] $desc (fallback ログなし)"
  fi
}

echo "=== Issue #166 per-task ループ Stage A フォールバック判定スモーク ==="

# AC1: flag=true + tasks.md 不在 → Stage A フォールバック（claude-failed なし）
assert_route "AC1: flag=true + tasks.md 不在 → Stage A fallback" "true" "$TASKS_ABSENT" "stage-a-fallback"
# AC5/Req3.1: フォールバック発生時は判別可能なログ行を出力
assert_fallback_log "AC5: フォールバック発生時に判別可能ログ行" "true" "$TASKS_ABSENT"

# AC3 / NFR1.2: flag=true + tasks.md あり → per-task ループ（挙動不変）
assert_route "AC3: flag=true + tasks.md あり → per-task loop" "true" "$TASKS_PRESENT" "per-task-loop"
# per-task ループ起動時はフォールバックログを出さない
assert_no_fallback_log "AC3: per-task loop 起動時は fallback ログなし" "true" "$TASKS_PRESENT"

# NFR1.1: flag 未指定（空） → 従来 Stage A 経路（tasks.md の有無に関わらず）
assert_route "NFR1.1: flag 空 + tasks.md あり → 従来 Stage A" "" "$TASKS_PRESENT" "stage-a-traditional"
assert_route "NFR1.1: flag 空 + tasks.md 不在 → 従来 Stage A" "" "$TASKS_ABSENT" "stage-a-traditional"
assert_no_fallback_log "NFR1.1: flag 空時は fallback ログなし" "" "$TASKS_ABSENT"

# NFR1.1: flag=false → 従来 Stage A 経路
assert_route "NFR1.1: flag=false + tasks.md あり → 従来 Stage A" "false" "$TASKS_PRESENT" "stage-a-traditional"
assert_route "NFR1.1: flag=false + tasks.md 不在 → 従来 Stage A" "false" "$TASKS_ABSENT" "stage-a-traditional"

# NFR1.1: flag=厳密一致以外（typo / True / 1） → 従来 Stage A 経路
assert_route "NFR1.1: flag=True（大文字）→ 従来 Stage A" "True" "$TASKS_PRESENT" "stage-a-traditional"
assert_route "NFR1.1: flag=1 → 従来 Stage A" "1" "$TASKS_PRESENT" "stage-a-traditional"
assert_no_fallback_log "NFR1.1: flag=True 時は fallback ログなし" "True" "$TASKS_ABSENT"

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "SMOKE_RESULT: pass"
  exit 0
else
  echo "SMOKE_RESULT: fail"
  exit 1
fi
