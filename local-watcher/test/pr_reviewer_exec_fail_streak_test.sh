#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-reviewer.sh の Issue #403（codex exec-failed の
#       同一 sha リトライ抑止 + stderr 抜粋 / artifact 保存）で追加した関数群の単体
#       検証スモークテスト。
#
# 対象関数:
#   - pr_extract_exec_fail_streak           : marker から (sha, streak) を抽出（純粋関数）
#   - pr_read_exec_fail_streak              : gh pr view + extract（stub 越し検証）
#   - pr_write_exec_fail_streak             : gh pr edit + marker insert/replace
#   - pr_reset_exec_fail_streak             : sha 変化 / 成功時のリセット
#   - pr_increment_exec_fail_streak         : +1 加算、sha 変化時は 1 から再スタート
#   - pr_exec_fail_limit_reached            : 上限到達判定（候補除外用）
#   - pr_truncate_stderr_tail               : 末尾優先抜粋（1MB 超 truncation）
#   - pr_save_stderr_artifact               : $HOME/.issue-watcher/... 配下保存
#   - pr_post_exec_fail_escalation_comment  : advisory コメント 1 回投稿（重複防止）
#
# 検証する AC（docs/specs/403-fix-pr-reviewer-codex-exec-failed-sha-ra/requirements.md）:
#   Req 1.1 / 1.2 / 1.3 / 1.4 / 1.5 / 1.6
#   Req 2.1 / 2.2 / 2.3 / 2.4 / 2.5 / 2.6 / 2.7
#   Req 3.1 / 3.2 / 3.3 / 3.4 / 3.5
#   Req 4.1（既存正常系挙動不変 — limit=0 での streak 加算 / リセットの形を検証）
#   NFR 1.1 / 1.2 / 2.1 / 3.2 / 4.2
#
# 既存テストと同じイディオム（pr_publish_commit_status_test.sh 参照）:
#   extract_function で対象 1 関数を awk 抽出し eval する。
#   依存関数（pr_already_processed / pr_build_marker / pr_log / pr_warn 等）は stub 化。
#
# 配置先: local-watcher/test/pr_reviewer_exec_fail_streak_test.sh
# 依存:   bash 4+, awk, grep, sed, tail, mktemp
# 実行:   bash local-watcher/test/pr_reviewer_exec_fail_streak_test.sh

set -euo pipefail

# 抽出関数で参照されるグローバル env / stub が shellcheck から未使用に見えるため抑止。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MOD="$SCRIPT_DIR/../bin/modules/pr-reviewer.sh"

if [ ! -f "$PR_MOD" ]; then
  echo "ERROR: cannot find pr-reviewer.sh at $PR_MOD" >&2
  exit 2
fi

# pr_publish_commit_status_test.sh と同じ extract_function イディオム
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を読み込む。pr_increment_exec_fail_streak / pr_reset_exec_fail_streak は
# pr_read_exec_fail_streak / pr_write_exec_fail_streak / pr_extract_exec_fail_streak に
# 依存するため、合わせて抽出する。
for fn in \
  pr_extract_exec_fail_streak \
  pr_read_exec_fail_streak \
  pr_write_exec_fail_streak \
  pr_reset_exec_fail_streak \
  pr_increment_exec_fail_streak \
  pr_exec_fail_limit_reached \
  pr_truncate_stderr_tail \
  pr_save_stderr_artifact \
  pr_post_exec_fail_escalation_comment \
  pr_build_marker
do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$PR_MOD" "$fn")"
done

for fn in \
  pr_extract_exec_fail_streak \
  pr_read_exec_fail_streak \
  pr_write_exec_fail_streak \
  pr_reset_exec_fail_streak \
  pr_increment_exec_fail_streak \
  pr_exec_fail_limit_reached \
  pr_truncate_stderr_tail \
  pr_save_stderr_artifact \
  pr_post_exec_fail_escalation_comment
do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される / SC2034 抑止）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
PR_REVIEWER_GIT_TIMEOUT="120"
# shellcheck disable=SC2034
PR_REVIEWER_EXEC_FAIL_LIMIT="3"
# shellcheck disable=SC2034
PR_REVIEWER_STDERR_EXCERPT_BYTES="8192"
# artifact dir は test 毎に上書き
# shellcheck disable=SC2034
PR_REVIEWER_STDERR_ARTIFACT_DIR=""
# shellcheck disable=SC2034
PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES="1048576"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"; local expected="$2"; local actual="$3"
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
  local label="$1"; local expected_rc="$2"; shift 2
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

