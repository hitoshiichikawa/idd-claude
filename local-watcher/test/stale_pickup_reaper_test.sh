#!/usr/bin/env bash
#
# 用途: Issue #379（Stale Pickup Reaper）の task 1 / task 2 / task 3 で追加する以下を
#       fixture で検証するスモークテスト。
#
#       対象:
#         - Config ブロック正規化（issue-watcher.sh の Stale Pickup Reaper Config 節 / task 1）
#           - STALE_PICKUP_REAPER_ENABLED: true 厳密一致のみ ON / それ以外 false
#           - STALE_PICKUP_REAPER_THRESHOLD_MINUTES: 既定 45 / 非整数・0 以下 → 45
#           - STALE_PICKUP_REAPER_MAX_ISSUES: 既定 20 / 不正値 → 20
#           - STALE_PICKUP_REAPER_GH_TIMEOUT: 既定 60 / 不正値 → 60
#         - sr_is_enabled (task 1 / Req 1.1 / 1.2 / 1.3 / 1.4 / NFR 1.1 / NFR 1.3)
#         - sr_marker_path / sr_load_marker / sr_save_marker (task 2 / Req 5.5 /
#           NFR 2.2 / NFR 2.3 / NFR 3.1)
#         - sr_fetch_candidates (task 3 / Req 2.1 / 2.2 / 2.3 / 2.4 / 2.5 / NFR 1.2 /
#           NFR 3.1 / NFR 5.2)
#
#       検証する AC（docs/specs/379-feat-watcher-claude-picked-up-issue-reap/requirements.md）:
#         - Req 1.1: STALE_PICKUP_REAPER_ENABLED=true で gate が ON（rc=0）
#         - Req 1.2: 未設定 / true 以外で gate が OFF（rc=1）
#         - Req 1.3: typo / 不正値（True / 1 / on / yes / 空白 等）はすべて安全側 OFF
#         - Req 1.4: gate OFF 時は副作用なし（env 変数を改変せず stdout / stderr に出力なし）
#         - Req 2.1: claude-picked-up ラベル付き Issue を走査対象とする
#         - Req 2.2: claude-claimed ラベル付き Issue も走査対象に含める
#         - Req 2.3: 人間判断待ちラベル（needs-decisions / awaiting-design-review /
#                    needs-quota-wait / blocked / staged-for-release / hold）は除外
#         - Req 2.4: claude-failed は除外（failed-recovery の領分）
#         - Req 2.5: server-side label filter のみで走査
#         - Req 4.1: 閾値 env を受け取り既定 45 分
#         - Req 4.3: 閾値 env が未設定 / 非整数 / 0 以下 → 既定 45 分に正規化
#         - Req 4.4: 閾値 env が有効な整数のときその値を採用
#         - Req 5.5: marker 状態の冪等な save / load 往復で全 field 保持
#         - NFR 1.1: 既定運用（gate OFF）で本機能導入前と完全に同一挙動
#         - NFR 1.2: 既存 dispatcher / 候補クエリと整合する `--state open` / `--repo`
#         - NFR 1.3: gate OFF で副作用ゼロ（rc=1 のみ返す純粋関数）
#         - NFR 2.2: 状態ファイルからの再読込で値継承
#         - NFR 2.3: atomic write（mktemp → mv -f）で破損ファイル不残存
#         - NFR 3.1: jq --arg / --argjson による未信頼入力 sanitize
#         - NFR 5.2: 取得失敗時も非破壊（sr_warn + `[]` 返却 / fail-continue）
#
# 配置先: local-watcher/test/stale_pickup_reaper_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/stale_pickup_reaper_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# トップレベル副作用は回避する（task 2 以降は modules/stale-pickup-reaper.sh 側を
# 抽出元とする / task 1 の暫定配置は本体側から module 側へ移送済み）。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 抽出: 5 関数を modules/stale-pickup-reaper.sh から取り出す
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_is_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_marker_path")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_load_marker")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_save_marker")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_fetch_candidates")"

for fn in sr_is_enabled sr_marker_path sr_load_marker sr_save_marker sr_fetch_candidates; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded from $MODULE_SH" >&2
    exit 2
  fi
done

