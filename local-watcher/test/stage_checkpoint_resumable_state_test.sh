#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の Stage Checkpoint Resume 用 resumable state
#       判定ヘルパ `_stage_checkpoint_has_resumable_state` を fixture で検証する
#       スモークテスト。Issue #383 で導入。
#
#       検証範囲:
#         Req 1.2 (skip 経路): spec dir 存在 + 4 観点いずれも不在 → return 1（skip）
#         Req 2.1 (発火経路): impl PR / impl branch / impl-notes / review-notes の
#                              いずれか 1 つでも実在 → return 0（fire）
#         Req 3.1: 4 観点が OR で判定される（個別に return 0）
#         NFR 2.1 (safe-side): gh API / git ls-remote / git ls-tree 失敗時は return 2
#                              （呼び出し元は 0 と同等に扱い slug guard を発火）
#
# 配置先: local-watcher/test/stage_checkpoint_resumable_state_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/stage_checkpoint_resumable_state_test.sh
# 前提:   issue-watcher.sh から関数定義を awk で切り出して eval で読み込み、
#         `stage_checkpoint_find_impl_pr` / `git` は test 内で stub する。
#
# shellcheck disable=SC2317

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

extract_function() {
  local script="$1" fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# ─── 対象関数の load ───
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "_stage_checkpoint_has_resumable_state")"

if ! declare -F _stage_checkpoint_has_resumable_state >/dev/null; then
  echo "ERROR: _stage_checkpoint_has_resumable_state not loaded" >&2
  exit 2
fi

# ─── 依存関数の stub ───
# 各テストケースの fixture で MOCK_* 変数を差し替えて挙動を制御する。

# stage_checkpoint_find_impl_pr の stub。
# MOCK_FIND_IMPL_PR_RC で戻り値、MOCK_FIND_IMPL_PR_OUT で stdout を制御する。
MOCK_FIND_IMPL_PR_RC=1
MOCK_FIND_IMPL_PR_OUT=""
stage_checkpoint_find_impl_pr() {
  if [ -n "$MOCK_FIND_IMPL_PR_OUT" ]; then
    echo "$MOCK_FIND_IMPL_PR_OUT"
  fi
  return "$MOCK_FIND_IMPL_PR_RC"
}
export -f stage_checkpoint_find_impl_pr

# git の stub。引数パターンで分岐させる。
#   - `git ls-remote --heads origin ...` → MOCK_LS_REMOTE_RC / MOCK_LS_REMOTE_OUT
#   - `git -C <dir> ls-tree --name-only HEAD -- <path>` → MOCK_LS_TREE_RC_<basename> /
#                                                         MOCK_LS_TREE_OUT_<basename>
MOCK_LS_REMOTE_RC=0
MOCK_LS_REMOTE_OUT=""
MOCK_LS_TREE_IMPL_RC=0
MOCK_LS_TREE_IMPL_OUT=""
MOCK_LS_TREE_REVIEW_RC=0
MOCK_LS_TREE_REVIEW_OUT=""

git() {
  # サブコマンド位置: `git -C <dir> <subcmd> ...` の場合 $3 が subcmd、それ以外は $1
  local subcmd=""
  local args=()
  if [ "${1:-}" = "-C" ]; then
    shift 2  # -C と <dir> を捨てる
  fi
  subcmd="${1:-}"
  shift || true
  args=("$@")

  case "$subcmd" in
    ls-remote)
      # 形式: git ls-remote --heads origin -- "refs/heads/claude/issue-<N>-impl-*"
      if [ -n "$MOCK_LS_REMOTE_OUT" ]; then
        echo "$MOCK_LS_REMOTE_OUT"
      fi
      return "$MOCK_LS_REMOTE_RC"
      ;;
    ls-tree)
      # 形式: git ls-tree --name-only HEAD -- <path>
      # 最後の引数（path）の basename で impl-notes / review-notes を判別
      local path="${args[$((${#args[@]} - 1))]}"
      case "$path" in
        */impl-notes.md)
          if [ -n "$MOCK_LS_TREE_IMPL_OUT" ]; then
            echo "$MOCK_LS_TREE_IMPL_OUT"
          fi
          return "$MOCK_LS_TREE_IMPL_RC"
          ;;
        */review-notes.md)
          if [ -n "$MOCK_LS_TREE_REVIEW_OUT" ]; then
            echo "$MOCK_LS_TREE_REVIEW_OUT"
          fi
          return "$MOCK_LS_TREE_REVIEW_RC"
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      return 0
      ;;
  esac
}
export -f git

