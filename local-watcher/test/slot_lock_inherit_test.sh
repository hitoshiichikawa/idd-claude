#!/usr/bin/env bash
#
# 用途: Phase C per-slot lock（core_utils.sh の _slot_acquire / _slot_release）と
#       Dispatcher の空き slot 探索（issue-watcher.sh の _dispatcher_find_free_slot）が、
#       fork した Slot Worker に lock fd を **実際に継承させる** ことを検証する近接テスト
#       （無人運用改善提案 P0-1）。
#
#       旧実装は `slot=$(_dispatcher_find_free_slot)` のコマンド置換で呼んでいたため、
#       _slot_acquire が開いた fd (210+N) と flock が置換サブシェルの終了と同時に消え、
#       worker 実行中に lock を握るプロセスが存在しなかった。本テストは
#         - _slot_acquire / _slot_release 単体の lock 取得・解放
#         - _dispatcher_find_free_slot（置換なし呼び出し）が slot 番号を
#           _DISPATCHER_PICKED_SLOT で返し、呼び出し側シェルに fd を残すこと
#         - PID map に載っている slot を busy とみなして次の slot を取ること
#         - fork した worker が親の _slot_release 後も lock を保持し続け、worker 終了で
#           解放されること（= 継承が成立していること）
#         - 回帰ガード: コマンド置換 `$(...)` で呼ぶと lock が残らないこと（旧実装の欠陥の形）
#       を、外部プロセスからの `flock -n` で観測する。
#
# 配置先: local-watcher/test/slot_lock_inherit_test.sh
# 依存:   bash 4+, flock (util-linux), awk
# 実行:   bash local-watcher/test/slot_lock_inherit_test.sh
# 前提:   core_utils.sh / issue-watcher.sh から関数を extract_function で隔離抽出し、
#         dispatcher_log / _slot_run_issue を stub する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
CORE_UTILS_SH="$SCRIPT_DIR/../bin/modules/core_utils.sh"

for f in "$WATCHER_SH" "$CORE_UTILS_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: cannot find $f" >&2
    exit 2
  fi
done
if ! command -v flock >/dev/null 2>&1; then
  echo "ERROR: flock not found (util-linux が必要)" >&2
  exit 2
fi

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ─── fixture env（抽出関数が参照するグローバル）───
# shellcheck disable=SC2034
SLOT_LOCK_DIR="$TMPDIR_TEST/locks"
mkdir -p "$SLOT_LOCK_DIR"
# shellcheck disable=SC2034
REPO_SLUG="owner-test-repo"
# shellcheck disable=SC2034
PARALLEL_SLOTS=2
declare -A _DISPATCHER_SLOT_PIDS
_DISPATCHER_PICKED_SLOT=""

dispatcher_log() { :; }
dispatcher_warn() { :; }

# shellcheck disable=SC1090
eval "$(extract_function "$CORE_UTILS_SH" "_slot_lock_path")"
# shellcheck disable=SC1090
eval "$(extract_function "$CORE_UTILS_SH" "_slot_acquire")"
# shellcheck disable=SC1090
eval "$(extract_function "$CORE_UTILS_SH" "_slot_release")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "_dispatcher_reap_finished_slots")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "_dispatcher_find_free_slot")"
# shellcheck disable=SC1090
eval "$(extract_function "$WATCHER_SH" "_dispatcher_spawn_worker")"

for fn in _slot_lock_path _slot_acquire _slot_release _dispatcher_reap_finished_slots \
          _dispatcher_find_free_slot _dispatcher_spawn_worker; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

# 外部プロセスから slot N の lock が取れるか（0 = 空いている / 1 = 誰かが保持中）
lock_is_free() {
  local f
  f="$(_slot_lock_path "$1")"
  flock -n "$f" true 2>/dev/null
}
lock_state() {
  if lock_is_free "$1"; then echo "free"; else echo "held"; fi
}

