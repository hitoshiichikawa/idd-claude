#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/auto-rebase.sh の Issue #366（Phase D-12 Claude
#       semantic resolution）で追加した:
#         - dual opt-in gate (ar_semantic_enabled)
#         - 環境変数値の正規化（AUTO_REBASE_SEMANTIC 厳密一致）
#         - 状態ファイル IO (ar_semantic_state_path / ar_semantic_load_state /
#           ar_semantic_save_state)
#         - idempotency 判定 (ar_semantic_should_skip_idempotent)
#         - attempt budget 判定 (ar_semantic_get_attempts /
#           ar_semantic_budget_exhausted)
#       を fixture で検証するスモークテスト。
#
#       検証する AC（docs/specs/366-feat-auto-rebase-semantic-conflict-claud/requirements.md）:
#         - Req 1.2, 1.3, 1.4: AUTO_REBASE_SEMANTIC の正規化（claude / off のみ受理）
#         - Req 2.1〜2.5: dual opt-in (AND with FULL_AUTO_ENABLED)
#         - Req 6.1, 6.4, 6.5: 同一 head SHA に対する二重実行抑止
#         - Req 6.2, 6.3: state ファイルの配置と fail-open
#         - Req 7.1, 7.2: attempt budget の数え上げと上限判定
#         - NFR 1.1: gate OFF 時に本機能導入前と外形等価
#
# 配置先: local-watcher/test/ar_semantic_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/ar_semantic_test.sh

set -euo pipefail

# 本テストは抽出関数（ar_semantic_enabled / ar_semantic_budget_exhausted など）が
# AUTO_REBASE_SEMANTIC / FULL_AUTO_ENABLED / AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS /
# AUTO_REBASE_SEMANTIC_STATE_DIR 等のグローバル env を遅延束縛で参照するため、
# static 解析（shellcheck）からは未使用に見える。本ファイル全体で SC2034 を抑止する。
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/auto-rebase.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find auto-rebase.sh at $MODULE_SH" >&2
  exit 2
fi
if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 既存テスト（fr_state_test.sh / full_auto_enabled_test.sh）と同じイディオム:
# 対象スクリプトから 1 関数だけを awk で切り出して eval で読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 抽出: 6 関数を同一 module から取り出す
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_semantic_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_semantic_state_path")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_semantic_load_state")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_semantic_save_state")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_semantic_should_skip_idempotent")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_semantic_get_attempts")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "ar_semantic_budget_exhausted")"

for fn in ar_semantic_enabled ar_semantic_state_path ar_semantic_load_state \
          ar_semantic_save_state ar_semantic_should_skip_idempotent \
          ar_semantic_get_attempts ar_semantic_budget_exhausted; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ar_save_state が失敗時に ar_warn を呼ぶため stub する（実体は core_utils.sh 側）。
AR_WARN_TRACE="$(mktemp)"
trap 'rm -f "$AR_WARN_TRACE"' EXIT

