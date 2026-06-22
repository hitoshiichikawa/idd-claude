#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/needs-decisions-auto.sh の Issue #362
#       （needs-decisions 自動続行）で追加した関数群と本体 Config block の
#       正規化挙動を fixture と gh stub で検証するスモークテスト。
#
#       対象関数:
#         - nda_resolve_mode_enabled         (Req 1.5 / NFR 3.3 安全側正規化)
#         - nda_extract_classification       (Req 4.4 / 4.5 / NFR 4.2 fail-safe to human-only)
#         - nda_extract_first_recommendation (Open Question (b) recommendation 必須化)
#         - nda_auto_continue                (Req 3.3 / 3.4 best-effort error paths)
#         - nda_evaluate_auto_continue       (Req 3.1 / 3.2 / 4.x / 5.x AND 二重 opt-in)
#
#       検証する AC（docs/specs/362-feat-watcher-needs-decisions-needs-decis/requirements.md）:
#         - AC 1.5: NEEDS_DECISIONS_MODE 不正値正規化（3 値以外は all-human）
#         - AC 2.4 / 2.5: classification 欠落 / 不明 / 混在は "human-only" fail-safe
#         - AC 3.1 / 3.2: classified / all-auto + safe → 自動続行
#         - AC 3.3: 自動続行時 needs-decisions ラベル不付与 + claude-claimed 除去
#         - AC 3.4: 採用 recommendation を Issue コメントに記録
#         - AC 4.1〜4.3: human-only はモードによらず halt（gh ゼロ呼び出し）
#         - AC 4.4: classification 欠落 → "human-only" 扱い
#         - AC 4.5: safe + human-only 混在 → "human-only" 扱い
#         - AC 5.2: FULL_AUTO_ENABLED=false → 自動続行しない（gh ゼロ呼び出し）
#         - AC 5.3: kill ON + mode=all-human → 自動続行しない
#         - AC 5.4: AND 二重 opt-in（kill ON AND mode != all-human）
#         - NFR 1.1: gate OFF / mode=all-human で gh API ゼロ呼び出し
#         - NFR 3.2 / 3.3: env 不正値 typo → all-human
#         - NFR 4.2: all-auto モードでも human-only halt は hard safety boundary
#
# 配置先: local-watcher/test/needs_decisions_auto_test.sh
# 依存:   bash 4+, awk, grep, jq, mktemp, env, printf
# 実行:   bash local-watcher/test/needs_decisions_auto_test.sh

set -euo pipefail

# 抽出関数および stub から indirect 参照される変数を多用するため、shellcheck からは
# 未使用に見える。本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDA_MOD="$SCRIPT_DIR/../bin/modules/needs-decisions-auto.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$NDA_MOD" ]; then
  echo "ERROR: cannot find needs-decisions-auto.sh at $NDA_MOD" >&2
  exit 2
fi
if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 既存テスト同イディオム: 対象スクリプトから 1 関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# nda module から対象関数を抽出
for fn in nda_log nda_warn nda_error \
  nda_resolve_mode_enabled \
  nda_extract_classification \
  nda_extract_first_recommendation \
  nda_auto_continue \
  nda_evaluate_auto_continue; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$NDA_MOD" "$fn")"
done

# full_auto_enabled は本体 issue-watcher.sh に定義（#348）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"

for fn in nda_log nda_warn nda_error \
  nda_resolve_mode_enabled \
  nda_extract_classification \
  nda_extract_first_recommendation \
  nda_auto_continue \
  nda_evaluate_auto_continue \
  full_auto_enabled; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# 本体 Config block の NEEDS_DECISIONS_MODE 正規化部分を awk で抽出（Section 2 で使用）。
# `^NEEDS_DECISIONS_MODE=` 開始から `^esac$` 終了までを 1 ブロック分だけ取り出す。
extract_needs_decisions_mode_block() {
  awk '
    /^NEEDS_DECISIONS_MODE=/ { in_block = 1 }
    in_block { print }
    in_block && /^esac$/ { in_block = 0; exit }
  ' "$WATCHER_SH"
}

