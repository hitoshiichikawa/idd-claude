#!/usr/bin/env bash
#
# 用途: Issue #379（Stale Pickup Reaper）の Config ブロック正規化 / sr_is_enabled
#       二重 opt-in 判定 / 本体配線（REQUIRED_MODULES + call site）を fixture で
#       検証するスモークテスト。stale_pickup_reaper_test.sh（1,812 行 / 194 assert）を
#       観点単位に 4 分割した 1 本（#475。他は sr_marker_state_test.sh /
#       sr_activity_check_test.sh / sr_recovery_action_test.sh）。
#
#       対象:
#         - Config ブロック正規化（STALE_PICKUP_REAPER_ENABLED / THRESHOLD_MINUTES /
#           MAX_ISSUES / GH_TIMEOUT）
#         - sr_is_enabled の二重 opt-in 判定 + 副作用なし
#         - REQUIRED_MODULES 配線 / call site 順序 / gate OFF no-op
#
#       検証する AC（docs/specs/379-feat-watcher-claude-picked-up-issue-reap/requirements.md）:
#         - Req 1.1〜1.4: sr_is_enabled 二重 opt-in 判定 + 安全側 fallback
#         - Req 4.1 / 4.3 / 4.4: THRESHOLD_MINUTES 正規化
#         - NFR 1.1 / 1.2 / 1.3: gate OFF 既定・副作用ゼロ・REQUIRED_MODULES 順序契約
#
# 配置先: local-watcher/test/sr_wiring_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/sr_wiring_test.sh

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

if ! declare -F sr_is_enabled >/dev/null; then
  echo "ERROR: sr_is_enabled not loaded from $MODULE_SH" >&2
  exit 2
fi

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
# Section 0: Config ブロック正規化（Req 1.3 / 4.1 / 4.3 / 4.4）
#
# issue-watcher.sh の Stale Pickup Reaper Config ブロック相当のロジックを inline
# で再現して各 env の正規化を検証する（fr_state_test.sh Section 11 と同パターン）。
# inline 正規化ロジックは issue-watcher.sh 本体の `case` 文と完全等価に保つこと。
# ============================================================
echo "--- Section 0: Config ブロック正規化（Req 1.3 / 4.1 / 4.3 / 4.4） ---"

# ── 0a: STALE_PICKUP_REAPER_ENABLED の正規化 ──
normalize_enabled() {
  local input="$1"
  STALE_PICKUP_REAPER_ENABLED="${input}"
  STALE_PICKUP_REAPER_ENABLED="${STALE_PICKUP_REAPER_ENABLED:-false}"
  case "$STALE_PICKUP_REAPER_ENABLED" in
    true) : ;;
    *)    STALE_PICKUP_REAPER_ENABLED="false" ;;
  esac
  echo "$STALE_PICKUP_REAPER_ENABLED"
}

assert_eq "Req 1.1: ENABLED=true はそのまま true" "true" "$(normalize_enabled 'true')"
assert_eq "Req 1.2: ENABLED=false は false 維持" "false" "$(normalize_enabled 'false')"
assert_eq "Req 1.3: ENABLED=True は false（typo 安全側）" "false" "$(normalize_enabled 'True')"
assert_eq "Req 1.3: ENABLED=TRUE は false（typo 安全側）" "false" "$(normalize_enabled 'TRUE')"
assert_eq "Req 1.3: ENABLED=1 は false（typo 安全側）" "false" "$(normalize_enabled '1')"
assert_eq "Req 1.3: ENABLED=on は false（typo 安全側）" "false" "$(normalize_enabled 'on')"
assert_eq "Req 1.3: ENABLED=yes は false（typo 安全側）" "false" "$(normalize_enabled 'yes')"
assert_eq "Req 1.3: ENABLED='  true  ' は false（前後空白 typo）" "false" "$(normalize_enabled '  true  ')"
assert_eq "Req 1.3: ENABLED=空文字は false" "false" "$(normalize_enabled '')"

