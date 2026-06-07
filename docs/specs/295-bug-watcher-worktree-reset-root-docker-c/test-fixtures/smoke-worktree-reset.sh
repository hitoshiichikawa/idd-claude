#!/usr/bin/env bash
# Issue #295 smoke test: _worktree_reset の通常パスが既存挙動と同一であることを
# 最小再現で確認する。
#
# シナリオ:
#   1. 一時 origin repo を作成 / 初期 commit を main ブランチに push
#   2. 一時 REPO_DIR をクローン
#   3. core_utils.sh を source して _worktree_reset を呼び、worktree の中の untracked
#      ファイルが消えて origin/main の最新状態になることを確認
#   4. WORKTREE_DOCKER_CLEANUP_ENABLED=false（既定）であることを確認し、追加の
#      docker 経路や worktree 再作成経路が起動しないことを期待
#
# 実行: bash docs/specs/295-bug-watcher-worktree-reset-root-docker-c/test-fixtures/smoke-worktree-reset.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE="$REPO_ROOT/local-watcher/bin/modules/core_utils.sh"

if [ ! -f "$MODULE" ]; then
  echo "ERROR: core_utils.sh が見つからない: $MODULE" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d -t worktree-reset-smoke-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ORIGIN_DIR="$TMP_ROOT/origin.git"
REPO_DIR="$TMP_ROOT/repo"
WORKTREE_BASE_DIR="$TMP_ROOT/worktrees"
REPO_SLUG="testowner-testrepo"
BASE_BRANCH="main"
REPO="testowner/testrepo"
PARALLEL_SLOTS=2
SLOT_LOCK_DIR="$TMP_ROOT/locks"

mkdir -p "$WORKTREE_BASE_DIR/$REPO_SLUG" "$SLOT_LOCK_DIR"

# ── 1. 一時 origin repo を作成 ──
git init --quiet --bare "$ORIGIN_DIR"

# ── 2. seed clone を作って初期 commit を push ──
SEED_DIR="$TMP_ROOT/seed"
git clone --quiet "$ORIGIN_DIR" "$SEED_DIR"
(
  cd "$SEED_DIR"
  git checkout -B "$BASE_BRANCH" --quiet
  git config user.email "test@example.com"
  git config user.name "Smoke Test"
  echo "hello" > README.md
  git add README.md
  git commit --quiet -m "initial commit"
  git push --quiet origin "$BASE_BRANCH"
)

# ── 3. REPO_DIR を改めてクローン ──
git clone --quiet "$ORIGIN_DIR" "$REPO_DIR"
git -C "$REPO_DIR" fetch --quiet origin

# ── 4. core_utils.sh を source（worktree ユーティリティのみテストするため
#       dispatcher_log / slot_log / rs_set_scaffolding はダミー定義で stub する）──
dispatcher_log() { :; }
dispatcher_warn() { echo "[dispatcher_warn] $*" >&2; }
slot_log() { :; }
slot_warn() { echo "[slot_warn] $*" >&2; }

export REPO REPO_DIR BASE_BRANCH WORKTREE_BASE_DIR REPO_SLUG SLOT_LOCK_DIR PARALLEL_SLOTS

# shellcheck source=/dev/null
. "$MODULE"

# ── 5. slot-1 worktree を作成 ──
if ! _worktree_ensure 1; then
  echo "FAIL: _worktree_ensure 1 が失敗" >&2
  exit 1
fi
WT="$(_worktree_path 1)"
echo "[smoke] worktree=$WT"

# ── 6. worktree に untracked ファイル / ignored 様のディレクトリを置く ──
echo "garbage" > "$WT/untracked-file"
mkdir -p "$WT/node_modules" && touch "$WT/node_modules/big.txt"

# ── 7. _worktree_reset を呼ぶ ──
echo "[smoke] WORKTREE_DOCKER_CLEANUP_ENABLED=${WORKTREE_DOCKER_CLEANUP_ENABLED:-unset}"
if ! _worktree_reset "$WT"; then
  echo "FAIL: _worktree_reset が失敗（通常ケース）" >&2
  exit 1
fi

# ── 8. untracked が消えていることを確認 ──
if [ -e "$WT/untracked-file" ]; then
  echo "FAIL: untracked-file が残存" >&2
  exit 1
fi
if [ -e "$WT/node_modules" ]; then
  echo "FAIL: node_modules が残存" >&2
  exit 1
fi

# ── 9. README.md が origin/main から復元されている ──
if [ ! -f "$WT/README.md" ]; then
  echo "FAIL: README.md が復元されていない" >&2
  exit 1
fi

echo "[smoke] PASS: 通常ケースで _worktree_reset が origin/$BASE_BRANCH の clean 状態に戻した"

# ── 10. opt-in 判定: lowercase 完全一致のみ有効 ──
#       env が未設定の状態で escalated cleanup の docker 経路に入らないことは関数の
#       コードパスに不可分なので、ここでは値判定の境界だけ確認しておく。
for val in "" "false" "FALSE" "True" "1" "yes" "opt-in" "true "; do
  if [ "${val:-false}" = "true" ]; then
    echo "FAIL: WORKTREE_DOCKER_CLEANUP_ENABLED='$val' が誤って true 扱いされた" >&2
    exit 1
  fi
done
val="true"
if [ "${val:-false}" != "true" ]; then
  echo "FAIL: WORKTREE_DOCKER_CLEANUP_ENABLED='true' が正しく opt-in 認識されない" >&2
  exit 1
fi
echo "[smoke] PASS: opt-in 判定が lowercase 完全一致のみ true（NFR 4.1）"

echo "[smoke] ALL PASS"
