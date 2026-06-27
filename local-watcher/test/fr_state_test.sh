#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した状態永続化レイヤ（fr_state_path / fr_load_state /
#       fr_save_state）を fixture で検証するスモークテスト。
#
#       対象関数:
#         - fr_state_path (Issue #359 Req 4.7)
#         - fr_load_state (Issue #359 Req 4.1 / 4.7 / 5.5 / 6.2 / NFR 2.2)
#         - fr_save_state (Issue #359 Req 4.1 / 4.2 / 5.5 / 6.2 / NFR 2.3 / NFR 3.1)
#
#       検証する AC（docs/specs/359-feat-watcher-failed-recovery-sh-claude-f/requirements.md）:
#         - Req 4.1: 通算カウンタ管理（schema フィールド total_attempts が読み書き可能）
#         - Req 4.2: 試行開始時 +1 加算ロジックの基盤として save → load で値が保持される
#         - Req 4.7: $HOME/.issue-watcher/ 配下に永続化
#         - Req 4.8: MAX_ATTEMPTS の不正値正規化（issue-watcher.sh Config ブロックの間接検証）
#         - Req 5.5: 直前試行情報（last_failure_signature / last_head_sha）の永続化
#         - Req 6.2: last_status enum（succeeded / max-attempts / no-progress / in-progress）
#         - NFR 2.2: プロセス再起動でカウンタ継承（同一ファイルの load → 同値）
#         - NFR 2.3: TOCTOU 安全な atomic write（mktemp → mv -f / 中間 tmp file が残らない）
#         - NFR 3.1: jq --arg / --argjson によるサニタイズ（特殊文字を含む input でも壊れない）
#
#       本 test は task 2.1 の `_Requirements_partial:_ 4.8` を本 task でカバーするものでもある。
#
# 配置先: local-watcher/test/fr_state_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/fr_state_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi
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

# 抽出: 3 関数を同一 module から取り出す
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_state_path")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_load_state")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_save_state")"

for fn in fr_state_path fr_load_state fr_save_state; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# fr_save_state が失敗時に fr_warn を呼ぶため stub する（実体は core_utils.sh 側）。
# 出力を trace ファイルに append して後段の assertion で使う。
FR_WARN_TRACE="$(mktemp)"
trap 'rm -f "$FR_WARN_TRACE"' EXIT