# timeout の stub: 引数の最初の token（秒数）を捨てて残りを実行する。
# `git ls-remote` 経路の `timeout 30 git ls-remote ...` を再現するため。
timeout() {
  shift  # 秒数を捨てる
  "$@"
}
export -f timeout

# ─── アサーションヘルパ ───
PASS=0
FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  needle  : $(printf '%q' "$needle")"
      echo "  haystack: $(printf '%q' "$haystack")"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

# ─── テスト環境のセットアップ ───
TMP_LOG=$(mktemp -t resumable-state-test-XXXXXX.log)
TMP_REPO=$(mktemp -d -t resumable-state-repo-XXXXXX)
mkdir -p "$TMP_REPO/docs/specs/383-test-slug"
export LOG="$TMP_LOG"
export REPO_DIR="$TMP_REPO"
export REPO="owner/test"
trap 'rm -f "$TMP_LOG"; rm -rf "$TMP_REPO"' EXIT

# 各ケース実行前に MOCK 変数を全 reset するヘルパ
reset_mocks() {
  MOCK_FIND_IMPL_PR_RC=1
  MOCK_FIND_IMPL_PR_OUT=""
  MOCK_LS_REMOTE_RC=0
  MOCK_LS_REMOTE_OUT=""
  MOCK_LS_TREE_IMPL_RC=0
  MOCK_LS_TREE_IMPL_OUT=""
  MOCK_LS_TREE_REVIEW_RC=0
  MOCK_LS_TREE_REVIEW_OUT=""
  : > "$TMP_LOG"
}

SPEC_DIR="$TMP_REPO/docs/specs/383-test-slug"

# ─── テストケース ───

echo "--- _stage_checkpoint_has_resumable_state cases (Issue #383 Req 1, 2, 3, 4, NFR 2) ---"

# ===========================================================================
# Case 1: Req 1.2 — spec dir 存在 + 4 観点いずれも不在 → return 1（skip 経路）
# ===========================================================================
NUMBER=383
export NUMBER
reset_mocks
# 全 mock を「不在」状態のままにする
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 1.2: 4 観点不在 → return 1（skip 経路）" "1" "$rc"

# ===========================================================================
# Case 2: Req 3.1(a) — impl PR 実在 → return 0
# ===========================================================================
reset_mocks
MOCK_FIND_IMPL_PR_RC=0
MOCK_FIND_IMPL_PR_OUT="42,OPEN"
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 2.1/3.1(a): impl PR 実在 → return 0" "0" "$rc"
assert_contains "Req 4.1: impl PR 実在ログに observation=impl-pr が含まれる" \
  "stage-checkpoint: resumable-state-found issue=#383 observation=impl-pr" \
  "$(cat "$TMP_LOG")"

# ===========================================================================
# Case 3: Req 3.1(b) — origin impl-* ブランチ実在 → return 0
# ===========================================================================
reset_mocks
MOCK_LS_REMOTE_OUT="abc123	refs/heads/claude/issue-383-impl-test-slug"
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 2.1/3.1(b): origin impl branch 実在 → return 0" "0" "$rc"
assert_contains "Req 4.1: impl branch 実在ログに observation=impl-branch が含まれる" \
  "stage-checkpoint: resumable-state-found issue=#383 observation=impl-branch" \
  "$(cat "$TMP_LOG")"

# ===========================================================================
# Case 3b: Req 3.1(b) — slug 不問の prefix マッチ（mismatch slug でも検出する）
# 確認事項に従い、ブランチ slug が expected と異なっても resumable state として検出する
# ===========================================================================
reset_mocks
MOCK_LS_REMOTE_OUT="abc123	refs/heads/claude/issue-383-impl-different-slug"
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 3.1(b): slug 不問の prefix マッチで mismatch slug ブランチも検出" "0" "$rc"

# ===========================================================================
# Case 4: Req 3.1(c) — impl-notes.md tracked → return 0
# ===========================================================================
reset_mocks
MOCK_LS_TREE_IMPL_OUT="docs/specs/383-test-slug/impl-notes.md"
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 2.1/3.1(c): impl-notes.md tracked → return 0" "0" "$rc"
assert_contains "Req 4.1: impl-notes 検出ログに observation=impl-notes が含まれる" \
  "stage-checkpoint: resumable-state-found issue=#383 observation=impl-notes" \
  "$(cat "$TMP_LOG")"