assert_contains() {
  local label="$1"; local haystack="$2"; local needle="$3"
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

# ── stub state ──
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  GH_PR_BODY="${GH_PR_BODY:-}"
  GH_NEXT_RC="${GH_NEXT_RC:-0}"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG" 2>/dev/null || true
}

# pr_log / pr_warn / pr_error stub
# shellcheck disable=SC2317
pr_log()   { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pr_warn()  { echo "$*" >>"$WARN_LOG"; }
# shellcheck disable=SC2317
pr_error() { echo "$*" >>"$WARN_LOG"; }

# pr_already_processed stub: PR_ALREADY_PROCESSED=1 で「既存扱い」、0 で「未存在扱い」
# shellcheck disable=SC2317
pr_already_processed() {
  if [ "${PR_ALREADY_PROCESSED:-0}" = "1" ]; then
    return 0
  fi
  return 1
}

# timeout stub: 秒数を捨てる
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}

# gh stub: 呼び出し payload を記録 + GH_PR_BODY を返す
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >>"$GH_CALL_LOG"
  case "$2" in
    view)
      printf '%s' "${GH_PR_BODY:-}"
      ;;
  esac
  return "${GH_NEXT_RC:-0}"
}

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_warns() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$WARN_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

VALID_SHA="abcdef0123456789abcdef0123456789abcdef01"
VALID_SHA2="0011223344556677889900112233445566778899"
VALID_PR="123"

# ============================================================
# Section 1: pr_extract_exec_fail_streak（純粋関数 / Req 1.1, 1.4）
# ============================================================
echo "--- Section 1: pr_extract_exec_fail_streak ---"

# Case 1.A: marker 不在 → `\t0`
out=$(pr_extract_exec_fail_streak "")
assert_eq "Req 1.4: 空入力で sha=空 / streak=0" "$(printf '\t0')" "$out"

out=$(pr_extract_exec_fail_streak "本文に marker が無い")
assert_eq "Req 1.4: marker 無し本文で sha=空 / streak=0" "$(printf '\t0')" "$out"

# Case 1.B: 単一 marker
body="本文
<!-- idd-claude:pr-reviewer-exec-fail-streak sha=${VALID_SHA} streak=2 tool=codex last-updated=2026-06-24T00:00:00Z -->"
out=$(pr_extract_exec_fail_streak "$body")
assert_eq "Req 1.1: 単一 marker から sha=$VALID_SHA / streak=2" \
  "$(printf '%s\t%s' "$VALID_SHA" "2")" "$out"

# Case 1.C: 複数 marker（末尾を採用 / 既存 pi_read* と整合）
body="<!-- idd-claude:pr-reviewer-exec-fail-streak sha=oldsha streak=1 tool=codex last-updated=2026-06-24T00:00:00Z -->
本文
<!-- idd-claude:pr-reviewer-exec-fail-streak sha=${VALID_SHA} streak=5 tool=codex last-updated=2026-06-24T01:00:00Z -->"
out=$(pr_extract_exec_fail_streak "$body")
assert_eq "Req 1.4: 複数 marker は末尾を採用（streak=5, sha=$VALID_SHA）" \
  "$(printf '%s\t%s' "$VALID_SHA" "5")" "$out"

# ============================================================
# Section 2: pr_read_exec_fail_streak（gh stub 越し）
# ============================================================
echo ""
echo "--- Section 2: pr_read_exec_fail_streak ---"

# Case 2.A: gh pr view 成功
reset_stub_state
GH_PR_BODY="$(printf '本文\n<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=3 tool=codex last-updated=2026-06-24T00:00:00Z -->\n' "$VALID_SHA")"
out=$(pr_read_exec_fail_streak "$VALID_PR")
assert_eq "Req 1.1: gh pr view 経由で sha + streak を取得" \
  "$(printf '%s\t%s' "$VALID_SHA" "3")" "$out"
gh_count=$(count_calls "^gh pr view")
assert_eq "Req 1.1: gh pr view が 1 回呼ばれる" "1" "$gh_count"
cleanup_stub_state

