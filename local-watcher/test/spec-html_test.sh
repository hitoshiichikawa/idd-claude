#!/usr/bin/env bash
# =============================================================================
# spec-html_test.sh — spec-html.sh モジュールのユニットテスト（#526 / Task 2）
#
# extract_function で各関数を隔離抽出し、live 依存（pandoc / gh / network）なしで
# 検証する。design「Testing Strategy > Unit Tests」の 5 項目を網羅:
#   1. shx_enabled            — true のみ ON / 未設定・空・typo は OFF（Req 1.1, 1.2）
#   2. shx_html_path          — <name>.md → <name>.html 導出（Req 2.4）
#   3. shx_target_files       — 実在 regular file のみ列挙 / allowlist 外・不在は除外（Req 2.2, 2.3, NFR 5.1）
#   4. shx_render_available   — SPEC_HTML_RENDER_BIN を stub で存在/不在双方（Req 5）
#   5. shx_render_one         — stub CLI で成功/失敗、.md 不変・.html 生成（Req 2.5, 3.1, 4.2, 5.2）
#   6. shx_run_for_spec_dir   — gate OFF no-op / CLI 不在 skip / render 失敗でも return 0（Req 1.4, 5.1, 5.3）
#
# 配置先: local-watcher/test/spec-html_test.sh
# 実行:   bash local-watcher/test/spec-html_test.sh
# =============================================================================
# 本テストは extract_function で抽出した関数を bash -c 文字列内で eval するため、
# 単一引用符内の `$var`（bash -c 実行時に展開される意図的な記述）が多数ある。
# SC2016 は本テストの設計上の false-positive のため file-level で抑止する。
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"

MODULE="$SCRIPT_DIR/../bin/modules/spec-html.sh"

PASS_COUNT=0
FAIL_COUNT=0

if [ ! -f "$MODULE" ]; then
  echo "FATAL: spec-html.sh not found at $MODULE" >&2
  exit 1
fi

# テスト用の最小 logger stub（副作用を抑えつつ WARN/LOG を観測可能にする）。
# extract した関数群の前に定義しておくと、抽出関数からの呼び出しがこれに束縛される。
STUB_LOGGERS='
REPO="owner/test"
shx_log()  { echo "LOG: $*"; }
shx_warn() { echo "WARN: $*" >&2; }
shx_error(){ echo "ERROR: $*" >&2; }
'

echo "=== 1. shx_enabled（true 厳密一致のみ ON / Req 1.1, 1.2）==="
run_enabled() {
  # $1 = SPEC_HTML_ENABLED 値（"__unset__" で未設定）
  local val="$1"
  local envassign=()
  [ "$val" != "__unset__" ] && envassign=("SPEC_HTML_ENABLED=$val")
  env "${envassign[@]}" bash -c "
    $(extract_function "$MODULE" shx_enabled)
    shx_enabled"
}
assert_rc "enabled: true → rc 0 (ON)"      0 run_enabled "true"
assert_rc "enabled: 未設定 → rc 1 (OFF)"    1 run_enabled "__unset__"
assert_rc "enabled: 空文字 → rc 1 (OFF)"    1 run_enabled ""
assert_rc "enabled: false → rc 1 (OFF)"    1 run_enabled "false"
assert_rc "enabled: True → rc 1 (OFF)"     1 run_enabled "True"
assert_rc "enabled: 1 → rc 1 (OFF)"        1 run_enabled "1"
assert_rc "enabled: typo(on) → rc 1 (OFF)" 1 run_enabled "on"

echo "=== 2. shx_html_path（<name>.md → <name>.html / Req 2.4）==="
html_path() {
  bash -c "
    $(extract_function "$MODULE" shx_html_path)
    shx_html_path \"\$1\"" _ "$1"
}
assert_eq "html_path: design.md → design.html" "design.html" "$(html_path "design.md")"
assert_eq "html_path: 絶対パス" "/a/b/tasks.html" "$(html_path "/a/b/tasks.md")"
assert_eq "html_path: 同一 dir 維持" "/x/docs/specs/1-x/requirements.html" "$(html_path "/x/docs/specs/1-x/requirements.md")"

