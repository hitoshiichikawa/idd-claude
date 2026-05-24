#!/usr/bin/env bash
#
# 用途: Issue #198 で追加した「per-task ループ全 task 完了ゲートが ready-for-review を
#       保留する際に claude-picked-up ラベルを除去して bare auto-dev candidate に戻す」
#       挙動を fixture + gh スタブで検証するスモークスクリプト。保留時に当該 Issue が
#       再 pickup 可能化されることで後続 tick の impl-resume 再開が成立する（#180 Part 2
#       の stuck を解消する）ことを確認する。
# 配置: docs/specs/198-bug-watcher-per-task-195-ready-for-revie/test-pt-hold-relabel.sh
# 依存: bash 4+, grep, sed, sort, wc
# セットアップ参照先: docs/specs/198-bug-watcher-per-task-195-ready-for-revie/impl-notes.md
#
# 実行:
#   ./docs/specs/198-bug-watcher-per-task-195-ready-for-revie/test-pt-hold-relabel.sh
# 出力:
#   各ケース: `[OK]` / `[NG]` の prefix で 1 行レポート
#   末尾: `SMOKE_RESULT: pass` / `SMOKE_RESULT: fail`
# 副作用:
#   /tmp/pt-hold-relabel-XXXX/ に一時ディレクトリ（tasks.md fixture / gh 呼び出しログ）を
#   作成し、終了時に削除する

set -euo pipefail

# ─── ラベル定数（issue-watcher.sh と同一名） ───
LABEL_CLAIMED="claude-claimed"
LABEL_PICKED="claude-picked-up"
LABEL_NEEDS_QUOTA_WAIT="needs-quota-wait"
REPO="owner/test"

WORKDIR="$(mktemp -d /tmp/pt-hold-relabel-XXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
GH_LOG="$WORKDIR/gh-calls.log"
: > "$GH_LOG"

# ─── gh スタブ ───
# `gh issue edit ...` の引数列を $GH_LOG へ追記し、成功（exit 0）を返す。
# GH_STUB_FAIL=1 のとき exit 1 を返して副作用失敗を模擬する。
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
    return 1
  fi
  return 0
}

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

# ─── 完了ゲート + 保留時ラベル除去の参照実装（issue-watcher.sh の per-task 分岐から抽出） ───
# `run_per_task_loop` の return 0 後、tasks.md を再読込して必須未完了 task の有無で分岐する。
# 必須未完了が残れば ready-for-review を保留し、保留時に claude-picked-up / claude-claimed を
# 除去して bare auto-dev candidate へ戻す（#198）。`needs-quota-wait` は一切触らない（Req 3）。
#
# 引数: $1 = tasks.md の絶対パス, $2 = Issue 番号
# stdout: "ready-for-review" | "hold-resumable"
resolve_pt_completion_gate() {
  local tasks_md="$1" number="$2"
  local _pt_remaining
  _pt_remaining=$(pt_extract_pending_tasks "$tasks_md" || true)
  if [ -n "$_pt_remaining" ]; then
    # 保留: claude-picked-up / claude-claimed を除去（needs-quota-wait は付与しない）。
    # gh edit の成否に関わらず hold-resumable を維持する（副作用失敗で全体を落とさない / Req 1.4）。
    gh issue edit "$number" --repo "$REPO" \
      --remove-label "$LABEL_PICKED" \
      --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1 || true
    echo "hold-resumable"
  else
    echo "ready-for-review"
  fi
}

# ─── fixture ───
F_PARTIAL="$WORKDIR/partial.md"
cat > "$F_PARTIAL" <<'EOF'
- [x] 1. task 1 完了
  - _Requirements: 1.1_
- [ ] 2. task 2 未完了
  - _Requirements: 1.2_
- [ ] 3. task 3 未完了
  - _Requirements: 1.3_
EOF

F_ALL_DONE="$WORKDIR/all-done.md"
cat > "$F_ALL_DONE" <<'EOF'
- [x] 1. 実装
  - _Requirements: 1.1_
- [x] 2. 仕上げ
  - _Requirements: 1.2_
EOF

F_DEFERRABLE_ONLY="$WORKDIR/deferrable-only.md"
cat > "$F_DEFERRABLE_ONLY" <<'EOF'
- [x] 1. 実装
  - _Requirements: 1.1_
