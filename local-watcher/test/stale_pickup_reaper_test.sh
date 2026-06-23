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
#         - sr_check_marker_age / sr_check_slot_lock / sr_check_session / sr_is_active
#           (task 4 / Req 3.1 / 3.2 / 3.3 / 3.4 / 3.5 / 4.2 / 6.3 / NFR 4.1 / NFR 4.2)
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
#         - Req 3.1: 3 観点 AND で「非アクティブ」確定
#         - Req 3.2: いずれか 1 観点でも「アクティブの可能性あり」なら revert しない
#         - Req 3.3: 判定中の副作用ゼロ（read-only / gh を呼ばない）
#         - Req 3.4: 根拠取得失敗時 safe-side fallback（fresh / may-have-lock / may-have-session）
#         - Req 3.5: 判定根拠を 1 行ログ（age / lock / sess）で記録
#         - Req 4.2: 経過時間が閾値未満なら復旧対象とせず継続観測
#         - Req 6.3: branch 状態を「アクティブ」根拠にしない（layer は branch を見ない）
#         - NFR 4.1: 判定イベント種別と issue 番号を 1 行ログで記録
#         - NFR 4.2: 見送り理由を 1 行ログで記録
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

# 抽出: 9 関数を modules/stale-pickup-reaper.sh から取り出す
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
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_marker_age")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_slot_lock")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_check_session")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sr_is_active")"

for fn in sr_is_enabled sr_marker_path sr_load_marker sr_save_marker sr_fetch_candidates \
          sr_check_marker_age sr_check_slot_lock sr_check_session sr_is_active; do
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
# shellcheck disable=SC2218  # extract_function + eval で定義済み（Section 13 で stub 再定義する関係で SC2218 抑制）
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
# shellcheck disable=SC2218  # extract_function + eval で定義済み（Section 13 で stub 再定義する関係で SC2218 抑制）
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
fr_line=$(grep -n '^process_failed_recovery ||' "$WATCHER_SH" | head -1 | cut -d: -f1)
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
trap 'rm -f "$SR_WARN_TRACE" "$SR12_GH_TRACE" "$SR12_GH_VIEW_RESPONSE" "$SR12_GH_REMOVE_RC_FILE" "$SR12_GH_VIEW_RC_FILE" "$SR12_GH_ADD_RC_FILE" "$SR12_LOG_TRACE" "$SR13_GH_TRACE" "$SR13_REVERT_COUNT_FILE" "$SR13_SAVE_TRACE" "$SR14C_GH_TRACE"' EXIT

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
