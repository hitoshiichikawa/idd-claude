#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407 / #433) の pdr_invoke_reviewer による spec 本文取得経路と
#       fail-closed 挙動を検証するスモークテスト。
#
#       検証する受入基準（docs/specs/433-fix-pr-design-reviewer-pr-spec-pr-none-a/requirements.md）:
#         - Req 1.1〜1.5  spec 本文を head ブランチの git ref（origin/<head_ref>）から取得し、
#                         取得できたファイルは実本文をプレースホルダに埋め込む（(none) ではない）
#         - Req 2.1/2.3/2.5  3 ファイルすべて取得不能 → claude を起動せず非 approve rc=3 で打ち切る
#         - Req 2.2/2.5  spec dir 解決不能（空）→ claude を起動せず非 approve rc=3 で打ち切る
#         - Req 3.1     spec dir 解決済みかつ本文取得不能 → WARN を 1 行出力し、解決済み dir
#                         パスと取得不能の事実を併記する
#         - Req 4.3     取得成功時は従来どおり claude を起動し、本文を stdout に返す（非回帰）
#
#       検証ケース:
#         1. 3 ファイルすべて origin/<head_ref> から取得可能 → claude 起動 / プレースホルダに
#            実本文が埋め込まれる / rc=0
#         2. spec dir 解決済みだが 3 ファイルすべて取得不能 → claude 未起動 / rc=3 / WARN に
#            解決済み dir パスが含まれる
#         3. spec dir が空（解決不能）→ claude 未起動 / rc=3 / WARN（spec dir 解決不能）
#         4. 一部のみ取得可能（requirements のみ）→ claude 起動 / rc=0（部分取得は AC 2.1
#            「1 つも取得できない」に該当しないため fail-closed しない）
#
# 配置先: local-watcher/test/pdr_invoke_reviewer_spec_fetch_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pdr_invoke_reviewer_spec_fetch_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"

if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して eval。
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
eval "$(extract_function "$PDR_SH" "pdr_invoke_reviewer")"

if ! declare -F pdr_invoke_reviewer >/dev/null; then
  echo "ERROR: pdr_invoke_reviewer not loaded" >&2
  exit 2
fi

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
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  expected NOT to contain: $(printf '%q' "$needle")"
      echo "  actual                 : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
}

# ── ロガー stub（WARN_LOG に追記して観測） ──
WARN_LOG=""
pdr_warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }
pdr_log()  { :; }

# ── git stub ──
# `git status --porcelain` → 常に空（read-only invariant: workspace 変更なし）
# `git cat-file -e origin/<ref>:<path>` → GIT_PRESENT_FILES に含まれるパスのみ rc=0
# `git show origin/<ref>:<path>`        → GIT_PRESENT_FILES に含まれるパスのみ本文を返す
# `git checkout -- .`                   → no-op（呼ばれないはず）
GIT_PRESENT_FILES=""   # 改行区切りの "<相対パス>=<本文 token>"
git() {
  local sub="${1:-}"
  case "$sub" in
    status)
      # --porcelain: 空出力（変更なし）
      return 0
      ;;
    cat-file)
      # $2 = -e, $3 = origin/<ref>:<path>
      local rev="${3:-}"
      local path="${rev#*:}"
      if printf '%s\n' "$GIT_PRESENT_FILES" | grep -q "^${path}="; then
        return 0
      fi
      return 1
      ;;
    show)
      local rev="${2:-}"
      local path="${rev#*:}"
      local line
      line=$(printf '%s\n' "$GIT_PRESENT_FILES" | grep "^${path}=" | head -n 1 || true)
      if [ -n "$line" ]; then
        printf '%s' "${line#*=}"
        return 0
      fi
      return 1
      ;;
    checkout)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

# ── timeout stub ── 内側コマンドをそのまま実行（先頭の秒数を捨てる）
timeout() {
  shift
  "$@"
}

# ── claude stub ──
# pdr_invoke_reviewer は `out=$(pdr_invoke_reviewer ...)` の command substitution（subshell）
# 内で実行されるため、stub のシェル変数代入は親に伝播しない。観測値はファイル経由で残す。
#   CLAUDE_CALL_LOG : 呼ばれたら "called" を追記
#   CLAUDE_PROMPT_FILE : -p 引数（プロンプト本文）を書き出す
CLAUDE_CALL_LOG=""
CLAUDE_PROMPT_FILE=""
claude() {
  printf 'called\n' >> "$CLAUDE_CALL_LOG"
  # 引数から -p の次の値を抜き出す
  local prev=""
  local a
  for a in "$@"; do
    if [ "$prev" = "-p" ]; then
      printf '%s' "$a" > "$CLAUDE_PROMPT_FILE"
    fi
    prev="$a"
  done
  printf '## Design Review\nVERDICT: approve\n'
  return 0
}