- [ ]* 1.1 統合テスト追加（deferrable）
  - _Requirements: 1.1_
EOF

FAIL=0
pass() { echo "[OK] $1"; }
fail() { echo "[NG] $1"; FAIL=1; }

echo "=== Issue #198 per-task ゲート保留時の再 pickup 可能化スモーク ==="

# ── Case 1: 必須未完了残存 → hold-resumable かつ claude-picked-up の remove-label が呼ばれる（Req 1.1/1.4） ──
: > "$GH_LOG"
GOT=$(resolve_pt_completion_gate "$F_PARTIAL" 198)
if [ "$GOT" = "hold-resumable" ]; then
  pass "Req1.1: 必須未完了残存 → hold-resumable"
else
  fail "Req1.1: 必須未完了残存 → 期待 hold-resumable / 実際 $GOT"
fi
if grep -q -- "--remove-label $LABEL_PICKED" "$GH_LOG"; then
  pass "Req1.1/1.4: 保留時に claude-picked-up の remove-label が呼ばれる"
else
  fail "Req1.1/1.4: 保留時に claude-picked-up の remove-label が呼ばれていない"
fi
# Req 3.2/3.3: needs-quota-wait を付与しない（quota 非干渉）
if grep -q -- "$LABEL_NEEDS_QUOTA_WAIT" "$GH_LOG"; then
  fail "Req3.2/3.3: 保留時に needs-quota-wait が付与されている（quota 非干渉違反）"
else
  pass "Req3.2/3.3: 保留時に needs-quota-wait を付与しない（quota 非干渉）"
fi
# Req 1.4: claude-claimed も除去対象に含む（quota ハンドラと整合）
if grep -q -- "--remove-label $LABEL_CLAIMED" "$GH_LOG"; then
  pass "Req1.4: 保留時に claude-claimed の remove-label も呼ばれる"
else
  fail "Req1.4: 保留時に claude-claimed の remove-label が呼ばれていない"
fi

# ── Case 2: 全 task 完了 → ready-for-review かつ remove-label が一切呼ばれない（Req 1.3/2.4/NFR1.5） ──
: > "$GH_LOG"
GOT=$(resolve_pt_completion_gate "$F_ALL_DONE" 198)
if [ "$GOT" = "ready-for-review" ]; then
  pass "Req1.3: 全 task 完了 → ready-for-review"
else
  fail "Req1.3: 全 task 完了 → 期待 ready-for-review / 実際 $GOT"
fi
if [ -s "$GH_LOG" ]; then
  fail "NFR1.5: 全 task 完了時に gh issue edit が呼ばれている（保留挙動の誤発火）"
else
  pass "NFR1.5: 全 task 完了時は gh issue edit（ラベル除去）を呼ばない"
fi

# ── Case 3: deferrable のみ残 → ready-for-review かつ remove-label が呼ばれない（Req 1.5） ──
: > "$GH_LOG"
GOT=$(resolve_pt_completion_gate "$F_DEFERRABLE_ONLY" 198)
if [ "$GOT" = "ready-for-review" ]; then
  pass "Req1.5: deferrable のみ残 → ready-for-review（deferrable は未完了扱いしない）"
else
  fail "Req1.5: deferrable のみ残 → 期待 ready-for-review / 実際 $GOT"
fi
if [ -s "$GH_LOG" ]; then
  fail "Req1.5: deferrable のみ残のとき gh issue edit が呼ばれている（誤保留）"
else
  pass "Req1.5: deferrable のみ残のときラベル除去を呼ばない"
fi

# ── Case 4: 副作用失敗（gh edit が exit 1）でも hold-resumable は維持される（Req 1.4） ──
: > "$GH_LOG"
GOT=$(GH_STUB_FAIL=1 resolve_pt_completion_gate "$F_PARTIAL" 198)
if [ "$GOT" = "hold-resumable" ]; then
  pass "Req1.4: gh edit 失敗時も hold-resumable を維持（副作用失敗で全体を落とさない）"
else
  fail "Req1.4: gh edit 失敗時に hold-resumable を維持できていない / 実際 $GOT"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "SMOKE_RESULT: pass"
  exit 0
else
  echo "SMOKE_RESULT: fail"
  exit 1
fi
