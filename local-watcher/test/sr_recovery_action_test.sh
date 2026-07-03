#!/usr/bin/env bash
#
# 用途: Issue #379（Stale Pickup Reaper）の sr_revert_to_auto_dev（ラベル除去 /
#       auto-dev 復帰）と process_stale_pickup_reaper（orchestrator）を fixture で
#       検証するスモークテスト。stale_pickup_reaper_test.sh（1,812 行 / 194 assert）を
#       観点単位に 4 分割した 1 本（#475。他は sr_wiring_test.sh /
#       sr_marker_state_test.sh / sr_activity_check_test.sh）。
#
#       対象:
#         - sr_revert_to_auto_dev（task 5 / Req 3.1 / 5.1〜5.6 / 6.1 / 6.2 /
#           NFR 1.2 / 2.1 / 3.1 / 3.2）
#         - process_stale_pickup_reaper（task 5 / Req 1.1 / 1.2 / 3.1 / 5.1〜5.6 /
#           NFR 1.1 / 2.1 / 5.2）
#
#       検証する AC（docs/specs/379-feat-watcher-claude-picked-up-issue-reap/requirements.md）:
#         - Req 5.1〜5.6: ラベル除去 + auto-dev 復帰の 2 段 PATCH / idempotent no-op
#         - Req 6.1 / 6.2: 不正 issue 番号 reject / 1 行ログ記録
#         - NFR 1.1: gate OFF で gh 0 回呼び出し
#         - NFR 2.1 / 3.1 / 3.2: fail-continue（orchestrator は常に rc=0）
#
# 配置先: local-watcher/test/sr_recovery_action_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/sr_recovery_action_test.sh
#
# SC2034 file-wide 抑止の根拠（#475 分割の副作用 / #464 SC2153 / #469 SC2034 と同種の
# cross-file 可視性喪失）: STALE_PICKUP_REAPER_ENABLED 等は本ファイルで代入するが、
# 参照は抽出した process_stale_pickup_reaper の関数本体（eval 経由）にあるため、単一
# ファイル静的解析では「未使用」に見える。分割元 stale_pickup_reaper_test.sh では他
# Section の代入と合わせて可視だった。本文自体は無改変（#455 共通規約）のため
# file-wide で抑止する。
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
eval "$(extract_function "$MODULE_SH" "sr_is_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_revert_to_auto_dev")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "process_stale_pickup_reaper")"

for fn in sr_is_enabled sr_revert_to_auto_dev process_stale_pickup_reaper; do
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

# 必須ラベル定数 / REPO / Config を fixture で設定（issue-watcher.sh Config と等価）。
# 抽出した sr_revert_to_auto_dev / process_stale_pickup_reaper が呼び出し時に参照する
# 遅延束縛変数のため、本テストスクリプト内では直接参照しないが宣言が必須。
# SC2034（未使用扱い）を局所抑止する（Section 7 の fixture 定義を複製 / #475）。
# shellcheck disable=SC2034
{
  LABEL_PICKED="claude-picked-up"
  LABEL_CLAIMED="claude-claimed"
  LABEL_FAILED="claude-failed"
  LABEL_NEEDS_DECISIONS="needs-decisions"
  LABEL_AWAITING_DESIGN="awaiting-design-review"
  LABEL_NEEDS_QUOTA_WAIT="needs-quota-wait"
  LABEL_BLOCKED="blocked"
  LABEL_STAGED_FOR_RELEASE="staged-for-release"
  REPO="owner/test-repo"
  STALE_PICKUP_REAPER_GH_TIMEOUT=60
  STALE_PICKUP_REAPER_MAX_ISSUES=20
}

PASS_COUNT=0
FAIL_COUNT=0

# ============================================================
# Section 12: sr_revert_to_auto_dev — 復旧アクション
#  (task 5 / Req 3.1 / 5.1 / 5.2 / 5.3 / 5.4 / 5.5 / 5.6 / 6.1 / 6.2 / NFR 1.2 / 2.1 / 3.1 / 3.2)
#
# 検証観点:
#   - 1 PATCH 内で `--remove-label claude-picked-up` + `--remove-label claude-claimed`
#     を同時発行（既存 round=1 defer / mark_issue_needs_decisions と同型）
#   - 1 PATCH 目成功後 `gh issue view --json labels` で再取得
#     - auto-dev 不在 → 2 回目 PATCH で `--add-label auto-dev` を発行
#     - auto-dev 残存 → 2 回目 PATCH を **発行しない**
#   - 不正な issue 番号（^[0-9]+$ 違反）を sr_warn + return 1 で reject
#   - 同サイクル 2 回目呼び出しは in-memory set による idempotent no-op（gh 0 回呼ばれない）
#   - 1 行ログ（reason=stale-pickup orphan / age=Nm / prev_labels=csv）を sr_log で記録
# ============================================================
echo ""
echo "--- Section 12: sr_revert_to_auto_dev（task 5 / Req 5.1〜5.6 / NFR 2.1 / 3.1） ---"