# shellcheck disable=SC2317
ar_warn() {
  echo "$*" >> "$AR_WARN_TRACE"
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

new_state_dir() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# ============================================================
# Section 1: ar_semantic_enabled の値正規化（Req 1.2 / 1.3 / 1.4 / 2.1〜2.5）
# ============================================================
echo "--- Section 1: ar_semantic_enabled の値正規化と dual opt-in ---"

# 1.1: 両 gate ON のみ enabled
AUTO_REBASE_SEMANTIC="claude"
FULL_AUTO_ENABLED="true"
assert_rc "Req 2.1: 両 gate ON で enabled (rc=0)" 0 ar_semantic_enabled

# 1.2: AUTO_REBASE_SEMANTIC=off → disabled
AUTO_REBASE_SEMANTIC="off"
FULL_AUTO_ENABLED="true"
assert_rc "Req 2.2: AUTO_REBASE_SEMANTIC=off で disabled" 1 ar_semantic_enabled

# 1.3: FULL_AUTO_ENABLED!=true → disabled（kill switch OFF）
AUTO_REBASE_SEMANTIC="claude"
FULL_AUTO_ENABLED="false"
assert_rc "Req 2.3: FULL_AUTO_ENABLED=false で disabled" 1 ar_semantic_enabled

# 1.4: 両 gate 未設定 → disabled（既定値）
unset AUTO_REBASE_SEMANTIC
unset FULL_AUTO_ENABLED
assert_rc "Req 1.4: 両 gate 未設定で既定 disabled" 1 ar_semantic_enabled

# 1.5: AUTO_REBASE_SEMANTIC の正規化対象値はすべて disabled
# （Config ブロック側で off に正規化される想定 / 本関数は受け取った値の厳密一致のみ判定）
FULL_AUTO_ENABLED="true"
for v in "" "off" "Claude" "CLAUDE" "on" "true" "1" "yes" "  claude  " "claudes"; do
  AUTO_REBASE_SEMANTIC="$v"
  assert_rc "Req 1.3: AUTO_REBASE_SEMANTIC=$(printf '%q' "$v") は disabled" 1 ar_semantic_enabled
done

# 1.6: FULL_AUTO_ENABLED の正規化対象値はすべて disabled（NFR 1.1 安全側）
AUTO_REBASE_SEMANTIC="claude"
for v in "" "false" "0" "True" "TRUE" "1" "on" "yes"; do
  FULL_AUTO_ENABLED="$v"
  assert_rc "Req 2.5: FULL_AUTO_ENABLED=$(printf '%q' "$v") は disabled" 1 ar_semantic_enabled
done

# ============================================================
# Section 2: AUTO_REBASE_SEMANTIC の Config ブロック側正規化（Req 1.3, 1.4）
# ============================================================
echo ""
echo "--- Section 2: AUTO_REBASE_SEMANTIC の正規化（Config ブロック相当） ---"

normalize_auto_rebase_semantic() {
  local input="$1"
  # issue-watcher.sh の Config ブロック相当のロジック
  AUTO_REBASE_SEMANTIC="${input:-off}"
  case "$AUTO_REBASE_SEMANTIC" in
    claude) : ;;
    *)      AUTO_REBASE_SEMANTIC="off" ;;
  esac
  echo "$AUTO_REBASE_SEMANTIC"
}

assert_eq "Req 1.2: 'claude' は受理" "claude" "$(normalize_auto_rebase_semantic 'claude')"
assert_eq "Req 1.3: 'off' は受理" "off" "$(normalize_auto_rebase_semantic 'off')"
assert_eq "Req 1.4: 未設定は off" "off" "$(normalize_auto_rebase_semantic '')"
assert_eq "Req 1.4: 'Claude' (typo) は off" "off" "$(normalize_auto_rebase_semantic 'Claude')"
assert_eq "Req 1.4: 'CLAUDE' (typo) は off" "off" "$(normalize_auto_rebase_semantic 'CLAUDE')"
assert_eq "Req 1.4: 'on' (typo) は off" "off" "$(normalize_auto_rebase_semantic 'on')"
assert_eq "Req 1.4: 'true' (typo) は off" "off" "$(normalize_auto_rebase_semantic 'true')"
assert_eq "Req 1.4: '1' は off" "off" "$(normalize_auto_rebase_semantic '1')"
assert_eq "Req 1.4: 前後空白付きは off" "off" "$(normalize_auto_rebase_semantic '  claude  ')"

# ============================================================
# Section 3: ar_semantic_state_path / load / save の往復（Req 6.2, 6.3 / NFR 4.1）
# ============================================================
echo ""
echo "--- Section 3: 状態ファイル IO（path / save / load） ---"

AUTO_REBASE_SEMANTIC_STATE_DIR=$(new_state_dir)

# 3.1: ar_semantic_state_path はパスを返す
path=$(ar_semantic_state_path 366)
expected_path="${AUTO_REBASE_SEMANTIC_STATE_DIR}/pr-366.json"
assert_eq "Req 6.2: state path は pr-<N>.json 形式" "$expected_path" "$path"

# 3.2: 不在ファイルで fail-open
loaded=$(ar_semantic_load_state 999)
assert_eq "Req 6.3: 不在ファイルで {} を返す（fail-open）" "{}" "$loaded"

# 3.3: save → load の往復
assert_rc "Req 6.2: ar_semantic_save_state が成功" 0 \
  ar_semantic_save_state 366 1 "in-progress" "abc123def456"