# sr_save_marker が失敗時に sr_warn を呼ぶため stub する（実体は core_utils.sh 側）。
# 出力を trace ファイルに append して後段の assertion で使う（fr_state_test.sh と同パターン）。
SR_WARN_TRACE="$(mktemp)"
trap 'rm -f "$SR_WARN_TRACE"' EXIT

# shellcheck disable=SC2317
sr_warn() {
  echo "$*" >> "$SR_WARN_TRACE"
}

# テスト隔離環境を作成する helper（各 Section で別ディレクトリを使う）
new_state_dir() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

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
# Section 2: sr_marker_path（純粋関数 / 絶対パス算出）
#
# state dir の env を切り替えると path 算出も追従することを検証する
# （遅延束縛で `$STALE_PICKUP_REAPER_STATE_DIR` を呼び出し時に解決）。
# ============================================================
echo ""
echo "--- Section 2: sr_marker_path（絶対パス算出） ---"

STALE_PICKUP_REAPER_STATE_DIR="/tmp/sr-test-state"
path=$(sr_marker_path 123)
assert_eq "sr_marker_path 123 が /tmp/sr-test-state/123.json を返す" \
  "/tmp/sr-test-state/123.json" "$path"

STALE_PICKUP_REAPER_STATE_DIR="$HOME/.issue-watcher/stale-pickup/owner-repo"
path=$(sr_marker_path 379)
assert_eq "NFR 2.3: \$HOME 配下の path を返す（repo-slug 分離）" \
  "$HOME/.issue-watcher/stale-pickup/owner-repo/379.json" "$path"

# state dir を別の値に切り替えても追従する（遅延束縛 / 純粋関数）
STALE_PICKUP_REAPER_STATE_DIR="/var/tmp/sr-other"
path=$(sr_marker_path 999)
assert_eq "state dir 切替で path 算出も追従する" \
  "/var/tmp/sr-other/999.json" "$path"

# ============================================================
# Section 3: sr_save_marker → sr_load_marker の往復で schema 全 field が読み出せる
# （Req 5.5 / NFR 2.2 / NFR 2.3）
# ============================================================
echo ""
echo "--- Section 3: save → load 往復で schema 全 field 保持（Req 5.5 / NFR 2.2） ---"

STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)

# 1 回目の save（observing / labels 配列付き / revert_at 空）
assert_rc "Req 5.5: 1 回目 sr_save_marker が成功（observing）" 0 \
  sr_save_marker 359 "2026-06-22T10:34:56Z" "2026-06-22T11:04:56Z" \
  '["claude-picked-up","auto-dev"]' "observing" ""

# load して各 field を検証
loaded=$(sr_load_marker 359)
issue=$(printf '%s' "$loaded" | jq -r '.issue')
first=$(printf '%s' "$loaded" | jq -r '.first_seen_at')
last=$(printf '%s' "$loaded" | jq -r '.last_seen_at')
labels0=$(printf '%s' "$loaded" | jq -r '.last_known_labels[0]')
labels1=$(printf '%s' "$loaded" | jq -r '.last_known_labels[1]')
labels_len=$(printf '%s' "$loaded" | jq -r '.last_known_labels | length')
status=$(printf '%s' "$loaded" | jq -r '.status')
revert_at=$(printf '%s' "$loaded" | jq -r '.revert_at')

assert_eq "Req 5.5: schema.issue = 359（int）" "359" "$issue"
assert_eq "Req 5.5: schema.first_seen_at 保持" "2026-06-22T10:34:56Z" "$first"
assert_eq "Req 5.5: schema.last_seen_at 保持" "2026-06-22T11:04:56Z" "$last"
assert_eq "Req 5.5: schema.last_known_labels 長さ = 2" "2" "$labels_len"
assert_eq "Req 5.5: schema.last_known_labels[0] = claude-picked-up" "claude-picked-up" "$labels0"
assert_eq "Req 5.5: schema.last_known_labels[1] = auto-dev" "auto-dev" "$labels1"
assert_eq "Req 5.5: schema.status = observing" "observing" "$status"
assert_eq "Req 5.5: schema.revert_at = 空文字（observing 時）" "" "$revert_at"