NDM_BLOCK="$(extract_needs_decisions_mode_block)"
if [ -z "$NDM_BLOCK" ]; then
  echo "ERROR: failed to extract NEEDS_DECISIONS_MODE Config block from $WATCHER_SH" >&2
  exit 2
fi

# グローバル env（遅延束縛で抽出関数本体から参照される）
REPO="owner/test-repo"
LABEL_CLAIMED="claude-claimed"
LABEL_NEEDS_DECISIONS="needs-decisions"
NUMBER="42"

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

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  shift 2
  local actual_rc=0
  "$@" >/dev/null 2>&1 || actual_rc=$?
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ── stub state for nda_auto_continue / nda_evaluate_auto_continue gh observability ──
GH_CALL_LOG=""
WARN_LOG=""
LOG_LOG=""
GH_COMMENT_FAIL=0
GH_EDIT_FAIL=0

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  GH_COMMENT_FAIL=0
  GH_EDIT_FAIL=0
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
}

# nda_log / nda_warn / nda_error stub: 本体関数を上書きして出力を記録ファイルへ。
# 後から定義された関数が優先される（bash の関数名は call 時に解決される）。
# shellcheck disable=SC2317
nda_log()   { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
nda_warn()  { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
nda_error() { echo "$*" >>"$WARN_LOG"; }

# gh stub: gh issue comment / gh issue edit を観測。
# GH_COMMENT_FAIL / GH_EDIT_FAIL でエラー化を制御。
# shellcheck disable=SC2317
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  echo "gh $*" >>"$GH_CALL_LOG"
  case "$sub" in
    issue)
      case "$sub2" in
        comment)
          [ "$GH_COMMENT_FAIL" = "1" ] && return 1
          return 0
          ;;
        edit)
          [ "$GH_EDIT_FAIL" = "1" ] && return 1
          return 0
          ;;
      esac
      ;;
  esac
  return 0
}

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_logs() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$LOG_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_warns() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$WARN_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# 一時 JSON ファイルを作成（呼出側で rm -f 必須）
make_triage_json() {
  local file
  file="$(mktemp)"
  printf '%s' "$1" >"$file"
  echo "$file"
}

# ============================================================
# Section 1: nda_resolve_mode_enabled の正規化（Req 1.5 / NFR 3.3）
#   task 1 partial 解消の 1.5 一部 + task 2.2 partial 解消の NFR 3.3
# ============================================================
echo "--- Section 1: nda_resolve_mode_enabled の正規化（Req 1.5 / NFR 3.3） ---"

NEEDS_DECISIONS_MODE="all-human"
assert_rc "Req 1.5: all-human → rc=1（自動続行不可）" 1 nda_resolve_mode_enabled

NEEDS_DECISIONS_MODE="classified"
assert_rc "Req 1.3: classified → rc=0（自動続行評価可）" 0 nda_resolve_mode_enabled

NEEDS_DECISIONS_MODE="all-auto"
assert_rc "Req 1.4: all-auto → rc=0（自動続行評価可）" 0 nda_resolve_mode_enabled

unset NEEDS_DECISIONS_MODE
assert_rc "Req 1.5 / NFR 3.3: 未設定 → rc=1（all-human 安全側）" 1 nda_resolve_mode_enabled

NEEDS_DECISIONS_MODE=""
assert_rc "Req 1.5 / NFR 3.3: 空文字列 → rc=1（all-human 安全側）" 1 nda_resolve_mode_enabled

NEEDS_DECISIONS_MODE="Classified"
assert_rc "NFR 3.3: typo 'Classified' → rc=1（大文字 / 安全側）" 1 nda_resolve_mode_enabled

NEEDS_DECISIONS_MODE="auto"
assert_rc "NFR 3.3: typo 'auto' → rc=1（部分文字列 / 安全側）" 1 nda_resolve_mode_enabled