# issue-watcher.sh の Config ブロックを直接 bash -c で source して既定値が false
# になることも 1 ケース直接検証する（fr_state_test.sh Section 11 と同パターン）。
got=$(bash -c 'unset STALE_PICKUP_REAPER_ENABLED; \
  STALE_PICKUP_REAPER_ENABLED="${STALE_PICKUP_REAPER_ENABLED:-false}"; \
  case "$STALE_PICKUP_REAPER_ENABLED" in \
    true) : ;; \
    *)    STALE_PICKUP_REAPER_ENABLED="false" ;; \
  esac; \
  echo "$STALE_PICKUP_REAPER_ENABLED"')
assert_eq "Req 1.2 / NFR 1.1: ENABLED 未設定で既定 false" "false" "$got"

# ── 0b: STALE_PICKUP_REAPER_THRESHOLD_MINUTES の正規化 ──
normalize_threshold() {
  local input="$1"
  STALE_PICKUP_REAPER_THRESHOLD_MINUTES="${input}"
  STALE_PICKUP_REAPER_THRESHOLD_MINUTES="${STALE_PICKUP_REAPER_THRESHOLD_MINUTES:-45}"
  case "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES" in
    ''|*[!0-9]*) STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45 ;;
    *)
      if [ "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES" -le 0 ]; then
        STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45
      fi
      ;;
  esac
  echo "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES"
}

assert_eq "Req 4.3: THRESHOLD 空文字 → 45" "45" "$(normalize_threshold '')"
assert_eq "Req 4.3: THRESHOLD 非整数 abc → 45" "45" "$(normalize_threshold 'abc')"
assert_eq "Req 4.3: THRESHOLD 負の値 -10 → 45（非整数扱い）" "45" "$(normalize_threshold '-10')"
assert_eq "Req 4.3: THRESHOLD 0 → 45（0 以下）" "45" "$(normalize_threshold '0')"
assert_eq "Req 4.3: THRESHOLD 小数 1.5 → 45（非整数扱い）" "45" "$(normalize_threshold '1.5')"
assert_eq "Req 4.4: THRESHOLD 正常値 30 はそのまま" "30" "$(normalize_threshold '30')"
assert_eq "Req 4.4: THRESHOLD 正常値 1 はそのまま" "1" "$(normalize_threshold '1')"
assert_eq "Req 4.4: THRESHOLD 正常値 120 はそのまま" "120" "$(normalize_threshold '120')"

# 未設定時の既定 45 を bash -c で直接検証
got=$(bash -c 'unset STALE_PICKUP_REAPER_THRESHOLD_MINUTES; \
  STALE_PICKUP_REAPER_THRESHOLD_MINUTES="${STALE_PICKUP_REAPER_THRESHOLD_MINUTES:-45}"; \
  case "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES" in \
    "" | *[!0-9]*) STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45 ;; \
    *) [ "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES" -le 0 ] && STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45 ;; \
  esac; \
  echo "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES"')
assert_eq "Req 4.1: THRESHOLD 未設定で既定 45" "45" "$got"

# ── 0c: STALE_PICKUP_REAPER_MAX_ISSUES の正規化 ──
normalize_max_issues() {
  local input="$1"
  STALE_PICKUP_REAPER_MAX_ISSUES="${input}"
  STALE_PICKUP_REAPER_MAX_ISSUES="${STALE_PICKUP_REAPER_MAX_ISSUES:-20}"
  case "$STALE_PICKUP_REAPER_MAX_ISSUES" in
    ''|*[!0-9]*) STALE_PICKUP_REAPER_MAX_ISSUES=20 ;;
    *)
      if [ "$STALE_PICKUP_REAPER_MAX_ISSUES" -le 0 ]; then
        STALE_PICKUP_REAPER_MAX_ISSUES=20
      fi
      ;;
  esac
  echo "$STALE_PICKUP_REAPER_MAX_ISSUES"
}

assert_eq "MAX_ISSUES 空文字 → 20" "20" "$(normalize_max_issues '')"
assert_eq "MAX_ISSUES 非整数 abc → 20" "20" "$(normalize_max_issues 'abc')"
assert_eq "MAX_ISSUES 0 → 20" "20" "$(normalize_max_issues '0')"
assert_eq "MAX_ISSUES 正常値 5 はそのまま" "5" "$(normalize_max_issues '5')"