# 抽出: sr_revert_to_auto_dev / process_stale_pickup_reaper を module から取り出す
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_revert_to_auto_dev")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "process_stale_pickup_reaper")"

for fn in sr_revert_to_auto_dev process_stale_pickup_reaper; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded from $MODULE_SH" >&2
    exit 2
  fi
done

# Section 12 用 gh stub と trace ファイル
SR12_GH_TRACE="$(mktemp)"
SR12_GH_VIEW_RESPONSE="$(mktemp)"
SR12_GH_REMOVE_RC_FILE="$(mktemp)"
SR12_GH_VIEW_RC_FILE="$(mktemp)"
SR12_GH_ADD_RC_FILE="$(mktemp)"
echo "0" > "$SR12_GH_REMOVE_RC_FILE"
echo "0" > "$SR12_GH_VIEW_RC_FILE"
echo "0" > "$SR12_GH_ADD_RC_FILE"
SR12_LOG_TRACE="$(mktemp)"
trap 'rm -f "$SR_WARN_TRACE" "$SR12_GH_TRACE" "$SR12_GH_VIEW_RESPONSE" "$SR12_GH_REMOVE_RC_FILE" "$SR12_GH_VIEW_RC_FILE" "$SR12_GH_ADD_RC_FILE" "$SR12_LOG_TRACE"' EXIT

# fixture defaults: REPO / LABEL_* / LABEL_TRIGGER は Section 7 で既に export 済み
# shellcheck disable=SC2034  # sr_revert_to_auto_dev 内部で参照される遅延束縛変数
LABEL_TRIGGER="auto-dev"

# gh stub: edit (remove-label / add-label) と view を引数で識別
# 引数を 1 行に整形して trace に記録、stdout は view 時のみ JSON 応答
# shellcheck disable=SC2317
gh() {
  {
    printf 'gh'
    local arg
    for arg in "$@"; do
      printf ' %s' "$arg"
    done
    printf '\n'
  } >> "$SR12_GH_TRACE"

  # 判別: 引数列に "view" / "edit" / "--remove-label" / "--add-label" のいずれが含まれるか
  local is_view=0 has_remove=0 has_add=0
  local a
  for a in "$@"; do
    case "$a" in
      view) is_view=1 ;;
      --remove-label) has_remove=1 ;;
      --add-label) has_add=1 ;;
    esac
  done

  if [ "$is_view" = "1" ]; then
    local rc
    rc=$(cat "$SR12_GH_VIEW_RC_FILE")
    if [ "$rc" != "0" ]; then
      return "$rc"
    fi
    cat "$SR12_GH_VIEW_RESPONSE"
    return 0
  fi

  if [ "$has_remove" = "1" ] && [ "$has_add" = "0" ]; then
    cat "$SR12_GH_REMOVE_RC_FILE" >/dev/null  # only existence check
    return "$(cat "$SR12_GH_REMOVE_RC_FILE")"
  fi
  if [ "$has_add" = "1" ]; then
    return "$(cat "$SR12_GH_ADD_RC_FILE")"
  fi
  return 0
}

# sr_log を SR12_LOG_TRACE に記録する stub に上書き（既存定義を退避する必要なし: 後段で復帰）
# shellcheck disable=SC2317
sr_log() {
  echo "$*" >> "$SR12_LOG_TRACE"
}

# Section 12 開始時の共通リセット
sr12_reset() {
  echo "" > "$SR12_GH_TRACE"
  echo "" > "$SR12_LOG_TRACE"
  echo "" > "$SR_WARN_TRACE"
  SR_PROCESSED_THIS_CYCLE=""
}

# fixture marker: first_seen_at は 60 分前（age=60m 想定）
sr12_marker_json='{"issue":555,"first_seen_at":"2026-06-22T10:00:00Z","last_seen_at":"2026-06-22T11:00:00Z","last_known_labels":["claude-picked-up","auto-dev"],"status":"observing","revert_at":""}'