# Case 2.B: gh pr view 失敗 → 安全側 (sha=空, streak=0)
reset_stub_state
GH_NEXT_RC=1
GH_PR_BODY=""
out=$(pr_read_exec_fail_streak "$VALID_PR")
GH_NEXT_RC=0
assert_eq "Req 1.5: gh pr view 失敗時は安全側 (\\t0)" \
  "$(printf '\t0')" "$out"
warn_count=$(count_warns "body 取得に失敗")
assert_eq "Req 1.5: gh pr view 失敗時は WARN ログを残す" "1" "$warn_count"
cleanup_stub_state

# ============================================================
# Section 3: pr_write_exec_fail_streak（marker insert / replace）
# ============================================================
echo ""
echo "--- Section 3: pr_write_exec_fail_streak ---"

# Case 3.A: marker 不在 → 末尾追記
reset_stub_state
GH_PR_BODY="本文だけ"
pr_write_exec_fail_streak "$VALID_PR" "$VALID_SHA" "2" "codex"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 1.1: gh pr edit が呼ばれる" "$gh_line" "gh pr edit"
assert_contains "Req 1.1: 追記 body に marker prefix が含まれる" "$gh_line" "idd-claude:pr-reviewer-exec-fail-streak"
assert_contains "Req 1.1: 追記 body に streak=2 が含まれる" "$gh_line" "streak=2"
assert_contains "Req 1.1: 追記 body に sha=$VALID_SHA が含まれる" "$gh_line" "sha=$VALID_SHA"
cleanup_stub_state

# Case 3.B: 既存 marker を最新値で置換
reset_stub_state
GH_PR_BODY="$(printf '本文\n<!-- idd-claude:pr-reviewer-exec-fail-streak sha=oldsha streak=1 tool=codex last-updated=2026-06-24T00:00:00Z -->\n' )"
pr_write_exec_fail_streak "$VALID_PR" "$VALID_SHA" "4" "antigravity"
gh_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 1.1: 置換結果に streak=4 が含まれる" "$gh_line" "streak=4"
assert_contains "Req 1.1: 置換結果に tool=antigravity が含まれる" "$gh_line" "tool=antigravity"
# 旧 marker (sha=oldsha) が消えていることを確認するため、新値以外の sha が出ないこと
case "$gh_line" in
  *"streak=1"*)
    echo "FAIL: 旧 streak=1 が残存している（marker 置換失敗）"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
  *)
    echo "PASS: Req 1.1: 旧 marker (streak=1) が置換で消えている"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
esac
cleanup_stub_state

# Case 3.C: gh pr view 失敗 → WARN + rc=1（書き込みを skip）
reset_stub_state
GH_NEXT_RC=1
rc=0
pr_write_exec_fail_streak "$VALID_PR" "$VALID_SHA" "1" "codex" || rc=$?
GH_NEXT_RC=0
assert_eq "Req 1.5: body 取得失敗で rc=1" "1" "$rc"
warn_count=$(count_warns "body 取得に失敗")
assert_eq "Req 1.5: body 取得失敗で WARN 記録" "1" "$warn_count"
cleanup_stub_state

# ============================================================
# Section 4: pr_increment_exec_fail_streak（+1 / sha 変化時は 1）
# ============================================================
echo ""
echo "--- Section 4: pr_increment_exec_fail_streak ---"

# Case 4.A: 既存 streak=2、同一 sha → 3
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=2 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
new_streak=$(pr_increment_exec_fail_streak "$VALID_PR" "$VALID_SHA" "codex" 2>/dev/null)
assert_eq "Req 1.1: 既存 streak=2 + 同一 sha → 3" "3" "$new_streak"
edit_call=$(grep -E "gh pr edit" "$GH_CALL_LOG" || true)
assert_contains "Req 1.1: streak=3 で書き込み" "$edit_call" "streak=3"
cleanup_stub_state

# Case 4.B: 既存 streak=2、sha 変化 → 1（Req 1.2 fail-safe in increment）
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=2 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
new_streak=$(pr_increment_exec_fail_streak "$VALID_PR" "$VALID_SHA2" "codex" 2>/dev/null)
assert_eq "Req 1.2: sha 変化（旧→新）→ streak=1 から開始" "1" "$new_streak"
edit_call=$(grep -E "gh pr edit" "$GH_CALL_LOG" || true)
assert_contains "Req 1.2: 書き込みに新 sha が含まれる" "$edit_call" "sha=$VALID_SHA2"
cleanup_stub_state

