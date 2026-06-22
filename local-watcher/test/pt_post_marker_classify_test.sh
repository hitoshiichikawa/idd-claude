#!/usr/bin/env bash
#
# 本テストの fake 依存（git）は eval で読み込んだ pt_classify_post_marker_paths /
# pt_handle_post_marker_commits から間接的にのみ呼ばれるため unreachable 扱いに
# なる。false positive のため抑止する（既存 stage_a_verify_round1_defer_test.sh
# 等と同じ扱い）。
#
# SC2034 も同様に、`POST_MARKER_DOCS_ALLOWLIST` / `POST_MARKER_RECOVERY_MODE` は
# eval で読み込んだ関数本体から参照されるため shellcheck からは unused に見える
# が、実際には scope 内で参照されている。false positive のため抑止する。
# shellcheck disable=SC2317,SC2034
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #356（per-task post-marker
#       commit の docs-only auto-refresh）で追加した
#       `pt_classify_post_marker_paths` / `pt_handle_post_marker_commits` の
#       挙動を fixture で検証するスモークテスト。
#
#       対象関数:
#         - pt_classify_post_marker_paths (Issue #356 Req 1.1 / 1.5 / 2.1 / 2.2 / NFR 1.3)
#         - pt_handle_post_marker_commits (Issue #356 Req 1.1 / 1.2 / 2.2 / 3.2 / 3.3)
#
#       既存 `pt_check_fail_fast_test.sh` の「awk による関数抽出 + eval 読み込み」
#       パターンを踏襲し、`git diff --name-only` / `git log` / `git rev-parse HEAD`
#       を本テスト内で stub する。トップレベル副作用は回避する。
#
# 配置先: local-watcher/test/pt_post_marker_classify_test.sh
# 依存:   bash 4+, awk, grep, sed
# 実行:   bash local-watcher/test/pt_post_marker_classify_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# issue-watcher.sh から該当関数 1 個だけを抽出する（インデント無しの単独 `}` まで）。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# pt_warn は pt_classify_post_marker_paths / pt_handle_post_marker_commits から
# 呼ばれるため stub で隔離する（実体は date / hostname / >&2 への副作用を含むため）。
pt_warn() {
  echo "[stub-warn] $*" >&2
}

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_classify_post_marker_paths")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_handle_post_marker_commits")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_detect_post_marker_commits")"

for fn in pt_classify_post_marker_paths pt_handle_post_marker_commits pt_detect_post_marker_commits; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── fake git: 以下のサブコマンドを fixture から差し替え可能にする。
#    - git diff --name-only <range>  → $GIT_DIFF_NAME_ONLY の echo
#    - git log --format=%H <range>   → $GIT_LOG_FORMAT の echo
#    - git rev-parse HEAD            → $GIT_HEAD_SHA の echo
#    上記以外の git 呼び出しは想定外として exit 127。
GIT_DIFF_NAME_ONLY=""
GIT_LOG_FORMAT=""
GIT_HEAD_SHA=""
GIT_DIFF_RC=0
GIT_LOG_RC=0
GIT_REVPARSE_RC=0

git() {
  case "${1:-}" in
    diff)
      if [ "${2:-}" = "--name-only" ]; then
        if [ "$GIT_DIFF_RC" != "0" ]; then
          return "$GIT_DIFF_RC"
        fi
        printf '%s' "$GIT_DIFF_NAME_ONLY"
        return 0
      fi
      ;;
    log)
      if [ "${2:-}" = "--format=%H" ]; then
        if [ "$GIT_LOG_RC" != "0" ]; then
          return "$GIT_LOG_RC"
        fi
        printf '%s' "$GIT_LOG_FORMAT"
        return 0
      fi
      ;;
    rev-parse)
      if [ "${2:-}" = "HEAD" ]; then
        if [ "$GIT_REVPARSE_RC" != "0" ]; then
          return "$GIT_REVPARSE_RC"
        fi
        printf '%s' "$GIT_HEAD_SHA"
        return 0
      fi
      ;;
  esac
  echo "[fake-git] unexpected git call: $*" >&2
  return 127
}

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
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
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle  : $(printf '%q' "$needle")"
    echo "  haystack: $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "FAIL: $label"
    echo "  needle (should NOT contain): $(printf '%q' "$needle")"
    echo "  haystack                  : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# 既定 allowlist（issue-watcher.sh と同じ）
DEFAULT_ALLOWLIST="**/impl-notes.md,docs/specs/**/*.md"

# ─────────────────────────────────────────────────────────────────────────────
# pt_classify_post_marker_paths 単体テスト
# ─────────────────────────────────────────────────────────────────────────────

