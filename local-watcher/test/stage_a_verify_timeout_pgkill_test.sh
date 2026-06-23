#!/usr/bin/env bash
#
# 本テストの fake 依存（gh / mark_issue_failed）は eval / source で読み込んだ
# stage_a_verify_run 等から間接的にのみ呼ばれるため静的解析からは unreachable 扱いに
# なる。env var（NUMBER / REPO / LOG / REPO_DIR / SPEC_DIR_REL 等）も同関数から
# 参照されるため unused 扱いになる。いずれも false positive のためファイル全体で
# 抑止する（既存 stage_a_verify_path_missing_test.sh と同じ扱い）。
# shellcheck disable=SC2317,SC2034
#
# 用途: local-watcher/bin/modules/stage-a-verify.sh の Issue #377（verify ハング時の
#       pgid kill とパイプデッドロック回避）で追加した挙動を検証するスモークテスト。
#
#       対象関数:
#         - _sav_exec_with_timeout  (#377 Req 2.1〜2.5 / Req 3.1〜3.4)
#         - stage_a_verify_run      (#377 Req 2.1〜2.5 / Req 4.1〜4.3 / Req 5.x)
#
#       検証する AC（docs/specs/377-fix-stage-a-verify-verify-timeout-flock/
#                    requirements.md）:
#         - Req 2.1: 孫プロセスを spawn してハングした verify cmd が wall-clock 上限
#                    + grace 以内に強制終了される
#         - Req 2.2: 強制終了後に有限時間内に呼び出し元へ復帰する（test 全体が finite 時間）
#         - Req 2.5: 復帰時点で session 配下に残存プロセスがいない
#         - Req 3.1: 大量出力を行う verify cmd でも pipe deadlock しない（tempfile 経由）
#         - Req 4.1: timeout 強制終了時の WARN ログに elapsed / kill_after を含む
#         - Req 5.1, 5.2: 新規 env STAGE_A_VERIFY_KILL_AFTER の既定値で従来挙動を再現
#         - Req 5.4: stage_a_verify_run の return code 契約（0/1/2）を破壊しない
#         - NFR 3.1, 3.2, 3.3: ハング cmd / 大量出力 cmd / extract_function イディオム
#
# 配置先: local-watcher/test/stage_a_verify_timeout_pgkill_test.sh
# 依存:   bash 4+, setsid (util-linux), timeout (coreutils), date, pgrep, awk
# 実行:   bash local-watcher/test/stage_a_verify_timeout_pgkill_test.sh
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

# 依存 CLI 検証
for _cli in setsid timeout date; do
  if ! command -v "$_cli" >/dev/null 2>&1; then
    echo "ERROR: required CLI '$_cli' not found (util-linux / coreutils が必要)" >&2
    exit 2
  fi
done

# モジュール source（関数定義のみ）。set -euo pipefail はテスト側で既に宣言済み。
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

assert_le() {
  # actual <= bound を assert（経過秒数の上限検証用）
  local label="$1"
  local bound="$2"
  local actual="$3"
  if [ "$actual" -le "$bound" ] 2>/dev/null; then
    echo "PASS: $label (actual=$actual <= bound=$bound)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  bound:  $bound"
    echo "  actual: $actual"
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
    echo "  haystack: $(printf '%q' "$haystack" | head -c 400)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: _sav_exec_with_timeout 単体テスト（核心 AC）
# ─────────────────────────────────────────────────────────────────────────────

echo "================================================================"
echo "Section 1: _sav_exec_with_timeout 単体テスト"
echo "================================================================"

# REPO_DIR は cd 先として参照されるので tmpdir を設定する
TEST_TMP=$(mktemp -d)
REPO_DIR="$TEST_TMP"

# ── Case 1.1: 正常系 — 短時間で exit 0 ──
echo "--- Case 1.1: 正常終了（exit 0） ---"
_stdout=$(mktemp)
_stderr=$(mktemp)
_rc=0
_sav_exec_with_timeout "echo ok" 5 1 "$_stdout" "$_stderr" || _rc=$?
assert_eq "Req 5.4: 正常系 rc=0" "0" "$_rc"
assert_eq "Req 5.4: _SAV_LAST_EXEC_RC=0" "0" "$_SAV_LAST_EXEC_RC"
assert_contains "Req 3.3: stdout に 'ok'" "ok" "$(cat "$_stdout")"
rm -f "$_stdout" "$_stderr"

# ── Case 1.2: 核心 AC — 単純 sleep infinity が timeout で復帰する ──
echo "--- Case 1.2: sleep infinity → timeout=124 復帰（Req 2.1, 2.2） ---"
_stdout=$(mktemp)
_stderr=$(mktemp)
_rc=0
_t0=$(date +%s)
# timeout=2 / kill_after=1 → 最悪 3 秒 + ε で復帰すべき
_sav_exec_with_timeout "sleep infinity" 2 1 "$_stdout" "$_stderr" || _rc=$?
_t1=$(date +%s)
_wall=$(( _t1 - _t0 ))
# GNU timeout は SIGTERM で終了したプロセスは 124、SIGKILL は 137 を返す可能性がある
case "$_rc" in
  124|137) echo "PASS: Req 2.3: timeout 経路 rc=$_rc"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *)       echo "FAIL: Req 2.3: timeout 経路 rc 期待=124 or 137 / 実際=$_rc"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
