#!/usr/bin/env bash
#
# 用途: Phase C Dispatcher の Slot Worker 起動（_dispatcher_spawn_worker）と終了処理
#       （_dispatcher_signal_worker_tree / _dispatcher_list_descendants /
#       _dispatcher_any_worker_alive）を検証する近接テスト（無人運用改善提案 P0-2）。
#
#       検証観点:
#         - worker サブシェルが自身を leader とする process group（pgid == pid）で起動する
#         - worker 内で多重起動防止の fd 200 が閉じられている（孫へ継承されない）
#         - worker の stdin が /dev/null（job control 下でも従来どおり）
#         - _dispatcher_signal_worker_tree TERM で、worker 本体・同 group の孫・
#           `timeout` 配下で別 process group に移った孫までが全て終了する
#         - _dispatcher_any_worker_alive が生存 / 全終了を正しく返す
#
# 配置先: local-watcher/test/dispatcher_worker_pgid_test.sh
# 依存:   bash 4+, ps, pgrep, timeout (coreutils), sleep
# 実行:   bash local-watcher/test/dispatcher_worker_pgid_test.sh
# 前提:   issue-watcher.sh から関数を extract_function で隔離抽出し、_slot_run_issue /
#         dispatcher_warn を stub する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
for _cli in ps pgrep timeout; do
  if ! command -v "$_cli" >/dev/null 2>&1; then
    echo "ERROR: required CLI '$_cli' not found" >&2
    exit 2
  fi
done

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

declare -A _DISPATCHER_SLOT_PIDS
dispatcher_warn() { :; }
dispatcher_log() { :; }

# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "_dispatcher_spawn_worker")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "_dispatcher_signal_worker_tree")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "_dispatcher_list_descendants")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "_dispatcher_any_worker_alive")"

for fn in _dispatcher_spawn_worker _dispatcher_signal_worker_tree \
          _dispatcher_list_descendants _dispatcher_any_worker_alive; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

PIDS_FILE="$TMPDIR_TEST/pids"
FD200_FILE="$TMPDIR_TEST/fd200"
STDIN_FILE="$TMPDIR_TEST/stdin"

# _slot_run_issue stub: 本番 worker を模して
#   - fd 200 の open 状態と stdin の種類を記録
#   - 同 process group の孫（sleep）と、`timeout` 配下で別 group に移る孫を起動して wait
_slot_run_issue() {
  if { true >&200; } 2>/dev/null; then echo "open" > "$FD200_FILE"; else echo "closed" > "$FD200_FILE"; fi
  if [ -t 0 ]; then echo "tty" > "$STDIN_FILE"; else
    # /dev/null かどうか（文字デバイスかつ読み出しが即 EOF）
    if read -r -t 0.2 _ ; then echo "readable" > "$STDIN_FILE"; else echo "eof-or-devnull" > "$STDIN_FILE"; fi
  fi
  sleep 60 &
  local g1=$!
  timeout 60 sleep 60 &
  local g2=$!
  printf '%s %s %s\n' "$BASHPID" "$g1" "$g2" > "$PIDS_FILE"
  wait
}

# 本番と同じく fd 200 を open した状態で fork する
exec 200>"$TMPDIR_TEST/global.lock"

_dispatcher_spawn_worker 1 '{"number":1}'
worker_pid="${_DISPATCHER_SLOT_PIDS[1]}"

# pids ファイルが書かれるまで待つ（最大 5 秒）
for _ in $(seq 1 50); do
  [ -s "$PIDS_FILE" ] && break
  sleep 0.1
done
read -r sub_pid g1 g2 < "$PIDS_FILE"

echo "--- spawn: process group / fd 200 / stdin ---"
assert_eq "worker subshell pid matches registered pid" "$worker_pid" "$sub_pid"
worker_pgid=$(ps -o pgid= -p "$worker_pid" | tr -d ' ')
assert_eq "worker is its own process group leader (pgid == pid)" "$worker_pid" "$worker_pgid"
g1_pgid=$(ps -o pgid= -p "$g1" | tr -d ' ')
assert_eq "plain grandchild shares worker pgid" "$worker_pid" "$g1_pgid"
assert_eq "fd 200 closed inside worker" "closed" "$(cat "$FD200_FILE")"
assert_eq "worker stdin is not a tty / not readable" "eof-or-devnull" "$(cat "$STDIN_FILE")"
assert_rc "_dispatcher_any_worker_alive while running" 0 _dispatcher_any_worker_alive

echo "--- descendants are enumerated before signalling ---"
desc_list=$(_dispatcher_list_descendants "$worker_pid" | tr '\n' ' ')
assert_contains "descendant list includes plain grandchild" "$desc_list" "$g1 "
assert_contains "descendant list includes timeout grandchild" "$desc_list" "$g2 "
g2_child=$(pgrep -P "$g2" | head -1)
assert_contains "descendant list includes sleep under timeout (depth 2)" "$desc_list" "$g2_child "

echo "--- signal: TERM reaches worker, same-group grandchild and timeout-regrouped grandchild ---"
_dispatcher_signal_worker_tree "$worker_pid" TERM
# 全プロセス終了まで最大 5 秒待つ
all_dead=""
for _ in $(seq 1 50); do
  if ! kill -0 "$worker_pid" 2>/dev/null && ! kill -0 "$g1" 2>/dev/null && ! kill -0 "$g2" 2>/dev/null; then
    all_dead="yes"
    break
  fi
  sleep 0.1
done
# g2 (timeout) 配下の sleep も残っていないこと
g2_children=$(pgrep -P "$g2" 2>/dev/null || true)
assert_eq "worker + grandchildren all terminated within 5s" "yes" "$all_dead"
assert_eq "no leftover child under timeout grandchild" "" "$g2_children"
wait "$worker_pid" 2>/dev/null || true
assert_rc "_dispatcher_any_worker_alive after termination" 1 _dispatcher_any_worker_alive

echo "--- signal helper is a no-op for non-numeric pid ---"
assert_rc "_dispatcher_signal_worker_tree with garbage pid returns 0" 0 _dispatcher_signal_worker_tree "not-a-pid" TERM

exec 200>&-

echo
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
