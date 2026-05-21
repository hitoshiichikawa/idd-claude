#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# extract-driver.sh — stage_a_verify_extract_command の fixture 回帰テスト
#
# 用途: `local-watcher/bin/issue-watcher.sh` 内の `stage_a_verify_extract_command`
#       関数を fixture (`fixtures/tasks-*.md`) に対して走らせ、期待文字列と
#       diff する。全件 pass で exit 0、不一致あれば該当 fixture 名と期待 / 実測
#       を出力して exit 1。
#
# 配置: tests/local-watcher/stage-a-verify/extract-driver.sh
# 依存: bash 4+, awk, mktemp
# 設計参照: docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/design.md
#           (Testing Strategy / Unit-level)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# 自身の場所から repo root を解決する（呼び出し元 cwd に依存しない）。
_DRV_DIR="$(cd "$(dirname "$0")" && pwd)"
_REPO_ROOT="$(cd "$_DRV_DIR/../../.." && pwd)"
_WATCHER_SH="$_REPO_ROOT/local-watcher/bin/issue-watcher.sh"
_FIXTURE_DIR="$_DRV_DIR/fixtures"

if [ ! -f "$_WATCHER_SH" ]; then
  echo "ERROR: watcher script not found at $_WATCHER_SH" >&2
  exit 2
fi
if [ ! -d "$_FIXTURE_DIR" ]; then
  echo "ERROR: fixture dir not found at $_FIXTURE_DIR" >&2
  exit 2
fi

# watcher 本体を source するとメイン処理が走るため、対象関数だけを抽出して source する。
# `stage_a_verify_extract_command()` から最初の単独 `^}` までを切り出す。
_EXTRACTED=$(mktemp -t sav-extract-XXXXXX.sh)
trap 'rm -f "$_EXTRACTED"' EXIT
awk '
  /^stage_a_verify_extract_command\(\) \{/ { found = 1 }
  found { print }
  found && /^\}$/ { exit }
' "$_WATCHER_SH" > "$_EXTRACTED"

if ! [ -s "$_EXTRACTED" ]; then
  echo "ERROR: stage_a_verify_extract_command を $_WATCHER_SH から抽出できませんでした" >&2
  exit 2
fi

# shellcheck source=/dev/null
. "$_EXTRACTED"

# ── 期待値テーブル ──
# fixture 名 (basename without dir) → 期待出力 1 行。空文字列は「マッチなし
# （関数が exit 1 で抜ける）」を期待することを示す。
declare -A _SAV_EXPECTED=(
  ["tasks-gradlew.md"]="./gradlew assembleDebug"
  ["tasks-npm.md"]="npm test"
  ["tasks-cargo.md"]="cargo build && cargo test"
  ["tasks-go.md"]="go test ./..."
  ["tasks-pytest.md"]="pytest -x"
  ["tasks-make.md"]="make verify"
  ["tasks-bundle.md"]="bundle exec rspec"
  ["tasks-shellcheck.md"]="shellcheck local-watcher/bin/*.sh && actionlint .github/workflows/*.yml"
  ["tasks-no-verify.md"]=""
  ["tasks-deferrable.md"]="pytest tests/integration/"
  ["tasks-mixed.md"]="./gradlew assembleDebug && ./gradlew test"
  ["tasks-empty.md"]=""
)

_pass=0
_fail=0
_failed_names=()

# 各 fixture について、一時 spec dir に配置して `stage_a_verify_extract_command`
# を呼ぶ。関数は環境変数 REPO_DIR / SPEC_DIR_REL から tasks.md のパスを解決する
# ため、それらを設定して呼び出す。
for _fixture_path in "$_FIXTURE_DIR"/tasks-*.md; do
  _name=$(basename "$_fixture_path")
  if [ -z "${_SAV_EXPECTED[$_name]+set}" ]; then
    echo "WARN: 期待値テーブル未登録 fixture=$_name (skip)" >&2
    continue
  fi
  _expected="${_SAV_EXPECTED[$_name]}"

  _tmp_repo=$(mktemp -d -t sav-fix-XXXXXX)
  _spec_rel="docs/specs/125-test"
  mkdir -p "$_tmp_repo/$_spec_rel"
  cp "$_fixture_path" "$_tmp_repo/$_spec_rel/tasks.md"

  # 関数は環境変数 REPO_DIR / SPEC_DIR_REL を参照する。export で subshell に
  # 引き継ぐ（shellcheck SC2034 抑制兼用）。
  export REPO_DIR="$_tmp_repo"
  export SPEC_DIR_REL="$_spec_rel"
  _actual=$(stage_a_verify_extract_command 2>/dev/null || true)
  unset REPO_DIR SPEC_DIR_REL

  rm -rf "$_tmp_repo"

  if [ "$_actual" = "$_expected" ]; then
    _pass=$((_pass + 1))
    printf '  ok   %s\n' "$_name"
  else
    _fail=$((_fail + 1))
    _failed_names+=("$_name")
    printf '  FAIL %s\n' "$_name"
    printf '    expected: %q\n' "$_expected"
    printf '    actual:   %q\n' "$_actual"
  fi
done

echo
echo "summary: pass=$_pass fail=$_fail total=$((_pass + _fail))"

if [ "$_fail" -gt 0 ]; then
  echo "failed fixtures: ${_failed_names[*]}" >&2
  exit 1
fi
exit 0