echo "=== 3. shx_target_files（実在 regular file のみ列挙 / Req 2.2, 2.3, NFR 5.1）==="
# 実運用同様 REPO_DIR + SPEC_DIR_REL で spec dir を構成する（`docs/specs/<N>-<slug>`）。
TMPBASE="$(mktemp -d)"
SPECREL="docs/specs/1-x"
SPECDIR="$TMPBASE/$SPECREL"
mkdir -p "$SPECDIR"
# 実在させるファイル（allowlist の一部）
: > "$SPECDIR/requirements.md"
: > "$SPECDIR/design.md"
: > "$SPECDIR/tasks.md"
# impl-notes.md / review-notes.md は作らない（design 段で不在 → 除外される想定）
# allowlist 外のファイルも作る（列挙されないことを確認）
: > "$SPECDIR/notes.md"
# ディレクトリ（regular file でない → 除外）
mkdir -p "$SPECDIR/subdir.md"

target_files() {
  # $1 = SPEC_HTML_TARGETS
  env SPEC_HTML_TARGETS="$1" REPO_DIR="$TMPBASE" SPEC_DIR_REL="$SPECREL" bash -c "
    $(extract_function "$MODULE" shx_target_files)
    shx_target_files"
}
DEFAULT_TARGETS="requirements.md design.md tasks.md impl-notes.md review-notes.md"
OUT="$(target_files "$DEFAULT_TARGETS")"
assert_contains "target: requirements.md 列挙" "$OUT" "$SPECDIR/requirements.md"
assert_contains "target: design.md 列挙" "$OUT" "$SPECDIR/design.md"
assert_contains "target: tasks.md 列挙" "$OUT" "$SPECDIR/tasks.md"
# 不在の impl-notes.md / review-notes.md は列挙されない
case "$OUT" in
  *impl-notes.md*) assert_eq "target: 不在 impl-notes.md 除外" "excluded" "included" ;;
  *) assert_eq "target: 不在 impl-notes.md 除外" "excluded" "excluded" ;;
esac
# allowlist 外の notes.md は列挙されない（`/impl-notes.md` は `/notes.md` を含まないため誤検出しない）
case "$OUT" in
  */notes.md*) assert_eq "target: allowlist 外 notes.md 除外" "excluded" "included" ;;
  *) assert_eq "target: allowlist 外 notes.md 除外" "excluded" "excluded" ;;
esac
# 実在 3 件のみ列挙される（行数 = 3）
LINES="$(printf '%s\n' "$OUT" | grep -c '\.md$' || true)"
assert_eq "target: 実在 3 件のみ列挙" "3" "$LINES"
# path separator を含む allowlist エントリは除外（NFR 5.1）
OUT2="$(target_files "../etc/passwd design.md")"
case "$OUT2" in
  *passwd*) assert_eq "target: path-traversal エントリ除外" "excluded" "included" ;;
  *) assert_eq "target: path-traversal エントリ除外" "excluded" "excluded" ;;
esac
assert_contains "target: 正常エントリは併存で列挙" "$OUT2" "$SPECDIR/design.md"
rm -rf "$TMPBASE"

echo "=== 4. shx_render_available（stub コマンド存在/不在 / Req 5）==="
render_available() {
  # $1 = SPEC_HTML_RENDER_BIN
  env SPEC_HTML_RENDER_BIN="$1" bash -c "
    $STUB_LOGGERS
    $(extract_function "$MODULE" shx_render_available)
    shx_render_available"
}
# 実在するコマンド（cat は必ず PATH にある）→ rc 0
assert_rc "available: 実在 CLI(cat) → rc 0" 0 render_available "cat"
# 不在コマンド → rc 1（+ warn）
assert_rc "available: 不在 CLI → rc 1" 1 render_available "definitely_not_a_real_binary_xyz"
# 不在時に warn を出す
AVAIL_ERR="$( { render_available "definitely_not_a_real_binary_xyz" >/dev/null; } 2>&1 )"
assert_contains "available: 不在時に skip warn" "$AVAIL_ERR" "render CLI 不在"