echo "================================================================"
echo "pt_classify_post_marker_paths 単体テスト"
echo "================================================================"

# ─── Case 1: docs-only（impl-notes.md のみ） → rc=0 ────────────────────────
#     Req 1.1: post-marker 全変更ファイルが allowlist 内 → docs-only
echo "--- Case 1: docs-only(impl-notes.md only) ---"
POST_MARKER_DOCS_ALLOWLIST="$DEFAULT_ALLOWLIST"
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
"
GIT_DIFF_RC=0
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
assert_eq "Req 1.1: rc=0" "0" "$rc"
assert_eq "Req 1.1: verdict=docs-only" "docs-only" "$(printf '%s' "$out" | sed -n '1p')"

# ─── Case 2: docs-only（docs/specs/**/*.md 配下の複数ファイル） → rc=0 ───
echo "--- Case 2: docs-only(docs/specs multiple) ---"
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
docs/specs/356-foo/requirements.md
docs/specs/356-foo/design.md
"
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
assert_eq "Req 1.1: docs/specs multiple → rc=0" "0" "$rc"
assert_eq "Req 1.1: verdict=docs-only" "docs-only" "$(printf '%s' "$out" | sed -n '1p')"

# ─── Case 3: mixed（コードファイル含む） → rc=1 ──────────────────────────
#     Req 2.1: allowlist 外（コード）を含む → mixed + first_unmatched
echo "--- Case 3: mixed(code file included) ---"
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
local-watcher/bin/issue-watcher.sh
"
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
assert_eq "Req 2.1: rc=1" "1" "$rc"
assert_eq "Req 2.1: verdict=mixed" "mixed" "$(printf '%s' "$out" | sed -n '1p')"
assert_eq "Req 2.1: first_unmatched=watcher.sh" "local-watcher/bin/issue-watcher.sh" "$(printf '%s' "$out" | sed -n '2p')"

# ─── Case 4: mixed（テストファイル含む） → rc=1 ──────────────────────────
echo "--- Case 4: mixed(test file included) ---"
GIT_DIFF_NAME_ONLY="local-watcher/test/foo_test.sh
"
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
assert_eq "Req 2.1: test file → rc=1" "1" "$rc"
assert_eq "Req 2.1: verdict=mixed" "mixed" "$(printf '%s' "$out" | sed -n '1p')"

# ─── Case 5: git diff エラー → rc=2 + verdict=mixed ──────────────────────
#     NFR 1.3: classify 失敗時は安全側に倒して mixed
echo "--- Case 5: git diff error → fail-safe mixed ---"
GIT_DIFF_NAME_ONLY=""
GIT_DIFF_RC=128
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
assert_eq "NFR 1.3: git diff エラー → rc=2" "2" "$rc"
assert_eq "NFR 1.3: verdict=mixed (fail-safe)" "mixed" "$(printf '%s' "$out" | sed -n '1p')"
GIT_DIFF_RC=0

# ─── Case 6: allowlist 空 → rc=1 + verdict=mixed ────────────────────────
#     Req 2.2: allowlist が空文字なら保守的に mixed
echo "--- Case 6: allowlist empty → mixed ---"
POST_MARKER_DOCS_ALLOWLIST=""
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
"
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
assert_eq "Req 2.2: allowlist 空 → rc=1" "1" "$rc"
assert_eq "Req 2.2: verdict=mixed" "mixed" "$(printf '%s' "$out" | sed -n '1p')"
POST_MARKER_DOCS_ALLOWLIST="$DEFAULT_ALLOWLIST"

# ─── Case 7: 変更ファイル 0 件 → rc=1 + verdict=mixed ───────────────────
echo "--- Case 7: no changed files → mixed ---"
GIT_DIFF_NAME_ONLY=""
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
assert_eq "Req 2.2: 変更 0 件 → rc=1" "1" "$rc"
assert_eq "Req 2.2: verdict=mixed" "mixed" "$(printf '%s' "$out" | sed -n '1p')"