# ── 12a: 正常系（auto-dev 残存 / 2 回目 PATCH を呼ばない） ──
sr12_reset
cat > "$SR12_GH_VIEW_RESPONSE" <<'JSON'
{"labels":[{"name":"auto-dev"},{"name":"other"}]}
JSON
# shellcheck disable=SC2218  # extract_function + eval で定義済み（Section 13 で stub 再定義する関係で SC2218 を抑制）
sr_revert_to_auto_dev "555" "$sr12_marker_json"
rc_12a=$?
assert_eq "Req 5.1, 5.2: rc=0（成功）" "0" "$rc_12a"

# 1 回目 PATCH に --remove-label claude-picked-up / --remove-label claude-claimed を含む
trace_12a=$(cat "$SR12_GH_TRACE")
if echo "$trace_12a" | grep -q -- '--remove-label claude-picked-up'; then
  echo "PASS: Req 5.1: --remove-label claude-picked-up を発行"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.1: --remove-label claude-picked-up が見つからない"
  echo "  trace: $trace_12a"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
if echo "$trace_12a" | grep -q -- '--remove-label claude-claimed'; then
  echo "PASS: Req 5.2: --remove-label claude-claimed を発行"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.2: --remove-label claude-claimed が見つからない"
  echo "  trace: $trace_12a"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 1 PATCH 内で同時発行（同一行に両 --remove-label を含む）
if echo "$trace_12a" | grep -q -- '--remove-label claude-picked-up.*--remove-label claude-claimed'; then
  echo "PASS: Req 5.1 / 5.2: 1 PATCH 内で --remove-label 2 種を同時発行"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.1 / 5.2: --remove-label 2 種が同一 PATCH 内に並んでいない"
  echo "  trace: $trace_12a"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# `--` でオプション解釈打ち切り（NFR 3.1）
if echo "$trace_12a" | grep -qE 'gh issue edit 555 --repo owner/test-repo -- '; then
  echo 'PASS: NFR 3.1: gh issue edit に -- でオプション解釈打ち切りを伝達'
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo 'FAIL: NFR 3.1: -- が見つからない'
  echo "  trace: $trace_12a"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# auto-dev 残存 → 2 回目 PATCH (--add-label auto-dev) は **発行しない**
add_label_calls_12a=$(grep -c -- '--add-label auto-dev' "$SR12_GH_TRACE" || true)
assert_eq "Req 5.3: auto-dev 残存時 --add-label auto-dev は発行しない" "0" "$add_label_calls_12a"

# 1 行ログ確認（Req 5.4）
if grep -q 'reason=stale-pickup orphan' "$SR12_LOG_TRACE" && \
   grep -q 'age=' "$SR12_LOG_TRACE" && \
   grep -q 'prev_labels=' "$SR12_LOG_TRACE"; then
  echo "PASS: Req 5.4: 1 行ログ（reason / age / prev_labels）を記録"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.4: 1 行ログの形式が想定と異なる"
  echo "  log: $(cat "$SR12_LOG_TRACE")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# in-memory set への append（Req 5.5 / NFR 2.1）
case " $SR_PROCESSED_THIS_CYCLE " in
  *" 555 "*)
    echo "PASS: NFR 2.1: SR_PROCESSED_THIS_CYCLE に issue を append"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: NFR 2.1: SR_PROCESSED_THIS_CYCLE に issue が append されていない"
    echo "  SR_PROCESSED_THIS_CYCLE='$SR_PROCESSED_THIS_CYCLE'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac

# ── 12b: 同サイクル 2 回目呼び出しは no-op（gh 0 回 / SR_PROCESSED_THIS_CYCLE 由来） ──
echo "" > "$SR12_GH_TRACE"
echo "" > "$SR12_LOG_TRACE"
# SR_PROCESSED_THIS_CYCLE は 12a で 555 が append された状態を継承
# shellcheck disable=SC2218
sr_revert_to_auto_dev "555" "$sr12_marker_json"
rc_12b=$?
assert_eq "Req 5.5 / NFR 2.1: 同サイクル 2 回目 rc=0（idempotent no-op）" "0" "$rc_12b"

gh_calls_12b=$(grep -c '^gh ' "$SR12_GH_TRACE" || true)
assert_eq "Req 5.5 / NFR 2.1: 2 回目呼び出しで gh 0 回（in-memory set による短絡）" "0" "$gh_calls_12b"

