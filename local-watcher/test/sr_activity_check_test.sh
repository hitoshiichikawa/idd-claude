#!/usr/bin/env bash
#
# 用途: Issue #379（Stale Pickup Reaper）の 3 観点判定（marker_age / slot_lock /
#       session）+ sr_is_active の組み合わせロジックを fixture で検証するスモークテスト。
#       stale_pickup_reaper_test.sh（1,812 行 / 194 assert）を観点単位に 4 分割した
#       1 本（#475。他は sr_wiring_test.sh / sr_marker_state_test.sh /
#       sr_recovery_action_test.sh）。
#
#       対象:
#         - sr_check_marker_age / sr_check_slot_lock / sr_check_session / sr_is_active
#           (task 4 / Req 3.1 / 3.2 / 3.3 / 3.4 / 3.5 / 4.2 / 6.3 / NFR 4.1 / NFR 4.2)
#
#       検証する AC（docs/specs/379-feat-watcher-claude-picked-up-issue-reap/requirements.md）:
#         - Req 3.1: 3 観点 AND で「非アクティブ」確定
#         - Req 3.2: いずれか 1 観点でも「アクティブの可能性あり」なら revert しない
#         - Req 3.3: 判定中の副作用ゼロ（read-only / gh を呼ばない）
#         - Req 3.4: 根拠取得失敗時 safe-side fallback
#         - Req 3.5: 判定根拠を 1 行ログで記録
#         - Req 4.2: 経過時間が閾値未満なら復旧対象とせず継続観測
#         - Req 6.3: branch 状態を「アクティブ」根拠にしない
#         - NFR 4.1 / 4.2: 判定イベント種別・見送り理由を 1 行ログで記録
#
# 配置先: local-watcher/test/sr_activity_check_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/sr_activity_check_test.sh
#
# SC2034 file-wide 抑止の根拠（#475 分割の副作用 / #464 SC2153 / #469 SC2034 と同種の
# cross-file 可視性喪失）: STALE_PICKUP_REAPER_THRESHOLD_MINUTES 等は本ファイルで代入するが、
# 参照は抽出した sr_check_marker_age 等の関数本体（eval 経由）にあるため、単一ファイル
# 静的解析では「未使用」に見える。分割元 stale_pickup_reaper_test.sh では他 Section の
# 代入と合わせて可視だった。本文自体は無改変（#455 共通規約）のため file-wide で抑止する。
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# extract_function / assert_eq / assert_contains / assert_rc を共有ライブラリから source（#474）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
MODULE_SH="$SCRIPT_DIR/../bin/modules/stale-pickup-reaper.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find stale-pickup-reaper.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（fr_is_enabled_test.sh / fr_state_test.sh）と同じイディオム:
# 対象スクリプトから 1 関数だけを awk で切り出して eval で読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_marker_age")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_slot_lock")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_session")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_is_active")"

for fn in sr_check_marker_age sr_check_slot_lock sr_check_session sr_is_active; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded from $MODULE_SH" >&2
    exit 2
  fi
done

# sr_save_marker 等が失敗時に sr_warn を呼ぶため stub する（実体は core_utils.sh 側）。
# 出力を trace ファイルに append して後段の assertion で使う（fr_state_test.sh と同パターン）。
SR_WARN_TRACE="$(mktemp)"
trap 'rm -f "$SR_WARN_TRACE"' EXIT

# shellcheck disable=SC2317
sr_warn() {
  echo "$*" >> "$SR_WARN_TRACE"
}

PASS_COUNT=0
FAIL_COUNT=0

# ============================================================
# Section 8: sr_check_marker_age — 閾値判定 4 経路（task 4 / Req 3.1 観点 1 / Req 4.2）
#
# fixture marker JSON で以下 4 経路を検証:
#   - 閾値未満: first_seen_at が現在から数分前 → rc=1 (fresh)
#   - 閾値超:   first_seen_at が現在から数時間前 → rc=0 (aged)
#   - first_seen_at 不在: rc=1 (safe-side fresh)
#   - date parse 失敗: rc=1 (safe-side fresh / Req 3.4)
# ============================================================
echo ""
echo "--- Section 8: sr_check_marker_age（task 4 / Req 3.1 観点 1 / Req 3.4 / Req 4.2） ---"

# 閾値を 45 分に固定（既定値 / Req 4.1）
STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45