# ── 0d: STALE_PICKUP_REAPER_GH_TIMEOUT の正規化 ──
normalize_gh_timeout() {
  local input="$1"
  STALE_PICKUP_REAPER_GH_TIMEOUT="${input}"
  STALE_PICKUP_REAPER_GH_TIMEOUT="${STALE_PICKUP_REAPER_GH_TIMEOUT:-60}"
  case "$STALE_PICKUP_REAPER_GH_TIMEOUT" in
    ''|*[!0-9]*) STALE_PICKUP_REAPER_GH_TIMEOUT=60 ;;
    *)
      if [ "$STALE_PICKUP_REAPER_GH_TIMEOUT" -le 0 ]; then
        STALE_PICKUP_REAPER_GH_TIMEOUT=60
      fi
      ;;
  esac
  echo "$STALE_PICKUP_REAPER_GH_TIMEOUT"
}

assert_eq "GH_TIMEOUT 空文字 → 60" "60" "$(normalize_gh_timeout '')"
assert_eq "GH_TIMEOUT 非整数 xyz → 60" "60" "$(normalize_gh_timeout 'xyz')"
assert_eq "GH_TIMEOUT 0 → 60" "60" "$(normalize_gh_timeout '0')"
assert_eq "GH_TIMEOUT 正常値 30 はそのまま" "30" "$(normalize_gh_timeout '30')"

# ============================================================
# Section 1: sr_is_enabled の二重 opt-in 判定（Req 1.1〜1.4 / NFR 1.1 / NFR 1.3）
#
# `STALE_PICKUP_REAPER_ENABLED=true` 厳密一致のみ rc=0、それ以外は rc=1 を返す
# 純粋関数。Config ブロック側 `case` 正規化と二重防御として機能する。
# ============================================================
echo ""
echo "--- Section 1: sr_is_enabled 判定（Req 1.1〜1.4 / NFR 1.1 / NFR 1.3） ---"

# Case A: true 厳密一致のみ rc=0（Req 1.1）
STALE_PICKUP_REAPER_ENABLED="true"
assert_rc "Req 1.1: ENABLED=true で rc=0（gate ON）" 0 sr_is_enabled

# Case B: false で rc=1（Req 1.2）
STALE_PICKUP_REAPER_ENABLED="false"
assert_rc "Req 1.2: ENABLED=false で rc=1（gate OFF）" 1 sr_is_enabled

# Case C: 未設定で rc=1（Req 1.2 / NFR 1.1）
unset STALE_PICKUP_REAPER_ENABLED
assert_rc "Req 1.2 / NFR 1.1: ENABLED 未設定で rc=1（既定 OFF）" 1 sr_is_enabled

# Case D: typo / 不正値はすべて rc=1（Req 1.3 / 安全側 fallback）
for v in "True" "TRUE" "1" "on" "yes" "enable" "enabled" "Yes" "tRue" "  true  " "trues" "0"; do
  STALE_PICKUP_REAPER_ENABLED="$v"
  assert_rc "Req 1.3: ENABLED=$(printf '%q' "$v") は disabled（rc=1 / 安全側）" 1 sr_is_enabled
done

# 全 7 主要パターン（true / false / 未設定 / True / 1 / on / typo）の return code
# 確認は task 仕様の明示要件。trailing で 1 件ずつまとめ verify する。
echo ""
echo "--- Section 1 (verify 7 主要ケース要約) ---"
STALE_PICKUP_REAPER_ENABLED="true"
assert_rc "summary: true → rc=0" 0 sr_is_enabled
STALE_PICKUP_REAPER_ENABLED="false"
assert_rc "summary: false → rc=1" 1 sr_is_enabled
unset STALE_PICKUP_REAPER_ENABLED
assert_rc "summary: 未設定 → rc=1" 1 sr_is_enabled
STALE_PICKUP_REAPER_ENABLED="True"
assert_rc "summary: True → rc=1" 1 sr_is_enabled
STALE_PICKUP_REAPER_ENABLED="1"
assert_rc "summary: 1 → rc=1" 1 sr_is_enabled
STALE_PICKUP_REAPER_ENABLED="on"
assert_rc "summary: on → rc=1" 1 sr_is_enabled
STALE_PICKUP_REAPER_ENABLED="enabel"  # typo
assert_rc "summary: enabel(typo) → rc=1" 1 sr_is_enabled