# ── 12c: auto-dev 欠落 → 2 回目 PATCH で --add-label auto-dev を発行 ──
sr12_reset
cat > "$SR12_GH_VIEW_RESPONSE" <<'JSON'
{"labels":[{"name":"other"}]}
JSON
# shellcheck disable=SC2218
sr_revert_to_auto_dev "777" "$sr12_marker_json"
rc_12c=$?
assert_eq "Req 5.3: auto-dev 欠落時 rc=0（追加付与成功）" "0" "$rc_12c"

trace_12c=$(cat "$SR12_GH_TRACE")
if echo "$trace_12c" | grep -q -- '--add-label auto-dev'; then
  echo "PASS: Req 5.3: auto-dev 欠落時 --add-label auto-dev を発行"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.3: auto-dev 欠落時 --add-label auto-dev が見つからない"
  echo "  trace: $trace_12c"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── 12d: 不正な issue 番号は sr_warn + return 1 ──
sr12_reset
for bad_issue in "abc" "12; rm -rf /" "" "-1" "1.5"; do
  echo "" > "$SR12_GH_TRACE"
  echo "" > "$SR_WARN_TRACE"
  SR_PROCESSED_THIS_CYCLE=""
  set +e
  # shellcheck disable=SC2218
  sr_revert_to_auto_dev "$bad_issue" "$sr12_marker_json"
  bad_rc=$?
  set -e
  if [ "$bad_rc" != "0" ]; then
    echo "PASS: NFR 3.1: 不正 issue=$(printf '%q' "$bad_issue") を reject（rc=$bad_rc）"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: NFR 3.1: 不正 issue=$(printf '%q' "$bad_issue") を rc=0 で受理した"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  bad_gh_calls=$(grep -c '^gh ' "$SR12_GH_TRACE" || true)
  assert_eq "NFR 3.1: 不正 issue=$(printf '%q' "$bad_issue") で gh 0 回" "0" "$bad_gh_calls"
done

# ── 12e: 1 回目 PATCH 失敗（gh remove-label rc!=0）で return 1 ──
sr12_reset
echo "1" > "$SR12_GH_REMOVE_RC_FILE"
set +e
# shellcheck disable=SC2218
sr_revert_to_auto_dev "888" "$sr12_marker_json"
rc_12e=$?
set -e
assert_eq "Req 5.6: 1 回目 PATCH 失敗で rc=1" "1" "$rc_12e"
warn_lines_12e=$(grep -c 'sr_revert_to_auto_dev' "$SR_WARN_TRACE" || true)
if [ "$warn_lines_12e" -ge 1 ]; then
  echo "PASS: Req 5.6: 1 回目 PATCH 失敗時に sr_warn を記録"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.6: sr_warn が呼ばれていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
# in-memory set には append しない（失敗時 / 次サイクル再評価のため）
case " $SR_PROCESSED_THIS_CYCLE " in
  *" 888 "*)
    echo "FAIL: Req 5.6: 失敗時に SR_PROCESSED_THIS_CYCLE へ append されている"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
  *)
    echo "PASS: Req 5.6: 失敗時は in-memory set に append しない（次サイクル再評価可）"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
esac
# 復元
echo "0" > "$SR12_GH_REMOVE_RC_FILE"

# Section 12 後始末
unset -f gh sr_log
# sr_log を「core_utils.sh の本物に近い no-op stub」に再定義（後続 Section 13 用）
# shellcheck disable=SC2317
sr_log() {
  echo "$*" >/dev/null
}

# ============================================================
# Section 13: process_stale_pickup_reaper — orchestrator
#  (task 5 / Req 1.1 / 1.2 / 3.1 / 5.1〜5.6 / NFR 1.1 / 2.1 / 5.2)
#
# 検証観点:
#   - STALE_PICKUP_REAPER_ENABLED=false / 未設定 で gh が 1 回も呼ばれない（NFR 1.1）
#   - active 経路（sr_is_active stub で rc=0 を返す = keep）で revert が呼ばれない
#   - inactive 経路（sr_is_active stub で rc=1 = inactive 確定）で revert が呼ばれる
#   - 戻り値は常に 0（fail-continue / watcher サイクルを落とさない）
# ============================================================
echo ""
echo "--- Section 13: process_stale_pickup_reaper（task 5 / Req 1.x, 3.x, 5.x / NFR 1.1 / 5.2） ---"