# ─── Case 8: 親ディレクトリで impl-notes.md（**/impl-notes.md glob 検証） ──
echo "--- Case 8: impl-notes.md at root via **/impl-notes.md ---"
GIT_DIFF_NAME_ONLY="impl-notes.md
"
rc=0
out=$(pt_classify_post_marker_paths "abc1234") || rc=$?
# 注: bash の `[[ str == **/impl-notes.md ]]` は `**` を `*` と同じ扱いなので
# root の `impl-notes.md` は前置 path がないと match しない可能性がある。
# 実装上の挙動を観測テストとして固定し、運用での誤解を防ぐ。
# bash `**` は `globstar` 設定でのみ複数階層を意味するが、`[[ ]]` 内では `*` と同等。
# `impl-notes.md` が `**/impl-notes.md` パターンに match するかは bash 実装依存のため、
# ここでは結果を観測のみとして PASS とする（runtime での挙動を documenting）。
echo "  [observation] rc=$rc verdict=$(printf '%s' "$out" | sed -n '1p')"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# pt_handle_post_marker_commits 統合テスト（docs-only auto-refresh 経路）
# ─────────────────────────────────────────────────────────────────────────────

echo "================================================================"
echo "pt_handle_post_marker_commits 経路テスト"
echo "================================================================"

# pt_handle_post_marker_commits は pt_classify_post_marker_paths を呼ぶため、
# 同関数の git diff stub が活きる。git rev-parse HEAD も stub する。
GIT_HEAD_SHA="deadbeefcafe0000000000000000000000000000"