# ===========================================================================
# Case 5: Req 3.1(d) — review-notes.md tracked → return 0
# ===========================================================================
reset_mocks
MOCK_LS_TREE_REVIEW_OUT="docs/specs/383-test-slug/review-notes.md"
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 2.1/3.1(d): review-notes.md tracked → return 0" "0" "$rc"
assert_contains "Req 4.1: review-notes 検出ログに observation=review-notes が含まれる" \
  "stage-checkpoint: resumable-state-found issue=#383 observation=review-notes" \
  "$(cat "$TMP_LOG")"

# ===========================================================================
# Case 6: Req 3.1 OR — 4 観点が OR で判定される（複数同時に真でも 1 件目で return 0）
# 既に Case 2-5 で個別観点を確認したことが OR 性の証拠（OR semantics: any 1 → return 0）
# ===========================================================================
reset_mocks
MOCK_FIND_IMPL_PR_RC=0
MOCK_FIND_IMPL_PR_OUT="99,MERGED"
MOCK_LS_REMOTE_OUT="abc	refs/heads/claude/issue-383-impl-x"
MOCK_LS_TREE_IMPL_OUT="docs/specs/383-test-slug/impl-notes.md"
MOCK_LS_TREE_REVIEW_OUT="docs/specs/383-test-slug/review-notes.md"
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 3.1: 4 観点全部真 → return 0（OR 判定）" "0" "$rc"

# ===========================================================================
# Case 7: NFR 2.1 — gh API 失敗（stage_checkpoint_find_impl_pr rc=2）+ 他観点不在
#         → return 2（safe-side）
# ===========================================================================
reset_mocks
MOCK_FIND_IMPL_PR_RC=2
MOCK_FIND_IMPL_PR_OUT=""
# 他観点は不在のまま
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "NFR 2.1: gh API 失敗 + 他観点不在 → return 2（safe-side）" "2" "$rc"

# ===========================================================================
# Case 8: NFR 2.1 — git ls-remote 失敗 + 他観点不在 → return 2（safe-side）
# ===========================================================================
reset_mocks
MOCK_LS_REMOTE_RC=128
# その他観点は不在のまま
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "NFR 2.1: git ls-remote 失敗 + 他観点不在 → return 2（safe-side）" "2" "$rc"

# ===========================================================================
# Case 9: NFR 2.1 — gh API 失敗だが impl-notes tracked → return 0（観測成功優先）
# 「観測失敗があっても 1 つでも実在観測が成功すれば実在として扱う」semantics の確認
# ===========================================================================
reset_mocks
MOCK_FIND_IMPL_PR_RC=2
MOCK_LS_TREE_IMPL_OUT="docs/specs/383-test-slug/impl-notes.md"
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "NFR 2.1: 観測失敗があっても 1 つ実在ヒットすれば return 0" "0" "$rc"

# ===========================================================================
# Case 10: Req 3.1 入力検証 — NUMBER 未設定 → return 2（safe-side）
# ===========================================================================
reset_mocks
unset NUMBER
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "NFR 2.1: NUMBER 未設定 → return 2（safe-side）" "2" "$rc"
NUMBER=383
export NUMBER

# ===========================================================================
# Case 11: Req 3.1 入力検証 — NUMBER 非数値 → return 2（safe-side）
# ===========================================================================
reset_mocks
NUMBER="abc"
export NUMBER
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "NFR 2.1: NUMBER 非数値 → return 2（safe-side）" "2" "$rc"
NUMBER=383
export NUMBER

# ===========================================================================
# Case 12: Req 4.1 — skip 経路では resumable-state-found ログを出さない
# ===========================================================================
reset_mocks
rc=0
_stage_checkpoint_has_resumable_state "$SPEC_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "Req 1.2: 4 観点不在 → return 1" "1" "$rc"
# Skip 経路では resumable-state-found ログを出さない
case "$(cat "$TMP_LOG")" in
  *"resumable-state-found"*)
    echo "FAIL: Req 4.1: skip 経路で resumable-state-found ログが出ている"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "PASS: Req 4.1: skip 経路では resumable-state-found ログを出さない"
    PASS=$((PASS + 1))
    ;;
esac

echo ""
echo "==========================================="
echo "PASS: $PASS, FAIL: $FAIL"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