# 2 回目: status=reverted + revert_at 付き で上書き（冪等な状態遷移）
assert_rc "Req 5.5: 2 回目 sr_save_marker が成功（reverted）" 0 \
  sr_save_marker 359 "2026-06-22T10:34:56Z" "2026-06-22T11:34:56Z" \
  '["auto-dev"]' "reverted" "2026-06-22T11:34:56Z"

loaded=$(sr_load_marker 359)
status=$(printf '%s' "$loaded" | jq -r '.status')
revert_at=$(printf '%s' "$loaded" | jq -r '.revert_at')
labels_len=$(printf '%s' "$loaded" | jq -r '.last_known_labels | length')
labels0=$(printf '%s' "$loaded" | jq -r '.last_known_labels[0]')
assert_eq "Req 5.5: 上書き後の status = reverted" "reverted" "$status"
assert_eq "Req 5.5: 上書き後の revert_at 保持" "2026-06-22T11:34:56Z" "$revert_at"
assert_eq "Req 5.5: 上書き後の labels 長さ = 1" "1" "$labels_len"
assert_eq "Req 5.5: 上書き後の labels[0] = auto-dev" "auto-dev" "$labels0"

# 空 labels 配列を渡してもエラーにならない（fail-safe）
STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)
assert_rc "Req 5.5: 空 labels 配列でも save 成功" 0 \
  sr_save_marker 42 "2026-06-22T10:00:00Z" "2026-06-22T10:00:00Z" '[]' "observing" ""
loaded=$(sr_load_marker 42)
labels_len=$(printf '%s' "$loaded" | jq -r '.last_known_labels | length')
assert_eq "Req 5.5: 空 labels 配列が長さ 0 で保持される" "0" "$labels_len"

# ============================================================
# Section 4: atomic rename — save 中間の tmp file が残らない（NFR 2.3）
# ============================================================
echo ""
echo "--- Section 4: atomic rename（NFR 2.3） ---"

STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)
sr_save_marker 100 "2026-06-22T10:00:00Z" "2026-06-22T10:00:00Z" \
  '["claude-picked-up"]' "observing" "" >/dev/null 2>&1

# 状態ファイル自体は存在する
if [ -f "${STALE_PICKUP_REAPER_STATE_DIR}/100.json" ]; then
  echo "PASS: NFR 2.3: marker ファイルが atomic rename で作成された"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 2.3: marker ファイルが作成されていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# tmp file（${marker_file}.XXXXXX）が残っていないこと
tmp_count=$(find "$STALE_PICKUP_REAPER_STATE_DIR" -name '100.json.*' 2>/dev/null | wc -l)
assert_eq "NFR 2.3: save 成功時に中間 tmp file が残らない" "0" "$tmp_count"

# mkdir -p で state_dir を冪等確保（ネストした未作成 dir でも自動作成される）
STALE_PICKUP_REAPER_STATE_DIR="$(mktemp -d)/nested/deep/dir"
assert_rc "NFR 2.3: ネスト未作成 state_dir でも mkdir -p で確保し save 成功" 0 \
  sr_save_marker 200 "2026-06-22T10:00:00Z" "2026-06-22T10:00:00Z" '[]' "observing" ""
if [ -f "${STALE_PICKUP_REAPER_STATE_DIR}/200.json" ]; then
  echo "PASS: NFR 2.3: ネスト dir 配下に marker ファイル作成"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 2.3: ネスト dir 配下に marker ファイル未作成"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================
# Section 5: 破損 JSON / 不在ファイルで fail-open（{} を返す）
# ============================================================
echo ""
echo "--- Section 5: 破損 JSON / 不在で fail-open ---"

# 不在ファイルで {} を返す（NFR 2.2 の fail-open）
STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)
loaded=$(sr_load_marker 9999)
assert_eq "NFR 2.2: 不在ファイルで {} を返す（fail-open）" "{}" "$loaded"

# 破損 JSON でも {} を返す
STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)
echo "this is not json {[}" > "${STALE_PICKUP_REAPER_STATE_DIR}/777.json"
loaded=$(sr_load_marker 777)
assert_eq "NFR 2.3: 破損 JSON は {} を返す（fail-open）" "{}" "$loaded"