# ─── Case 1: _slot_acquire / _slot_release 単体 ───
echo "--- case 1: _slot_acquire / _slot_release ---"
assert_eq "slot-1 initially free" "free" "$(lock_state 1)"
assert_rc "_slot_acquire 1 succeeds" 0 _slot_acquire 1
assert_eq "slot-1 held after acquire" "held" "$(lock_state 1)"
# shellcheck disable=SC2016  # 単一引用符内の $1/$2 は子 bash 側で展開させる意図
assert_rc "_slot_acquire 1 again fails (already held by self fd)" 1 bash -c '
  SLOT_LOCK_DIR="$1"; REPO_SLUG="$2"
  '"$(declare -f _slot_lock_path _slot_acquire)"'
  _slot_acquire 1' _ "$SLOT_LOCK_DIR" "$REPO_SLUG"
_slot_release 1
assert_eq "slot-1 free after release" "free" "$(lock_state 1)"

# ─── Case 2: _dispatcher_find_free_slot（置換なし）が fd を呼び出し側に残す ───
echo "--- case 2: _dispatcher_find_free_slot keeps lock in caller shell ---"
assert_rc "find_free_slot rc=0" 0 _dispatcher_find_free_slot
assert_eq "picked slot is 1" "1" "$_DISPATCHER_PICKED_SLOT"
assert_eq "slot-1 held by caller shell" "held" "$(lock_state 1)"

# slot-1 を busy（PID map 登録）扱いにすると次は slot-2 を取る
_DISPATCHER_SLOT_PIDS[1]=$$
assert_rc "find_free_slot (slot-1 busy) rc=0" 0 _dispatcher_find_free_slot
assert_eq "picked slot is 2" "2" "$_DISPATCHER_PICKED_SLOT"
assert_eq "slot-2 held by caller shell" "held" "$(lock_state 2)"
unset '_DISPATCHER_SLOT_PIDS[1]'
_slot_release 1
_slot_release 2
assert_eq "slot-1 free after release" "free" "$(lock_state 1)"
assert_eq "slot-2 free after release" "free" "$(lock_state 2)"

# 全 slot busy（PID map に 1, 2 とも登録）→ rc=1 / picked 空
_DISPATCHER_SLOT_PIDS[1]=$$
_DISPATCHER_SLOT_PIDS[2]=$$
assert_rc "find_free_slot (all busy) rc=1" 1 _dispatcher_find_free_slot
assert_eq "picked slot cleared when none free" "" "$_DISPATCHER_PICKED_SLOT"
unset '_DISPATCHER_SLOT_PIDS[1]' '_DISPATCHER_SLOT_PIDS[2]'

# ─── Case 3: fork した worker が lock を継承し、親の _slot_release 後も保持する ───
echo "--- case 3: forked worker inherits the slot lock ---"
WORKER_GATE="$TMPDIR_TEST/worker.gate"
# _slot_run_issue stub: gate ファイルが消えるまで待つ（worker 実行中を模す）
_slot_run_issue() {
  while [ -e "$WORKER_GATE" ]; do sleep 0.1; done
}
: > "$WORKER_GATE"
_dispatcher_find_free_slot
slot="$_DISPATCHER_PICKED_SLOT"
assert_eq "case3 picked slot is 1" "1" "$slot"
_dispatcher_spawn_worker "$slot" '{"number":1}'
worker_pid="${_DISPATCHER_SLOT_PIDS[$slot]}"
_slot_release "$slot"   # 親側の fd を閉じる（本番 Dispatcher と同じ手順）
assert_eq "slot-1 still held while worker runs (inherited fd)" "held" "$(lock_state 1)"
# worker を終了させる
rm -f "$WORKER_GATE"
wait "$worker_pid" 2>/dev/null || true
unset "_DISPATCHER_SLOT_PIDS[$slot]"
assert_eq "slot-1 free after worker exits" "free" "$(lock_state 1)"

# ─── Case 4: 回帰ガード — コマンド置換で呼ぶと lock が残らない（旧実装の欠陥の形）───
echo "--- case 4: command substitution form does NOT keep the lock (regression guard) ---"
_DISPATCHER_PICKED_SLOT=""
_picked=$(_dispatcher_find_free_slot; printf '%s' "$_DISPATCHER_PICKED_SLOT")
assert_eq "substitution form returns slot 1" "1" "$_picked"
assert_eq "substitution form leaves slot-1 free (lock lost with subshell)" "free" "$(lock_state 1)"
# 呼び出し側の変数も置換サブシェル内の代入なので更新されない
assert_eq "caller _DISPATCHER_PICKED_SLOT not updated by substitution form" "" "$_DISPATCHER_PICKED_SLOT"

echo
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