# Case 4.C: marker 不在（初回失敗）→ 1
reset_stub_state
GH_PR_BODY="本文だけ"
new_streak=$(pr_increment_exec_fail_streak "$VALID_PR" "$VALID_SHA" "codex" 2>/dev/null)
assert_eq "Req 1.1: marker 不在 → streak=1 から開始" "1" "$new_streak"
cleanup_stub_state

# ============================================================
# Section 5: pr_reset_exec_fail_streak（成功 / sha 変化時）
# ============================================================
echo ""
echo "--- Section 5: pr_reset_exec_fail_streak ---"

# Case 5.A: 既存 streak=0 かつ sha 一致 → no-op（gh edit 呼ばない）
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=0 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
pr_reset_exec_fail_streak "$VALID_PR" "$VALID_SHA" "codex"
edit_count=$(count_calls "^gh pr edit")
assert_eq "NFR 4.2: streak=0 / sha 一致は no-op（gh edit 呼ばない）" "0" "$edit_count"
cleanup_stub_state

# Case 5.B: 既存 streak=2 → 0 に書き戻し
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=2 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
pr_reset_exec_fail_streak "$VALID_PR" "$VALID_SHA" "codex"
edit_call=$(grep -E "gh pr edit" "$GH_CALL_LOG" || true)
assert_contains "Req 1.3: streak=2 を 0 にリセット" "$edit_call" "streak=0"
cleanup_stub_state

# Case 5.C: sha 変化時のリセット
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=2 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
pr_reset_exec_fail_streak "$VALID_PR" "$VALID_SHA2" "codex"
edit_call=$(grep -E "gh pr edit" "$GH_CALL_LOG" || true)
assert_contains "Req 1.2: sha 変化時に新 sha+streak=0 で書き戻す" "$edit_call" "sha=$VALID_SHA2"
assert_contains "Req 1.2: sha 変化時 streak=0" "$edit_call" "streak=0"
cleanup_stub_state

# ============================================================
# Section 6: pr_exec_fail_limit_reached（上限到達判定）
# ============================================================
echo ""
echo "--- Section 6: pr_exec_fail_limit_reached ---"

# shellcheck disable=SC2034
PR_REVIEWER_EXEC_FAIL_LIMIT="3"

# Case 6.A: streak=2 < 3 → 未到達
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=2 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
assert_rc "Req 2.1: streak=2 < limit=3 → 未到達 (rc=1)" 1 \
  pr_exec_fail_limit_reached "$VALID_PR" "$VALID_SHA"
cleanup_stub_state

# Case 6.B: streak=3 = 3 → 到達
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=3 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
assert_rc "Req 2.2: streak=3 = limit=3 → 到達 (rc=0)" 0 \
  pr_exec_fail_limit_reached "$VALID_PR" "$VALID_SHA"
cleanup_stub_state

# Case 6.C: streak=5 > 3 → 到達
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=5 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
assert_rc "Req 2.2: streak=5 > limit=3 → 到達 (rc=0)" 0 \
  pr_exec_fail_limit_reached "$VALID_PR" "$VALID_SHA"
cleanup_stub_state

# Case 6.D: 記録 sha が現在 sha と異なる → 未到達（Req 2.5 / 1.2）
reset_stub_state
GH_PR_BODY="$(printf '<!-- idd-claude:pr-reviewer-exec-fail-streak sha=%s streak=5 tool=codex last-updated=2026-06-24T00:00:00Z -->' "$VALID_SHA")"
assert_rc "Req 2.5: 異なる sha では到達扱いにしない (rc=1)" 1 \
  pr_exec_fail_limit_reached "$VALID_PR" "$VALID_SHA2"
cleanup_stub_state

# ============================================================
# Section 7: pr_truncate_stderr_tail（末尾優先抜粋）
# ============================================================
echo ""
echo "--- Section 7: pr_truncate_stderr_tail ---"

# Case 7.A: 末尾優先で N バイト
tmp_err=$(mktemp)
printf 'HEAD_PREFIX_SHOULD_NOT_APPEAR\n%s\nRATE_LIMIT_429_TRUE_REASON\n' \
  "$(yes 'AAAA' | head -n 3000 | tr -d '\n')" > "$tmp_err"