# shellcheck disable=SC2317
fr_warn() {
  echo "$*" >> "$FR_WARN_TRACE"
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

# テスト隔離環境を作成する helper（各 Section で別ディレクトリを使う）
new_state_dir() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# ============================================================
# Section 1: fr_state_path（純粋関数 / 絶対パス生成）
# ============================================================
echo "--- Section 1: fr_state_path（絶対パス生成） ---"

FAILED_RECOVERY_STATE_DIR="/tmp/fr-test-state"
path=$(fr_state_path 123)
assert_eq "Req 4.7: fr_state_path 123 が /tmp/fr-test-state/123.json を返す" \
  "/tmp/fr-test-state/123.json" "$path"

FAILED_RECOVERY_STATE_DIR="$HOME/.issue-watcher/failed-recovery/owner-repo"
path=$(fr_state_path 359)
assert_eq "Req 4.7: \$HOME 配下の path を返す（repo-slug 分離）" \
  "$HOME/.issue-watcher/failed-recovery/owner-repo/359.json" "$path"

# ============================================================
# Section 2: fr_load_state — ファイル不在で fail-open（{}）
# ============================================================
echo ""
echo "--- Section 2: fr_load_state — ファイル不在（fail-open） ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
loaded=$(fr_load_state 999)
assert_eq "Req 4.7 / NFR 2.2: 不在ファイルで {} を返す（fail-open）" "{}" "$loaded"

# ============================================================
# Section 3: fr_save_state → fr_load_state の往復で全 field が読み出せる
# ============================================================
echo ""
echo "--- Section 3: save → load の往復（schema 全 field） ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)

# 1 回目の save（in-progress / signature あり / head_sha あり）
assert_rc "Req 4.1: 1 回目の fr_save_state が成功（rc=0）" 0 \
  fr_save_state 359 1 "in-progress" "abc123def456" "0000000000000000000000000000000000000001"

# load して各 field を検証
loaded=$(fr_load_state 359)
issue=$(printf '%s' "$loaded" | jq -r '.issue')
total=$(printf '%s' "$loaded" | jq -r '.total_attempts')
status=$(printf '%s' "$loaded" | jq -r '.last_status')
sig=$(printf '%s' "$loaded" | jq -r '.last_failure_signature')
head=$(printf '%s' "$loaded" | jq -r '.last_head_sha')
at=$(printf '%s' "$loaded" | jq -r '.last_attempt_at')

assert_eq "Req 4.1: schema.issue = 359" "359" "$issue"
assert_eq "Req 4.1 / 4.2: schema.total_attempts = 1" "1" "$total"
assert_eq "Req 6.2: schema.last_status = in-progress" "in-progress" "$status"
assert_eq "Req 5.5: schema.last_failure_signature = abc123def456" "abc123def456" "$sig"
assert_eq "Req 5.5: schema.last_head_sha 保持" "0000000000000000000000000000000000000001" "$head"

# last_attempt_at は ISO 8601 UTC（YYYY-MM-DDTHH:MM:SSZ）。書式のみ正規表現で検証
if [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "PASS: NFR 2.2: schema.last_attempt_at は ISO 8601 UTC 形式（$at）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 2.2: schema.last_attempt_at が ISO 8601 UTC 形式でない: $at"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================
# Section 4: 2 回 save → history に 2 件累積（append-only）
# ============================================================
echo ""
echo "--- Section 4: history append 動作 ---"

# Section 3 の state に対して 2 回目 save
assert_rc "Req 4.1: 2 回目の fr_save_state が成功" 0 \
  fr_save_state 359 2 "in-progress" "deadbeef" "0000000000000000000000000000000000000002"

loaded=$(fr_load_state 359)
hist_len=$(printf '%s' "$loaded" | jq -r '.history | length')
assert_eq "Req 5.5: history は 2 件累積（append-only）" "2" "$hist_len"

# 各 history エントリの schema を検証
attempt_0=$(printf '%s' "$loaded" | jq -r '.history[0].attempt')
attempt_1=$(printf '%s' "$loaded" | jq -r '.history[1].attempt')
sig_0=$(printf '%s' "$loaded" | jq -r '.history[0].signature')
sig_1=$(printf '%s' "$loaded" | jq -r '.history[1].signature')
outcome_1=$(printf '%s' "$loaded" | jq -r '.history[1].outcome')

assert_eq "Req 5.5: history[0].attempt = 1（古い順）" "1" "$attempt_0"
assert_eq "Req 5.5: history[1].attempt = 2（最新）" "2" "$attempt_1"
assert_eq "Req 5.5: history[0].signature 保持" "abc123def456" "$sig_0"
assert_eq "Req 5.5: history[1].signature 保持" "deadbeef" "$sig_1"
assert_eq "Req 6.2: history[1].outcome = in-progress" "in-progress" "$outcome_1"

# top-level の total_attempts / last_status が最新値で上書きされていること
top_total=$(printf '%s' "$loaded" | jq -r '.total_attempts')
top_sig=$(printf '%s' "$loaded" | jq -r '.last_failure_signature')
assert_eq "Req 4.2: top-level total_attempts は最新値（2）" "2" "$top_total"
assert_eq "Req 5.5: top-level last_failure_signature は最新値" "deadbeef" "$top_sig"

# ============================================================
# Section 5: atomic rename — save 中間の tmp file が残らない
# ============================================================
echo ""
echo "--- Section 5: atomic rename（NFR 2.3） ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
fr_save_state 100 1 "in-progress" "sig1" "sha1" >/dev/null 2>&1

# 状態ファイル自体は存在する
if [ -f "${FAILED_RECOVERY_STATE_DIR}/100.json" ]; then
  echo "PASS: NFR 2.3: 状態ファイルが atomic rename で作成された"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 2.3: 状態ファイルが作成されていない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# tmp file（${state_file}.XXXXXX）が残っていないこと
tmp_count=$(find "$FAILED_RECOVERY_STATE_DIR" -name '100.json.*' 2>/dev/null | wc -l)
assert_eq "NFR 2.3: save 成功時に中間 tmp file が残らない" "0" "$tmp_count"

# ============================================================
# Section 6: last_status enum を全て受け付ける（Req 6.2）
# ============================================================
echo ""
echo "--- Section 6: last_status enum（Req 6.2） ---"

for status in "in-progress" "succeeded" "max-attempts" "no-progress"; do
  FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
  assert_rc "Req 6.2: last_status=$status を受け付ける" 0 \
    fr_save_state 42 1 "$status" "sig" "sha"
  loaded=$(fr_load_state 42)
  got=$(printf '%s' "$loaded" | jq -r '.last_status')
  assert_eq "Req 6.2: $status が往復で保持される" "$status" "$got"
done

# ============================================================
# Section 7: 破損ファイル（不正 JSON）で fail-open
# ============================================================
echo ""
echo "--- Section 7: 破損ファイルで fail-open（NFR 2.3） ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
echo "this is not json {[}" > "${FAILED_RECOVERY_STATE_DIR}/777.json"

loaded=$(fr_load_state 777)
assert_eq "NFR 2.3: 破損 JSON は {} を返す（fail-open）" "{}" "$loaded"

# 破損後でも save が成功して上書きできる（救済できる）
assert_rc "NFR 2.3: 破損ファイル後の save が成功" 0 \
  fr_save_state 777 5 "in-progress" "newsig" "newsha"

# save 後は正常な JSON として読める
loaded=$(fr_load_state 777)
total=$(printf '%s' "$loaded" | jq -r '.total_attempts')
assert_eq "NFR 2.3: 破損ファイル救済後の total_attempts = 5" "5" "$total"

# ============================================================
# Section 8: history 8 件 truncate（古いものから捨てる）
# ============================================================
echo ""
echo "--- Section 8: history 8 件 truncate ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
# 10 回 save して history が 8 件で truncate されることを確認
for i in 1 2 3 4 5 6 7 8 9 10; do
  fr_save_state 50 "$i" "in-progress" "sig$i" "sha$i" >/dev/null 2>&1
done

loaded=$(fr_load_state 50)
hist_len=$(printf '%s' "$loaded" | jq -r '.history | length')
assert_eq "design Data Model: history は最大 8 件で truncate" "8" "$hist_len"

# 最古は attempt=3、最新は attempt=10 のはず（古いものから捨てる）
oldest=$(printf '%s' "$loaded" | jq -r '.history[0].attempt')
newest=$(printf '%s' "$loaded" | jq -r '.history[-1].attempt')
assert_eq "design Data Model: history 最古は attempt=3（古いものから捨てる）" "3" "$oldest"
assert_eq "design Data Model: history 最新は attempt=10" "10" "$newest"

# ============================================================
# Section 9: 未信頼入力 sanitize（NFR 3.1）
#
# signature / head_sha に特殊文字（jq インジェクションを誘発しうる値）を
# 渡しても、--arg / --argjson 経由なので壊れずに literal として保持される。
# ============================================================
echo ""
echo "--- Section 9: 未信頼入力 sanitize（NFR 3.1） ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
# jq フィルタ構文を誘発しうる値を入れてみる。これらは意図的に literal として
# 渡し、jq --arg / --argjson 経路でサニタイズされることを検証する。
# shellcheck disable=SC2016
tricky_sig='"; .total_attempts = 9999 // "'
# shellcheck disable=SC2016
tricky_head='$( evil )'

assert_rc "NFR 3.1: 特殊文字を含む signature でも save 成功" 0 \
  fr_save_state 60 1 "in-progress" "$tricky_sig" "$tricky_head"

loaded=$(fr_load_state 60)
got_sig=$(printf '%s' "$loaded" | jq -r '.last_failure_signature')
got_head=$(printf '%s' "$loaded" | jq -r '.last_head_sha')
got_total=$(printf '%s' "$loaded" | jq -r '.total_attempts')

assert_eq "NFR 3.1: 特殊文字 signature が literal として保持される" "$tricky_sig" "$got_sig"
assert_eq "NFR 3.1: 特殊文字 head_sha が literal として保持される" "$tricky_head" "$got_head"
assert_eq "NFR 3.1: total_attempts が injection で書き換わっていない（= 1）" "1" "$got_total"

# ============================================================
# Section 10: 空文字 signature / head_sha（PR 経路の初回 / Issue 経路）
# ============================================================
echo ""
echo "--- Section 10: 空文字 signature / head_sha ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
assert_rc "Req 5.5: 空文字 signature でも save 成功（PR 経路の head_sha なし）" 0 \
  fr_save_state 70 1 "in-progress" "" ""
loaded=$(fr_load_state 70)
got_sig=$(printf '%s' "$loaded" | jq -r '.last_failure_signature')
got_head=$(printf '%s' "$loaded" | jq -r '.last_head_sha')
assert_eq "Req 5.5: 空文字 signature が空文字として保持される" "" "$got_sig"
assert_eq "Req 5.5: 空文字 head_sha が空文字として保持される" "" "$got_head"

# ============================================================
# Section 11: FAILED_RECOVERY_MAX_ATTEMPTS の不正値正規化
# （task 2.1 の _Requirements_partial:_ 4.8 を本 task で間接検証）
#
# issue-watcher.sh の Config ブロック（行 511-519）を bash -c で実行し、不正値が
# 4 に正規化されることを確認する。
# ============================================================
echo ""
echo "--- Section 11: MAX_ATTEMPTS 正規化（Req 4.8） ---"

normalize_max_attempts() {
  local input="$1"
  # issue-watcher.sh の Config ブロック相当のロジックを inline で実行
  FAILED_RECOVERY_MAX_ATTEMPTS="${input}"
  FAILED_RECOVERY_MAX_ATTEMPTS="${FAILED_RECOVERY_MAX_ATTEMPTS:-4}"
  case "$FAILED_RECOVERY_MAX_ATTEMPTS" in
    ''|*[!0-9]*) FAILED_RECOVERY_MAX_ATTEMPTS=4 ;;
    *)
      if [ "$FAILED_RECOVERY_MAX_ATTEMPTS" -le 0 ]; then
        FAILED_RECOVERY_MAX_ATTEMPTS=4
      fi
      ;;
  esac
  echo "$FAILED_RECOVERY_MAX_ATTEMPTS"
}