# ============================================================
# Section 1b: 副作用なし（Req 1.4 / NFR 1.3 / 純粋関数）
# sr_is_enabled は env 変数を書き換えず、stdout / stderr に何も出さない純粋関数。
# 複数回呼んでも env 状態が保持され、呼出後に env を read してそのまま使える。
# ============================================================
echo ""
echo "--- Section 1b: sr_is_enabled 副作用なし（Req 1.4 / NFR 1.3） ---"

STALE_PICKUP_REAPER_ENABLED="true"
sr_is_enabled || true
if [ "$STALE_PICKUP_REAPER_ENABLED" = "true" ]; then
  echo "PASS: Req 1.4: sr_is_enabled は env 変数を改変しない（ON → ON 維持）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.4: sr_is_enabled が env 変数を改変した"
  echo "  STALE_PICKUP_REAPER_ENABLED=$STALE_PICKUP_REAPER_ENABLED"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# stdout に何も出さない
STALE_PICKUP_REAPER_ENABLED="true"
stdout_out=$(sr_is_enabled 2>/dev/null || true)
if [ -z "$stdout_out" ]; then
  echo "PASS: Req 1.4: sr_is_enabled は stdout に何も出さない"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.4: sr_is_enabled が stdout に出力した: $(printf '%q' "$stdout_out")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# gate OFF 時も stderr に何も出さない（NFR 1.3）
STALE_PICKUP_REAPER_ENABLED="false"
stderr_out=$(sr_is_enabled 2>&1 >/dev/null || true)
if [ -z "$stderr_out" ]; then
  echo "PASS: NFR 1.3: gate OFF 時も stderr に何も出さない"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.3: gate OFF 時に stderr に出力: $(printf '%q' "$stderr_out")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi


# ============================================================
# Section 14: 本体配線（REQUIRED_MODULES と call site / task 6 / Req 1.1, 1.4 / NFR 1.1, 1.2, 1.3）
#
# 検証観点:
#   14a: bash -n で issue-watcher.sh の構文 OK
#   14b: REQUIRED_MODULES 順 source 後に sr_is_enabled / process_stale_pickup_reaper の
#        両方が定義済みになることを integration smoke で確認（issue-watcher.sh 全体は
#        config init / cron entry / main loop が走るため source せず、module path だけ
#        REQUIRED_MODULES 配列値から抽出して順次 source する subshell smoke）
#   14c: STALE_PICKUP_REAPER_ENABLED 未設定で process_stale_pickup_reaper を直接呼び
#        gh stub が 0 回呼ばれることを確認（NFR 1.1 の構造的検証 / call site が gate OFF
#        既定で副作用ゼロを満たすか）
# ============================================================
echo ""
echo "--- Section 14: 本体配線（REQUIRED_MODULES + call site / task 6 / Req 1.1, 1.4 / NFR 1.1, 1.2, 1.3） ---"

# ── 14a: bash -n で issue-watcher.sh の構文 OK ──
rc_14a=0
bash -n "$WATCHER_SH" >/dev/null 2>&1 || rc_14a=$?
assert_eq "Req 1.4 / NFR 1.2: bash -n で issue-watcher.sh の構文 OK" "0" "$rc_14a"

# ── 14b: REQUIRED_MODULES 順 source 後に 2 関数が両方定義済み ──
# issue-watcher.sh から REQUIRED_MODULES=( ... ) 行を grep し、subshell 内で配列順に
# 各 module を source する。issue-watcher.sh 全体は config init / cron entry / main loop が
# 走るため source しない（軽量 integration smoke）。
WATCHER_BIN_DIR="$(cd "$(dirname "$WATCHER_SH")" && pwd)"
MODULES_DIR="$WATCHER_BIN_DIR/modules"

# REQUIRED_MODULES の配列値だけを抽出（1 行で書かれている前提 / issue-watcher.sh:1052）
required_modules_line=$(grep -m1 '^REQUIRED_MODULES=' "$WATCHER_SH" || true)
if [ -z "$required_modules_line" ]; then
  echo "FAIL: Req 1.1: REQUIRED_MODULES 行が issue-watcher.sh から抽出できない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "PASS: 前提: REQUIRED_MODULES 行を抽出できた"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# 配線確認: REQUIRED_MODULES 行内に "stale-pickup-reaper.sh" が含まれること
