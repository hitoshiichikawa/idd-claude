#!/usr/bin/env bash
# 用途: spec #286 Req 1.3 / NFR 2.2 の空プロンプト・フェイルセーフを検証する。
#       `sec_execute_security_review` を一時 git repo 環境で直接呼び出し、
#       `SECURITY_REVIEW_PROMPT=""` 状態で:
#         (a) result_file の内容が `empty-prompt\n`（exactly 1 行）であること
#         (b) `git status --porcelain` が空（read-only invariant 維持）であること
#       を assert する。CLI（`claude`）は起動されないため網外依存はない。
# 配置先: docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-empty-prompt-shortcircuit.sh
# 依存: bash 4+, git。`claude` / `gh` は呼び出されない（空プロンプト早期 short-circuit）。
# セットアップ参照先: docs/specs/286-fix-watcher-security-review-processor-sc/impl-notes.md
#
# Usage:
#   bash docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-empty-prompt-shortcircuit.sh
#
# Exit code:
#   0 = ガード分岐が成立（result_file=empty-prompt + ワークツリー無変更）
#   1 = 失敗（assert の詳細は stderr）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
SEC_MODULE="$REPO_ROOT/local-watcher/bin/modules/security-review.sh"
CORE_UTILS="$REPO_ROOT/local-watcher/bin/modules/core_utils.sh"

for f in "$SEC_MODULE" "$CORE_UTILS"; do
  if [ ! -f "$f" ]; then
    echo "[FATAL] required module not found: $f" >&2
    exit 1
  fi
done

# 一時 git repo を用意（base / head 2 ブランチ + 同じ commit を双方に持たせる）。
TMPDIR_BASE=$(mktemp -d -t idd-claude-sec286-XXXXXX)
cleanup() {
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

REPO_TMP="$TMPDIR_BASE/repo"
ORIGIN_TMP="$TMPDIR_BASE/origin.git"

# origin 用の bare repo
git init --quiet --bare "$ORIGIN_TMP"

# 作業 repo
git init --quiet "$REPO_TMP"
cd "$REPO_TMP"
git config user.email "smoke@example.com"
git config user.name "smoke"
git checkout --quiet -b main
echo "base" > README.txt
git add README.txt
git commit --quiet -m "base"
git remote add origin "$ORIGIN_TMP"
git push --quiet origin main

# head ブランチを作成して同一 commit を origin に push（fetch / checkout が成立する状態）
HEAD_REF="claude/issue-286-smoke"
git checkout --quiet -b "$HEAD_REF" main
git push --quiet origin "$HEAD_REF"

# base に戻しておく（`sec_execute_security_review` の EXIT trap が
# `git checkout '${BASE_BRANCH}'` を呼ぶため）
git checkout --quiet main

# 依存 env（モジュールが参照する最低限のもの）
export REPO="example/test-286"
export BASE_BRANCH="main"
export SECURITY_REVIEW_GIT_TIMEOUT="30"
export SECURITY_REVIEW_EXEC_TIMEOUT="30"

# core_utils.sh / security-review.sh を source する。両 module は top-level に
# 関数定義のみを並べる形式で副作用を起こさない（既存実装慣習）。
# shellcheck source=/dev/null
source "$CORE_UTILS"
# shellcheck source=/dev/null
source "$SEC_MODULE"

# 空プロンプト状態（Config ブロックの export を意図的に無効化した状態を再現）
export SECURITY_REVIEW_PROMPT=""

# 一時 result_file / out_file / err_file を用意
out_file=$(mktemp -t idd-claude-sec286-out.XXXXXX)
err_file=$(mktemp -t idd-claude-sec286-err.XXXXXX)
result_file=$(mktemp -t idd-claude-sec286-res.XXXXXX)

# `resolved_cmd` は実行されない（空プロンプトで short-circuit）ため、防御的に
# 「失敗したらすぐ分かる」コマンドを渡す（万一 CLI 経路に流れた場合の検出用）。
resolved_cmd='echo "SHOULD_NOT_RUN" >&2; exit 99'

# 直接呼び出し
sec_execute_security_review "$HEAD_REF" "$resolved_cmd" "$out_file" "$err_file" "$result_file"

# (a) result_file が exactly `empty-prompt\n` であること
result_content=$(cat "$result_file")
expected="empty-prompt"
if [ "$result_content" != "$expected" ]; then
  echo "[FAIL] result_file が期待値と一致しません" >&2
  echo "        expected: '${expected}'" >&2
  echo "        actual:   '${result_content}'" >&2
  echo "        --- out_file ---" >&2
  cat "$out_file" >&2 || true
  echo "        --- err_file ---" >&2
  cat "$err_file" >&2 || true
  rm -f "$out_file" "$err_file" "$result_file"
  exit 1
fi

# (b) read-only invariant（CLI 未起動のためワークツリー変更は構造的に起きない）
worktree_status=$(git status --porcelain)
if [ -n "$worktree_status" ]; then
  echo "[FAIL] ワークツリーに変更が検出されました（read-only invariant 違反）" >&2
  echo "        git status --porcelain:" >&2
  echo "$worktree_status" >&2
  rm -f "$out_file" "$err_file" "$result_file"
  exit 1
fi

# (c) resolved_cmd が実行されていないことの追加保証（err_file に SHOULD_NOT_RUN なし）
if grep -q "SHOULD_NOT_RUN" "$err_file" 2>/dev/null; then
  echo "[FAIL] 空プロンプト状態にもかかわらず resolved_cmd が起動されました" >&2
  cat "$err_file" >&2
  rm -f "$out_file" "$err_file" "$result_file"
  exit 1
fi

rm -f "$out_file" "$err_file" "$result_file"
echo "OK: test-empty-prompt-shortcircuit"