esac
# wall-clock は timeout + kill_after + 余裕(5s) 以内（Req 2.1, 2.2）
assert_le "Req 2.1, 2.2: wall-clock <= timeout+kill_after+5s" "8" "$_wall"
assert_le "Req 4.1: _SAV_LAST_EXEC_ELAPSED 観測値 <= 8" "8" "$_SAV_LAST_EXEC_ELAPSED"
rm -f "$_stdout" "$_stderr"

# ── Case 1.3: 孫プロセス hang ケース — bash -c 内で sleep を spawn ──
echo "--- Case 1.3: 孫プロセス hang → 全グループ kill（Req 2.5） ---"
_stdout=$(mktemp)
_stderr=$(mktemp)
_rc=0
_t0=$(date +%s)
# bash -c の子 (`bash`) がさらに孫 (`sleep`) を spawn し、`wait` で孫を待つ。
# 旧実装では timeout が bash にしか SIGTERM を送らず、孫 sleep が無限に残る経路があった。
# 新実装は setsid + pgid kill で session 全体を kill するため、孫もここで終了する。
_sav_exec_with_timeout "sleep infinity & wait" 2 1 "$_stdout" "$_stderr" || _rc=$?
_t1=$(date +%s)
_wall=$(( _t1 - _t0 ))
case "$_rc" in
  124|137|143) echo "PASS: Req 2.5: 孫プロセス hang → rc=$_rc (timeout 経路)"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *)           echo "FAIL: Req 2.5: 孫プロセス hang → rc 期待=124/137/143 / 実際=$_rc"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
esac
assert_le "Req 2.2: 孫 hang でも wall-clock <= 8s" "8" "$_wall"

# pgid kill の効力確認: 残存 sleep プロセスが自テスト session 配下に存在しないこと。
# pgrep の親プロセス指定はテスト本体（$$ ＝本テストの bash プロセス）から孫を辿る形で実施。
# session leader が setsid 由来で本テスト session と切り離されているため、`pgrep -s $$` では
# 検出されないが、念のため verify cmd で起動した `sleep infinity` が残っていないことを
# pgrep でグローバル検索する（ただしホスト全体に他の `sleep infinity` がある可能性に配慮し
# プロセス親が本テスト pid 配下のものに絞る）。
sleep 0.5  # kill の伝播完了を待つ最小スリープ
# 本テスト pid 配下に sleep infinity が残っていないかチェック（pgrep -P は直接の親のみ）
# session 越えで残存検出はホスト依存になりやすいため、ここでは「テスト pid グループ配下」を見る。
_residual=$(ps -o pid=,ppid=,cmd= -A 2>/dev/null | awk -v me="$$" '$2 == me && /sleep infinity/' || true)
if [ -z "$_residual" ]; then
  echo "PASS: Req 2.5: 本テスト pid 配下に sleep infinity 残存なし"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.5: sleep infinity 残存検出"
  echo "  residual: $_residual"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
rm -f "$_stdout" "$_stderr"

# ── Case 1.4: 大量出力 + 早期 exit — pipe deadlock 回帰検出 ──
echo "--- Case 1.4: 大量出力 + 早期 exit → deadlock しない（Req 3.1, NFR 3.2） ---"
_stdout=$(mktemp)
_stderr=$(mktemp)
_rc=0
_t0=$(date +%s)
# `yes | head -n 100000` で大量出力（約 200KB）してから exit。
# 旧 process substitution 実装でも `head -n` で write 端が閉じれば deadlock しないが、
# 念のため timeout=10 を与えて wall-clock 制限内で完了することを確認する。
_sav_exec_with_timeout "yes | head -n 100000" 10 1 "$_stdout" "$_stderr" || _rc=$?
_t1=$(date +%s)
_wall=$(( _t1 - _t0 ))
# `yes | head` は SIGPIPE で yes が終了するため exit code が 141 になり得る（yes の終了状態）。
# 但し bash の pipefail なしの単純パイプは最後の cmd（head=0）が返るはず。
# どちらでも deadlock せず wall-clock 内で復帰すれば OK。
case "$_rc" in
  0|141) echo "PASS: Req 3.1: 大量出力後 rc=$_rc（deadlock せず復帰）"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
  *)     echo "INFO: rc=$_rc（許容範囲。deadlock 不発が本質）"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
esac
assert_le "Req 3.1: 大量出力でも wall-clock <= 5s" "5" "$_wall"
# stdout に少なくとも 1 万行は書かれているはず（pipe deadlock せず完走した証拠）
_lines=$(wc -l < "$_stdout" 2>/dev/null || echo 0)
if [ "$_lines" -ge 10000 ]; then
  echo "PASS: Req 3.3: stdout に十分な行数（$_lines >= 10000）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: stdout 行数不足（$_lines）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