echo "=== 5. shx_render_one（stub CLI で成功/失敗・.md 不変・.html 生成 / Req 2.5, 3.1, 4.2, 5.2）==="
TMPR="$(mktemp -d)"
printf '# Title\n\ncontent\n' > "$TMPR/design.md"
MD_BEFORE="$(cat "$TMPR/design.md")"
# stub render: {OUT} に固定内容を書き込む（`cp {IN} {OUT}` 相当）を cat リダイレクトで代替。
# SPEC_HTML_RENDER_CMD をトークン分割し {IN}/{OUT} 置換 → 実行する経路を検証するため、
# 実コマンドは `cp {IN} {OUT}`（cp は必ず存在）を使う。
render_one() {
  # $1 = RENDER_CMD / $2 = md_path / $3 = TIMEOUT
  env SPEC_HTML_RENDER_CMD="$1" SPEC_HTML_TIMEOUT="${3:-60}" bash -c "
    $STUB_LOGGERS
    $(extract_function "$MODULE" shx_html_path)
    $(extract_function "$MODULE" shx_render_one)
    shx_render_one \"\$1\"" _ "$2"
}
# 成功: cp で .md を .html にコピー（render 成功 rc 0）
assert_rc "render_one: 成功 → rc 0" 0 render_one "cp {IN} {OUT}" "$TMPR/design.md"
# .html が生成される
assert_eq "render_one: .html 生成" "exists" "$([ -f "$TMPR/design.html" ] && echo exists || echo missing)"
# .md は書き換えられていない（正準維持 / Req 3.1）
assert_eq "render_one: .md 不変（正準維持）" "$MD_BEFORE" "$(cat "$TMPR/design.md")"
# 失敗: 存在しないコマンド → rc 非 0 + warn
assert_rc "render_one: 失敗コマンド → rc 非 0" 127 render_one "definitely_not_real_cmd_xyz {IN} {OUT}" "$TMPR/design.md"
FAIL_ERR="$( { render_one "definitely_not_real_cmd_xyz {IN} {OUT}" "$TMPR/design.md" >/dev/null; } 2>&1 )"
assert_contains "render_one: 失敗時に対象ファイル名付き warn" "$FAIL_ERR" "design.md"
# 空 render cmd → rc 1 + warn
assert_rc "render_one: 空 cmd → rc 1" 1 render_one "" "$TMPR/design.md"
rm -rf "$TMPR"

echo "=== 6. shx_run_for_spec_dir（gate OFF / CLI 不在 / render 失敗でも return 0 / Req 1.4, 5.1, 5.3）==="
# 依存関数（shx_enabled / shx_render_available / shx_target_files / shx_render_one）を
# stub 化し、orchestration ロジックのみを検証する。
run_spec_dir() {
  # $1 = enabled_rc / $2 = available_rc / $3 = render_one_behavior (ok|fail|mixed)
  env SPEC_DIR_REL="1-x" NUMBER="1" bash -c '
    REPO="owner/test"
    shx_log()  { echo "LOG: $*"; }
    shx_warn() { echo "WARN: $*" >&2; }
    shx_enabled()           { return '"$1"'; }
    shx_render_available()  { return '"$2"'; }
    shx_target_files()      { printf "%s\n" "/tmp/a.md" "/tmp/b.md"; }
    case "'"$3"'" in
      ok)    shx_render_one() { return 0; } ;;
      fail)  shx_render_one() { return 1; } ;;
      mixed) shx_render_one() { case "$1" in *a.md) return 0 ;; *) return 1 ;; esac; } ;;
    esac
    '"$(extract_function "$MODULE" shx_run_for_spec_dir)"'
    shx_run_for_spec_dir'
}
# gate OFF（enabled rc 1）→ return 0 かつ無ログ（no-op / Req 1.4）
assert_rc "run: gate OFF → return 0" 0 run_spec_dir 1 0 ok
OFF_OUT="$(run_spec_dir 1 0 ok 2>&1)"
assert_eq "run: gate OFF は無ログ（NFR 1.1）" "" "$OFF_OUT"
# gate ON + CLI 不在（available rc 1）→ return 0 で skip
assert_rc "run: CLI 不在 → return 0" 0 run_spec_dir 0 1 ok
# gate ON + CLI 可用 + 全成功 → return 0、summary に ok=2
assert_rc "run: 全成功 → return 0" 0 run_spec_dir 0 0 ok
OK_OUT="$(run_spec_dir 0 0 ok 2>&1)"
assert_contains "run: summary ok=2 fail=0" "$OK_OUT" "targets=2 ok=2 fail=0"
# gate ON + render 全失敗でも return 0（Req 5.1, 5.3）、summary fail=2
assert_rc "run: render 全失敗でも return 0" 0 run_spec_dir 0 0 fail
FAIL_OUT="$(run_spec_dir 0 0 fail 2>&1)"
assert_contains "run: summary ok=0 fail=2" "$FAIL_OUT" "targets=2 ok=0 fail=2"
# 一部失敗（mixed）→ return 0、summary ok=1 fail=1
assert_rc "run: 一部失敗でも return 0" 0 run_spec_dir 0 0 mixed
MIX_OUT="$(run_spec_dir 0 0 mixed 2>&1)"
assert_contains "run: summary ok=1 fail=1" "$MIX_OUT" "targets=2 ok=1 fail=1"

echo ""
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