# ============================================================
# Section 2: 本体 Config block の正規化スモーク（Req 1.5 / task 1 partial 解消）
# 本体 issue-watcher.sh の NEEDS_DECISIONS_MODE 正規化 Config block を awk で
# 抽出して env -i 配下で隔離 evaluate。Module 側 nda_resolve_mode_enabled とは
# 別レイヤで、本体 Config 自体が不正値を all-human に倒すことを確認する。
# ============================================================
echo ""
echo "--- Section 2: 本体 Config block の正規化スモーク（Req 1.5） ---"

assert_config_normalize() {
  local label="$1"
  local input_set="$2"   # "set" / "unset"
  local input_val="$3"
  local expected="$4"
  local actual
  local snippet
  snippet="${NDM_BLOCK}"$'\nprintf %s "$NEEDS_DECISIONS_MODE"'
  if [ "$input_set" = "set" ]; then
    actual=$(env -i HOME="$HOME" PATH="$PATH" NEEDS_DECISIONS_MODE="$input_val" \
      bash -c "$snippet")
  else
    actual=$(env -i HOME="$HOME" PATH="$PATH" \
      bash -c "$snippet")
  fi
  assert_eq "$label" "$expected" "$actual"
}

assert_config_normalize "Req 1.1 / 1.5: 未設定 → 既定 all-human" "unset" "" "all-human"
assert_config_normalize "Req 1.5: 空文字列 → all-human" "set" "" "all-human"
assert_config_normalize "Req 1.2: all-human はそのまま" "set" "all-human" "all-human"
assert_config_normalize "Req 1.3: classified はそのまま" "set" "classified" "classified"
assert_config_normalize "Req 1.4: all-auto はそのまま" "set" "all-auto" "all-auto"
assert_config_normalize "Req 1.5 / NFR 3.3: typo 'auto' → all-human" "set" "auto" "all-human"
assert_config_normalize "Req 1.5 / NFR 3.3: typo 'Classified' → all-human" "set" "Classified" "all-human"
assert_config_normalize "Req 1.5 / NFR 3.3: typo 'ALL-AUTO' → all-human" "set" "ALL-AUTO" "all-human"

# ============================================================
# Section 3: nda_extract_classification fail-safe（Req 4.4 / 4.5 / NFR 4.2）
#   task 2.2 partial 解消（2.4 / 2.5 / 4.4 / 4.5 / NFR 4.2）
# ============================================================
echo ""
echo "--- Section 3: nda_extract_classification fail-safe（Req 4.4 / 4.5 / NFR 4.2） ---"

F="$(make_triage_json '{"decisions":[{"classification":"safe"}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 2.3: safe 単独 → safe" "safe" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"classification":"safe"},{"classification":"safe"}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 2.3: 全件 safe → safe" "safe" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"classification":"human-only"}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.1: human-only 単独 → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"classification":"safe"},{"classification":"human-only"}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.5: safe + human-only 混在 → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"classification":"human-only"},{"classification":"safe"}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.5: human-only + safe 順序逆転 → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"topic":"x"}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.4: classification 欠落 → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"classification":null}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.4: classification null → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":[]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.4: decisions[] 空配列 → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.4: decisions key 不在 → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{"decisions":null}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.4: decisions null → human-only" "human-only" "$RESULT"
rm -f "$F"

F="$(make_triage_json '{not_valid_json')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "NFR 4.2: 不正 JSON (jq 失敗) → human-only" "human-only" "$RESULT"
rm -f "$F"

RESULT="$(nda_extract_classification "/nonexistent/path/needs-decisions-test-$$.json")"
assert_eq "NFR 4.2: file 不在 → human-only" "human-only" "$RESULT"

F="$(make_triage_json '{"decisions":[{"classification":"unknown"}]}')"
RESULT="$(nda_extract_classification "$F")"
assert_eq "Req 4.4: classification 不明値 → human-only" "human-only" "$RESULT"
rm -f "$F"

# ============================================================
# Section 4: nda_extract_first_recommendation
# ============================================================
echo ""
echo "--- Section 4: nda_extract_first_recommendation ---"