total=$(wc -c < "$tmp_err" | tr -d ' ')
# 64 byte の末尾抜粋
out=$(pr_truncate_stderr_tail "$tmp_err" "64")
out_len=${#out}
if [ "$out_len" -le 64 ]; then
  echo "PASS: Req 3.4: 末尾優先抜粋が 64B 以内（actual=${out_len}, total=${total}）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 3.4: 末尾優先抜粋サイズ違反 actual=${out_len}, expected <= 64"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
assert_contains "Req 3.4: 末尾の RATE_LIMIT 行が抜粋に含まれる（先頭の prompt echo に埋もれない）" \
  "$out" "RATE_LIMIT_429_TRUE_REASON"
rm -f "$tmp_err"

# Case 7.B: ファイル不在 → 空文字
out=$(pr_truncate_stderr_tail "/nonexistent/path/$$" "1024")
assert_eq "Req 3.1: ファイル不在で空文字" "" "$out"

# ============================================================
# Section 8: pr_save_stderr_artifact（$HOME/.issue-watcher/... 配下保存）
# ============================================================
echo ""
echo "--- Section 8: pr_save_stderr_artifact ---"

# Case 8.A: 通常保存
reset_stub_state
tmp_root=$(mktemp -d)
PR_REVIEWER_STDERR_ARTIFACT_DIR="$tmp_root/pr-reviewer-artifacts"
PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES="1048576"
tmp_err=$(mktemp)
printf 'stderr line 1\nstderr line 2\nrate-limit-429\n' > "$tmp_err"
artifact_path=$(pr_save_stderr_artifact "$VALID_PR" "$VALID_SHA" "codex" "$tmp_err")
assert_contains "Req 3.5: 保存先パスは PR_REVIEWER_STDERR_ARTIFACT_DIR 配下" \
  "$artifact_path" "$tmp_root/pr-reviewer-artifacts"
assert_contains "Req 3.5: 保存先パスに PR 番号" "$artifact_path" "pr-${VALID_PR}-"
assert_contains "Req 3.5: 保存先パスに sha 先頭 8 文字" "$artifact_path" "${VALID_SHA:0:8}"
assert_contains "Req 3.5: 保存先パスに tool 名" "$artifact_path" "codex"
if [ -f "$artifact_path" ]; then
  saved=$(cat "$artifact_path")
  assert_contains "Req 3.1: 保存内容が stderr の本文と一致" "$saved" "rate-limit-429"
  echo "PASS: Req 3.5: artifact ファイルが実在する"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: artifact ファイルが存在しない: $artifact_path"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
rm -rf "$tmp_root" "$tmp_err"
cleanup_stub_state

# Case 8.B: 1MB 超 → 末尾優先で truncate（Req 3.4）
reset_stub_state
tmp_root=$(mktemp -d)
PR_REVIEWER_STDERR_ARTIFACT_DIR="$tmp_root/pr-reviewer-artifacts"
PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES="64"   # 64 バイトに絞ってテスト容易性確保
tmp_err=$(mktemp)
{
  printf 'HEAD_PREFIX_SHOULD_NOT_APPEAR_'
  for _ in $(seq 1 200); do printf 'XXXXXXXX'; done
  printf '\nTAIL_TRUE_REASON_RATE_LIMIT_429\n'
} > "$tmp_err"
artifact_path=$(pr_save_stderr_artifact "$VALID_PR" "$VALID_SHA" "antigravity" "$tmp_err")
if [ -n "$artifact_path" ] && [ -f "$artifact_path" ]; then
  saved=$(cat "$artifact_path")
  assert_contains "Req 3.4: 1MB 超は末尾優先で保存（TAIL_TRUE_REASON が残る）" \
    "$saved" "TAIL_TRUE_REASON"
  case "$saved" in
    *"HEAD_PREFIX_SHOULD_NOT_APPEAR"*)
      echo "FAIL: Req 3.4: 末尾優先抜粋に先頭が混入"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: Req 3.4: 末尾優先抜粋に先頭は含まれない"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
else
  echo "FAIL: Req 3.4: artifact が保存されていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
rm -rf "$tmp_root" "$tmp_err"
# shellcheck disable=SC2034
PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES="1048576"
cleanup_stub_state

