#!/usr/bin/env bash
#
# 本テストの fake 依存（git）は eval で読み込んだ pt_resolve_diff_range から
# 間接的にのみ呼ばれるため unreachable 扱いになる false positive を抑止する
# （既存 pt_post_marker_classify_test.sh と同じ扱い）。
# shellcheck disable=SC2317
#
# SC2034 も同様に、`BASE_BRANCH` は eval で読み込んだ pt_resolve_diff_range 内の
# `${BASE_BRANCH:-main}` から参照されるが shellcheck からは unused に見える。
# false positive のため抑止する。
# shellcheck disable=SC2034
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #421（per-task Reviewer の
#       diff-range 解決で trailing issue-ref suffix `(#<number>)` を許容する
#       拡張）における `pt_resolve_diff_range` 関数の挙動を fixture で
#       検証するスモークテスト。
#
#       対象 Requirements (Issue #421):
#         - Req 1.1 / 1.3 / 1.4 / 1.5: suffix 付き 単記 marker の解決と
#           `via=single-id-marker-with-suffix` 観測タグ
#         - Req 1.2: suffix 無し / suffix 付き 混在時の一意決定（時系列最終一致）
#         - Req 2.1 / 2.2 / 2.3: suffix 付き 連記 marker の解決と
#           `via=multi-id-marker-with-suffix` 観測タグ
#         - Req 3.1 / 3.2 / 3.3: 既存 suffix 無し marker の後方互換
#         - Req 4.1〜4.6: suffix 許容 / 拒否境界（空白なし / 括弧なし /
#           追加文字列 / 非数字 number / 単記＆連記の同一規則適用）
#         - Req 5.1: 該当 marker 不在で return 1
#         - NFR 1.1: 既存ログタグ `via=single-id-marker` / `via=multi-id-marker`
#           の文字列形式と発火条件を変更しないこと
#
#       既存 `pt_post_marker_classify_test.sh` の「awk による関数抽出 +
#       eval 読み込み」パターンを踏襲し、`git log` / `git rev-parse` を
#       本テスト内で stub する。トップレベル副作用は回避する。
#
# 配置先: local-watcher/test/pt_resolve_diff_range_test.sh
# 依存:   bash 4+, awk, grep, sed
# 実行:   bash local-watcher/test/pt_resolve_diff_range_test.sh

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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "pt_resolve_diff_range")"

if ! declare -F pt_resolve_diff_range >/dev/null; then
  echo "ERROR: pt_resolve_diff_range not loaded" >&2
  exit 2
fi

# ── fake git: 以下のサブコマンドを fixture から差し替え可能にする。
#    - git log --grep=^docs(tasks): mark  --format=%H<TAB>%s --reverse <range>
#        → $GIT_LOG_OUTPUT の echo
#    - git rev-parse <base>  → $GIT_REVPARSE_OUTPUT の echo
#    上記以外の git 呼び出しは想定外として exit 127。
GIT_LOG_OUTPUT=""
GIT_LOG_RC=0
GIT_REVPARSE_OUTPUT=""
GIT_REVPARSE_RC=0

git() {
  case "${1:-}" in
    log)
      if [ "$GIT_LOG_RC" != "0" ]; then
        return "$GIT_LOG_RC"
      fi
      printf '%s' "$GIT_LOG_OUTPUT"
      return 0
      ;;
    rev-parse)
      if [ "$GIT_REVPARSE_RC" != "0" ]; then
        return "$GIT_REVPARSE_RC"
      fi
      printf '%s' "$GIT_REVPARSE_OUTPUT"
      return 0
      ;;
  esac
  echo "[fake-git] unexpected git call: $*" >&2
  return 127
}

BASE_BRANCH="main"

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

# 一時 stderr ファイル管理
STDERR_TMP="$(mktemp -t pt_resolve_diff_range_stderr.XXXXXX)"
STDOUT_TMP="$(mktemp -t pt_resolve_diff_range_stdout.XXXXXX)"
trap 'rm -f "$STDERR_TMP" "$STDOUT_TMP"' EXIT

