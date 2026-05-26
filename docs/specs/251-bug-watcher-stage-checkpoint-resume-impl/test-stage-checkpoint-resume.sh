#!/usr/bin/env bash
#
# 用途: Issue #251 で修正した「Stage Checkpoint resume の rev_rc=2 (impl-notes 有 /
#       review-notes 無) 分岐における残必須タスク確認」の判定挙動を fixture 付きで
#       検証するスモークスクリプト。per-task ループ (#21) が task 完了ごとに
#       impl-notes.md を commit する結果、残タスクがあるのに Stage A が永久 skip される
#       バグ (#251) の修正を回帰確認する。
# 配置: docs/specs/251-bug-watcher-stage-checkpoint-resume-impl/test-stage-checkpoint-resume.sh
# 依存: bash 4+, git, grep, sed, sort, wc, sed (関数抽出)
# セットアップ参照先: docs/specs/251-bug-watcher-stage-checkpoint-resume-impl/impl-notes.md
#
# 検証手法:
#   再実装ドリフトを避けるため、本テストは local-watcher/bin/issue-watcher.sh の
#   実関数定義（stage_checkpoint_* / pt_extract_pending_tasks / sc_log 等）を sed で
#   抽出して source し、実関数を直接実行する。git tracked 判定は一時 git repo で実体を
#   作り、gh CLI 呼び出しは PATH スタブで「PR なし (rc=1)」に固定する。
#
# 実行:
#   ./docs/specs/251-bug-watcher-stage-checkpoint-resume-impl/test-stage-checkpoint-resume.sh
# 出力:
#   各ケース: `[OK]` / `[NG]` の prefix で 1 行レポート
#   末尾: `SMOKE_RESULT: pass` / `SMOKE_RESULT: fail`
# 副作用:
#   /tmp/sc-resume-XXXX/ に一時 git repo / gh スタブ / 抽出関数ファイルを作成し、
#   終了時に削除する（実 repo・branch には一切触れない / NFR 2.2）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SCRIPT_DIR/../../../local-watcher/bin/issue-watcher.sh"
if [ ! -f "$WATCHER" ]; then
  echo "ERROR: watcher script not found: $WATCHER" >&2
  exit 1
fi

WORKDIR="$(mktemp -d /tmp/sc-resume-XXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# ─── 実関数を issue-watcher.sh から抽出して source する ───
# `<func>() {` から、列 0 で `}` が現れる行までを 1 ブロックとして抽出する。
# 抽出対象は本テストが必要とする関数群のみ（自動実行される _dispatcher_run 等は除外）。
FUNCS_FILE="$WORKDIR/extracted-funcs.sh"
extract_func() {
  local fname="$1"
  # 関数定義開始行から、列 0 の閉じ波括弧までを抽出
  sed -n "/^${fname}() {/,/^}/p" "$WATCHER"
}
{
  echo '#!/usr/bin/env bash'
  extract_func "sc_log"
  extract_func "sc_warn"
  extract_func "sc_error"
  extract_func "extract_review_result_token"
  extract_func "parse_review_result"
  extract_func "stage_checkpoint_has_impl_notes"
  extract_func "stage_checkpoint_read_review_result"
  extract_func "stage_checkpoint_find_impl_pr"
  extract_func "pt_extract_pending_tasks"
  extract_func "stage_checkpoint_resolve_resume_point"
} > "$FUNCS_FILE"

# 抽出健全性チェック: 必須関数が抽出できているか
for f in sc_log extract_review_result_token parse_review_result stage_checkpoint_has_impl_notes \
         stage_checkpoint_read_review_result stage_checkpoint_find_impl_pr \
         pt_extract_pending_tasks stage_checkpoint_resolve_resume_point; do
  if ! grep -q "^${f}() {" "$FUNCS_FILE"; then
    echo "ERROR: 関数 $f を issue-watcher.sh から抽出できませんでした" >&2
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$FUNCS_FILE"

# ─── gh CLI スタブ（既存 impl PR なし = rc=1 に固定） ───
# stage_checkpoint_find_impl_pr は `gh pr list ...` を呼ぶ。PR なし状態を再現するため
# 空 JSON 配列を返す（found が空 → return 1）。jq は実体を使う。
STUB_BIN="$WORKDIR/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# テスト用 gh スタブ: pr list は常に空配列（PR なし）を返す
echo '[]'
exit 0
EOF
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ─── 一時 git repo セットアップヘルパ ───
# 各ケースごとに新しい git repo を作り、spec dir に impl-notes.md / review-notes.md /
# tasks.md を配置して HEAD に commit（= tracked 化）する。引数で各ファイル内容を制御。
SPEC_REL="docs/specs/251-test/spec"