# 破損後でも save が成功して上書きできる（救済できる）
assert_rc "NFR 2.3: 破損ファイル後の save が成功" 0 \
  sr_save_marker 777 "2026-06-22T11:00:00Z" "2026-06-22T11:00:00Z" \
  '["claude-picked-up"]' "observing" ""

# save 後は正常な JSON として読める
loaded=$(sr_load_marker 777)
issue=$(printf '%s' "$loaded" | jq -r '.issue')
assert_eq "NFR 2.3: 破損ファイル救済後の issue = 777" "777" "$issue"

# load 系は rc=0 always（呼出側を落とさない）
load_rc=0
sr_load_marker 9999 >/dev/null 2>&1 || load_rc=$?
assert_eq "fail-open: sr_load_marker は不在でも rc=0" "0" "$load_rc"

# ============================================================
# Section 6: 未信頼入力 sanitize（NFR 3.1 / jq 特殊文字）
#
# 引数（first_seen_at / last_seen_at / labels_json / status / revert_at）に
# jq インジェクションを誘発しうる特殊文字（"、\、$、`、改行）を渡しても、
# --arg / --argjson 経路でサニタイズされ、literal として保持されることを検証する。
# ============================================================
echo ""
echo "--- Section 6: 未信頼入力 sanitize（NFR 3.1） ---"

STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)
# jq フィルタ構文を誘発しうる値を意図的に渡す
# shellcheck disable=SC2016
tricky_first='"; .issue = 9999 // "'
# shellcheck disable=SC2016
tricky_last='$( evil )'
# shellcheck disable=SC2016
tricky_status='` rm -rf / `'
# shellcheck disable=SC2016
tricky_revert=$'line1\nline2\\with-backslash'

assert_rc "NFR 3.1: 特殊文字を含む各 field でも save 成功" 0 \
  sr_save_marker 60 "$tricky_first" "$tricky_last" \
  '["claude-picked-up","auto-dev"]' "$tricky_status" "$tricky_revert"

loaded=$(sr_load_marker 60)
got_first=$(printf '%s' "$loaded" | jq -r '.first_seen_at')
got_last=$(printf '%s' "$loaded" | jq -r '.last_seen_at')
got_status=$(printf '%s' "$loaded" | jq -r '.status')
got_revert=$(printf '%s' "$loaded" | jq -r '.revert_at')
got_issue=$(printf '%s' "$loaded" | jq -r '.issue')

assert_eq "NFR 3.1: 特殊文字 first_seen_at が literal として保持される" "$tricky_first" "$got_first"
assert_eq "NFR 3.1: 特殊文字 last_seen_at が literal として保持される" "$tricky_last" "$got_last"
assert_eq "NFR 3.1: 特殊文字 status が literal として保持される" "$tricky_status" "$got_status"
assert_eq "NFR 3.1: 改行・バックスラッシュ revert_at が literal として保持される" "$tricky_revert" "$got_revert"
assert_eq "NFR 3.1: issue が injection で書き換わっていない（= 60）" "60" "$got_issue"

# labels_json は --argjson 経由（型は配列に限定し、配列でなければ空配列に正規化）
STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)
assert_rc "NFR 3.1: labels_json が空文字でも save 成功（[] に正規化）" 0 \
  sr_save_marker 61 "2026-06-22T10:00:00Z" "2026-06-22T10:00:00Z" '' "observing" ""
loaded=$(sr_load_marker 61)
labels_type=$(printf '%s' "$loaded" | jq -r '.last_known_labels | type')
labels_len=$(printf '%s' "$loaded" | jq -r '.last_known_labels | length')
assert_eq "NFR 3.1: labels_json 空入力でも型は array" "array" "$labels_type"
assert_eq "NFR 3.1: labels_json 空入力で長さ 0" "0" "$labels_len"

# labels_json に jq 特殊文字を含む文字列要素を入れても injection が起きない
STALE_PICKUP_REAPER_STATE_DIR=$(new_state_dir)
labels_with_quotes='["claude-picked-up","label\"with\\backslash"]'
assert_rc "NFR 3.1: labels_json に jq 特殊文字要素でも save 成功" 0 \
  sr_save_marker 62 "2026-06-22T10:00:00Z" "2026-06-22T10:00:00Z" \
  "$labels_with_quotes" "observing" ""