F="$(make_triage_json '{"decisions":[{"recommendation":"オプション A を採用"}]}')"
RESULT="$(nda_extract_first_recommendation "$F")"
assert_eq "正常抽出 → 本文" "オプション A を採用" "$RESULT"
RC=0
nda_extract_first_recommendation "$F" >/dev/null 2>&1 || RC=$?
assert_eq "正常抽出 → rc=0" "0" "$RC"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"recommendation":""}]}')"
RC=0
nda_extract_first_recommendation "$F" >/dev/null 2>&1 || RC=$?
assert_eq "空文字 recommendation → rc=1" "1" "$RC"
rm -f "$F"

F="$(make_triage_json '{"decisions":[{"recommendation":null}]}')"
RC=0
nda_extract_first_recommendation "$F" >/dev/null 2>&1 || RC=$?
assert_eq "null recommendation → rc=1" "1" "$RC"
rm -f "$F"

F="$(make_triage_json '{"decisions":[]}')"
RC=0
nda_extract_first_recommendation "$F" >/dev/null 2>&1 || RC=$?
assert_eq "decisions[] 空 → rc=1" "1" "$RC"
rm -f "$F"

RC=0
nda_extract_first_recommendation "/nonexistent/path/needs-decisions-test-$$.json" >/dev/null 2>&1 || RC=$?
assert_eq "file 不在 → rc=1" "1" "$RC"

# ============================================================
# Section 5: nda_auto_continue エラーパス（Req 3.3 / 3.4 / task 2.3 partial 解消）
# ============================================================
echo ""
echo "--- Section 5: nda_auto_continue エラーパス（Req 3.3 / 3.4） ---"

# Case A: gh issue comment 失敗 → rc=1 + label remove skip + WARN
reset_stub_state
GH_COMMENT_FAIL=1
F="$(make_triage_json '{"decisions":[{"recommendation":"adopt A"}]}')"
NEEDS_DECISIONS_MODE="classified"
RC=0
nda_auto_continue "$F" "adopt A" || RC=$?
assert_eq "Req 3.3 / 3.4: gh comment 失敗 → rc=1" "1" "$RC"
edit_count=$(count_calls "^gh issue edit")
assert_eq "Req 3.3: gh comment 失敗 → gh edit (label remove) 呼ばれない" "0" "$edit_count"
warn_count=$(count_warns "gh-comment-failed")
assert_eq "Req 3.3: gh comment 失敗 → WARN ログ 1 行" "1" "$warn_count"
rm -f "$F"
cleanup_stub_state

# Case B: gh issue edit 失敗 → rc=1 + WARN（コメントは投稿成功）
reset_stub_state
GH_EDIT_FAIL=1
F="$(make_triage_json '{"decisions":[{"recommendation":"adopt A"}]}')"
RC=0
nda_auto_continue "$F" "adopt A" || RC=$?
assert_eq "Req 3.3: gh edit 失敗 → rc=1" "1" "$RC"
comment_count=$(count_calls "^gh issue comment")
assert_eq "Req 3.4: gh edit 失敗時もコメント投稿は試行済（1 回）" "1" "$comment_count"
warn_count=$(count_warns "gh-edit-failed")
assert_eq "Req 3.3: gh edit 失敗 → WARN ログ 1 行" "1" "$warn_count"
rm -f "$F"
cleanup_stub_state

# Case C: 全成功 → rc=0 + comment 1 + edit 1（remove-label 含む）
reset_stub_state
F="$(make_triage_json '{"decisions":[{"recommendation":"adopt A"}]}')"
RC=0
nda_auto_continue "$F" "adopt A" || RC=$?
assert_eq "Req 3.3 / 3.4: 全成功 → rc=0" "0" "$RC"
comment_count=$(count_calls "^gh issue comment")
assert_eq "Req 3.4: 全成功 → コメント投稿 1 回" "1" "$comment_count"
edit_count=$(count_calls "^gh issue edit")
assert_eq "Req 3.3: 全成功 → label remove 1 回" "1" "$edit_count"
remove_count=$(count_calls "remove-label")
assert_eq "Req 3.3: edit には --remove-label が含まれる" "1" "$remove_count"
ac_log_count=$(count_logs "action=auto-continue")
assert_eq "Req 6.1: action=auto-continue ログ 1 行" "1" "$ac_log_count"
rm -f "$F"
cleanup_stub_state