if echo "$required_modules_line" | grep -q '"stale-pickup-reaper.sh"'; then
  echo "PASS: Req 1.1: REQUIRED_MODULES に stale-pickup-reaper.sh が含まれる"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.1: REQUIRED_MODULES に stale-pickup-reaper.sh が含まれない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 配線確認: failed-recovery.sh の直後に stale-pickup-reaper.sh が並ぶこと（順序契約）
if echo "$required_modules_line" | grep -q '"failed-recovery.sh" "stale-pickup-reaper.sh"'; then
  echo "PASS: NFR 1.2: REQUIRED_MODULES で failed-recovery.sh の直後に stale-pickup-reaper.sh"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.2: REQUIRED_MODULES の順序契約（failed-recovery.sh → stale-pickup-reaper.sh）が崩れている"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# call site 配線確認: process_failed_recovery 行の後ろに process_stale_pickup_reaper 行がある
# Issue #521: failed-recovery は non-essential のため縮退 gate でラップされ、call site は
# `grl_degrade_should_run "failed-recovery" && { process_failed_recovery || fr_warn ...; }`
# となった。行頭アンカーを外して wrapped 形の call site も検出する（順序契約の意図は不変）。
# stale-pickup-reaper は essential のため従来どおり行頭 `process_stale_pickup_reaper ||`。
fr_line=$(grep -n 'process_failed_recovery ||' "$WATCHER_SH" | head -1 | cut -d: -f1)
spr_line=$(grep -n '^process_stale_pickup_reaper ||' "$WATCHER_SH" | head -1 | cut -d: -f1)
if [ -n "$fr_line" ] && [ -n "$spr_line" ] && [ "$spr_line" -gt "$fr_line" ]; then
  echo "PASS: Req 1.1 / NFR 1.2: process_stale_pickup_reaper の call site が process_failed_recovery の後（fr=$fr_line, spr=$spr_line）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.1 / NFR 1.2: process_stale_pickup_reaper の call site が見つからないか順序が逆（fr=$fr_line, spr=$spr_line）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# integration smoke: subshell 内で各 module を順次 source し declare -F で 2 関数の定義を確認
# REQUIRED_MODULES 配列値を bash の eval で再構築し、$MODULES_DIR の各 module を順次 source する。
# 注意: 各 module はトップレベル副作用を持たない契約（CLAUDE.md「機能追加ガイドライン §1」）。
smoke_output=$(
  bash -c '
    set -eo pipefail
    # issue-watcher.sh が REQUIRED_MODULES を source する時点では config init で
    # 解決済みの最小 env 群（LOG_DIR / REPO / REPO_SLUG / SLOT_LOCK_DIR / BASE_BRANCH 等）
    # を smoke 用にも事前設定する（subshell で set -u を外し、本体と同じ前提を再現）。
    MODULES_DIR="$1"
    required_modules_line="$2"
    : "${REPO:=owner/test-repo}"
    : "${REPO_SLUG:=owner-test-repo}"
    : "${BASE_BRANCH:=main}"
    : "${LOG_DIR:=/tmp/smoke-log-$$}"
    : "${SLOT_LOCK_DIR:=/tmp/smoke-slot-$$}"
    mkdir -p "$LOG_DIR" "$SLOT_LOCK_DIR"
    # REQUIRED_MODULES=( ... ) の値部分から各 module 名を抽出
    arr_str=$(echo "$required_modules_line" | sed -E "s/^REQUIRED_MODULES=\( //; s/ \)$//")
    # shellcheck disable=SC2086
    eval "modules=( $arr_str )"
    for m in "${modules[@]}"; do
      mod_path="$MODULES_DIR/$m"
      if [ ! -f "$mod_path" ]; then
        echo "MISSING:$m"
        exit 2
      fi
      # shellcheck disable=SC1090
      . "$mod_path"
    done
    # 2 関数の定義を確認
    if declare -F sr_is_enabled >/dev/null; then echo "sr_is_enabled:defined"; else echo "sr_is_enabled:missing"; fi
    if declare -F process_stale_pickup_reaper >/dev/null; then echo "process_stale_pickup_reaper:defined"; else echo "process_stale_pickup_reaper:missing"; fi
    rm -rf "$LOG_DIR" "$SLOT_LOCK_DIR"
  ' _ "$MODULES_DIR" "$required_modules_line" 2>&1
) || true