# ── 8a: 閾値未満（5 分前） → rc=1 (fresh / Req 4.2） ──
# GNU date `-u -d "@<epoch>"` で UTC ISO 8601 を生成
fresh_epoch=$(($(date +%s) - 5 * 60))
if fresh_iso=$(date -u -d "@$fresh_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
  :
else
  # macOS BSD date fallback
  fresh_iso=$(date -u -r "$fresh_epoch" '+%Y-%m-%dT%H:%M:%SZ')
fi
fresh_marker=$(jq -n -c --arg t "$fresh_iso" '{issue:1, first_seen_at:$t}')
assert_rc "Req 4.2: 閾値未満（5 分前）で rc=1 (fresh)" 1 sr_check_marker_age "$fresh_marker"

# ── 8b: 閾値超（120 分前） → rc=0 (aged / Req 3.1 観点 1） ──
aged_epoch=$(($(date +%s) - 120 * 60))
if aged_iso=$(date -u -d "@$aged_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
  :
else
  aged_iso=$(date -u -r "$aged_epoch" '+%Y-%m-%dT%H:%M:%SZ')
fi
aged_marker=$(jq -n -c --arg t "$aged_iso" '{issue:2, first_seen_at:$t}')
assert_rc "Req 3.1 観点 1: 閾値超（120 分前）で rc=0 (aged)" 0 sr_check_marker_age "$aged_marker"

# ── 8c: 閾値ちょうど（45 分前）→ rc=0 (aged / 境界値) ──
boundary_epoch=$(($(date +%s) - 45 * 60))
if boundary_iso=$(date -u -d "@$boundary_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
  :
else
  boundary_iso=$(date -u -r "$boundary_epoch" '+%Y-%m-%dT%H:%M:%SZ')
fi
boundary_marker=$(jq -n -c --arg t "$boundary_iso" '{issue:3, first_seen_at:$t}')
assert_rc "境界値: 閾値ちょうど（45 分前）で rc=0 (aged / -ge 比較)" 0 sr_check_marker_age "$boundary_marker"

# ── 8d: first_seen_at 不在 → rc=1 (safe-side fresh / Req 3.4) ──
no_first_marker='{"issue":4}'
assert_rc "Req 3.4: first_seen_at 不在で rc=1 (safe-side fresh)" 1 sr_check_marker_age "$no_first_marker"

# ── 8e: 空 marker （{}） → rc=1 (safe-side fresh) ──
empty_marker='{}'
assert_rc "Req 3.4: 空 marker {} で rc=1 (safe-side fresh)" 1 sr_check_marker_age "$empty_marker"

# ── 8f: date parse 失敗（不正文字列） → rc=1 (safe-side fresh / Req 3.4) ──
invalid_marker='{"issue":5, "first_seen_at":"invalid-date-string"}'
assert_rc "Req 3.4: date parse 失敗で rc=1 (safe-side fresh)" 1 sr_check_marker_age "$invalid_marker"

# ── 8g: 閾値を変えると判定境界も追従する（遅延束縛 / Req 4.4） ──
# 閾値 10 分に変えると 5 分前は依然 fresh、15 分前は aged になる
STALE_PICKUP_REAPER_THRESHOLD_MINUTES=10
short_aged_epoch=$(($(date +%s) - 15 * 60))
if short_aged_iso=$(date -u -d "@$short_aged_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
  :
else
  short_aged_iso=$(date -u -r "$short_aged_epoch" '+%Y-%m-%dT%H:%M:%SZ')
fi
short_aged_marker=$(jq -n -c --arg t "$short_aged_iso" '{issue:6, first_seen_at:$t}')
assert_rc "Req 4.4: 閾値 10 分で 15 分前は rc=0 (aged)" 0 sr_check_marker_age "$short_aged_marker"
assert_rc "Req 4.4: 閾値 10 分で 5 分前は依然 rc=1 (fresh)" 1 sr_check_marker_age "$fresh_marker"
# 閾値を 45 分に復元（後続 section のため）
STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45

# ============================================================
# Section 9: sr_check_slot_lock — flock 観測（task 4 / Req 3.1 観点 2 / Req 3.4）
#
# `mktemp -d` で一時 SLOT_LOCK_DIR を作り、以下を検証:
#   - lock file 不在: rc=0 (no lock)
#   - lock file 存在しいずれも非保持: rc=0 (no lock held)
#   - lock file 1 つを別プロセスで保持中: rc=1 (some slot lock held)
#
# 注意: テスト中の lock 保持には `flock -x <fd>` の background 子プロセス + named pipe
# 同期を使い、テスト終了時に確実に解放する。
# ============================================================
echo ""
echo "--- Section 9: sr_check_slot_lock（task 4 / Req 3.1 観点 2 / Req 3.4） ---"

# `flock` binary 不在環境は本 section を skip（CI 互換 / Linux 想定環境のみ実行）
if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP: Section 9 を skip（flock binary 不在）"
else
  # ── 9a: lock file 不在で rc=0 (no lock) ──
  SLOT_LOCK_DIR=$(mktemp -d)
  REPO_SLUG="owner-test-repo"
  assert_rc "Req 3.1 観点 2: lock file 不在で rc=0 (no lock held)" 0 sr_check_slot_lock '{}'

  # ── 9b: lock file 存在しいずれも非保持で rc=0 ──
  touch "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-1.lock"
  touch "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-2.lock"
  assert_rc "Req 3.1 観点 2: 空 lock file 2 つで rc=0 (取得可能 = no lock held)" 0 sr_check_slot_lock '{}'

  # ── 9c: lock file 1 つを別プロセスで保持中で rc=1 (some slot lock held) ──
  # `flock -x <fd> -c 'sleep 30'` を background で起動。同期は別 lock file で取る:
  #   1. ready_file をテスト fixture 側で作成
  #   2. background は flock を取得した後 ready_file を消す
  #   3. テスト本体は ready_file が消えるまで poll で待つ（最大 5 秒）
  ready_file=$(mktemp)
  lock_held_file="$SLOT_LOCK_DIR/${REPO_SLUG}-slot-1.lock"
  (
    # exec で fd 9 を lock 対象に開き、flock -x で取得後 ready_file を消して 30 秒待機
    exec 9>"$lock_held_file"
    flock -x 9
    rm -f "$ready_file"
    sleep 30
  ) &
  bg_pid=$!
  # ready_file が消えるまで最大 5 秒待つ（flock 取得完了の検知）
  for _wait_i in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -e "$ready_file" ] && break
    sleep 0.5
  done

  if [ -e "$ready_file" ]; then
    echo "FAIL: Section 9c setup: background flock が 5 秒以内に取得できなかった"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    rm -f "$ready_file"
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
  else
    assert_rc "Req 3.1 観点 2: 1 つ flock 保持中で rc=1 (some slot lock held)" 1 sr_check_slot_lock '{}'
    # 後片付け: background プロセスを kill して lock 解放
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
  fi

  # ── 9d: 保持を解放した後は rc=0 に戻る ──
  assert_rc "Req 3.1 観点 2: 保持解放後 rc=0 に戻る" 0 sr_check_slot_lock '{}'

  # 後片付け
  rm -rf "$SLOT_LOCK_DIR"
fi

# ============================================================
# Section 10: sr_check_session — kill -0 による pid 生存確認（task 4 / Req 3.1 観点 3 / Req 3.4）
#
# 検証経路:
#   - lock file 不在 → rc=0 (no session detected)
#   - lock file 存在 + 自プロセス（`$$`）pid が保持中 → rc=1 (session may be alive)
#   - lock file 存在 + 大値 pid（99999 等）の死活確認 → rc=0 (no session)
#
# 注意: fuser / lsof の挙動を直接呼ぶと OS 差異が出るため、本 section では
# fuser / lsof を **bash 関数として stub 化** し、関数経路で pid を返す形に統一する。
# ============================================================
echo ""
echo "--- Section 10: sr_check_session（task 4 / Req 3.1 観点 3 / Req 3.4） ---"

# ── 10a: lock file 不在で rc=0 (no session detected) ──
SLOT_LOCK_DIR=$(mktemp -d)
REPO_SLUG="owner-test-repo"
assert_rc "Req 3.1 観点 3: lock file 不在で rc=0 (no session detected)" 0 sr_check_session '{}'

# ── 10b: lock file 存在 + fuser stub が生存 pid を返す → rc=1 (session may be alive) ──
touch "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-1.lock"

# fuser を関数 stub: 自プロセス pid（必ず生存）を返す
# shellcheck disable=SC2317
fuser() {
  echo "$$"
}
# 関数 stub を優先的に使うため command -v fuser は true を返す（builtin 経路）
assert_rc "Req 3.1 観点 3: 自プロセス pid（生存）で rc=1 (session may be alive)" 1 sr_check_session '{}'

# ── 10c: fuser stub が大値 pid（不在）を返す → rc=0 (no session) ──
# 99999 のような大値 pid は通常存在しない（厳密には環境依存だが Linux 既定 pid_max ≦ 32768 環境で確実に不在）
# shellcheck disable=SC2317
fuser() {
  echo "99999"
}
# Linux 既定 pid_max を確認: 32768 以下なら 99999 は不在確定
pid_max_ok=1
if [ -r /proc/sys/kernel/pid_max ]; then
  pid_max_val=$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 0)
  if [ "$pid_max_val" -gt 99999 ] 2>/dev/null; then
    pid_max_ok=0  # 99999 が pid_max 範囲内なら不在保証できない
  fi
fi
if [ "$pid_max_ok" = "0" ]; then
  echo "SKIP: 10c を skip（pid_max=$pid_max_val > 99999 のため 99999 不在保証不可）"
else
  assert_rc "Req 3.1 観点 3: 99999 (不在 pid) で rc=0 (no session)" 0 sr_check_session '{}'
fi

# ── 10d: fuser stub が空文字を返す（pid 取得失敗） → rc=1 (safe-side / Req 3.4) ──
# shellcheck disable=SC2317
fuser() {
  echo ""
}
assert_rc "Req 3.4: pid 取得失敗（空 fuser 出力）で rc=1 (safe-side)" 1 sr_check_session '{}'

# ── 10e: fuser / lsof どちらも不在 → rc=1 (safe-side / Req 3.4) ──
# fuser / lsof を unset し、command -v が両方 fail する状態を作る
unset -f fuser
# lsof も同様に不在を保証するため、関数 lsof を unset（元から関数ではないが念のため）
# 環境に lsof binary が実在する場合は本ケースを skip
if command -v fuser >/dev/null 2>&1; then
  echo "SKIP: 10e を skip（fuser binary が実在し関数 stub 不在 → bin に到達するため safe-side 経路を構成できない）"
elif command -v lsof >/dev/null 2>&1; then
  echo "SKIP: 10e を skip（lsof binary が実在し関数 stub 不在 → bin に到達する）"
else
  assert_rc "Req 3.4: fuser/lsof 双方不在で rc=1 (safe-side)" 1 sr_check_session '{}'
fi

# 後片付け
unset -f fuser 2>/dev/null || true
rm -rf "$SLOT_LOCK_DIR"

# ============================================================
# Section 11: sr_is_active — 3 観点 AND の 2^3=8 通り組み合わせ（task 4 / Req 3.1 / 3.2 / 3.5 / Req 6.3 / NFR 4.1 / 4.2）
#
# `sr_check_marker_age` / `sr_check_slot_lock` / `sr_check_session` を bash 関数として
# 上書き定義し、全 8 通り（2^3）の戻り値組み合わせで sr_is_active の rc を assert する。
#
# 戻り値の語義:
#   - sr_is_active: 0 = active or unknown (keep), 1 = inactive (revert へ)
#   - 全観点 rc=0 (非アクティブ寄り) のときのみ sr_is_active rc=1 (inactive 確定)
#   - それ以外（1 観点でも rc>0）は sr_is_active rc=0 (keep)
#
# 注意:
#   - 本 section では `sr_check_*` の本物を上書きするため、終了時に `unset -f` で復元する
#   - `sr_log` も呼ばれるため stub 化して SR_LOG_TRACE に append（Req 3.5 / NFR 4.2 確認用）
# ============================================================
echo ""
echo "--- Section 11: sr_is_active 8 通り組み合わせ（task 4 / Req 3.1 / 3.2 / 3.5 / NFR 4.1 / 4.2） ---"

# sr_log stub: SR_LOG_TRACE に append（後続 assertion で内容確認）
SR_LOG_TRACE="$(mktemp)"
# shellcheck disable=SC2317
sr_log() {
  echo "$*" >> "$SR_LOG_TRACE"
}

# 3 観点 stub を組み合わせて sr_is_active を呼ぶヘルパー
# Args: $1=age_rc $2=lock_rc $3=sess_rc, expects $4=expected_active_rc, $5=label
run_combo() {
  local age_rc="$1" lock_rc="$2" sess_rc="$3" expected="$4" label="$5"
  # shellcheck disable=SC2317
  sr_check_marker_age() { return "$age_rc"; }
  # shellcheck disable=SC2317
  sr_check_slot_lock()  { return "$lock_rc"; }
  # shellcheck disable=SC2317
  sr_check_session()    { return "$sess_rc"; }
  local actual=0
  sr_is_active '{"issue":42}' >/dev/null 2>&1 || actual=$?
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label (age=$age_rc lock=$lock_rc sess=$sess_rc → rc=$actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (age=$age_rc lock=$lock_rc sess=$sess_rc → expected=$expected actual=$actual)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo "" > "$SR_LOG_TRACE"

# ── 2^3 = 8 通り（age × lock × sess の組み合わせ）──
# 全 0 のときだけ rc=1 (inactive)、他は rc=0 (keep)
run_combo 0 0 0 1 "Req 3.1: 全 0 (aged + no-lock + no-sess) で inactive (rc=1)"
run_combo 0 0 1 0 "Req 3.2: sess=1 (may-have-session) で keep (rc=0)"
run_combo 0 1 0 0 "Req 3.2: lock=1 (some-lock) で keep (rc=0)"
run_combo 0 1 1 0 "Req 3.2: lock=1 + sess=1 で keep (rc=0)"
run_combo 1 0 0 0 "Req 3.2: age=1 (fresh) で keep (rc=0)"
run_combo 1 0 1 0 "Req 3.2: age=1 + sess=1 で keep (rc=0)"
run_combo 1 1 0 0 "Req 3.2: age=1 + lock=1 で keep (rc=0)"
run_combo 1 1 1 0 "Req 3.2: 全 1 (全観点 may-active) で keep (rc=0)"

# ── slot_lock の rc=2（判定不能 / 権限エラー等 / Req 3.4）も「アクティブ寄り」として扱う ──
run_combo 0 2 0 0 "Req 3.4: lock=2 (判定不能) で keep (rc=0 / safe-side)"

# ── ログ記録の確認（Req 3.5 / NFR 4.1 / NFR 4.2） ──
# 全 0 ケースで "inactive" を含むログ、他ケースで "keep" を含むログが出ているか
inactive_count=$(grep -c 'inactive (age>threshold, no slot lock, no session)' "$SR_LOG_TRACE" || true)
keep_count=$(grep -c 'keep age=' "$SR_LOG_TRACE" || true)

if [ "$inactive_count" -ge 1 ]; then
  echo "PASS: Req 3.5 / NFR 4.1: 非アクティブ確定時に 'inactive' ログを記録（$inactive_count 件）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 3.5 / NFR 4.1: 非アクティブ確定時の 'inactive' ログが見つからない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ "$keep_count" -ge 1 ]; then
  echo "PASS: Req 3.5 / NFR 4.2: keep 判定時に 'keep' ログを記録（$keep_count 件）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 3.5 / NFR 4.2: keep 判定時の 'keep' ログが見つからない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── ログ 1 行に age / lock / sess の 3 値が含まれることを確認（Req 3.5） ──
if grep -qE 'age=[0-9]+ lock=[0-9]+ sess=[0-9]+' "$SR_LOG_TRACE"; then
  echo "PASS: Req 3.5: ログ 1 行に 'age=N lock=N sess=N' 形式の判定根拠を記録"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 3.5: ログ 1 行に 'age=N lock=N sess=N' 形式の判定根拠が見つからない"
  echo "  trace 抜粋: $(head -3 "$SR_LOG_TRACE")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── issue 番号がログに含まれる（NFR 4.1） ──
if grep -q 'issue=#42' "$SR_LOG_TRACE"; then
  echo "PASS: NFR 4.1: ログに issue 番号 (#42) を含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 4.1: ログに issue 番号が含まれない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── 後片付け: stub を unset し、本物の関数を復元（後続テストへの影響回避） ──
unset -f sr_check_marker_age sr_check_slot_lock sr_check_session sr_log
rm -f "$SR_LOG_TRACE"

# extract_function で本物を再抽出（後続テストで参照されないが、念のため復元）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_marker_age")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_slot_lock")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_session")"

# sr_log stub を再定義（core_utils.sh の本物は extract していない / 過去 section と同パターン）
# shellcheck disable=SC2317
sr_log() {
  echo "$*" >/dev/null
}


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