setup_repo() {
  # $1=repo dir, $2=impl(yes/no), $3=review内容(空=無), $4=tasks内容(NONE=不在)
  local repo="$1" impl="$2" review="$3" tasks="$4"
  rm -rf "$repo"
  mkdir -p "$repo/$SPEC_REL"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "test"
  if [ "$impl" = "yes" ]; then
    printf 'impl notes\nSTATUS: complete\n' > "$repo/$SPEC_REL/impl-notes.md"
    git -C "$repo" add "$SPEC_REL/impl-notes.md"
  fi
  if [ -n "$review" ]; then
    printf '%s\n' "$review" > "$repo/$SPEC_REL/review-notes.md"
    git -C "$repo" add "$SPEC_REL/review-notes.md"
  fi
  if [ "$tasks" != "NONE" ]; then
    printf '%s\n' "$tasks" > "$repo/$SPEC_REL/tasks.md"
    git -C "$repo" add "$SPEC_REL/tasks.md"
  fi
  # 何か 1 つは commit する（空 commit でも HEAD を作る）
  git -C "$repo" commit -q --allow-empty -m "setup" >/dev/null 2>&1
}

# ─── resolve 実行ヘルパ ───
# 実関数 stage_checkpoint_resolve_resume_point を呼び、START_STAGE と LOG を返す。
run_resolve() {
  local repo="$1"
  # サブシェルで env を隔離し、START_STAGE を stdout の最終行へ吐く。
  # env 変更がサブシェル内に閉じるのは意図的（テストケース間の汚染回避）なので
  # SC2030/SC2031（subshell modification）を抑制する。
  # shellcheck disable=SC2030,SC2031
  (
    export REPO_DIR="$repo"
    export SPEC_DIR_REL="$SPEC_REL"
    export REPO="owner/test"
    export BRANCH="claude/issue-251-test"
    export NUMBER="251"
    export LOG="$WORKDIR/run.log"
    : > "$LOG"
    START_STAGE="A"
    stage_checkpoint_resolve_resume_point >/dev/null 2>&1 || true
    echo "$START_STAGE"
  )
}

FAIL=0
assert_stage() {
  local desc="$1" repo="$2" expected="$3"
  local got
  got=$(run_resolve "$repo")
  if [ "$got" = "$expected" ]; then
    echo "[OK] $desc (START_STAGE=$got)"
  else
    echo "[NG] $desc (expected=$expected got=$got)"
    FAIL=1
  fi
}

# ログに残タスク理由が出ているか（Req 5: 可観測性）を確認
assert_log_contains() {
  local desc="$1" repo="$2" pattern="$3"
  local log="$WORKDIR/check.log"
  # shellcheck disable=SC2030,SC2031
  (
    export REPO_DIR="$repo" SPEC_DIR_REL="$SPEC_REL" REPO="owner/test"
    export BRANCH="claude/issue-251-test" NUMBER="251" LOG="$log"
    : > "$log"
    START_STAGE="A"
    stage_checkpoint_resolve_resume_point >/dev/null 2>&1 || true
  )
  if grep -qE "$pattern" "$log"; then
    echo "[OK] $desc (log matched: $pattern)"
  else
    echo "[NG] $desc (log missing pattern: $pattern)"
    echo "----- log -----"; cat "$log"; echo "---------------"
    FAIL=1
  fi
}

echo "=== Issue #251 Stage Checkpoint resume 残必須タスク確認スモーク ==="

# ── fixture 内容 ──
TASKS_PENDING='- [x] 1. task1 完了
  - _Requirements: 1.1_
- [ ] 2. task2 未完了
  - _Requirements: 1.2_
- [ ] 2.1 子タスク未完了
  - _Requirements: 1.3_'

TASKS_ALL_DONE='- [x] 1. task1 完了
  - _Requirements: 1.1_
- [x] 2. task2 完了
  - _Requirements: 1.2_
- [x] 2.1 子タスク完了
  - _Requirements: 1.3_'

TASKS_DEFERRABLE_ONLY='- [x] 1. 実装完了
  - _Requirements: 1.1_
- [ ]* 1.1 deferrable テスト追加
  - _Requirements: 1.1_'

REVIEW_APPROVE='# review notes
RESULT: approve'

REVIEW_REJECT_R2='<!-- idd-claude:review round=2 -->
# review notes
RESULT: reject'

REVIEW_REJECT_R1='<!-- idd-claude:review round=1 -->
# review notes
RESULT: reject'

# ── Case 1 (本バグ修正): impl有 + review無 + tasks残必須あり → A (Req 1) ──
R1="$WORKDIR/case1"
setup_repo "$R1" yes "" "$TASKS_PENDING"
assert_stage "Req1: impl有/review無/残必須あり → START_STAGE=A" "$R1" "A"
assert_log_contains "Req5: 残タスク件数を含む判定根拠ログ (count=2)" "$R1" \
  'stage-checkpoint:.*reason=pending-tasks-remain count=2'

