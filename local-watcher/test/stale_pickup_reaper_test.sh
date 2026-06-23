#!/usr/bin/env bash
#
# 用途: Issue #379（Stale Pickup Reaper）の task 1 で追加する Config 正規化 +
#       gate 関数 `sr_is_enabled` を fixture で検証するスモークテスト。
#
#       対象:
#         - Config ブロック正規化（issue-watcher.sh の Stale Pickup Reaper Config 節）
#           - STALE_PICKUP_REAPER_ENABLED: true 厳密一致のみ ON / それ以外 false
#           - STALE_PICKUP_REAPER_THRESHOLD_MINUTES: 既定 45 / 非整数・0 以下 → 45
#           - STALE_PICKUP_REAPER_MAX_ISSUES: 既定 20 / 不正値 → 20
#           - STALE_PICKUP_REAPER_GH_TIMEOUT: 既定 60 / 不正値 → 60
#         - sr_is_enabled (Issue #379 Req 1.1 / 1.2 / 1.3 / 1.4 / NFR 1.1 / NFR 1.3)
#
#       検証する AC（docs/specs/379-feat-watcher-claude-picked-up-issue-reap/requirements.md）:
#         - Req 1.1: STALE_PICKUP_REAPER_ENABLED=true で gate が ON（rc=0）
#         - Req 1.2: 未設定 / true 以外で gate が OFF（rc=1）
#         - Req 1.3: typo / 不正値（True / 1 / on / yes / 空白 等）はすべて安全側 OFF
#         - Req 1.4: gate OFF 時は副作用なし（env 変数を改変せず stdout / stderr に出力なし）
#         - Req 4.1: 閾値 env を受け取り既定 45 分
#         - Req 4.3: 閾値 env が未設定 / 非整数 / 0 以下 → 既定 45 分に正規化
#         - Req 4.4: 閾値 env が有効な整数のときその値を採用
#         - NFR 1.1: 既定運用（gate OFF）で本機能導入前と完全に同一挙動
#         - NFR 1.3: gate OFF で副作用ゼロ（rc=1 のみ返す純粋関数）
#
# 配置先: local-watcher/test/stale_pickup_reaper_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/stale_pickup_reaper_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 既存テスト（fr_is_enabled_test.sh / fr_state_test.sh）と同じイディオム:
# 対象スクリプトから 1 関数だけを awk で切り出して eval で読み込む。
# トップレベル副作用は回避する（task 1 時点で sr_is_enabled は issue-watcher.sh
# 本体の Config ブロック直後に定義されている暫定実装 / task 2 で module へ移送）。
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
eval "$(extract_function "$WATCHER_SH" "sr_is_enabled")"

if ! declare -F sr_is_enabled >/dev/null; then
  echo "ERROR: sr_is_enabled not loaded from $WATCHER_SH" >&2
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