# ── グローバル env ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"
# shellcheck disable=SC2034
DESIGN_REVIEWER_EXEC_TIMEOUT="300"
# shellcheck disable=SC2034
DESIGN_REVIEWER_MODEL="claude-sonnet-4-6"
# shellcheck disable=SC2034
DESIGN_REVIEWER_OUTPUT_FORMAT="text"
# プロンプト本文は env override で固定（ファイル / HOME 解決を回避）
# shellcheck disable=SC2034
DESIGN_REVIEWER_PROMPT="REQ={REQUIREMENTS_MD}|DESIGN={DESIGN_MD}|TASKS={TASKS_MD}|SPEC={SPEC_DIR}"

reset_state() {
  WARN_LOG="$(mktemp)"
  CLAUDE_CALL_LOG="$(mktemp)"
  CLAUDE_PROMPT_FILE="$(mktemp)"
}

claude_call_count() {
  # CLAUDE_CALL_LOG の行数（呼ばれた回数）
  wc -l < "$CLAUDE_CALL_LOG" | tr -d ' '
}

claude_prompt() {
  cat "$CLAUDE_PROMPT_FILE"
}

HEAD_REF="claude/issue-433-design-foo"
SHA="abcdef1234567890abcdef1234567890abcdef12"
SPEC_DIR="docs/specs/433-fix-foo"

echo "--- pdr_invoke_reviewer spec fetch / fail-closed (Issue #433 Req 1-4) ---"

# ── ケース 1: 3 ファイルすべて取得可能 → claude 起動 / プレースホルダに実本文 / rc=0 ──
reset_state
GIT_PRESENT_FILES="$(printf '%s\n%s\n%s\n' \
  "${SPEC_DIR}/requirements.md=REQ_BODY_TOKEN" \
  "${SPEC_DIR}/design.md=DESIGN_BODY_TOKEN" \
  "${SPEC_DIR}/tasks.md=TASKS_BODY_TOKEN")"
rc=0
out=$(pdr_invoke_reviewer "433" "$SHA" "$HEAD_REF" "main" "$SPEC_DIR") || rc=$?
prompt=$(claude_prompt)
assert_eq "Req 1: 3 ファイル取得可能 → rc=0" "0" "$rc"
assert_eq "Req 4.3: 取得成功で claude 起動" "1" "$(claude_call_count)"
assert_contains "Req 1.1: requirements 実本文がプロンプトに埋め込まれる" "$prompt" "REQ_BODY_TOKEN"
assert_contains "Req 1.2: design 実本文がプロンプトに埋め込まれる" "$prompt" "DESIGN_BODY_TOKEN"
assert_contains "Req 1.3: tasks 実本文がプロンプトに埋め込まれる" "$prompt" "TASKS_BODY_TOKEN"
assert_not_contains "Req 1.5: 取得成功時は (none) を埋め込まない" "$prompt" "(none)"
assert_contains "Req 4.3: claude 応答本文が stdout に返る" "$out" "VERDICT: approve"

# ── ケース 2: spec dir 解決済みだが 3 ファイルすべて取得不能 → claude 未起動 / rc=3 / WARN ──
reset_state
GIT_PRESENT_FILES=""   # どのパスも存在しない
rc=0
out=$(pdr_invoke_reviewer "433" "$SHA" "$HEAD_REF" "main" "$SPEC_DIR") || rc=$?
assert_eq "Req 2.1/2.3: 全ファイル取得不能 → fail-closed rc=3" "3" "$rc"
assert_eq "Req 2.5: fail-closed で claude を起動しない" "0" "$(claude_call_count)"
warn_body=$(cat "$WARN_LOG")
assert_contains "Req 3.1: WARN に解決済み spec dir パスを併記" "$warn_body" "$SPEC_DIR"
assert_contains "Req 3.1: WARN に本文取得不能の事実を併記" "$warn_body" "取得できず"

# ── ケース 3: spec dir が空（解決不能）→ claude 未起動 / rc=3 / WARN ──
reset_state
GIT_PRESENT_FILES=""
rc=0
out=$(pdr_invoke_reviewer "433" "$SHA" "$HEAD_REF" "main" "") || rc=$?
assert_eq "Req 2.2: spec dir 解決不能 → fail-closed rc=3" "3" "$rc"
assert_eq "Req 2.5: spec dir 解決不能でも claude を起動しない" "0" "$(claude_call_count)"
warn_body=$(cat "$WARN_LOG")
assert_contains "Req 2.2: WARN に spec dir 解決不能の事実" "$warn_body" "解決不能"

# ── ケース 4: 一部のみ取得可能（requirements のみ）→ claude 起動 / rc=0（部分取得は非 fail-closed） ──
reset_state
GIT_PRESENT_FILES="${SPEC_DIR}/requirements.md=REQ_ONLY_TOKEN"
rc=0
out=$(pdr_invoke_reviewer "433" "$SHA" "$HEAD_REF" "main" "$SPEC_DIR") || rc=$?
prompt=$(claude_prompt)
assert_eq "Req 2.1 境界: 部分取得（1 つでも取れれば）は fail-closed しない → rc=0" "0" "$rc"
assert_eq "Req 4.3: 部分取得でも claude を起動" "1" "$(claude_call_count)"
assert_contains "Req 1.5: 取得できた requirements は実本文" "$prompt" "REQ_ONLY_TOKEN"
assert_contains "Req 1.4: 取得できなかった design は (none)" "$prompt" "DESIGN=(none)"

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