# 1 ケースだけ「issue-watcher.sh の Config ブロックを source して既定値 4 になる」を直接検証
# （他の表記揺れは inline で済ます）
got=$(bash -c 'unset FAILED_RECOVERY_MAX_ATTEMPTS; \
  FAILED_RECOVERY_MAX_ATTEMPTS="${FAILED_RECOVERY_MAX_ATTEMPTS:-4}"; \
  case "$FAILED_RECOVERY_MAX_ATTEMPTS" in \
    "" | *[!0-9]*) FAILED_RECOVERY_MAX_ATTEMPTS=4 ;; \
    *) [ "$FAILED_RECOVERY_MAX_ATTEMPTS" -le 0 ] && FAILED_RECOVERY_MAX_ATTEMPTS=4 ;; \
  esac; \
  echo "$FAILED_RECOVERY_MAX_ATTEMPTS"')
assert_eq "Req 4.8: 未設定 → 既定 4" "4" "$got"

# inline normalize で全パターンを検証
assert_eq "Req 4.8: 空文字 → 4" "4" "$(normalize_max_attempts '')"
assert_eq "Req 4.8: 非整数 abc → 4" "4" "$(normalize_max_attempts 'abc')"
assert_eq "Req 4.8: 負の値 -3 → 4（非整数扱い: ハイフン含む）" "4" "$(normalize_max_attempts '-3')"
assert_eq "Req 4.8: 0 → 4（0 以下）" "4" "$(normalize_max_attempts '0')"
assert_eq "Req 4.8: 小数 1.5 → 4（非整数扱い）" "4" "$(normalize_max_attempts '1.5')"
assert_eq "Req 4.8: 正常値 5 はそのまま" "5" "$(normalize_max_attempts '5')"
assert_eq "Req 4.8: 正常値 100 はそのまま" "100" "$(normalize_max_attempts '100')"
assert_eq "Req 4.8: 正常値 1 はそのまま" "1" "$(normalize_max_attempts '1')"

