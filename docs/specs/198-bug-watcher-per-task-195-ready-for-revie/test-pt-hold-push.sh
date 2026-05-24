#!/usr/bin/env bash
#
# 用途: Issue #198 欠陥②（push-skip）の回帰テスト。per-task ループ全 task 完了ゲートが
#       必須未完了 task を検出して ready-for-review 遷移を保留する経路で、保留する **前に**
#       完了済み task の commit を origin へ push することを検証する。従来は保留 (return 0) が
#       後段の verify_pushed_or_retry より手前にあり、完了済み commit が未 push のまま次サイクルの
#       branch 再初期化（impl-resume の `git checkout -B "$BRANCH" "origin/$BRANCH"`）で失われ、
#       再 pickup されても task 1 からやり直す無限空転になっていた（#180 Part 2 実測）。
#       本テストは実 git リポジトリを用い、保留時 push により完了済み commit が origin に残り、
#       次サイクル reset 後も `- [x]` 進捗が温存されることを確認する。
# 配置: docs/specs/198-bug-watcher-per-task-195-ready-for-revie/test-pt-hold-push.sh
# 依存: bash 4+, git, grep, sed, sort
# セットアップ参照先: docs/specs/198-bug-watcher-per-task-195-ready-for-revie/impl-notes.md
#
# 実行:
#   ./docs/specs/198-bug-watcher-per-task-195-ready-for-revie/test-pt-hold-push.sh
# 出力:
#   各ケース: `[OK]` / `[NG]` の prefix で 1 行レポート
#   末尾: `SMOKE_RESULT: pass` / `SMOKE_RESULT: fail`
# 副作用:
#   /tmp/pt-hold-push-XXXX/ に一時 git リポジトリ群を作成し、終了時に削除する

set -euo pipefail

# ─── ラベル定数（issue-watcher.sh と同一名） ───
LABEL_CLAIMED="claude-claimed"
LABEL_PICKED="claude-picked-up"
REPO="owner/test"

ROOT="$(mktemp -d /tmp/pt-hold-push-XXXX)"
trap 'rm -rf "$ROOT"' EXIT

# ─── pt_extract_pending_tasks の参照実装（issue-watcher.sh と同一ロジック） ───
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

# ─── verify_pushed_or_retry の参照実装（issue-watcher.sh と同一方針） ───
# `@{u}..HEAD` の ahead 数を測り、>0 なら plain `git push origin <branch>` を 1 回試行する。
# 成功で 0、push 失敗で 1（本物では mark_issue_failed 相当）を返す。呼び出し記録を ORDER_LOG に
# `push` 行として残し、相対順序の検証を可能にする。
verify_pushed_or_retry() {
  local branch="$2"
  printf 'push\n' >> "$ORDER_LOG"
  local ahead
  ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo "unknown")
  if [ "$ahead" = "0" ]; then
    return 0
  fi
  if git push origin "$branch" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─── gh スタブ（保留時のラベル除去を模擬） ───
# 呼び出し引数を GH_LOG に、呼び出し順序を ORDER_LOG に `relabel` 行として残す。
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  printf 'relabel\n' >> "$ORDER_LOG"
  return 0
}

# ─── 完了ゲート（push → relabel → hold）の参照実装（issue-watcher.sh の新ロジックを抽出） ───
# 必須未完了が残れば: (a) 保留前に verify_pushed_or_retry で完了済み commit を origin に残す。
# push 失敗時はラベル除去（再 pickup 可能化）に進まず "failed" を返す（未 push のまま再 pickup
# すると空転が再発するため失敗に倒す / #198 欠陥②）。push 成功時のみ claude-picked-up /
# claude-claimed を除去して "hold-resumable" を返す。全 task 完了時も push を実行してから
# "ready-for-review" を返す（ラベル除去は呼ばない）。
#
# 引数: $1 = tasks.md の絶対パス, $2 = Issue 番号, $3 = branch
# stdout: "hold-resumable" | "ready-for-review" | "failed"
resolve_pt_completion_gate() {
  local tasks_md="$1" number="$2" branch="$3"
  local _pt_remaining
  _pt_remaining=$(pt_extract_pending_tasks "$tasks_md" || true)
  if [ -n "$_pt_remaining" ]; then
    if ! verify_pushed_or_retry "stageA-pt-hold-push-missing" "$branch" "Stage A (per-task loop hold)"; then
      echo "failed"
      return 0
    fi
    gh issue edit "$number" --repo "$REPO" \
      --remove-label "$LABEL_PICKED" \
      --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1 || true
    echo "hold-resumable"
    return 0
  fi
  if ! verify_pushed_or_retry "stageA-push-missing" "$branch" "Stage A (per-task loop)"; then
    echo "failed"
    return 0
  fi
  echo "ready-for-review"
  return 0
}

