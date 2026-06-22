#!/usr/bin/env bash
#
# 本テストの fake 依存（gh / mark_issue_failed）は eval / source で読み込んだ
# stage_a_verify_run や _sav_handle_failure から間接的にのみ呼ばれるため
# 静的解析からは unreachable 扱いになる。env var（NUMBER, REPO, LOG,
# REPO_DIR, SPEC_DIR_REL 等）も同関数から参照されるため unused 扱いになる。
# いずれも false positive のためファイル全体で抑止する（既存
# stage_a_verify_round1_defer_test.sh / pt_post_marker_classify_test.sh と同じ扱い）。
# shellcheck disable=SC2317,SC2034
#
# 用途: local-watcher/bin/modules/stage-a-verify.sh の Issue #364（パス不在 diff の
#       WARN 降格）で追加した挙動を検証するスモークテスト。
#
#       対象関数:
#         - _sav_is_path_missing_diff_failure (#364 Req 2.1 / 2.5 / 3.1 / NFR 2.1)
#         - _sav_extract_missing_path         (#364 Req 4.2)
#         - stage_a_verify_run                (#364 Req 2.1〜2.5 / 3.1 / 3.2 / 4.1〜4.4)
#
#       検証する AC（docs/specs/364-fix-watcher-architect-stage-a-verify-dif/
#                    requirements.md）:
#         - Req 2.1: diff 対象パス不在（exit=2 + No such file or directory）→ WARN 降格
#         - Req 2.2: WARN 降格時に round counter を増やさない
#         - Req 2.3: WARN ログを 1 行以上記録（reason=verify-path-missing + path）
#         - Req 2.4: real な lint/test 失敗（exit=1 等）は従来どおり round1/round2 経路
#         - Req 2.5: 連結コマンド中の real fail が優先（混在ケース）
#         - Req 3.1: パス不在を含まない既存 verify は本機能導入前と同一挙動
#         - Req 4.1〜4.3: WARN 行が `grep '\[.*\] stage-a-verify: WARN'` で抽出可能
#         - Req 4.4: outcome=warn-skipped を _SAV_LAST_OUTCOME に露出（success と区別）
#         - NFR 1.1: 既存挙動の byte-equivalent な後方互換
#         - NFR 2.2(a)(b)(c): (a) パス不在 → WARN / (b) real fail → 従来 fail / (c) diff exit=1 → 従来 fail
#
# 配置先: local-watcher/test/stage_a_verify_path_missing_test.sh
# 依存:   bash 4+, awk, sed, grep
# 実行:   bash local-watcher/test/stage_a_verify_path_missing_test.sh
# 前提:   stage-a-verify.sh は関数定義のみでトップレベル副作用を持たないため source する。
#         _sav_handle_failure → mark_issue_failed の cross-module 呼び出しは本テスト内で
#         stub する（gh も同様）。round counter の state dir / source sidecar は mktemp
#         で隔離する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/stage-a-verify.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find stage-a-verify.sh at $MODULE_SH" >&2
  exit 2
fi

# モジュールを source（関数定義のみのファイル）。set -euo pipefail はテスト側で既に宣言済み。
# shellcheck disable=SC1090
source "$MODULE_SH"

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

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: _sav_is_path_missing_diff_failure 単体テスト（純粋関数 / Req 2.1, 3.1, NFR 2.1）
# ─────────────────────────────────────────────────────────────────────────────

echo "================================================================"
echo "Section 1: _sav_is_path_missing_diff_failure 単体テスト"
echo "================================================================"

# Case 1.1: exit=2 + 'No such file or directory' + 'diff:' 行 → rc=0（WARN 対象）
rc=0
_sav_is_path_missing_diff_failure 2 "diff: nonexistent/path: No such file or directory" || rc=$?
assert_eq "Req 2.1: exit=2 + diff: ENOENT → rc=0（WARN 対象）" "0" "$rc"

# Case 1.2: exit=2 + ENOENT だが diff: 始まりでない（別コマンド由来）→ rc=1（real fail）
rc=0
_sav_is_path_missing_diff_failure 2 "cat: nonexistent/path: No such file or directory" || rc=$?
assert_eq "Req 2.5: exit=2 + 非 diff の ENOENT → rc=1（real fail として扱う）" "1" "$rc"

# Case 1.3: exit=1（diff の content 差分）→ rc=1（real fail / NFR 2.2(c)）
rc=0
_sav_is_path_missing_diff_failure 1 "diff: extra non-blank text" || rc=$?
assert_eq "NFR 2.2(c): exit=1（diff content 差分）→ rc=1（従来 fail）" "1" "$rc"

# Case 1.4: exit=124（timeout）→ rc=1（real fail / Req 2.4）
rc=0
_sav_is_path_missing_diff_failure 124 "" || rc=$?
assert_eq "Req 2.4: exit=124（timeout）→ rc=1（従来 fail）" "1" "$rc"