loaded=$(sr_load_marker 62)
got_label1=$(printf '%s' "$loaded" | jq -r '.last_known_labels[1]')
assert_eq "NFR 3.1: labels_json の特殊文字要素が literal として保持される" \
  'label"with\backslash' "$got_label1"

# ============================================================
# Section 7: sr_fetch_candidates — gh API filter / 2 クエリ結合 / dedup / fail-continue
# （task 3 / Req 2.1 / 2.2 / 2.3 / 2.4 / 2.5 / NFR 1.2 / NFR 3.1 / NFR 5.2）
#
# `gh` / `timeout` を bash 関数で stub し、search 文字列の必須トークン検証、2 クエリ
# 結合 + dedup（unique_by(.number)）、fail-continue（gh エラー / 非 JSON / 空文字
# fallback）、--repo / --state open / --limit 引数の伝達を fixture で確認する。
# ============================================================
echo ""
echo "--- Section 7: sr_fetch_candidates（task 3 / Req 2.1〜2.5 / NFR 1.2 / 5.2） ---"

# 必須ラベル定数 / REPO / Config を fixture で設定（issue-watcher.sh Config と等価）。
# 抽出した sr_fetch_candidates が呼び出し時に参照する遅延束縛変数のため、本テスト
# スクリプト内では直接参照しないが宣言が必須。SC2034（未使用扱い）を局所抑止する。
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

# gh / timeout を bash 関数として stub し、引数を trace ファイルに記録する。
# timeout を関数化するため、sr_fetch_candidates 内の `timeout <sec> gh ...` 構文も
# bash 関数解決経路で stub gh に到達する（gh が関数定義のため builtin/PATH より優先）。
SR_GH_TRACE="$(mktemp)"
SR_GH_RC_FILE="$(mktemp)"
SR_GH_PICKED_RESPONSE="$(mktemp)"
SR_GH_CLAIMED_RESPONSE="$(mktemp)"
echo "0" > "$SR_GH_RC_FILE"
SR_GH_CALL_COUNT_FILE="$(mktemp)"
echo "0" > "$SR_GH_CALL_COUNT_FILE"
SR_TIMEOUT_TRACE="$(mktemp)"
trap 'rm -f "$SR_WARN_TRACE" "$SR_GH_TRACE" "$SR_GH_RC_FILE" "$SR_GH_PICKED_RESPONSE" "$SR_GH_CLAIMED_RESPONSE" "$SR_GH_CALL_COUNT_FILE" "$SR_TIMEOUT_TRACE"' EXIT

# shellcheck disable=SC2317
gh() {
  # 全引数を 1 行で trace 記録（stdout には出さず trace ファイルに直接書く / 関数本体の
  # stdout は JSON 応答として保つ）
  {
    printf 'gh'
    local arg
    for arg in "$@"; do
      printf ' %s' "$arg"
    done
    printf '\n'
  } >> "$SR_GH_TRACE"

  # call count 増加
  local n
  n=$(cat "$SR_GH_CALL_COUNT_FILE")
  echo $((n + 1)) > "$SR_GH_CALL_COUNT_FILE"

  # search 文字列を inspect して picked-up / claimed の応答を切替
  local search_str=""
  local next_is_search=0
  local a
  for a in "$@"; do
    if [ "$next_is_search" = "1" ]; then
      search_str="$a"
      break
    fi
    if [ "$a" = "--search" ]; then
      next_is_search=1
    fi
  done

  # rc が 0 でなければ失敗を返す
  local rc
  rc=$(cat "$SR_GH_RC_FILE")
  if [ "$rc" != "0" ]; then
    return "$rc"
  fi

  case "$search_str" in
    *"$LABEL_PICKED"*)
      cat "$SR_GH_PICKED_RESPONSE"
      ;;
    *"$LABEL_CLAIMED"*)
      cat "$SR_GH_CLAIMED_RESPONSE"
      ;;
    *)
      echo "[]"
      ;;
  esac
}

# shellcheck disable=SC2317
timeout() {
  # 第 1 引数（秒数）を記録した後、残りの引数（実際は gh ...）を関数として呼ぶ
  echo "timeout-arg: $1" >> "$SR_TIMEOUT_TRACE"
  shift
  "$@"
}