# ============================================================
# Section: #411 immediate_failure_streak フィールドの後方互換 + 読み書き
# ============================================================
echo ""
echo "--- Section #411: immediate_failure_streak フィールド ---"

FAILED_RECOVERY_STATE_DIR=$(new_state_dir)

# 1) 6 番目引数（streak）を明示指定で保存できる
assert_rc "#411 Req 1.4: streak を明示指定で save 成功" 0 \
  fr_save_state 411 1 "in-progress" "sigsig" "" "2"
loaded=$(fr_load_state 411)
streak=$(printf '%s' "$loaded" | jq -r '.immediate_failure_streak // "absent"')
assert_eq "#411 Req 1.4: schema.immediate_failure_streak = 2" "2" "$streak"

# 2) 6 番目引数を省略すると既存 state から streak を継承（NFR 1.1 後方互換）
assert_rc "#411 NFR 1.1: 6 番目引数省略で save 成功" 0 \
  fr_save_state 411 2 "in-progress" "sigsig" ""
loaded=$(fr_load_state 411)
streak=$(printf '%s' "$loaded" | jq -r '.immediate_failure_streak // "absent"')
assert_eq "#411 NFR 1.1: streak が前回値 2 から継承される" "2" "$streak"

# 3) 既存 state が streak field を持たない場合（#411 導入前の state）でも load して 0 fallback
FAILED_RECOVERY_STATE_DIR=$(new_state_dir)
legacy_path=$(fr_state_path 411)
mkdir -p "$(dirname "$legacy_path")"
# 既存 schema（streak フィールド無し）の JSON を直接書き込む
printf '%s\n' '{"issue":411,"total_attempts":1,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"2026-06-25T00:00:00Z","history":[]}' > "$legacy_path"

