#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #348（full-auto 系 processor の単一
#       kill switch `FULL_AUTO_ENABLED`）で追加した `full_auto_enabled` 関数の正規化
#       挙動、および `dr_unblock_sweep` の入口での AND 二重 opt-in セマンティクスを
#       fixture で検証するスモークテスト。
#
#       対象関数:
#         - full_auto_enabled        (Req 1.2 / 1.3 / NFR 1.1 / 安全側正規化)
#         - dr_unblock_sweep         (Req 2.5 / kill switch + 個別 gate AND 動作)
#
#       検証する AC（docs/specs/348-feat-watcher-full-auto-enabled-kill-swit/requirements.md）:
#         - AC 1.1: FULL_AUTO_ENABLED の既定値は false（未設定時 disabled）
#         - AC 1.2: =true 厳密一致のみ enabled
#         - AC 1.3: 未設定 / 空 / false / 0 / True / TRUE / 1 / typo はすべて disabled
#         - AC 2.5: kill OFF + 個別 gate=true → 早期 return（gh API ゼロ呼び出し）
#         - AC 2.6: kill ON + 個別 gate=false → no-op（個別 gate 評価へ進む）
#         - AC 2.7: kill ON + 個別 gate=true → 通常フロー実行
#         - AC 4.1: kill OFF 時に suppression 原因をログ出力
#
# 配置先: local-watcher/test/full_auto_enabled_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/full_auto_enabled_test.sh

set -euo pipefail

# 本テストは抽出関数（full_auto_enabled / dr_unblock_sweep など）と stub から indirect
# 参照される変数を多用するため、static 解析（shellcheck）からは未使用に見える。
# 本ファイル全体で SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を読み込む。dr_unblock_sweep は内部で dr_unblock_gate_enabled を呼ぶため
# それも合わせて読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "full_auto_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_gate_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_sweep")"

for fn in full_auto_enabled dr_unblock_gate_enabled dr_unblock_sweep; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される）
REPO="owner/test-repo"
LABEL_TRIGGER="auto-dev"
LABEL_BLOCKED="blocked"
LABEL_FAILED="claude-failed"
LABEL_NEEDS_DECISIONS="needs-decisions"

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

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

# ── stub state for dr_unblock_sweep gh-call observability ──
reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
}

# dr_log / dr_warn stub: 出力を記録ファイルへ
# shellcheck disable=SC2317
dr_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
dr_warn() { echo "$*" >>"$WARN_LOG"; }

# gh stub: kill switch ON 経由で gh issue list 呼び出しが発生したことを観測するための
# 最小実装。`gh issue list` は空 JSON を返し、その他の呼び出しは記録のみ。
# shellcheck disable=SC2317
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  echo "gh $*" >>"$GH_CALL_LOG"
  case "$sub" in
    issue)
      case "$sub2" in
        list)
          # 空 JSON を返して dr_unblock_sweep は早期 return（count=0）
          printf '%s' '[]'
          return 0
          ;;
      esac
      ;;
  esac
  return 0
}