# Case 8.C: PR_REVIEWER_STDERR_ARTIFACT_DIR 空文字 → skip（fail-safe / Req 3.1 fallback）
reset_stub_state
PR_REVIEWER_STDERR_ARTIFACT_DIR=""
tmp_err=$(mktemp)
echo "stderr content" > "$tmp_err"
artifact_path=$(pr_save_stderr_artifact "$VALID_PR" "$VALID_SHA" "codex" "$tmp_err")
assert_eq "Req 3.1: artifact dir 空文字で skip（空文字を返す）" "" "$artifact_path"
rm -f "$tmp_err"
cleanup_stub_state

# Case 8.D: 不正 PR 番号 / sha → skip（未信頼入力検証 / CLAUDE.md 5 番）
reset_stub_state
tmp_root=$(mktemp -d)
# shellcheck disable=SC2034
PR_REVIEWER_STDERR_ARTIFACT_DIR="$tmp_root/pr-reviewer-artifacts"
tmp_err=$(mktemp)
echo "stderr content" > "$tmp_err"
artifact_path=$(pr_save_stderr_artifact "abc" "$VALID_SHA" "codex" "$tmp_err")
assert_eq "Req 3.5: 不正 PR 番号で skip（空文字を返す）" "" "$artifact_path"
artifact_path=$(pr_save_stderr_artifact "$VALID_PR" "INVALID-SHA" "codex" "$tmp_err")
assert_eq "Req 3.5: 不正 sha で skip（空文字を返す）" "" "$artifact_path"
rm -rf "$tmp_root" "$tmp_err"
cleanup_stub_state

# ============================================================
# Section 9: pr_post_exec_fail_escalation_comment（advisory 1 回投稿）
# ============================================================
echo ""
echo "--- Section 9: pr_post_exec_fail_escalation_comment ---"

# Case 9.A: marker 不在 → 投稿
reset_stub_state
PR_ALREADY_PROCESSED=0
pr_post_exec_fail_escalation_comment "$VALID_PR" "$VALID_SHA" "codex" "3"
comment_count=$(count_calls "^gh pr comment")
assert_eq "Req 2.3: 初回検出 → advisory コメント 1 回投稿" "1" "$comment_count"
comment_line=$(cat "$GH_CALL_LOG")
assert_contains "Req 2.3: 本文に exec-fail-escalated marker" "$comment_line" "idd-claude:pr-reviewer"
assert_contains "Req 2.3: marker に kind=exec-fail-escalated" "$comment_line" "kind=exec-fail-escalated"
assert_contains "Req 2.3: 本文に連続失敗回数（streak=3）" "$comment_line" "3 回連続"
assert_contains "Req 2.3: 本文に運用者向け復旧手順（rate-limit 言及）" "$comment_line" "rate-limit"
assert_contains "Req 2.3: 本文に「新しい commit」復旧手順" "$comment_line" "新しい commit"
# Req 2.7: ラベル付与は行わない（advisory のみ）
case "$comment_line" in
  *"gh pr edit"*"--add-label"*)
    echo "FAIL: Req 2.7: advisory 経路でラベル付与が発生（禁止）"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
  *)
    echo "PASS: Req 2.7: ラベル付与なし（advisory のみ）"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
esac
cleanup_stub_state

# Case 9.B: marker 既存 → 再投稿しない（重複防止）
reset_stub_state
PR_ALREADY_PROCESSED=1
pr_post_exec_fail_escalation_comment "$VALID_PR" "$VALID_SHA" "codex" "3"
comment_count=$(count_calls "^gh pr comment")
assert_eq "Req 2.3: marker 既存 → advisory 再投稿しない（重複防止）" "0" "$comment_count"
cleanup_stub_state

# Case 9.C: 投稿失敗 → WARN + rc=1
reset_stub_state
PR_ALREADY_PROCESSED=0
GH_NEXT_RC=1
rc=0
pr_post_exec_fail_escalation_comment "$VALID_PR" "$VALID_SHA" "codex" "3" || rc=$?
GH_NEXT_RC=0
assert_eq "Req 2.3: 投稿失敗 → rc=1" "1" "$rc"
warn_count=$(count_warns "advisory コメントの投稿に失敗")
assert_eq "Req 2.3: 投稿失敗時 WARN 記録" "1" "$warn_count"
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