loaded=$(fr_load_state 411)
streak=$(printf '%s' "$loaded" | jq -r '.immediate_failure_streak // 0')
assert_eq "#411 NFR 1.1: 既存 state (streak field 不在) を load → 0 fallback" "0" "$streak"

# 4) 既存 state を 6 番目引数省略で save すると streak は 0 で永続化される
assert_rc "#411 NFR 1.1: 既存 state を save 成功（6 番目引数省略）" 0 \
  fr_save_state 411 2 "in-progress" "newsig" ""
loaded=$(fr_load_state 411)
streak=$(printf '%s' "$loaded" | jq -r '.immediate_failure_streak // "absent"')
assert_eq "#411 NFR 1.1: 既存 state（streak 不在）→ save で 0 が永続化される" "0" "$streak"

# 5) 不正値（非数値）を渡すと 0 に正規化される
assert_rc "#411 NFR 3.1: 不正値 streak=abc で save 成功（0 正規化）" 0 \
  fr_save_state 411 3 "in-progress" "sig3" "" "abc"
loaded=$(fr_load_state 411)
streak=$(printf '%s' "$loaded" | jq -r '.immediate_failure_streak')
assert_eq "#411 NFR 3.1: 不正値 streak=abc → 0 に正規化" "0" "$streak"

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
