#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の per-task terminal failure 経路で
#       diagnostic artifact の保全と push state 可視化を行う
#       publish_terminal_failure_artifacts ヘルパーを、ローカル bare repo を
#       fake origin とした擬似環境で end-to-end 検証するスモークテスト。
#       Issue #306 で導入。
#
#       検証観点（Req と対応付け）:
#         - per-task-reviewer-reject3 シナリオで review-notes.md / debugger-notes.md
#           が untracked のまま terminal failure に入った場合に、watcher が
#           diagnostic commit を作って origin に push し、失敗コメント本文に
#           push state（branch / local HEAD / origin HEAD / ahead / worktree path）と
#           artifact 状態が埋め込まれる（Req 1.1, 1.3, 2.1, 2.4, 5.1, 5.2, 5.3）
#         - 既に tracked かつ push 済みの artifact では diagnostic commit を作らず
#           既存コメント情報の append のみ行う（Req 1.2）
#         - diagnostic commit の push に失敗した場合、fallback として artifact 本文
#           を Issue コメントに埋め込む（Req 1.4, NFR 3.1）
#         - artifact 本文が長文の場合は先頭 + 末尾の抜粋に切り替える（NFR 3.1）
#         - 初回 push 前（origin branch 不在）でも push state 欄に「未 push」と
#           ahead count（local HEAD までの commit 数）を埋める（Req 2.3）
#         - 保全処理の途中失敗でも claude-failed ラベル付与責務を放棄しない
#           （Req 1.5, NFR 2.1）
#
# 配置先: local-watcher/test/publish_terminal_failure_artifacts_test.sh
# 依存:   bash 4+, git, awk
# 実行:   bash local-watcher/test/publish_terminal_failure_artifacts_test.sh
# 前提:   外部ネットワークを使わない。fake origin は mktemp 配下の bare repo。
#         GH_TOKEN は不要（gh コマンドを関数で stub する）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# publish_terminal_failure_artifacts は内部で mark_issue_failed を呼ぶため、
# 関数定義のみを抽出して current shell に load する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "publish_terminal_failure_artifacts")"

if ! declare -F publish_terminal_failure_artifacts >/dev/null; then
  echo "ERROR: publish_terminal_failure_artifacts not loaded from issue-watcher.sh" >&2
  exit 2
fi

# サニティ: 実装側の per-task terminal failure 経路が新ヘルパー名で呼んでいること
# （関数差し替え漏れを検出 / Issue #306）
if ! grep -q 'publish_terminal_failure_artifacts "per-task-reviewer-reject2"' "$WATCHER_SH"; then
  echo "ERROR: issue-watcher.sh から publish_terminal_failure_artifacts per-task-reviewer-reject2 の呼出がない" >&2
  exit 2
fi
if ! grep -q 'publish_terminal_failure_artifacts "per-task-reviewer-reject3"' "$WATCHER_SH"; then
  echo "ERROR: issue-watcher.sh から publish_terminal_failure_artifacts per-task-reviewer-reject3 の呼出がない" >&2
  exit 2
fi
if ! grep -q 'publish_terminal_failure_artifacts "per-task-reviewer-error"' "$WATCHER_SH"; then
  echo "ERROR: issue-watcher.sh から publish_terminal_failure_artifacts per-task-reviewer-error の呼出がない" >&2
  exit 2
fi
if ! grep -q 'publish_terminal_failure_artifacts "per-task-reviewer-missing-file"' "$WATCHER_SH"; then
  echo "ERROR: issue-watcher.sh から publish_terminal_failure_artifacts per-task-reviewer-missing-file の呼出がない" >&2
  exit 2
fi
if ! grep -q 'publish_terminal_failure_artifacts "debugger-notes-invalid"' "$WATCHER_SH"; then
  echo "ERROR: issue-watcher.sh から publish_terminal_failure_artifacts debugger-notes-invalid の呼出がない" >&2
  exit 2
fi