# orchestrator 内で参照する関数群を上書き stub する。
# sr_fetch_candidates: 1 件の Issue を返す stub
# sr_save_marker: 引数を記録するだけの noop
# sr_load_marker: marker JSON を文字列で返す
# sr_is_active: 後段で都度書き換え
# sr_revert_to_auto_dev: 呼び出し回数を記録

SR13_GH_TRACE="$(mktemp)"
SR13_REVERT_COUNT_FILE="$(mktemp)"
SR13_SAVE_TRACE="$(mktemp)"
echo "0" > "$SR13_REVERT_COUNT_FILE"
trap 'rm -f "$SR_WARN_TRACE" "$SR12_GH_TRACE" "$SR12_GH_VIEW_RESPONSE" "$SR12_GH_REMOVE_RC_FILE" "$SR12_GH_VIEW_RC_FILE" "$SR12_GH_ADD_RC_FILE" "$SR12_LOG_TRACE" "$SR13_GH_TRACE" "$SR13_REVERT_COUNT_FILE" "$SR13_SAVE_TRACE"' EXIT

# gh stub: 呼ばれたら trace に記録（gate OFF 検証で「0 回呼ばれない」を assert するため）
# shellcheck disable=SC2317
gh() {
  printf 'gh' >> "$SR13_GH_TRACE"
  local arg
  for arg in "$@"; do
    printf ' %s' "$arg" >> "$SR13_GH_TRACE"
  done
  printf '\n' >> "$SR13_GH_TRACE"
  return 0
}

# sr_fetch_candidates stub: 1 件の Issue を返す
# shellcheck disable=SC2317
sr_fetch_candidates() {
  cat <<'JSON'
[{"number":42,"labels":[{"name":"claude-picked-up"}],"title":"test","url":"https://example.com/42","updatedAt":"2026-06-22T10:00:00Z"}]
JSON
}

# sr_load_marker stub: 固定 marker を返す
# shellcheck disable=SC2317
sr_load_marker() {
  echo '{"issue":42,"first_seen_at":"2026-06-22T10:00:00Z","last_seen_at":"2026-06-22T11:00:00Z","last_known_labels":["claude-picked-up"],"status":"observing","revert_at":""}'
}

# sr_save_marker stub: 引数を trace ファイルに記録
# shellcheck disable=SC2317
sr_save_marker() {
  echo "save: $*" >> "$SR13_SAVE_TRACE"
  return 0
}

# sr_revert_to_auto_dev stub: 呼ばれた回数を increment
# shellcheck disable=SC2317
sr_revert_to_auto_dev() {
  local n
  n=$(cat "$SR13_REVERT_COUNT_FILE")
  echo $((n + 1)) > "$SR13_REVERT_COUNT_FILE"
  return 0
}

# sr_is_active stub: 各テストで書き換え（初期値: keep = rc=0）
# shellcheck disable=SC2317
sr_is_active() {
  return 0  # default: active = keep
}

# Section 13 リセット
sr13_reset() {
  echo "" > "$SR13_GH_TRACE"
  echo "" > "$SR13_SAVE_TRACE"
  echo "0" > "$SR13_REVERT_COUNT_FILE"
  echo "" > "$SR_WARN_TRACE"
  SR_PROCESSED_THIS_CYCLE=""
}

# Config defaults: orchestrator 内で参照する遅延束縛変数
STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45
STALE_PICKUP_REAPER_MAX_ISSUES=20

# ── 13a: gate OFF（ENABLED=false）で gh が 1 回も呼ばれない（NFR 1.1） ──
sr13_reset
STALE_PICKUP_REAPER_ENABLED=false
rc_13a=0
process_stale_pickup_reaper || rc_13a=$?
assert_eq "NFR 1.1: gate OFF で rc=0（即 return）" "0" "$rc_13a"

gh_calls_13a=$(grep -c '^gh ' "$SR13_GH_TRACE" || true)
assert_eq "NFR 1.1: gate OFF で gh 0 回呼ばれない（構造的検証）" "0" "$gh_calls_13a"

revert_count_13a=$(cat "$SR13_REVERT_COUNT_FILE")
assert_eq "NFR 1.1: gate OFF で sr_revert_to_auto_dev も 0 回" "0" "$revert_count_13a"