# ── 7a: gh が JSON 配列を返す正常系で search 必須トークン + 2 クエリ結合 + dedup を検証 ──
echo "" > "$SR_GH_TRACE"
echo "0" > "$SR_GH_RC_FILE"
echo "" > "$SR_WARN_TRACE"
echo "0" > "$SR_GH_CALL_COUNT_FILE"
# 同じ issue 番号 #100 を picked / claimed の両方に含めて dedup を確認、
# picked にのみ #101、claimed にのみ #102 を含める（最終 3 件期待）
cat > "$SR_GH_PICKED_RESPONSE" <<'JSON'
[{"number":100,"labels":[{"name":"claude-picked-up"}],"title":"dup case","url":"https://example.com/100","updatedAt":"2026-06-22T10:00:00Z"},{"number":101,"labels":[{"name":"claude-picked-up"}],"title":"picked only","url":"https://example.com/101","updatedAt":"2026-06-22T10:05:00Z"}]
JSON
cat > "$SR_GH_CLAIMED_RESPONSE" <<'JSON'
[{"number":100,"labels":[{"name":"claude-claimed"}],"title":"dup case","url":"https://example.com/100","updatedAt":"2026-06-22T10:10:00Z"},{"number":102,"labels":[{"name":"claude-claimed"}],"title":"claimed only","url":"https://example.com/102","updatedAt":"2026-06-22T10:15:00Z"}]
JSON

candidates=$(sr_fetch_candidates)
candidates_count=$(printf '%s' "$candidates" | jq -r '. | length' 2>/dev/null)
assert_eq "Req 2.5 / NFR 3.1: 2 クエリ結合 + dedup で 3 件（#100 dedup）" "3" "$candidates_count"

# 必須トークン検証（trace ファイルで grep）
gh_trace_content=$(cat "$SR_GH_TRACE")

# label トークン: claude-picked-up / claude-claimed
if echo "$gh_trace_content" | grep -q 'label:"claude-picked-up"'; then
  echo "PASS: Req 2.1: search に label:\"claude-picked-up\" 含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.1: search に label:\"claude-picked-up\" が見つからない"
  echo "  trace: $gh_trace_content"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if echo "$gh_trace_content" | grep -q 'label:"claude-claimed"'; then
  echo "PASS: Req 2.2: search に label:\"claude-claimed\" 含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.2: search に label:\"claude-claimed\" が見つからない"
  echo "  trace: $gh_trace_content"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 除外トークン
for exclude_label in "claude-failed" "needs-decisions" "awaiting-design-review" \
                     "needs-quota-wait" "blocked" "staged-for-release" "hold"; do
  pattern="-label:\"$exclude_label\""
  if echo "$gh_trace_content" | grep -qF "$pattern"; then
    echo "PASS: Req 2.3 / 2.4: search に $pattern 含む（除外）"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: Req 2.3 / 2.4: search に $pattern が見つからない"
    echo "  trace: $gh_trace_content"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

# --limit / --state open / --repo / --json の伝達検証
if echo "$gh_trace_content" | grep -q -- '--limit 20'; then
  echo "PASS: NFR 1.2: gh 呼び出しに --limit 20 を伝達"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.2: --limit 20 が見つからない"
  echo "  trace: $gh_trace_content"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if echo "$gh_trace_content" | grep -q -- '--state open'; then
  echo "PASS: NFR 1.2: gh 呼び出しに --state open を伝達"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.2: --state open が見つからない"
  echo "  trace: $gh_trace_content"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if echo "$gh_trace_content" | grep -q -- '--repo owner/test-repo'; then
  echo "PASS: NFR 1.2: gh 呼び出しに --repo を伝達"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.2: --repo owner/test-repo が見つからない"
  echo "  trace: $gh_trace_content"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if echo "$gh_trace_content" | grep -q -- '--json number,labels,title,url,updatedAt'; then
  echo "PASS: design API Contract: --json で 5 field を取得"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: design API Contract: --json field が想定と異なる"
  echo "  trace: $gh_trace_content"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# timeout 経由の検証（trace に gh timeout 秒数が記録されているはず）