count_calls() {
  local pattern="$1"
  local n
  # `--` でオプション解釈を打ち切り、pattern が `--foo` で始まっても安全に grep する
  n=$( { grep -E -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_logs() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$LOG_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# ============================================================
# Section 1: full_auto_enabled の値正規化（Req 1.2 / 1.3 / NFR 1.1）
# ============================================================
echo "--- Section 1: full_auto_enabled の値正規化（Req 1.2 / 1.3） ---"

# AC 1.1: 既定値（未設定）は disabled
unset FULL_AUTO_ENABLED
assert_rc "Req 1.1 / 1.3: 未設定なら disabled（rc=1）" 1 full_auto_enabled

# AC 1.2: =true 厳密一致のみ enabled
FULL_AUTO_ENABLED="true"
assert_rc "Req 1.2: =true 厳密一致で enabled（rc=0）" 0 full_auto_enabled

# AC 1.3: それ以外の値はすべて disabled（安全側 / NFR 1.1）
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes" "enable" "enabled" "Yes" "tRue" "  true  " "true\n" "trues"; do
  FULL_AUTO_ENABLED="$v"
  assert_rc "Req 1.3: FULL_AUTO_ENABLED=$(printf '%q' "$v") は disabled" 1 full_auto_enabled
done

# ============================================================
# Section 2: dr_unblock_sweep AND ゲート挙動（Req 2.5〜2.7）
# ============================================================
echo ""
echo "--- Section 2: dr_unblock_sweep AND ゲート挙動（Req 2.5 / 2.6 / 2.7） ---"

# Case A: kill OFF + 個別 gate=true → 早期 return（gh ゼロ呼び出し + suppression ログ）
reset_stub_state
unset FULL_AUTO_ENABLED
DEP_AUTO_UNBLOCK_ENABLED="true"
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "Req 2.5: kill OFF + 個別 gate=true で gh API ゼロ呼び出し" "0" "$gh_count"
# Req 4.1: suppression 原因のログを 1 行出力
sup_count=$(count_logs "suppressed by FULL_AUTO_ENABLED")
assert_eq "Req 4.1: kill OFF 時に suppression ログを 1 行出力" "1" "$sup_count"
cleanup_stub_state

# Case A': kill 未設定（既定 OFF）+ 個別 gate=true → 同様に早期 return
reset_stub_state
unset FULL_AUTO_ENABLED
DEP_AUTO_UNBLOCK_ENABLED="true"
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "Req 2.5 / 1.3: kill 未設定（既定 OFF）+ 個別 gate=true で gh ゼロ呼び出し" "0" "$gh_count"
cleanup_stub_state

# Case A'': kill OFF（typo: True）+ 個別 gate=true → 安全側で OFF（gh ゼロ呼び出し）
reset_stub_state
FULL_AUTO_ENABLED="True"
DEP_AUTO_UNBLOCK_ENABLED="true"
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "Req 1.3 / 2.5: kill=True（typo）+ 個別 gate=true で安全側 OFF" "0" "$gh_count"
cleanup_stub_state

# Case B: kill ON + 個別 gate=false → 個別 gate 段で早期 return（gh ゼロ呼び出し）
reset_stub_state
FULL_AUTO_ENABLED="true"
DEP_AUTO_UNBLOCK_ENABLED="false"
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "Req 2.6: kill ON + 個別 gate=false で no-op（gh ゼロ呼び出し）" "0" "$gh_count"
# kill switch suppression のログは出ない（個別 gate 段で抜けたため）
sup_count=$(count_logs "suppressed by FULL_AUTO_ENABLED")
assert_eq "Req 2.6: kill ON 時は suppression ログを出さない" "0" "$sup_count"
cleanup_stub_state

# Case B': kill ON + 個別 gate=未設定（既定 OFF）→ no-op
reset_stub_state
FULL_AUTO_ENABLED="true"
unset DEP_AUTO_UNBLOCK_ENABLED
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "Req 2.6: kill ON + 個別 gate 未設定 で no-op（gh ゼロ呼び出し）" "0" "$gh_count"
cleanup_stub_state

# Case C: kill ON + 個別 gate=true → 通常フローへ進む（gh issue list が呼ばれる）
reset_stub_state
FULL_AUTO_ENABLED="true"
DEP_AUTO_UNBLOCK_ENABLED="true"
dr_unblock_sweep
gh_count=$(count_calls "^gh issue list")
# 通常フロー進入を gh issue list 呼び出し回数で観測（空 JSON を返すので 1 回で終わる）
if [ "$gh_count" -ge 1 ]; then
  echo "PASS: Req 2.7: kill ON + 個別 gate=true で通常フロー進入（gh issue list 呼び出し ${gh_count}）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 2.7: kill ON + 個別 gate=true で通常フロー未進入（gh issue list 呼び出し 0）"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
# kill switch suppression のログは出ない
sup_count=$(count_logs "suppressed by FULL_AUTO_ENABLED")
assert_eq "Req 2.7: kill ON 時は suppression ログを出さない" "0" "$sup_count"
cleanup_stub_state

# ============================================================
# Section 3: 後方互換 (NFR 1.1) — FULL_AUTO_ENABLED 未設定時、
# DEP_AUTO_UNBLOCK_ENABLED 未設定の場合は本機能導入前と挙動が等価
# ============================================================
echo ""
echo "--- Section 3: 後方互換 (NFR 1.1) ---"

reset_stub_state
unset FULL_AUTO_ENABLED
unset DEP_AUTO_UNBLOCK_ENABLED
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "NFR 1.1: kill 未設定 + 個別 gate 未設定で gh ゼロ呼び出し（導入前と等価）" "0" "$gh_count"
# 本機能導入前の挙動: gate OFF で何もログを出さない（dr_unblock_gate_enabled が静かに return）
# kill switch suppression ログは出ているか確認（本機能導入後の差分はログ 1 行のみ）
sup_count=$(count_logs "suppressed by FULL_AUTO_ENABLED")
assert_eq "Req 4.1: 未設定状態でも suppression ログを 1 行出力（運用者の状態把握用）" "1" "$sup_count"
cleanup_stub_state

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