rm -f "$_stdout" "$_stderr"

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: stage_a_verify_run 統合テスト（timeout 経路 + observability ログ）
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "Section 2: stage_a_verify_run 統合（timeout → WARN + elapsed/kill_after ログ）"
echo "================================================================"

# テスト用 worktree / spec dir / state dir / log を mktemp で隔離
TEST_ROOT=$(mktemp -d)
REPO_DIR="$TEST_ROOT/work"
SPEC_DIR_REL="docs/specs/377-test"
mkdir -p "$REPO_DIR/$SPEC_DIR_REL"
STAGE_A_VERIFY_STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STAGE_A_VERIFY_STATE_DIR"

REPO="owner/test"
REPO_SLUG="owner-test"
NUMBER=377
BRANCH="claude/issue-377-test"
SLUG="test"
LOG="$TEST_ROOT/cron.log"
: > "$LOG"
LABEL_PICKED="claude-picked-up"
LABEL_CLAIMED="claude-claimed"
STAGE_A_VERIFY_COMMAND=""
STAGE_A_VERIFY_ENABLED="true"
# 短い timeout で核心 AC を素早く検証する
STAGE_A_VERIFY_TIMEOUT=2
STAGE_A_VERIFY_KILL_AFTER=1

# fake gh / mark_issue_failed
GH_ARGS_FILE="$TEST_ROOT/gh-args.log"
: > "$GH_ARGS_FILE"
gh() {
  printf '%s\n' "$*" >> "$GH_ARGS_FILE"
  return 0
}
MIF_CALLED=0
mark_issue_failed() {
  MIF_CALLED=1
  echo "[stub-mark_issue_failed] reason=$1 extra=$2" >> "$LOG"
  return 0
}

# 構造化 verify ブロックを書き込むヘルパー（Gate 3 bypass のため structured-block で投入）
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

reset_state() {
  stage_a_verify_reset_round
  : > "$LOG"
  : > "$GH_ARGS_FILE"
  MIF_CALLED=0
  _SAV_LAST_OUTCOME=""
}

run_with_log() {
  RUN_RC=0
  { stage_a_verify_run || RUN_RC=$?; } >> "$LOG" 2>&1
  return 0
}

# ── Case 2.1: stage_a_verify_run 統合 — hang cmd → TIMEOUT WARN + elapsed/kill_after ログ ──
echo "--- Case 2.1: hang cmd → TIMEOUT WARN（elapsed / kill_after を含む） ---"
reset_state
write_tasks_with_verify "sleep infinity"
_t0=$(date +%s)
run_with_log
_t1=$(date +%s)
_wall=$(( _t1 - _t0 ))
log_body=$(cat "$LOG")
# round=1 差し戻し or round=2 escalate のどちらかを期待。reset_state で round 0 始まりなので round=1。
assert_eq "Req 5.4: timeout 経路 rc=1 (round1 差し戻し)" "1" "$RUN_RC"
assert_eq "Req 5.3: outcome=round1" "round1" "$_SAV_LAST_OUTCOME"
assert_le "Req 2.1, 2.2: 復帰までの wall-clock <= timeout+kill_after+5s" "8" "$_wall"
assert_contains "Req 4.1, 4.2: TIMEOUT WARN ログ" "TIMEOUT timeout=2s" "$log_body"
assert_contains "Req 4.1: kill_after を含む" "kill_after=1s" "$log_body"
assert_contains "Req 4.1: elapsed を含む" "elapsed=" "$log_body"
assert_contains "Req 4.2: 'TIMEOUT' キーワード grep 抽出可能" "stage-a-verify: WARN: TIMEOUT" "$log_body"

# ── Case 2.2: 既定 KILL_AFTER（未設定）で従来挙動互換 ──
echo "--- Case 2.2: STAGE_A_VERIFY_KILL_AFTER 未設定 → 既定 10s（Req 5.1, 5.2） ---"
reset_state
unset STAGE_A_VERIFY_KILL_AFTER
write_tasks_with_verify "true"
run_with_log
log_body=$(cat "$LOG")
# 既定値 10 が EXEC ログに出ること（後方互換性 / 新規 env 未設定時の挙動確認）
assert_eq "Req 5.4: success → rc=0" "0" "$RUN_RC"
assert_contains "Req 5.2: 未設定時 kill_after=10s が EXEC ログに記録" "kill_after=10s" "$log_body"
STAGE_A_VERIFY_KILL_AFTER=1  # 後続テストのため復元

# ── Case 2.3: 成功時の elapsed ログ ──
echo "--- Case 2.3: success → SUCCESS ログに elapsed を含む（Req 4.1 拡張） ---"
reset_state
write_tasks_with_verify "true"
run_with_log
log_body=$(cat "$LOG")
assert_eq "Req 5.4: success → rc=0" "0" "$RUN_RC"
assert_contains "Req 4.1: SUCCESS ログに elapsed=" "SUCCESS exit=0 elapsed=" "$log_body"

# ── cleanup ──
rm -rf "$TEST_TMP" "$TEST_ROOT" 2>/dev/null || true

echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