# ─── 実 git リポジトリのセットアップヘルパー ───
# bare origin + working clone を作り、main(base) と feature branch を push 済みにする。
# feature branch 上で task の commit を local に積む（origin へは push しない = 保留前の状態）。
# 出力（グローバル）: WORK（作業ディレクトリ）/ ORIGIN（bare origin）/ BRANCH。
BRANCH="claude/issue-198-test"
setup_repo() {
  local name="$1"
  ORIGIN="$ROOT/$name-origin.git"
  WORK="$ROOT/$name-work"
  git init --quiet --bare "$ORIGIN"
  # 空 bare repo の clone は "cloned an empty repository" を必ず stderr に出すため抑制する
  git clone --quiet "$ORIGIN" "$WORK" 2>/dev/null
  (
    cd "$WORK"
    git config user.email "t@example.com"
    git config user.name "test"
    git checkout -q -b main
    # base: 3 task すべて未完了の tasks.md
    cat > tasks.md <<'EOF'
- [ ] 1. task 1
  - _Requirements: 1.1_
- [ ] 2. task 2
  - _Requirements: 1.2_
- [ ] 3. task 3
  - _Requirements: 1.3_
EOF
    git add tasks.md
    git commit -q -m "chore: base tasks.md"
    git push -q origin main
    # feature branch を base から派生し push（upstream 設定）。origin tip = base のまま。
    git checkout -q -b "$BRANCH"
    git push -q -u origin "$BRANCH"
  )
}

# feature branch 上で task を 1 件完了させる local commit を積む（push はしない）。
mark_task_done_local() {
  local work="$1" task_id="$2"
  (
    cd "$work"
    sed -i -E "s/^- \[ \] ${task_id}\. /- [x] ${task_id}. /" tasks.md
    git add tasks.md
    git commit -q -m "docs(tasks): mark ${task_id} as done"
  )
}

FAIL=0
pass() { echo "[OK] $1"; }
fail() { echo "[NG] $1"; FAIL=1; }

echo "=== Issue #198 欠陥② (push-skip) 回帰スモーク ==="

# ── Case 1: 必須未完了残存 → 保留前に完了済み commit が origin に push される（Req 1.2/2.1/NFR3.1） ──
setup_repo "case1"
GH_LOG="$ROOT/case1-gh.log"; ORDER_LOG="$ROOT/case1-order.log"; : > "$GH_LOG"; : > "$ORDER_LOG"
mark_task_done_local "$WORK" 1
mark_task_done_local "$WORK" 2   # task1/2 完了・task3 未完了。HEAD は origin より ahead。
LOCAL_HEAD=$(cd "$WORK" && git rev-parse HEAD)
GOT=$(cd "$WORK" && resolve_pt_completion_gate "$WORK/tasks.md" 198 "$BRANCH")
if [ "$GOT" = "hold-resumable" ]; then
  pass "Req1.2: 必須未完了残存（task3）→ hold-resumable"
else
  fail "Req1.2: 必須未完了残存 → 期待 hold-resumable / 実際 $GOT"
fi
ORIGIN_HEAD=$(cd "$WORK" && git ls-remote origin "refs/heads/$BRANCH" | cut -f1)
if [ "$ORIGIN_HEAD" = "$LOCAL_HEAD" ]; then
  pass "Req2.1/NFR3.1: 保留時に完了済み task commit が origin/$BRANCH へ push される"
else
  fail "Req2.1/NFR3.1: origin/$BRANCH が完了済み commit を含まない（origin=$ORIGIN_HEAD / local=$LOCAL_HEAD）"
fi