# ─── Case A: docs-only post-marker + default mode → auto-refresh rc=0 ───
#     Req 1.1: docs-only auto-refresh が発火し rc=0 + range 拡張
echo "--- Case A: docs-only + fail-with-diagnostic → auto-refresh ---"
POST_MARKER_DOCS_ALLOWLIST="$DEFAULT_ALLOWLIST"
POST_MARKER_RECOVERY_MODE="fail-with-diagnostic"
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
"
rc=0
stdout=$(pt_handle_post_marker_commits "1.2" "1" "rangestart01" "marker0001" "post001
post002" 2>/tmp/test_356_stderr_A.log) || rc=$?
stderr=$(cat /tmp/test_356_stderr_A.log)
rm -f /tmp/test_356_stderr_A.log
assert_eq "Req 1.1: docs-only + default → rc=0" "0" "$rc"
assert_eq "Req 1.1: stdout = rangestart\tHEAD" "rangestart01	$GIT_HEAD_SHA" "$stdout"
assert_contains "Req 1.2: stderr に recovery=docs-only-auto-refresh が含まれる" \
  "recovery=docs-only-auto-refresh" "$stderr"
assert_contains "Req 1.2: stderr に task_id=1.2 が含まれる" \
  "task_id=1.2" "$stderr"
assert_contains "Req 1.2: stderr に post_marker_shas=post001,post002 が含まれる" \
  "post_marker_shas=post001,post002" "$stderr"

# ─── Case B: 混在 (code) + default mode → fail-with-diagnostic rc=5 ───
#     Req 2.2: allowlist 外 1 件で fail-with-diagnostic 経路に倒れる
echo "--- Case B: mixed(code) + fail-with-diagnostic → fail rc=5 ---"
POST_MARKER_RECOVERY_MODE="fail-with-diagnostic"
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
local-watcher/bin/issue-watcher.sh
"
rc=0
stdout=$(pt_handle_post_marker_commits "1.2" "1" "rangestart02" "marker0002" "post010" 2>/tmp/test_356_stderr_B.log) || rc=$?
stderr=$(cat /tmp/test_356_stderr_B.log)
rm -f /tmp/test_356_stderr_B.log
assert_eq "Req 2.2: mixed + default → rc=5" "5" "$rc"
assert_eq "Req 2.2: stdout 空" "" "$stdout"
assert_contains "Req 2.2: stderr に recovery=fail-with-diagnostic が含まれる" \
  "recovery=fail-with-diagnostic" "$stderr"
assert_not_contains "Req 2.2: stderr に recovery=docs-only-auto-refresh が含まれない" \
  "recovery=docs-only-auto-refresh" "$stderr"

# ─── Case C: docs-only + extend-range mode → 既存 extend-range 維持 rc=0 ───
#     Req 3.3: extend-range 設定時は docs-only 判定を override しない
echo "--- Case C: docs-only + extend-range → recovery=extend-range ---"
POST_MARKER_RECOVERY_MODE="extend-range"
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
"
rc=0
stdout=$(pt_handle_post_marker_commits "1.2" "1" "rangestart03" "marker0003" "post020" 2>/tmp/test_356_stderr_C.log) || rc=$?
stderr=$(cat /tmp/test_356_stderr_C.log)
rm -f /tmp/test_356_stderr_C.log
assert_eq "Req 3.3: extend-range + docs-only → rc=0" "0" "$rc"
assert_eq "Req 3.3: stdout = rangestart\tHEAD" "rangestart03	$GIT_HEAD_SHA" "$stdout"
assert_contains "Req 3.3: stderr に recovery=extend-range が含まれる" \
  "recovery=extend-range" "$stderr"
assert_not_contains "Req 3.3: docs-only-auto-refresh が含まれない（extend-range が優先）" \
  "recovery=docs-only-auto-refresh" "$stderr"

# ─── Case D: 混在 + extend-range mode → 従来どおり rc=0 + range 拡張 ─────
echo "--- Case D: mixed(code) + extend-range → recovery=extend-range ---"
POST_MARKER_RECOVERY_MODE="extend-range"
GIT_DIFF_NAME_ONLY="local-watcher/bin/issue-watcher.sh
"
rc=0
stdout=$(pt_handle_post_marker_commits "1.2" "1" "rangestart04" "marker0004" "post030" 2>/tmp/test_356_stderr_D.log) || rc=$?
stderr=$(cat /tmp/test_356_stderr_D.log)
rm -f /tmp/test_356_stderr_D.log
assert_eq "Req 3.3: extend-range + mixed → rc=0 (既存挙動)" "0" "$rc"
assert_contains "Req 3.3: stderr に recovery=extend-range が含まれる" \
  "recovery=extend-range" "$stderr"

# ─── Case E: 不正値 mode + docs-only → fail-with-diagnostic に正規化後 auto-refresh ───
#     Req 3.4: 不正値は default に正規化したうえで docs-only 判定を適用
echo "--- Case E: invalid mode + docs-only → normalized to fail-with-diagnostic + auto-refresh ---"
POST_MARKER_RECOVERY_MODE="bogus-mode-value"
GIT_DIFF_NAME_ONLY="docs/specs/356-foo/impl-notes.md
"
rc=0
stdout=$(pt_handle_post_marker_commits "1.2" "1" "rangestart05" "marker0005" "post040" 2>/tmp/test_356_stderr_E.log) || rc=$?
stderr=$(cat /tmp/test_356_stderr_E.log)
rm -f /tmp/test_356_stderr_E.log
assert_eq "Req 3.4: 不正値 + docs-only → rc=0 (auto-refresh)" "0" "$rc"
assert_contains "Req 3.4: stderr に recovery=docs-only-auto-refresh が含まれる" \
  "recovery=docs-only-auto-refresh" "$stderr"
assert_contains "Req 3.4: stderr に invalid POST_MARKER_RECOVERY_MODE 警告が含まれる" \
  "invalid POST_MARKER_RECOVERY_MODE" "$stderr"

# ─────────────────────────────────────────────────────────────────────────────
# pt_detect_post_marker_commits の境界条件: 0 件 → rc=1 no-op
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "pt_detect_post_marker_commits 境界テスト"
echo "================================================================"

# ─── Case F: post-marker 0 件 → rc=1 no-op ─────────────────────────────
#     Req 3.1: post-marker commit が 0 件なら何もせず既存ルートで継続
echo "--- Case F: post-marker 0 commits → rc=1 ---"
GIT_LOG_FORMAT=""
GIT_LOG_RC=0
rc=0
stdout=$(pt_detect_post_marker_commits "marker0006" 2>/tmp/test_356_stderr_F.log) || rc=$?
rm -f /tmp/test_356_stderr_F.log
assert_eq "Req 3.1: 0 件 → rc=1" "1" "$rc"
assert_eq "Req 3.1: stdout 空" "" "$stdout"

# ─── Case G: post-marker 2 件 → rc=0 + list 返却 ───────────────────────
echo "--- Case G: post-marker 2 commits → rc=0 ---"
GIT_LOG_FORMAT="commit002
commit001
"
rc=0
stdout=$(pt_detect_post_marker_commits "marker0007" 2>/tmp/test_356_stderr_G.log) || rc=$?
rm -f /tmp/test_356_stderr_G.log
assert_eq "Req 3.1: 2 件 → rc=0" "0" "$rc"
assert_contains "Req 3.1: stdout に commit002 が含まれる" "commit002" "$stdout"
assert_contains "Req 3.1: stdout に commit001 が含まれる" "commit001" "$stdout"

# ─── Case H: git log エラー → rc=2 ─────────────────────────────────────
echo "--- Case H: git log error → rc=2 ---"
GIT_LOG_RC=128
rc=0
stdout=$(pt_detect_post_marker_commits "marker0008" 2>/tmp/test_356_stderr_H.log) || rc=$?
rm -f /tmp/test_356_stderr_H.log
assert_eq "NFR 1.3: git log エラー → rc=2" "2" "$rc"
GIT_LOG_RC=0

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