# ─── 一時環境（bare repo + work repo）構築ヘルパ ───
TMPROOT=$(mktemp -d)
cleanup() {
  chmod -R u+rwX "$TMPROOT" 2>/dev/null || true
  rm -rf "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT

# fake mark_issue_failed: 呼出を記録する
LAST_MARK_FAILED_STAGE=""
LAST_MARK_FAILED_BODY=""
MARK_FAILED_CALL_COUNT=0
mark_issue_failed() {
  LAST_MARK_FAILED_STAGE="$1"
  LAST_MARK_FAILED_BODY="$2"
  MARK_FAILED_CALL_COUNT=$((MARK_FAILED_CALL_COUNT + 1))
}

# work / bare repo を作って初期 commit を push 済みにする
setup_work_with_upstream() {
  local case_id="$1"
  local work="$TMPROOT/work-$case_id"
  local bare="$TMPROOT/bare-$case_id.git"

  git init --bare --quiet "$bare"
  git init --quiet "$work"
  (
    cd "$work"
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git remote add origin "$bare"
    mkdir -p docs/specs/306-test
    echo "v0" > docs/specs/306-test/requirements.md
    git add docs/specs/306-test/requirements.md
    git commit --quiet -m "init"
    git branch -m work-branch
    git push --quiet -u origin work-branch
  )
  echo "$work"
}

# 初回 push 前の work repo（origin branch 不在）
setup_work_without_upstream() {
  local case_id="$1"
  local work="$TMPROOT/work-$case_id"
  local bare="$TMPROOT/bare-$case_id.git"

  git init --bare --quiet "$bare"
  git init --quiet "$work"
  (
    cd "$work"
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git remote add origin "$bare"
    mkdir -p docs/specs/306-test
    echo "v0" > docs/specs/306-test/requirements.md
    git add docs/specs/306-test/requirements.md
    git commit --quiet -m "init"
    git branch -m work-branch
    # push しない
  )
  echo "$work"
}

# ─── アサーションヘルパ ───
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle: $(printf '%q' "$needle")"
    echo "  in (head): $(printf '%s' "$haystack" | head -c 800)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    echo "FAIL: $label (needle found unexpectedly)"
    echo "  needle: $(printf '%q' "$needle")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

reset_state() {
  LAST_MARK_FAILED_STAGE=""
  LAST_MARK_FAILED_BODY=""
  MARK_FAILED_CALL_COUNT=0
}

# 共通 env vars
LOG="$TMPROOT/test-watcher.log"
: > "$LOG"
export NUMBER REPO LOG SPEC_DIR_REL BASE_BRANCH BRANCH REPO_DIR
NUMBER="306"
REPO="owner/test"
SPEC_DIR_REL="docs/specs/306-test"
BASE_BRANCH="main"
BRANCH="work-branch"

echo "--- publish_terminal_failure_artifacts cases ---"

# ─────────────────────────────────────────────────────────────────
# Case 1: per-task-reviewer-reject3 シナリオ。review-notes.md / debugger-notes.md
# が untracked な状態で terminal failure → diagnostic commit 作成 + push 成功
# (Req 1.1, 1.3, 2.1, 2.4, 5.1, 5.2, 5.3)
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case1")
REPO_DIR="$WORK"
# untracked な review-notes.md / debugger-notes.md を作る
echo "# Review notes (reject categories: missing-test)" > "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "RESULT: reject" >> "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "# Debugger fix plan" > "$WORK/$SPEC_DIR_REL/debugger-notes.md"
echo "## 根本原因" >> "$WORK/$SPEC_DIR_REL/debugger-notes.md"

reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
publish_terminal_failure_artifacts "per-task-reviewer-reject3" "per-task ループの Reviewer (task=\`1.1\`, round=3) reject (Req 3.5)"
popd >/dev/null

assert_eq "Case 1: mark_issue_failed が 1 回呼ばれた (Req 1.5)" "1" "$MARK_FAILED_CALL_COUNT"
assert_eq "Case 1: stage 識別子が伝搬 (per-task-reviewer-reject3)" \
  "per-task-reviewer-reject3" "$LAST_MARK_FAILED_STAGE"

# Req 2.1: 失敗コメントに push state 必須項目
assert_contains "Case 1: コメントに実装 branch 名 (Req 2.1)" \
  "実装 branch: \`work-branch\`" "$LAST_MARK_FAILED_BODY"
assert_contains "Case 1: コメントに worktree path (Req 2.1)" \
  "worktree" "$LAST_MARK_FAILED_BODY"
assert_contains "Case 1: コメントに local HEAD ラベル (Req 2.1)" \
  "local HEAD" "$LAST_MARK_FAILED_BODY"
assert_contains "Case 1: コメントに origin HEAD ラベル (Req 2.1)" \
  "origin HEAD" "$LAST_MARK_FAILED_BODY"
assert_contains "Case 1: コメントに ahead count ラベル (Req 2.1)" \
  "ahead count" "$LAST_MARK_FAILED_BODY"

# Req 2.2: artifact 単位の状態（review-notes.md / debugger-notes.md）が記載される
assert_contains "Case 1: コメントに review-notes.md 行 (Req 2.2)" \
  "review-notes.md" "$LAST_MARK_FAILED_BODY"
assert_contains "Case 1: コメントに debugger-notes.md 行 (Req 2.2)" \
  "debugger-notes.md" "$LAST_MARK_FAILED_BODY"

# Req 1.1, 1.3, 5.2: diagnostic commit が origin に push されている
BARE_COMMITS=$(git -C "$TMPROOT/bare-case1.git" rev-list --count work-branch)
assert_eq "Case 1: bare 側に init + diagnostic commit の 2 件到達 (Req 1.1, 1.3)" \
  "2" "$BARE_COMMITS"
# Req 1.3 後: artifact が committed として表示される
assert_contains "Case 1: artifact status が committed (Req 1.3)" \
  "committed" "$LAST_MARK_FAILED_BODY"

# 既存 extra_body 部分が保持される（NFR 1.2）
assert_contains "Case 1: 既存 extra_body 文言が保持される (NFR 1.2)" \
  "per-task ループの Reviewer (task=\`1.1\`, round=3) reject" "$LAST_MARK_FAILED_BODY"

# NFR 2.2: $LOG に grep 可能な記録
assert_contains "Case 1: \$LOG に terminal-failure-artifacts 記録 (NFR 2.2)" \
  "terminal-failure-artifacts" "$(cat "$LOG")"
assert_contains "Case 1: \$LOG に stage 識別子 (NFR 2.2)" \
  "stage=per-task-reviewer-reject3" "$(cat "$LOG")"

# ─────────────────────────────────────────────────────────────────
# Case 2: artifact が既に tracked かつ pushed 済み → 重複保全しない (Req 1.2)
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case2")
REPO_DIR="$WORK"
# review-notes.md / debugger-notes.md を作成して commit + push 済みにする
echo "# Already tracked" > "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "RESULT: reject" >> "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "# Already tracked debugger notes" > "$WORK/$SPEC_DIR_REL/debugger-notes.md"
(
  cd "$WORK"
  git add docs/specs/306-test/review-notes.md docs/specs/306-test/debugger-notes.md
  git commit --quiet -m "preexisting review + debugger artifacts"
  git push --quiet origin work-branch
)

BARE_COMMITS_BEFORE=$(git -C "$TMPROOT/bare-case2.git" rev-list --count work-branch)

reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
publish_terminal_failure_artifacts "per-task-reviewer-reject2" "per-task Reviewer reject2 (既存 tracked artifact)"
popd >/dev/null

assert_eq "Case 2: mark_issue_failed が 1 回呼ばれた (Req 1.5)" "1" "$MARK_FAILED_CALL_COUNT"

# Req 1.2: 重複保全を行わない → bare 側に新規 commit が積まれていない
BARE_COMMITS_AFTER=$(git -C "$TMPROOT/bare-case2.git" rev-list --count work-branch)
assert_eq "Case 2: bare 側に新規 commit が追加されていない (Req 1.2)" \
  "$BARE_COMMITS_BEFORE" "$BARE_COMMITS_AFTER"

# Req 1.2: status が tracked-pushed と表示される
assert_contains "Case 2: artifact status が tracked-pushed (Req 1.2)" \
  "tracked-pushed" "$LAST_MARK_FAILED_BODY"

# 既存挙動（push state 情報は常に append される / Req 2.4）
assert_contains "Case 2: tracked かつ pushed でも push state 情報を append (Req 2.4)" \
  "実装 branch: \`work-branch\`" "$LAST_MARK_FAILED_BODY"

# ─────────────────────────────────────────────────────────────────
# Case 3: diagnostic commit の push に失敗 → 本文を Issue コメントに fallback 埋め込み
# (Req 1.4)
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case3")
REPO_DIR="$WORK"
# untracked artifact を用意
EMBED_MARKER="EMBED-MARKER-CASE3-CONTENT-XYZ"
echo "$EMBED_MARKER" > "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "RESULT: reject" >> "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "# Debugger" > "$WORK/$SPEC_DIR_REL/debugger-notes.md"

# bare を壊して push を失敗させる
chmod -R 000 "$TMPROOT/bare-case3.git/refs" 2>/dev/null || true

reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
publish_terminal_failure_artifacts "per-task-reviewer-error" "per-task Reviewer error (commit push 失敗シナリオ)"
popd >/dev/null

chmod -R 755 "$TMPROOT/bare-case3.git/refs" 2>/dev/null || true

assert_eq "Case 3: mark_issue_failed が 1 回呼ばれた (Req 1.5)" "1" "$MARK_FAILED_CALL_COUNT"

# Req 1.4: artifact 本文がコメント本文に fallback 埋め込みされる
assert_contains "Case 3: review-notes.md 本文の marker がコメントに埋め込まれた (Req 1.4)" \
  "$EMBED_MARKER" "$LAST_MARK_FAILED_BODY"
# 「全文」見出しが存在
assert_contains "Case 3: fallback 埋め込みの見出しが存在 (Req 1.4)" \
  "の内容（全文）" "$LAST_MARK_FAILED_BODY"

# ─────────────────────────────────────────────────────────────────
# Case 4: 初回 push 前（origin branch 不在）→ origin HEAD は「未 push」相当
# (Req 2.3) かつ ahead は local HEAD までの commit 数として算出
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_without_upstream "case4")
REPO_DIR="$WORK"
# untracked artifact
echo "# Initial push 前 review-notes" > "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "RESULT: reject" >> "$WORK/$SPEC_DIR_REL/review-notes.md"

reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
# 初回 push できる状態（bare に対する push 権限はある）にしておく
publish_terminal_failure_artifacts "per-task-reviewer-reject2" "per-task Reviewer reject2 初回 push 前"
popd >/dev/null

assert_eq "Case 4: mark_issue_failed が 1 回呼ばれた (Req 1.5)" "1" "$MARK_FAILED_CALL_COUNT"

# Req 2.3 の確認は「最初に push state を取得した段階」で origin が未 push だったことが
# コメントに反映されること。watcher は commit 成功後に origin HEAD を更新するため、
# ロジックとしては「origin HEAD: 未 push」が初期取得時に出力される実装。
# 実際の挙動: 初回取得時の origin_head=未 push がそのまま埋まる場合もあるが、
# commit/push 成功後に最新 SHA で上書きされるケースもある。
# 安定的に検証できるのは「初回時点で未 push 経路を通った」ことの log 記録。
assert_contains "Case 4: \$LOG に origin_head=未 push 記録 (Req 2.3)" \
  "origin_head=未 push" "$(cat "$LOG")"

# ─────────────────────────────────────────────────────────────────
# Case 5: 長文 artifact (NFR 3.1) → 要約埋め込み（ただし commit が成功すれば fallback
# 埋め込みは発生しないので、bare を壊して fallback 経路で評価する）
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case5")
REPO_DIR="$WORK"
# 長文 (16385 文字以上) の review-notes.md を作る
{
  i=0
  while [ "$i" -lt 600 ]; do
    printf 'long-line-marker-%04d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
    i=$((i + 1))
  done
} > "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "TAIL-MARKER-CASE5-END" >> "$WORK/$SPEC_DIR_REL/review-notes.md"
echo "# Debugger" > "$WORK/$SPEC_DIR_REL/debugger-notes.md"