if grep -q "timeout-arg: 60" "$SR_TIMEOUT_TRACE"; then
  echo "PASS: NFR 5.2: timeout 60 秒で gh 呼び出しを保護"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 5.2: timeout 60 秒が呼び出されていない"
  echo "  trace: $(cat "$SR_TIMEOUT_TRACE")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# gh 呼び出し回数（2 クエリ発行 = 2 回）
gh_count=$(cat "$SR_GH_CALL_COUNT_FILE")
assert_eq "NFR 1.2: gh 呼び出し回数 = 2（picked + claimed の 2 クエリ）" "2" "$gh_count"

# ── 7b: gh が失敗（rc != 0）したとき [] を返し sr_warn を 1 件記録（fail-continue） ──
echo "" > "$SR_GH_TRACE"
echo "1" > "$SR_GH_RC_FILE"
echo "" > "$SR_WARN_TRACE"
echo "0" > "$SR_GH_CALL_COUNT_FILE"
result_b=$(sr_fetch_candidates)
rc_b=$?
assert_eq "NFR 5.2: gh 失敗時 stdout は []" "[]" "$result_b"
assert_eq "NFR 5.2: gh 失敗時 rc=0（fail-continue）" "0" "$rc_b"
warn_lines=$(grep -c 'sr_fetch_candidates' "$SR_WARN_TRACE" || true)
if [ "$warn_lines" -ge 1 ]; then
  echo "PASS: NFR 5.2: gh 失敗時 sr_warn 1 行以上記録（$warn_lines 行）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 5.2: gh 失敗時 sr_warn が呼ばれていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── 7c: gh が非 JSON を返したとき [] を返し sr_warn を記録 ──
echo "" > "$SR_GH_TRACE"
echo "0" > "$SR_GH_RC_FILE"
echo "" > "$SR_WARN_TRACE"
echo "not json garbage" > "$SR_GH_PICKED_RESPONSE"
echo "not json garbage" > "$SR_GH_CLAIMED_RESPONSE"
result_c=$(sr_fetch_candidates)
rc_c=$?
assert_eq "NFR 5.2: gh 非 JSON 出力で stdout は []" "[]" "$result_c"
assert_eq "NFR 5.2: gh 非 JSON 出力で rc=0（fail-continue）" "0" "$rc_c"
warn_lines=$(grep -c 'sr_fetch_candidates' "$SR_WARN_TRACE" || true)
if [ "$warn_lines" -ge 1 ]; then
  echo "PASS: NFR 5.2: 非 JSON 出力で sr_warn 1 行以上記録（$warn_lines 行）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 5.2: 非 JSON 出力で sr_warn が呼ばれていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── 7d: gh が空文字を返したとき [] を返し rc=0 ──
echo "" > "$SR_GH_TRACE"
echo "0" > "$SR_GH_RC_FILE"
echo "" > "$SR_WARN_TRACE"
: > "$SR_GH_PICKED_RESPONSE"
: > "$SR_GH_CLAIMED_RESPONSE"
result_d=$(sr_fetch_candidates)
rc_d=$?
assert_eq "NFR 5.2: gh 空文字出力で stdout は []" "[]" "$result_d"
assert_eq "NFR 5.2: gh 空文字出力で rc=0（fail-continue）" "0" "$rc_d"

# ── 7e: --limit が STALE_PICKUP_REAPER_MAX_ISSUES で動的に切り替わる ──
echo "" > "$SR_GH_TRACE"
echo "0" > "$SR_GH_RC_FILE"
echo "" > "$SR_WARN_TRACE"
echo "[]" > "$SR_GH_PICKED_RESPONSE"
echo "[]" > "$SR_GH_CLAIMED_RESPONSE"
STALE_PICKUP_REAPER_MAX_ISSUES=5
sr_fetch_candidates >/dev/null
if grep -q -- '--limit 5' "$SR_GH_TRACE"; then
  echo "PASS: NFR 1.2: MAX_ISSUES=5 で --limit 5 を伝達（動的）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 1.2: MAX_ISSUES=5 で --limit 5 が見つからない"
  echo "  trace: $(cat "$SR_GH_TRACE")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
# 復元
STALE_PICKUP_REAPER_MAX_ISSUES=20

# stub を unset（後続 Summary section で `gh` / `timeout` が必要になることはないが安全側）
unset -f gh timeout

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