# ── Case 1b: 次サイクル reset 後も完了済み task の `- [x]` 進捗が温存される（Req 2.1 冪等性） ──
# impl-resume の `git checkout -B "$BRANCH" "origin/$BRANCH"` を fresh clone で模擬する。
NEXT="$ROOT/case1-next"
git clone --quiet "$ORIGIN" "$NEXT" >/dev/null 2>&1
(
  cd "$NEXT"
  git checkout -q -B "$BRANCH" "origin/$BRANCH"
)
DONE_COUNT=$(grep -cE '^- \[x\] [12]\. ' "$NEXT/tasks.md" || true)
if [ "$DONE_COUNT" = "2" ]; then
  pass "Req2.1: 次サイクル reset 後も task1/2 の done マーカーが温存（completed task 再実行防止）"
else
  fail "Req2.1: 次サイクル reset 後に done マーカー進捗が失われた（残存 done=$DONE_COUNT / 期待 2）"
fi

# ── Case 2: push が relabel より前に実行される（ラベル除去前に commit を保護） ──
FIRST_TWO=$(head -2 "$ROOT/case1-order.log" | tr '\n' ',')
if [ "$FIRST_TWO" = "push,relabel," ]; then
  pass "順序: 保留経路で push → relabel の順に実行される（push 失敗時はラベル除去しない設計）"
else
  fail "順序: 期待 push,relabel, / 実際 $FIRST_TWO"
fi

# ── Case 3: push 失敗時は failed を返し、再 pickup 用ラベル除去を呼ばない（#198 欠陥②の安全側） ──
setup_repo "case3"
GH_LOG="$ROOT/case3-gh.log"; ORDER_LOG="$ROOT/case3-order.log"; : > "$GH_LOG"; : > "$ORDER_LOG"
mark_task_done_local "$WORK" 1   # ahead>0 の完了済み commit あり
(cd "$WORK" && git remote set-url origin "$ROOT/case3-nonexistent.git")  # push を失敗させる
GOT=$(cd "$WORK" && resolve_pt_completion_gate "$WORK/tasks.md" 198 "$BRANCH")
if [ "$GOT" = "failed" ]; then
  pass "Req2.1: push 失敗時は failed を返す（未 push のまま再 pickup させない）"
else
  fail "Req2.1: push 失敗時の戻り値が failed でない / 実際 $GOT"
fi
if [ -s "$GH_LOG" ]; then
  fail "Req2.1: push 失敗時に gh issue edit（ラベル除去）が呼ばれている（空転再発リスク）"
else
  pass "Req2.1: push 失敗時はラベル除去（再 pickup 可能化）を呼ばない"
fi

# ── Case 4: 全 task 完了経路でも push を実行してから ready-for-review（NFR1.5 / 既存挙動維持） ──
setup_repo "case4"
GH_LOG="$ROOT/case4-gh.log"; ORDER_LOG="$ROOT/case4-order.log"; : > "$GH_LOG"; : > "$ORDER_LOG"
mark_task_done_local "$WORK" 1
mark_task_done_local "$WORK" 2
mark_task_done_local "$WORK" 3   # 全 task 完了
LOCAL_HEAD=$(cd "$WORK" && git rev-parse HEAD)
GOT=$(cd "$WORK" && resolve_pt_completion_gate "$WORK/tasks.md" 198 "$BRANCH")
if [ "$GOT" = "ready-for-review" ]; then
  pass "NFR1.5: 全 task 完了 → ready-for-review"
else
  fail "NFR1.5: 全 task 完了 → 期待 ready-for-review / 実際 $GOT"
fi
ORIGIN_HEAD=$(cd "$WORK" && git ls-remote origin "refs/heads/$BRANCH" | cut -f1)
if [ "$ORIGIN_HEAD" = "$LOCAL_HEAD" ]; then
  pass "NFR1.5: 全 task 完了経路でも完了 commit が origin へ push される"
else
  fail "NFR1.5: 全 task 完了経路で origin に未 push（origin=$ORIGIN_HEAD / local=$LOCAL_HEAD）"
fi
if grep -q "^push$" "$ROOT/case4-order.log" && ! grep -q "^relabel$" "$ROOT/case4-order.log"; then
  pass "NFR1.5: 全 task 完了時は push のみ実行しラベル除去は呼ばない"
else
  fail "NFR1.5: 全 task 完了時の push/relabel パターンが不正（$(tr '\n' ',' < "$ROOT/case4-order.log")）"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "SMOKE_RESULT: pass"
  exit 0
else
  echo "SMOKE_RESULT: fail"
  exit 1
fi