loaded=$(ar_semantic_load_state 366)
pr=$(printf '%s' "$loaded" | jq -r '.pr')
total=$(printf '%s' "$loaded" | jq -r '.total_attempts')
status=$(printf '%s' "$loaded" | jq -r '.last_status')
head=$(printf '%s' "$loaded" | jq -r '.last_head_sha')
at=$(printf '%s' "$loaded" | jq -r '.last_attempt_at')

assert_eq "Req 6.2: schema.pr = 366" "366" "$pr"
assert_eq "Req 6.2: schema.total_attempts = 1" "1" "$total"
assert_eq "Req 6.2: schema.last_status = in-progress" "in-progress" "$status"
assert_eq "Req 6.2: schema.last_head_sha 保持" "abc123def456" "$head"
if [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "PASS: Req 6.2: last_attempt_at は ISO 8601 UTC ($at)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 6.2: last_attempt_at が ISO 8601 UTC でない: $at"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 3.4: 上書き save が動作
assert_rc "Req 6.4: 2 回目 save が成功" 0 \
  ar_semantic_save_state 366 2 "succeeded" "def789abc012"
loaded=$(ar_semantic_load_state 366)
total=$(printf '%s' "$loaded" | jq -r '.total_attempts')
head=$(printf '%s' "$loaded" | jq -r '.last_head_sha')
status=$(printf '%s' "$loaded" | jq -r '.last_status')
assert_eq "Req 6.4: 上書きで total_attempts=2" "2" "$total"
assert_eq "Req 6.4: 上書きで last_head_sha 更新" "def789abc012" "$head"
assert_eq "Req 6.4: 上書きで last_status=succeeded" "succeeded" "$status"

# 3.5: 破損ファイル → fail-open
echo "this is not json {[}" > "${AUTO_REBASE_SEMANTIC_STATE_DIR}/pr-777.json"
loaded=$(ar_semantic_load_state 777)
assert_eq "Req 6.3: 破損 JSON は {} を返す（fail-open）" "{}" "$loaded"
# 破損後でも save で救済できる
assert_rc "Req 6.3: 破損ファイル後の save が成功" 0 \
  ar_semantic_save_state 777 1 "in-progress" "newhead"
loaded=$(ar_semantic_load_state 777)
total=$(printf '%s' "$loaded" | jq -r '.total_attempts')
assert_eq "Req 6.3: 破損救済後の total_attempts=1" "1" "$total"

# 3.6: atomic rename — tmp file が残らない
AUTO_REBASE_SEMANTIC_STATE_DIR=$(new_state_dir)
ar_semantic_save_state 100 1 "in-progress" "sha100" >/dev/null 2>&1
tmp_count=$(find "$AUTO_REBASE_SEMANTIC_STATE_DIR" -name 'pr-100.json.*' 2>/dev/null | wc -l)
assert_eq "NFR 4.1: save 成功時に中間 tmp file が残らない" "0" "$tmp_count"

# 3.7: 未信頼入力 sanitize（jq --arg 経路）
AUTO_REBASE_SEMANTIC_STATE_DIR=$(new_state_dir)
# shellcheck disable=SC2016
tricky='"; .total_attempts = 9999 // "'
assert_rc "NFR 4.1: 特殊文字 head_sha でも save 成功" 0 \
  ar_semantic_save_state 60 1 "in-progress" "$tricky"
loaded=$(ar_semantic_load_state 60)
got=$(printf '%s' "$loaded" | jq -r '.last_head_sha')
got_total=$(printf '%s' "$loaded" | jq -r '.total_attempts')
assert_eq "NFR 4.1: 特殊文字 head_sha が literal として保持される" "$tricky" "$got"
assert_eq "NFR 4.1: total_attempts が injection で書き換わっていない" "1" "$got_total"

# ============================================================
# Section 4: idempotency 判定（Req 6.1, 6.4, 6.5）
# ============================================================
echo ""
echo "--- Section 4: idempotency 判定（同一 head SHA で skip） ---"

AUTO_REBASE_SEMANTIC_STATE_DIR=$(new_state_dir)

# 4.1: state 不在 → 試行可（skip しない）
assert_rc "Req 6.1: state 不在で 試行可 (rc=1)" 1 \
  ar_semantic_should_skip_idempotent 200 "currenthead"

# 4.2: state あり、SHA 一致 → skip
ar_semantic_save_state 200 1 "in-progress" "currenthead" >/dev/null 2>&1
assert_rc "Req 6.1: 前回 head SHA と一致で skip (rc=0)" 0 \
  ar_semantic_should_skip_idempotent 200 "currenthead"

# 4.3: state あり、SHA 不一致 → 試行可
assert_rc "Req 6.1: 前回 head SHA と不一致で 試行可 (rc=1)" 1 \
  ar_semantic_should_skip_idempotent 200 "differenthead"

# 4.4: current_head_sha が空文字 → 安全側 (試行可) に倒す
assert_rc "Req 6.1: current_head_sha=空文字で 試行可 (rc=1)" 1 \
  ar_semantic_should_skip_idempotent 200 ""

# ============================================================
# Section 5: attempt budget 判定（Req 7.1, 7.2）
# ============================================================
echo ""
echo "--- Section 5: attempt budget の数え上げと上限判定 ---"

AUTO_REBASE_SEMANTIC_STATE_DIR=$(new_state_dir)
AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS=3

# 5.1: state 不在 → 0 attempts
got=$(ar_semantic_get_attempts 300)
assert_eq "Req 7.1: state 不在で 0 attempts" "0" "$got"

# 5.2: budget 上限未到達（0 < 3）→ exhausted=false
assert_rc "Req 7.2: 0 attempts は budget 余裕 (rc=1)" 1 \
  ar_semantic_budget_exhausted 0
assert_rc "Req 7.2: 2 attempts は budget 余裕 (rc=1)" 1 \
  ar_semantic_budget_exhausted 2

# 5.3: budget 上限到達（3 == 3）→ exhausted=true
assert_rc "Req 7.2: 3 attempts は budget 到達 (rc=0)" 0 \
  ar_semantic_budget_exhausted 3
# 5.4: budget 超過（4 > 3）→ exhausted=true
assert_rc "Req 7.2: 4 attempts は budget 超過 (rc=0)" 0 \
  ar_semantic_budget_exhausted 4

# 5.5: budget 不正値（非整数） → 既定 3 にフォールバック
# shellcheck disable=SC2034  # 抽出関数 ar_semantic_budget_exhausted が遅延束縛で参照
AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS="abc"
assert_rc "Req 7.2: 不正な budget は既定 3 にフォールバック" 0 \
  ar_semantic_budget_exhausted 3
# shellcheck disable=SC2034  # 抽出関数 ar_semantic_budget_exhausted が遅延束縛で参照
AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS=3

# 5.6: 完全フロー: save → get → exhausted の往復
ar_semantic_save_state 300 1 "in-progress" "sha1" >/dev/null 2>&1
got=$(ar_semantic_get_attempts 300)
assert_eq "Req 7.1: save 1 回目 → 1 attempts" "1" "$got"
ar_semantic_save_state 300 2 "in-progress" "sha2" >/dev/null 2>&1
ar_semantic_save_state 300 3 "in-progress" "sha3" >/dev/null 2>&1
got=$(ar_semantic_get_attempts 300)
assert_eq "Req 7.1: save 3 回目 → 3 attempts" "3" "$got"
assert_rc "Req 7.2: 3 attempts に到達したら budget exhausted" 0 \
  ar_semantic_budget_exhausted "$got"

# ============================================================
# Section 6: NFR 1.1 — gate OFF 時に旧 ar_apply_semantic 経路が選択される
# （ar_semantic_enabled が rc=1 を返すことで分岐）
# ============================================================
echo ""
echo "--- Section 6: NFR 1.1 — gate OFF 時の後方互換 ---"

unset AUTO_REBASE_SEMANTIC
unset FULL_AUTO_ENABLED
assert_rc "NFR 1.1: 両 gate 未設定で ar_semantic_enabled=disabled（旧経路 fall-through）" 1 \
  ar_semantic_enabled

AUTO_REBASE_SEMANTIC="off"
# shellcheck disable=SC2034  # 抽出関数 ar_semantic_enabled が遅延束縛で参照
FULL_AUTO_ENABLED="true"
assert_rc "NFR 1.1: gate OFF + kill ON でも disabled（旧経路 fall-through）" 1 \
  ar_semantic_enabled

AUTO_REBASE_SEMANTIC="claude"
unset FULL_AUTO_ENABLED
assert_rc "NFR 1.1: gate ON + kill 未設定でも disabled（旧経路 fall-through）" 1 \
  ar_semantic_enabled

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