# ── Case 2: impl有 + review無 + tasks全完了 → B (Req 2 従来維持) ──
R2="$WORKDIR/case2"
setup_repo "$R2" yes "" "$TASKS_ALL_DONE"
assert_stage "Req2: impl有/review無/全タスク完了 → START_STAGE=B" "$R2" "B"
assert_log_contains "Req2: 全完了は従来 reason を維持" "$R2" \
  'stage-checkpoint:.*reason=impl-notes-only-or-review-unparsed'

# ── Case 3: impl有 + review無 + tasks不在(design-less) → B (Req 4 後方互換) ──
R3="$WORKDIR/case3"
setup_repo "$R3" yes "" "NONE"
assert_stage "Req4: impl有/review無/tasks.md不在 → START_STAGE=B" "$R3" "B"

# ── Case 4: deferrable `- [ ]*` のみ残存 → 必須0件 → B (NFR 3.2) ──
R4="$WORKDIR/case4"
setup_repo "$R4" yes "" "$TASKS_DEFERRABLE_ONLY"
assert_stage "NFR3.2: deferrable のみ残 → 必須0件 → START_STAGE=B" "$R4" "B"

# ── Case 5: approve → C (Req 3.1 介入しない / 残必須あっても C) ──
R5="$WORKDIR/case5"
setup_repo "$R5" yes "$REVIEW_APPROVE" "$TASKS_PENDING"
assert_stage "Req3.1: approve は残必須あっても START_STAGE=C 維持" "$R5" "C"

# ── Case 6: reject round=2 → TERMINAL_FAILED (Req 3.2 介入しない) ──
R6="$WORKDIR/case6"
setup_repo "$R6" yes "$REVIEW_REJECT_R2" "$TASKS_PENDING"
assert_stage "Req3.2: reject round=2 は残必須あっても TERMINAL_FAILED 維持" "$R6" "TERMINAL_FAILED"

# ── Case 7: reject round=1 → A (Req 3.3 既存どおり / 残タスク確認の追加介入なしで一致) ──
R7="$WORKDIR/case7"
setup_repo "$R7" yes "$REVIEW_REJECT_R1" "$TASKS_PENDING"
assert_stage "Req3.3: reject round=1 は既存どおり START_STAGE=A" "$R7" "A"

# ── Case 8 (冪等性 NFR 2.1): 同一 repo HEAD で複数回呼んでも同一 START_STAGE ──
R8="$WORKDIR/case8"
setup_repo "$R8" yes "" "$TASKS_PENDING"
G1=$(run_resolve "$R8"); G2=$(run_resolve "$R8"); G3=$(run_resolve "$R8")
if [ "$G1" = "A" ] && [ "$G1" = "$G2" ] && [ "$G2" = "$G3" ]; then
  echo "[OK] NFR2.1: 複数回呼び出しで同一 START_STAGE ($G1=$G2=$G3)"
else
  echo "[NG] NFR2.1: 冪等性違反 ($G1 / $G2 / $G3)"
  FAIL=1
fi

# ── Case 9 (NFR 2.2 破壊的副作用ゼロ): resolve 前後で tasks.md / impl-notes.md / HEAD 不変 ──
R9="$WORKDIR/case9"
setup_repo "$R9" yes "" "$TASKS_PENDING"
HEAD_BEFORE=$(git -C "$R9" rev-parse HEAD)
SUM_BEFORE=$(cat "$R9/$SPEC_REL/tasks.md" "$R9/$SPEC_REL/impl-notes.md" | sha1sum)
STATUS_BEFORE=$(git -C "$R9" status --porcelain)
run_resolve "$R9" >/dev/null
HEAD_AFTER=$(git -C "$R9" rev-parse HEAD)
SUM_AFTER=$(cat "$R9/$SPEC_REL/tasks.md" "$R9/$SPEC_REL/impl-notes.md" | sha1sum)
STATUS_AFTER=$(git -C "$R9" status --porcelain)
if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ] && [ "$SUM_BEFORE" = "$SUM_AFTER" ] && [ "$STATUS_BEFORE" = "$STATUS_AFTER" ]; then
  echo "[OK] NFR2.2: resolve は破壊的副作用なし (HEAD / ファイル / status 不変)"
else
  echo "[NG] NFR2.2: 破壊的副作用検出 (HEAD: $HEAD_BEFORE→$HEAD_AFTER)"
  FAIL=1
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "SMOKE_RESULT: pass"
  exit 0
else
  echo "SMOKE_RESULT: fail"
  exit 1
fi