# ── 13b: gate OFF（ENABLED 未設定）でも同じ ──
sr13_reset
unset STALE_PICKUP_REAPER_ENABLED
rc_13b=0
process_stale_pickup_reaper || rc_13b=$?
assert_eq "NFR 1.1: ENABLED 未設定で rc=0（即 return）" "0" "$rc_13b"
gh_calls_13b=$(grep -c '^gh ' "$SR13_GH_TRACE" || true)
assert_eq "NFR 1.1: ENABLED 未設定で gh 0 回（fetch_candidates も呼ばれない）" "0" "$gh_calls_13b"
revert_count_13b=$(cat "$SR13_REVERT_COUNT_FILE")
assert_eq "NFR 1.1: ENABLED 未設定で sr_revert_to_auto_dev も 0 回" "0" "$revert_count_13b"

# ── 13c: gate ON + active 経路（sr_is_active rc=0 keep）で revert が呼ばれない ──
sr13_reset
STALE_PICKUP_REAPER_ENABLED=true
# shellcheck disable=SC2317
sr_is_active() { return 0; }  # active = keep
rc_13c=0
process_stale_pickup_reaper || rc_13c=$?
assert_eq "Req 3.2: active 経路で rc=0" "0" "$rc_13c"
revert_count_13c=$(cat "$SR13_REVERT_COUNT_FILE")
assert_eq "Req 3.2: active 経路で sr_revert_to_auto_dev 0 回" "0" "$revert_count_13c"
# sr_save_marker は observing として呼ばれる（fetch → save → is_active の流れ）
save_lines_13c=$(grep -c '^save: ' "$SR13_SAVE_TRACE" || true)
if [ "$save_lines_13c" -ge 1 ]; then
  echo "PASS: 仕様: active 経路でも sr_save_marker（observing）は呼ばれる（$save_lines_13c 件）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: 仕様: active 経路で sr_save_marker が呼ばれていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── 13d: gate ON + inactive 経路（sr_is_active rc=1）で revert が呼ばれる ──
sr13_reset
STALE_PICKUP_REAPER_ENABLED=true
# shellcheck disable=SC2317
sr_is_active() { return 1; }  # inactive 確定 → revert へ
rc_13d=0
process_stale_pickup_reaper || rc_13d=$?
assert_eq "Req 5.x: inactive 経路で rc=0（fail-continue）" "0" "$rc_13d"
revert_count_13d=$(cat "$SR13_REVERT_COUNT_FILE")
assert_eq "Req 5.1, 5.2: inactive 経路で sr_revert_to_auto_dev 1 回" "1" "$revert_count_13d"

# ── 13e: revert 成功後 reverted marker が保存される（Req 5.5 / 状態遷移） ──
# Section 13d の save trace に observing と reverted の 2 件が含まれることを確認
save_lines_13e=$(grep -c '^save: ' "$SR13_SAVE_TRACE" || true)
if [ "$save_lines_13e" -ge 2 ]; then
  echo "PASS: Req 5.5: inactive 経路で marker save が 2 回呼ばれる（observing → reverted）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.5: marker save が 2 回呼ばれていない（save_lines=$save_lines_13e）"
  echo "  trace: $(cat "$SR13_SAVE_TRACE")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
if grep -q 'reverted' "$SR13_SAVE_TRACE"; then
  echo "PASS: Req 5.5: reverted status で marker を更新"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.5: reverted status の marker save が見つからない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── 13f: 戻り値は常に 0（fail-continue / 内部例外を吸収） ──
sr13_reset
STALE_PICKUP_REAPER_ENABLED=true
# sr_revert_to_auto_dev が失敗を返しても orchestrator は 0 を返す
# shellcheck disable=SC2317
sr_revert_to_auto_dev() {
  local n
  n=$(cat "$SR13_REVERT_COUNT_FILE")
  echo $((n + 1)) > "$SR13_REVERT_COUNT_FILE"
  return 1  # 失敗
}
# shellcheck disable=SC2317
sr_is_active() { return 1; }  # inactive
rc_13f=0
process_stale_pickup_reaper || rc_13f=$?
assert_eq "NFR 5.2: revert 失敗時も orchestrator rc=0（fail-continue）" "0" "$rc_13f"
warn_lines_13f=$(grep -c 'revert 失敗' "$SR_WARN_TRACE" || true)
if [ "$warn_lines_13f" -ge 1 ]; then
  echo "PASS: Req 5.6: revert 失敗時に sr_warn を記録（次サイクル再評価）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.6: revert 失敗時の sr_warn が見つからない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 後始末
unset -f gh sr_fetch_candidates sr_load_marker sr_save_marker sr_revert_to_auto_dev sr_is_active


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