# run_resolve <task_id>
#
# stdout / stderr / rc を一時ファイルに残し、呼び出し側は以下の変数で参照する:
#   - $RESOLVE_STDOUT : stdout 全文（trailing newline は printf '%s' で除去済）
#   - $RESOLVE_STDERR : stderr 全文
#   - $RESOLVE_RC     : 終了コード
#
# 注: pt_resolve_diff_range は while ループ内で stdin リダイレクト (<<<) を使うため、
# `command || rc=$?` イディオムを使うと subshell が走るリスクがある（実際には bash の
# `||` は subshell を作らないが、関数の安全な実行のため明示的に rc を保存する）。
run_resolve() {
  local _task_id="$1"
  RESOLVE_RC=0
  pt_resolve_diff_range "$_task_id" >"$STDOUT_TMP" 2>"$STDERR_TMP" || RESOLVE_RC=$?
  RESOLVE_STDOUT="$(cat "$STDOUT_TMP")"
  RESOLVE_STDERR="$(cat "$STDERR_TMP")"
}

echo "================================================================"
echo "pt_resolve_diff_range 単体テスト (Issue #421 / 既存 #164 回帰)"
echo "================================================================"

# ───────────────────────────────────────────────────────────────────
# Section A: Req 1 — suffix 付き 単記 marker の解決
# ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Req 1.1: suffix 付き 単記 marker のみ → 解決 ---"
# task 5 の suffix 無し marker（range_start 算出用の先行 marker）
# task 6 の suffix 付き marker（解決対象）
GIT_LOG_OUTPUT="sha0005	docs(tasks): mark 5 as done
sha0006	docs(tasks): mark 6 as done (#118)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "6"
assert_eq "Req 1.1: rc=0" "0" "$RESOLVE_RC"
assert_eq "Req 1.1: range_start=sha0005 / range_end=sha0006" "sha0005	sha0006" "$RESOLVE_STDOUT"
assert_contains "Req 1.5: stderr に via=single-id-marker-with-suffix" \
  "via=single-id-marker-with-suffix" "$RESOLVE_STDERR"
assert_contains "Req 1.5: stderr に task_id=6" "task_id=6" "$RESOLVE_STDERR"
assert_contains "Req 1.5: stderr に sha=sha0006" "sha=sha0006" "$RESOLVE_STDERR"

echo ""
echo "--- Req 1.1 (初回 task): suffix 付き 単記 marker のみ・先行 marker なし ---"
GIT_LOG_OUTPUT="sha0001	docs(tasks): mark 1 as done (#42)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "1"
assert_eq "Req 1.1: rc=0 (initial task)" "0" "$RESOLVE_RC"
assert_eq "Req 1.1: range_start=base / range_end=sha0001" "sha_base_main	sha0001" "$RESOLVE_STDOUT"
assert_contains "Req 1.5: stderr に via=single-id-marker-with-suffix" \
  "via=single-id-marker-with-suffix" "$RESOLVE_STDERR"

echo ""
echo "--- Req 1.2: suffix 無し と suffix 付き が同 task_id で混在 → 時系列最終を採用 ---"
# 時系列順: suffix 無し (oldest) → suffix 付き (newer)
GIT_LOG_OUTPUT="sha_old	docs(tasks): mark 7 as done
sha_new	docs(tasks): mark 7 as done (#99)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "7"
assert_eq "Req 1.2: rc=0" "0" "$RESOLVE_RC"
# 時系列最終一致が採用される → range_end=sha_new、range_start=sha_old
assert_eq "Req 1.2: range_end は最新 (sha_new)" "sha_old	sha_new" "$RESOLVE_STDOUT"
assert_contains "Req 1.2: 最新が suffix 付きなので via=single-id-marker-with-suffix" \
  "via=single-id-marker-with-suffix" "$RESOLVE_STDERR"

echo ""
echo "--- Req 1.2 (逆順): suffix 付き → suffix 無し 順の混在 → 時系列最終 (suffix 無し) を採用 ---"
GIT_LOG_OUTPUT="sha_old	docs(tasks): mark 8 as done (#101)
sha_new	docs(tasks): mark 8 as done"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "8"
assert_eq "Req 1.2: rc=0" "0" "$RESOLVE_RC"
assert_eq "Req 1.2: 最新 suffix 無し を採用" "sha_old	sha_new" "$RESOLVE_STDOUT"
# 最新が suffix 無し → 既存ログタグ無し（NFR 1.1 後方互換）
assert_not_contains "Req 3.3: 最新 suffix 無し なら -with-suffix タグは出力しない" \
  "-with-suffix" "$RESOLVE_STDERR"

# ───────────────────────────────────────────────────────────────────
# Section B: Req 2 — suffix 付き 連記 marker の解決
# ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Req 2.1: suffix 付き 連記 marker のみ → 解決 ---"
GIT_LOG_OUTPUT="sha0010	docs(tasks): mark 1 / 1.1 as done (#205)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "1.1"
assert_eq "Req 2.1: rc=0" "0" "$RESOLVE_RC"
assert_eq "Req 2.1: range_end は連記 suffix 付き marker" "sha_base_main	sha0010" "$RESOLVE_STDOUT"
assert_contains "Req 2.3: stderr に via=multi-id-marker-with-suffix" \
  "via=multi-id-marker-with-suffix" "$RESOLVE_STDERR"
# 単記タグが誤って出ていないこと
assert_not_contains "Req 2.3: via=single-id-marker-with-suffix が出ていないこと" \
  "via=single-id-marker-with-suffix" "$RESOLVE_STDERR"

echo ""
echo "--- Req 2.1 (comma): suffix 付き カンマ連記 → 解決 ---"
GIT_LOG_OUTPUT="sha0011	docs(tasks): mark 2, 2.1, 2.2 as done (#206)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "2.1"
assert_eq "Req 2.1: rc=0" "0" "$RESOLVE_RC"
assert_eq "Req 2.1: range_end は連記 suffix 付き marker" "sha_base_main	sha0011" "$RESOLVE_STDOUT"
assert_contains "Req 2.3: stderr に via=multi-id-marker-with-suffix" \
  "via=multi-id-marker-with-suffix" "$RESOLVE_STDERR"

echo ""
echo "--- Req 2.2: token 化規則は suffix 有無で同一（task_id 1 が 1.1 と誤マッチしない） ---"
GIT_LOG_OUTPUT="sha0012	docs(tasks): mark 1.1 / 1.2 as done (#207)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "1"
assert_eq "Req 2.2: task_id=1 は 1.1 / 1.2 トークンに誤マッチしないため rc=1" \
  "1" "$RESOLVE_RC"
assert_eq "Req 2.2: stdout 空" "" "$RESOLVE_STDOUT"

# ───────────────────────────────────────────────────────────────────
# Section C: Req 3 — canonical (suffix 無し) marker 後方互換
# ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Req 3.1: suffix 無し 単記 marker のみ → 既存挙動 (タグ無し) ---"
GIT_LOG_OUTPUT="sha_a	docs(tasks): mark 3 as done
sha_b	docs(tasks): mark 4 as done"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "4"
assert_eq "Req 3.1: rc=0" "0" "$RESOLVE_RC"
assert_eq "Req 3.1: 既存と同一 SHA pair" "sha_a	sha_b" "$RESOLVE_STDOUT"
assert_eq "Req 3.3: 既存挙動 — stderr に -with-suffix タグを出さない" "" "$RESOLVE_STDERR"

echo ""
echo "--- Req 3.2: suffix 無し 連記 marker → 既存タグ via=multi-id-marker 維持 ---"
GIT_LOG_OUTPUT="sha_c	docs(tasks): mark 9 / 9.1 as done"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "9.1"
assert_eq "Req 3.2: rc=0" "0" "$RESOLVE_RC"
assert_eq "Req 3.2: range pair" "sha_base_main	sha_c" "$RESOLVE_STDOUT"
assert_contains "Req 3.2 / NFR 1.1: 既存タグ via=multi-id-marker (suffix 無し) を維持" \
  "via=multi-id-marker " "$RESOLVE_STDERR"
assert_not_contains "Req 3.2: -with-suffix サフィックスが付かないこと" \
  "-with-suffix" "$RESOLVE_STDERR"

# ───────────────────────────────────────────────────────────────────
# Section D: Req 4 — suffix 許容 / 拒否境界
# ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Req 4.1: 空白あり + 括弧 + 数字 → 解決 (canonical suffix) ---"
GIT_LOG_OUTPUT="sha_d	docs(tasks): mark 10 as done (#1)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "10"
assert_eq "Req 4.1: rc=0" "0" "$RESOLVE_RC"
assert_eq "Req 4.1: range pair" "sha_base_main	sha_d" "$RESOLVE_STDOUT"

echo ""
echo "--- Req 4.2: 空白なし → 解決しない (rc=1) ---"
GIT_LOG_OUTPUT="sha_e	docs(tasks): mark 11 as done(#118)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "11"
assert_eq "Req 4.2: rc=1 (空白なし)" "1" "$RESOLVE_RC"
assert_eq "Req 4.2: stdout 空" "" "$RESOLVE_STDOUT"

echo ""
echo "--- Req 4.3: 括弧なし → 解決しない (rc=1) ---"
GIT_LOG_OUTPUT="sha_f	docs(tasks): mark 12 as done #118"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "12"
assert_eq "Req 4.3: rc=1 (括弧なし)" "1" "$RESOLVE_RC"
assert_eq "Req 4.3: stdout 空" "" "$RESOLVE_STDOUT"

echo ""
echo "--- Req 4.4: 閉じ括弧後に追加文字列 → 解決しない (rc=1) ---"
GIT_LOG_OUTPUT="sha_g	docs(tasks): mark 13 as done (#118) extra"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "13"
assert_eq "Req 4.4: rc=1 (閉じ括弧後の追加文字列)" "1" "$RESOLVE_RC"
assert_eq "Req 4.4: stdout 空" "" "$RESOLVE_STDOUT"

echo ""
echo "--- Req 4.5: <number> 部が非数字 → 解決しない (rc=1) ---"
GIT_LOG_OUTPUT="sha_h	docs(tasks): mark 14 as done (#abc)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "14"
assert_eq "Req 4.5: rc=1 (非数字 number)" "1" "$RESOLVE_RC"
assert_eq "Req 4.5: stdout 空" "" "$RESOLVE_STDOUT"

echo ""
echo "--- Req 4.5 (mixed): <number> 部が数字混在 → 解決しない (rc=1) ---"
GIT_LOG_OUTPUT="sha_i	docs(tasks): mark 15 as done (#12a)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "15"
assert_eq "Req 4.5: rc=1 (数字混在 number)" "1" "$RESOLVE_RC"

echo ""
echo "--- Req 4.6: 連記パスにも同一規則 — 空白なし suffix → 解決しない (rc=1) ---"
GIT_LOG_OUTPUT="sha_j	docs(tasks): mark 16 / 16.1 as done(#118)"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "16.1"
assert_eq "Req 4.6 (multi): rc=1 (空白なし suffix)" "1" "$RESOLVE_RC"

echo ""
echo "--- Req 4.6: 連記パスにも同一規則 — 閉じ括弧後の追加文字列 → 解決しない (rc=1) ---"
GIT_LOG_OUTPUT="sha_k	docs(tasks): mark 17 / 17.1 as done (#118) extra"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "17.1"
assert_eq "Req 4.6 (multi): rc=1 (閉じ括弧後の追加文字列)" "1" "$RESOLVE_RC"

# ───────────────────────────────────────────────────────────────────
# Section E: Req 5 — 解決失敗時の既存契約
# ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Req 5.1: marker commit 0 件 → rc=1 ---"
GIT_LOG_OUTPUT=""
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "1"
assert_eq "Req 5.1: rc=1 (marker 不在)" "1" "$RESOLVE_RC"
assert_eq "Req 5.1: stdout 空" "" "$RESOLVE_STDOUT"

echo ""
echo "--- Req 5.1: 当該 task_id に対する単記 / 連記いずれも該当無し → rc=1 ---"
GIT_LOG_OUTPUT="sha_l	docs(tasks): mark 99 as done (#1)
sha_m	docs(tasks): mark 100 / 100.1 as done"
GIT_REVPARSE_OUTPUT="sha_base_main"
run_resolve "200"
assert_eq "Req 5.1: rc=1 (該当 task_id 不在)" "1" "$RESOLVE_RC"
assert_eq "Req 5.1: stdout 空" "" "$RESOLVE_STDOUT"

# ───────────────────────────────────────────────────────────────────
# Section F: Issue 本文 example の回帰固定（altpocket-server #118 由来）
# ───────────────────────────────────────────────────────────────────
echo ""
echo "--- Issue #421 root example: 'mark 6 as done (#118)' は解決される ---"
GIT_LOG_OUTPUT="sha_root	docs(tasks): mark 6 as done (#118)"
GIT_REVPARSE_OUTPUT="sha_base_root"
run_resolve "6"
assert_eq "Issue 本文 example: rc=0" "0" "$RESOLVE_RC"
assert_eq "Issue 本文 example: range pair" "sha_base_root	sha_root" "$RESOLVE_STDOUT"
assert_contains "Issue 本文 example: stderr に via=single-id-marker-with-suffix" \
  "via=single-id-marker-with-suffix" "$RESOLVE_STDERR"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