if echo "$smoke_output" | grep -q '^sr_is_enabled:defined$'; then
  echo "PASS: Req 1.1: REQUIRED_MODULES 順 source 後に sr_is_enabled が declare -F で定義済み"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.1: REQUIRED_MODULES 順 source 後に sr_is_enabled が定義されない"
  echo "  smoke_output: $smoke_output"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if echo "$smoke_output" | grep -q '^process_stale_pickup_reaper:defined$'; then
  echo "PASS: Req 1.1: REQUIRED_MODULES 順 source 後に process_stale_pickup_reaper が declare -F で定義済み"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 1.1: REQUIRED_MODULES 順 source 後に process_stale_pickup_reaper が定義されない"
  echo "  smoke_output: $smoke_output"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── 14c: gate OFF（STALE_PICKUP_REAPER_ENABLED 未設定）で gh stub が 0 回呼ばれない ──
# subshell 内で REQUIRED_MODULES を順次 source して本物の process_stale_pickup_reaper を
# 定義し、gh / sr_log を stub したうえで process_stale_pickup_reaper を直接呼ぶ。
# 期待: sr_is_enabled が rc=1 で早期 return → gh stub 0 回呼ばれない（NFR 1.1）。
SR14C_GH_TRACE="$(mktemp)"
trap 'rm -f "$SR_WARN_TRACE" "$SR14C_GH_TRACE"' EXIT

smoke_14c=$(
  GH_TRACE="$SR14C_GH_TRACE" MODULES_DIR="$MODULES_DIR" REQ_LINE="$required_modules_line" \
  bash -c '
    set -eo pipefail
    : "${REPO:=owner/test-repo}"
    : "${REPO_SLUG:=owner-test-repo}"
    : "${BASE_BRANCH:=main}"
    : "${LOG_DIR:=/tmp/smoke-log-$$}"
    : "${SLOT_LOCK_DIR:=/tmp/smoke-slot-$$}"
    mkdir -p "$LOG_DIR" "$SLOT_LOCK_DIR"
    arr_str=$(echo "$REQ_LINE" | sed -E "s/^REQUIRED_MODULES=\( //; s/ \)$//")
    # shellcheck disable=SC2086
    eval "modules=( $arr_str )"
    for m in "${modules[@]}"; do
      # shellcheck disable=SC1090
      . "$MODULES_DIR/$m"
    done
    # gh stub: 呼ばれたら trace に append（gate OFF 検証で「0 回」を assert する）
    gh() {
      printf "gh" >> "$GH_TRACE"
      for arg in "$@"; do printf " %s" "$arg" >> "$GH_TRACE"; done
      printf "\n" >> "$GH_TRACE"
      return 0
    }
    # sr_log / sr_warn は no-op（標準出力汚染防止）
    sr_log() { :; }
    sr_warn() { :; }
    # ENABLED 未設定で直接呼ぶ
    unset STALE_PICKUP_REAPER_ENABLED
    rc=0
    process_stale_pickup_reaper || rc=$?
    rm -rf "$LOG_DIR" "$SLOT_LOCK_DIR"
    echo "rc=$rc"
  ' 2>&1
)

if echo "$smoke_14c" | grep -q '^rc=0$'; then
  echo "PASS: NFR 1.1: ENABLED 未設定で process_stale_pickup_reaper が rc=0（即 return）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.1: ENABLED 未設定で process_stale_pickup_reaper が rc!=0"
  echo "  smoke_14c: $smoke_14c"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

gh_calls_14c=$(grep -c '^gh ' "$SR14C_GH_TRACE" || true)
gh_calls_14c=${gh_calls_14c:-0}
assert_eq "NFR 1.1 / NFR 1.3: ENABLED 未設定で本体配線経由でも gh stub が 0 回呼ばれない" "0" "$gh_calls_14c"

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