# ============================================================
# Section 6: nda_evaluate_auto_continue kill switch OFF halt（Req 5.2 / 5.3 / NFR 1.1）
#   task 2.4 partial 解消の 5.2 / 5.3 / 5.4
# ============================================================
echo ""
echo "--- Section 6: nda_evaluate_auto_continue kill OFF / mode=all-human halt（Req 5.2 / 5.3 / NFR 1.1） ---"

# kill OFF + mode=classified + safe → halt（gh ゼロ呼び出し + suppression ログ）
reset_stub_state
unset FULL_AUTO_ENABLED
NEEDS_DECISIONS_MODE="classified"
F="$(make_triage_json '{"decisions":[{"classification":"safe","recommendation":"adopt A"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 5.2: kill OFF → rc=1（halt）" "1" "$RC"
gh_count=$(count_calls "^gh ")
assert_eq "NFR 1.1: kill OFF + mode=classified + safe で gh API ゼロ呼び出し" "0" "$gh_count"
sup_count=$(count_logs "suppressed-by-FULL_AUTO_ENABLED")
assert_eq "Req 6.2: kill OFF 時に suppression ログを 1 行出力" "1" "$sup_count"
rm -f "$F"
cleanup_stub_state

# kill ON + mode=all-human + safe → halt（NFR 1.1: gh ゼロ呼び出し）
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="all-human"
F="$(make_triage_json '{"decisions":[{"classification":"safe","recommendation":"adopt A"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 5.3: kill ON + mode=all-human → rc=1（halt）" "1" "$RC"
gh_count=$(count_calls "^gh ")
assert_eq "NFR 1.1: kill ON + mode=all-human で gh API ゼロ呼び出し" "0" "$gh_count"
mode_halt_count=$(count_logs "cause=mode-all-human")
assert_eq "Req 6.1: mode=all-human halt 時に cause ログ 1 行出力" "1" "$mode_halt_count"
rm -f "$F"
cleanup_stub_state

# ============================================================
# Section 7: nda_evaluate_auto_continue AND 二重 opt-in（Req 3.1 / 3.2 / 5.4）
#   task 2.4 / 3 partial 解消の 3.1 / 3.2 / 3.3 / 5.4
# ============================================================
echo ""
echo "--- Section 7: nda_evaluate_auto_continue AND 二重 opt-in（Req 3.1 / 3.2 / 5.4） ---"

# kill ON + mode=classified + safe + valid recommendation → auto-continue
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="classified"
F="$(make_triage_json '{"decisions":[{"classification":"safe","recommendation":"adopt option A"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 3.1 / 5.4: classified + safe + rec → rc=0 (auto-continue)" "0" "$RC"
comment_count=$(count_calls "^gh issue comment")
assert_eq "Req 3.4: classified + safe → コメント投稿 1 回" "1" "$comment_count"
edit_count=$(count_calls "^gh issue edit")
assert_eq "Req 3.3: classified + safe → label remove 1 回" "1" "$edit_count"
ac_log_count=$(count_logs "action=auto-continue")
assert_eq "Req 6.1: auto-continue ログ 1 行" "1" "$ac_log_count"
rm -f "$F"
cleanup_stub_state

# kill ON + mode=all-auto + safe → auto-continue
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="all-auto"
F="$(make_triage_json '{"decisions":[{"classification":"safe","recommendation":"adopt option B"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 3.2 / 5.4: all-auto + safe + rec → rc=0 (auto-continue)" "0" "$RC"
comment_count=$(count_calls "^gh issue comment")
assert_eq "Req 3.4: all-auto + safe → コメント投稿 1 回" "1" "$comment_count"
edit_count=$(count_calls "^gh issue edit")
assert_eq "Req 3.3: all-auto + safe → label remove 1 回" "1" "$edit_count"
rm -f "$F"
cleanup_stub_state