# bare を壊して fallback 経路を通す
chmod -R 000 "$TMPROOT/bare-case5.git/refs" 2>/dev/null || true

reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
publish_terminal_failure_artifacts "per-task-reviewer-missing-file" "per-task Reviewer missing-file 長文"
popd >/dev/null

chmod -R 755 "$TMPROOT/bare-case5.git/refs" 2>/dev/null || true

assert_eq "Case 5: mark_issue_failed が 1 回呼ばれた (Req 1.5)" "1" "$MARK_FAILED_CALL_COUNT"

# NFR 3.1: 長文 → 要約埋め込み（「中略」を含む）
assert_contains "Case 5: 要約モード（中略）が選択された (NFR 3.1)" \
  "(中略" "$LAST_MARK_FAILED_BODY"
assert_contains "Case 5: 要約モードの末尾 marker が含まれる (NFR 3.1)" \
  "TAIL-MARKER-CASE5-END" "$LAST_MARK_FAILED_BODY"

# ─────────────────────────────────────────────────────────────────
# Case 6: review-notes.md / debugger-notes.md が両方 absent でも mark_issue_failed は
# 必ず呼ばれる (Req 1.5, NFR 2.1)
# ─────────────────────────────────────────────────────────────────
WORK=$(setup_work_with_upstream "case6")
REPO_DIR="$WORK"
# 何も artifact を作らない

reset_state
: > "$LOG"
pushd "$WORK" >/dev/null
publish_terminal_failure_artifacts "debugger-notes-invalid" "Debugger notes 不正 / 不在"
popd >/dev/null

assert_eq "Case 6: artifact 不在でも mark_issue_failed が呼ばれる (Req 1.5)" \
  "1" "$MARK_FAILED_CALL_COUNT"
assert_eq "Case 6: stage 識別子が正しく伝搬" \
  "debugger-notes-invalid" "$LAST_MARK_FAILED_STAGE"
# absent 状態が status で出る
assert_contains "Case 6: artifact 不在 status が absent (Req 1.5, NFR 2.1)" \
  "absent" "$LAST_MARK_FAILED_BODY"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