# Case 1.5: exit=2 + ENOENT メッセージ無し（権限エラー等）→ rc=1（real fail）
rc=0
_sav_is_path_missing_diff_failure 2 "diff: foo: Permission denied" || rc=$?
assert_eq "Req 2.5: exit=2 だが ENOENT 無し → rc=1（real fail）" "1" "$rc"

# Case 1.6: exit=2 + 空 stderr → rc=1（判定不能なら real fail に倒す / 安全側）
rc=0
_sav_is_path_missing_diff_failure 2 "" || rc=$?
assert_eq "NFR 2.1: exit=2 + 空 stderr → rc=1（安全側 fail）" "1" "$rc"

# Case 1.7: 非整数 rc → rc=1（防御的検証 / 安全側）
rc=0
_sav_is_path_missing_diff_failure "garbage" "diff: x: No such file or directory" || rc=$?
assert_eq "NFR 2.1: 非整数 rc → rc=1（安全側 fail）" "1" "$rc"

# Case 1.8: 複数行 stderr 中に diff: ENOENT 行を 1 件以上含む → rc=0
rc=0
_sav_is_path_missing_diff_failure 2 "$(printf 'some warning\ndiff: a/b: No such file or directory\nother line\n')" || rc=$?
assert_eq "Req 4.2: 複数行 stderr 中の diff ENOENT → rc=0" "0" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: _sav_extract_missing_path 単体テスト（純粋関数 / Req 4.2）
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "Section 2: _sav_extract_missing_path 単体テスト"
echo "================================================================"

# Case 2.1: 単一行 diff ENOENT → パスを抽出
out=$(_sav_extract_missing_path "diff: nonexistent/dir: No such file or directory")
assert_eq "Req 4.2: 単一行からパス抽出" "nonexistent/dir" "$out"

# Case 2.2: 複数行 stderr の最初の diff ENOENT 行からパス抽出
out=$(_sav_extract_missing_path "$(printf 'warning: foo\ndiff: a/b/c: No such file or directory\ndiff: x/y: No such file or directory\n')")
assert_eq "Req 4.2: 複数行から最初の path 抽出" "a/b/c" "$out"

# Case 2.3: マッチしない stderr → 空文字
out=$(_sav_extract_missing_path "no diff line here")
assert_eq "Req 4.2: マッチ無しは空文字" "" "$out"

# Case 2.4: 空 stderr → 空文字
out=$(_sav_extract_missing_path "")
assert_eq "Req 4.2: 空 stderr は空文字" "" "$out"

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: stage_a_verify_run 統合テスト（WARN 降格 / real fail / 既存挙動）
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "Section 3: stage_a_verify_run 統合テスト"
echo "================================================================"

# ── 共通 setup: テスト用 worktree / spec dir / round state dir を mktemp で隔離 ──
TEST_ROOT=$(mktemp -d)
REPO_DIR="$TEST_ROOT/work"
SPEC_DIR_REL="docs/specs/364-test"
mkdir -p "$REPO_DIR/$SPEC_DIR_REL"
# round counter は state dir env で隔離（worktree 外）
STAGE_A_VERIFY_STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STAGE_A_VERIFY_STATE_DIR"

# env: stage-a-verify モジュールが参照する変数
REPO="owner/test"
REPO_SLUG="owner-test"
NUMBER=364
BRANCH="claude/issue-364-test"
SLUG="test"
LOG="$TEST_ROOT/cron.log"
: > "$LOG"
LABEL_PICKED="claude-picked-up"
LABEL_CLAIMED="claude-claimed"
# `set -u` 配下で空文字でも参照可能なように明示初期化
STAGE_A_VERIFY_COMMAND=""
STAGE_A_VERIFY_TIMEOUT=30
STAGE_A_VERIFY_ENABLED="true"

# fake gh: ラベル除去等の副作用は stub で無視する
GH_ARGS_FILE="$TEST_ROOT/gh-args.log"
: > "$GH_ARGS_FILE"
gh() {
  printf '%s\n' "$*" >> "$GH_ARGS_FILE"
  return 0
}

# fake mark_issue_failed: round=2 escalate 経路で呼ばれる。実体は impl-pipeline 系に
# あり本モジュールから cross-module 呼び出しされるので、テストでは呼び出し有無のみ記録する。
MIF_CALLED=0
mark_issue_failed() {
  MIF_CALLED=1
  echo "[stub-mark_issue_failed] reason=$1 extra=$2" >> "$LOG"
  return 0
}