# kill ON + mode=classified + safe + recommendation 欠落 → halt（Open Question (b)）
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="classified"
F="$(make_triage_json '{"decisions":[{"classification":"safe"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Open Q (b): recommendation 欠落 → rc=1（halt）" "1" "$RC"
gh_count=$(count_calls "^gh ")
assert_eq "Open Q (b): recommendation 欠落 → gh ゼロ呼び出し" "0" "$gh_count"
rec_halt_count=$(count_logs "cause=recommendation-missing")
assert_eq "Open Q (b): recommendation 欠落 halt 時に cause ログ 1 行" "1" "$rec_halt_count"
rm -f "$F"
cleanup_stub_state

# ============================================================
# Section 8: nda_evaluate_auto_continue human-only halt（Req 4.x / NFR 4.2）
#   task 2.4 / 3 partial 解消の 4.1 / 4.2 / 4.3 + NFR 4.2 hard boundary
# ============================================================
echo ""
echo "--- Section 8: nda_evaluate_auto_continue human-only halt（Req 4.x / NFR 4.2） ---"

# kill ON + mode=classified + human-only → halt（gh ゼロ呼び出し）
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="classified"
F="$(make_triage_json '{"decisions":[{"classification":"human-only","recommendation":"adopt A"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 4.2: classified + human-only → rc=1（halt）" "1" "$RC"
gh_count=$(count_calls "^gh ")
assert_eq "Req 4.2 / NFR 1.1: classified + human-only で gh ゼロ呼び出し" "0" "$gh_count"
ho_halt_count=$(count_logs "cause=classification-human-only")
assert_eq "Req 6.3: human-only halt 時に cause ログ 1 行" "1" "$ho_halt_count"
rm -f "$F"
cleanup_stub_state

# kill ON + mode=all-auto + human-only → halt（NFR 4.2 hard boundary）
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="all-auto"
F="$(make_triage_json '{"decisions":[{"classification":"human-only","recommendation":"adopt A"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 4.3 / NFR 4.2: all-auto + human-only → rc=1（hard boundary halt）" "1" "$RC"
gh_count=$(count_calls "^gh ")
assert_eq "NFR 4.2: all-auto + human-only で gh ゼロ呼び出し" "0" "$gh_count"
ho_halt_count=$(count_logs "cause=classification-human-only")
assert_eq "Req 6.3: all-auto + human-only halt 時に cause ログ 1 行" "1" "$ho_halt_count"
rm -f "$F"
cleanup_stub_state

# kill ON + mode=all-auto + safe+human-only 混在 → halt（Req 4.5 hard boundary）
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="all-auto"
F="$(make_triage_json '{"decisions":[{"classification":"safe","recommendation":"A"},{"classification":"human-only","recommendation":"B"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 4.5: all-auto + safe+human-only 混在 → rc=1（halt）" "1" "$RC"
gh_count=$(count_calls "^gh ")
assert_eq "Req 4.5: 混在 → gh ゼロ呼び出し" "0" "$gh_count"
ho_halt_count=$(count_logs "cause=classification-human-only")
assert_eq "Req 4.5 / 6.3: 混在は human-only として halt ログ" "1" "$ho_halt_count"
rm -f "$F"
cleanup_stub_state

# kill ON + mode=classified + classification 欠落 → halt（Req 4.4 fail-safe）
reset_stub_state
FULL_AUTO_ENABLED="true"
NEEDS_DECISIONS_MODE="classified"
F="$(make_triage_json '{"decisions":[{"recommendation":"adopt A"}]}')"
RC=0
nda_evaluate_auto_continue "$F" || RC=$?
assert_eq "Req 4.4: classification 欠落 → rc=1（halt）" "1" "$RC"
gh_count=$(count_calls "^gh ")
assert_eq "Req 4.4: classification 欠落 → gh ゼロ呼び出し" "0" "$gh_count"
rm -f "$F"
cleanup_stub_state

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