# 構造化 verify ブロックを書き込んで tasks.md を生成するヘルパー
write_tasks_with_verify() {
  local cmd_body="$1"
  cat > "$REPO_DIR/$SPEC_DIR_REL/tasks.md" <<EOF
# Tasks

- [ ] 1. dummy task
  - _Requirements: 1.1_

<!-- stage-a-verify -->
\`\`\`sh
$cmd_body
\`\`\`
EOF
}

# round counter の値を読むヘルパー
read_round() {
  local rp
  rp=$(stage_a_verify_round_path)
  if [ -f "$rp" ]; then
    cat "$rp"
  else
    echo "0"
  fi
}

# 各 case で実行前に round counter / log / outcome を初期化するヘルパー
reset_state() {
  stage_a_verify_reset_round
  : > "$LOG"
  : > "$GH_ARGS_FILE"
  MIF_CALLED=0
  _SAV_LAST_OUTCOME=""
}

# stage_a_verify_run を実 watcher 環境（cron）と同じく stdout/stderr を $LOG へ集約して
# 実行するラッパー。実 watcher の cron 行は `>> cron.log 2>&1` で全出力を LOG に redirect
# しており、sav_log（stdout）/ sav_warn（stderr）/ EXEC 中の stdout/stderr もすべて LOG に
# 入る前提でログ grep の AC を組んでいる。テストでも同じ前提を再現することで AC が実 watcher
# 環境と同等に検証できる。`set -e` 配下で rc を吸収するため `|| true` を最後に置く。
run_with_log() {
  # stage_a_verify_run の戻り値は global RUN_RC へ格納する（command substitution の
  # サブシェル境界を避け、_SAV_LAST_OUTCOME 等の global を呼び出し側で観測可能にする）。
  RUN_RC=0
  { stage_a_verify_run || RUN_RC=$?; } >> "$LOG" 2>&1
  return 0
}

# ─── Case 3.1: パス不在の diff（exit=2 + ENOENT）→ WARN 降格 / rc=0 / Stage A 続行 ───
echo "--- Case 3.1: diff path missing → WARN 降格（NFR 2.2(a)） ---"
reset_state
# 連結ではなく単独の diff 失敗。`/nonexistent/...` を存在しないパスとして使う。
write_tasks_with_verify "diff -r '$REPO_DIR/nonexistent_a' '$REPO_DIR/nonexistent_b'"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
round_val=$(read_round)
assert_eq "Req 2.1 / 3.x: WARN 降格 → rc=0" "0" "$rc"
assert_eq "Req 4.4: _SAV_LAST_OUTCOME=warn-skipped" "warn-skipped" "$_SAV_LAST_OUTCOME"
assert_eq "Req 2.2: round counter 不変（0 のまま）" "0" "$round_val"
assert_contains "Req 4.1: WARN log 1 行以上" "stage-a-verify: WARN" "$log_body"
assert_contains "Req 4.1 / 4.2: reason=verify-path-missing を含む" "reason=verify-path-missing" "$log_body"
assert_contains "Req 4.2: WARN ログに検出パスを含む" "nonexistent_a" "$log_body"
# Req 4.3: grep 抽出可能性
warn_lines=$(grep '\[.*\] stage-a-verify: WARN' "$LOG" || true)
assert_contains "Req 4.3: grep '\\[.*\\] stage-a-verify: WARN' で抽出可能" "reason=verify-path-missing" "$warn_lines"
# mark_issue_failed は呼ばれない（escalate 防止）
assert_eq "Req 2.2: WARN 降格時に mark_issue_failed 呼ばれない" "0" "$MIF_CALLED"
# gh issue comment も呼ばれない（差し戻し防止 / Req 2.2）
gh_body=$(cat "$GH_ARGS_FILE")
assert_not_contains "Req 2.2: gh issue comment 呼ばれない" "issue comment" "$gh_body"

# ─── Case 3.2: real な lint 失敗（shellcheck exit=1 等）→ 従来 fail（round1 差し戻し） ───
echo "--- Case 3.2: real lint fail (exit=1) → 従来 fail（NFR 2.2(b)） ---"
reset_state
# shell-check や bash でなく直接 `exit 1` を返すコマンドで verify keyword 一致を回避しつつ、
# 構造化 verify ブロック経由でなら任意コマンドを実行できる（Gate 3 を bypass）。
write_tasks_with_verify "exit 1"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
round_val=$(read_round)
assert_eq "Req 2.4 / NFR 2.2(b): real fail → rc=1（round1 差し戻し）" "1" "$rc"
assert_eq "Req 4.4: _SAV_LAST_OUTCOME=round1" "round1" "$_SAV_LAST_OUTCOME"
assert_eq "Req 2.4: round counter=1" "1" "$round_val"
assert_contains "Req 2.4: FAILED log（real fail）" "FAILED exit=1" "$log_body"
assert_not_contains "Req 2.4: real fail で WARN 降格しない" "reason=verify-path-missing" "$log_body"

# ─── Case 3.3: diff content 差分（exit=1）→ 従来 fail（NFR 2.2(c)） ───
echo "--- Case 3.3: diff content difference (exit=1) → 従来 fail（NFR 2.2(c)） ---"
reset_state
# 2 つの異なる中身のディレクトリを作成し、diff -r が exit=1 を返すように仕込む。
mkdir -p "$REPO_DIR/dir_a" "$REPO_DIR/dir_b"
printf 'a content\n' > "$REPO_DIR/dir_a/file.txt"
printf 'b content\n' > "$REPO_DIR/dir_b/file.txt"
write_tasks_with_verify "diff -r '$REPO_DIR/dir_a' '$REPO_DIR/dir_b'"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "NFR 2.2(c): diff exit=1 → rc=1（従来 fail）" "1" "$rc"
assert_eq "Req 4.4: _SAV_LAST_OUTCOME=round1" "round1" "$_SAV_LAST_OUTCOME"
assert_contains "NFR 2.2(c): FAILED log" "FAILED exit=1" "$log_body"
assert_not_contains "NFR 2.2(c): WARN 降格しない" "reason=verify-path-missing" "$log_body"

# ─── Case 3.4: 既存 verify が success → 本機能導入前と同一挙動（Req 3.1） ───
echo "--- Case 3.4: success path（Req 3.1 / NFR 1.1） ---"
reset_state
write_tasks_with_verify "true"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 3.1: success → rc=0" "0" "$rc"
assert_eq "Req 4.4: _SAV_LAST_OUTCOME=success" "success" "$_SAV_LAST_OUTCOME"
assert_contains "Req 3.1: SUCCESS log" "SUCCESS exit=0" "$log_body"
assert_not_contains "Req 3.1: success で WARN 降格しない" "reason=verify-path-missing" "$log_body"

# ─── Case 3.5: STAGE_A_VERIFY_ENABLED=false（既存 opt-out）→ DISABLED（Req 3.2） ───
echo "--- Case 3.5: STAGE_A_VERIFY_ENABLED=false（Req 3.2 / NFR 1.1） ---"
reset_state
STAGE_A_VERIFY_ENABLED="false"
write_tasks_with_verify "exit 1"  # 実行されるべきでない
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 3.2: disabled → rc=0" "0" "$rc"
assert_eq "Req 4.4: _SAV_LAST_OUTCOME=disabled" "disabled" "$_SAV_LAST_OUTCOME"
assert_contains "Req 3.2: DISABLED log" "DISABLED reason=env-opt-out" "$log_body"
STAGE_A_VERIFY_ENABLED="true"  # 後続テストのため復元

# ─── Case 3.6: 連結 (real fail && path-missing 混在)→ real fail を優先（Req 2.5） ───
echo "--- Case 3.6: 連結 real fail + path-missing → real fail 優先（Req 2.5） ---"
reset_state
# `exit 1` で real fail、その後の diff は実行されない（`&&` 短絡）。
# bash -c 全体の exit code は最初の失敗で 1 となり WARN 降格しない。
write_tasks_with_verify "exit 1 && diff -r '$REPO_DIR/missing1' '$REPO_DIR/missing2'"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 2.5: 連結 real fail 優先 → rc=1" "1" "$rc"
assert_eq "Req 4.4: outcome=round1（real fail）" "round1" "$_SAV_LAST_OUTCOME"
assert_not_contains "Req 2.5: 連結 real fail 優先で WARN 降格しない" "reason=verify-path-missing" "$log_body"

# ─── Case 3.7: `;` 連結 で path-missing が最終 exit を支配 → WARN 降格（Req 2.5 inverse） ───
echo "--- Case 3.7: 連結 (path-missing が末尾 exit を支配)→ WARN 降格 ---"
reset_state
# `;` 連結で先頭が success、末尾の diff が path-missing → bash -c 全体 exit は 2
# このケースは「連結中のいずれかが path-missing のみで終了」の Req 2.5 該当ケースと
# 解釈できる（real fail を含まない連結）。WARN 降格を期待する。
write_tasks_with_verify "true ; diff -r '$REPO_DIR/missing1' '$REPO_DIR/missing2'"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 2.5: real fail 不在の連結 path-missing → rc=0（WARN 降格）" "0" "$rc"
assert_eq "Req 4.4: outcome=warn-skipped" "warn-skipped" "$_SAV_LAST_OUTCOME"
assert_contains "Req 4.1: WARN 降格 log" "reason=verify-path-missing" "$log_body"

# ─────────────────────────────────────────────────────────────────────────────
# cleanup
# ─────────────────────────────────────────────────────────────────────────────

rm -rf "$TEST_ROOT" 2>/dev/null || true

echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
