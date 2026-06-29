#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-iteration.sh の Issue #435（PR Iteration の Developer が
#       round 内で自分で commit せず auto-recovery commit に肩代わりさせる運用 / no-progress
#       誤判定の懸念）で固定する不変条件を回帰テストする。
#
#       対象関数（pi_run_iteration の round 終了処理から切り出した純粋関数）:
#         - pi_round_commit_pushed     (#435 Req 2.1〜2.3: SHA 比較 → 進捗あり/なし判定)
#         - pi_next_no_progress_streak (#435 Req 2.1〜2.3: 進捗あり=0 / 進捗なし=+1)
#
#       固定する不変条件（Issue #435 Req 2.1〜2.3 / NFR 2.1）:
#         - round 終了時 HEAD が round 開始時 HEAD と異なる → 進捗あり → streak=0  (Req 2.1)
#         - round 終了時 HEAD が round 開始時 HEAD と同じ     → 進捗なし → streak+1 (Req 2.2)
#         - auto-recovery commit で HEAD が進んだ場合も before≠after → 進捗あり → streak=0
#           （Developer 自身の commit と同等に扱う / Req 2.3）
#
#       切り分け結論（impl-notes.md 冒頭参照）: 現行コードは after_sha を
#       pi_auto_commit_and_push の「後」に採取しており（pr-iteration.sh の round ループ）、
#       auto-recovery commit が HEAD を変えれば commit_pushed=true → new_streak=0 に倒れる。
#       すなわち Req 2.1〜2.3 の不変条件は既に満たされている（Req 2.5）。本テストは挙動を
#       変えずにその不変条件を固定する。
#
#       本テストは pi_classify_round_outcome_test.sh と同じ extract_function イディオムで
#       対象純粋関数を隔離抽出し、入出力のみで検証する（gh / git / 環境変数に非依存）。
#
# 配置先: local-watcher/test/pi_no_progress_invariant_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pi_no_progress_invariant_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ITERATION_SH="$SCRIPT_DIR/../bin/modules/pr-iteration.sh"

if [ ! -f "$PR_ITERATION_SH" ]; then
  echo "ERROR: cannot find pr-iteration.sh at $PR_ITERATION_SH" >&2
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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_round_commit_pushed")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PR_ITERATION_SH" "pi_next_no_progress_streak")"

if ! declare -F pi_round_commit_pushed >/dev/null; then
  echo "ERROR: pi_round_commit_pushed not loaded" >&2
  exit 2
fi
if ! declare -F pi_next_no_progress_streak >/dev/null; then
  echo "ERROR: pi_next_no_progress_streak not loaded" >&2
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

# 40 桁の擬似 SHA（実 git に依存しないテスト用の固定値）
SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ─── Req 2.1: HEAD が変化したら進捗あり（commit_pushed=true） ──────────────────
echo "--- pi_round_commit_pushed: HEAD 変化あり → progress (Req 2.1 / 2.3) ---"

assert_eq "before≠after（Developer 自身の commit で HEAD 前進）→ true" \
  "true" \
  "$(pi_round_commit_pushed "$SHA_A" "$SHA_B")"

# Req 2.3: auto-recovery commit でも after は recovery commit の後に採取されるため
# before≠after になり、Developer 自身の commit と同様に true。
assert_eq "before≠after（auto-recovery commit 経由で HEAD 前進）→ true（Req 2.3）" \
  "true" \
  "$(pi_round_commit_pushed "$SHA_A" "$SHA_B")"

echo ""

# ─── Req 2.2: HEAD が変化しなければ進捗なし（commit_pushed=false） ─────────────
echo "--- pi_round_commit_pushed: HEAD 変化なし → no-progress (Req 2.2) ---"

assert_eq "before==after（commit なし / dirty なし）→ false" \
  "false" \
  "$(pi_round_commit_pushed "$SHA_A" "$SHA_A")"

echo ""

# ─── 異常系: SHA 取得失敗（空）は安全側で false ───────────────────────────────
echo "--- pi_round_commit_pushed: SHA 取得失敗の安全側挙動 (NFR 2.1) ---"

assert_eq "before='' (取得失敗) → false（進捗ありに誤判定しない）" \
  "false" \
  "$(pi_round_commit_pushed "" "$SHA_B")"

assert_eq "after='' (取得失敗) → false（進捗ありに誤判定しない）" \
  "false" \
  "$(pi_round_commit_pushed "$SHA_A" "")"

assert_eq "before='' / after='' (両方取得失敗) → false" \
  "false" \
  "$(pi_round_commit_pushed "" "")"

echo ""

# ─── Req 2.1 / 2.3: 進捗あり → streak リセット ───────────────────────────────
echo "--- pi_next_no_progress_streak: progress → reset to 0 (Req 2.1 / 2.3) ---"

assert_eq "commit_pushed=true / prev=0 → 0（リセット維持）" \
  "0" \
  "$(pi_next_no_progress_streak true 0)"

assert_eq "commit_pushed=true / prev=2 → 0（蓄積 streak をリセット）" \
  "0" \
  "$(pi_next_no_progress_streak true 2)"

# Req 2.3: auto-recovery commit round（commit_pushed=true）も Developer 自身の commit と
# 同等に streak を 0 にリセットする。
assert_eq "commit_pushed=true / prev=99 → 0（auto-recovery 経由でも完全リセット / Req 2.3）" \
  "0" \
  "$(pi_next_no_progress_streak true 99)"

echo ""

# ─── Req 2.2: 進捗なし → streak 加算 ─────────────────────────────────────────
echo "--- pi_next_no_progress_streak: no-progress → +1 (Req 2.2) ---"

assert_eq "commit_pushed=false / prev=0 → 1（初回 no-progress）" \
  "1" \
  "$(pi_next_no_progress_streak false 0)"

assert_eq "commit_pushed=false / prev=1 → 2" \
  "2" \
  "$(pi_next_no_progress_streak false 1)"

assert_eq "commit_pushed=false / prev=2 → 3（limit 到達の手前まで加算が積み上がる）" \
  "3" \
  "$(pi_next_no_progress_streak false 2)"

echo ""

# ─── 異常系: prev_streak 取得失敗（非数値）の安全側挙動 ──────────────────────
echo "--- pi_next_no_progress_streak: prev_streak 非数値の安全側挙動 (NFR 2.1) ---"

assert_eq "commit_pushed=false / prev='' → 1（0 起点で加算、巨大値で誤 escalate しない）" \
  "1" \
  "$(pi_next_no_progress_streak false "")"

assert_eq "commit_pushed=false / prev='abc' → 1（非数値は 0 起点 +1）" \
  "1" \
  "$(pi_next_no_progress_streak false abc)"

# commit_pushed=true は prev_streak の値に依らず常に 0（非数値でも 0）
assert_eq "commit_pushed=true / prev='abc' → 0（true は prev に依らず常にリセット）" \
  "0" \
  "$(pi_next_no_progress_streak true abc)"

echo ""

# ─── 統合: SHA 比較 → streak 更新の連鎖を通した不変条件（Req 2 統合） ─────────
echo "--- 統合シナリオ: SHA 比較 → streak 更新の連鎖 (Req 2.1〜2.3) ---"

# シナリオ A（Req 2.1）: HEAD 前進した round で蓄積 streak がリセットされる
cp_a=$(pi_round_commit_pushed "$SHA_A" "$SHA_B")
assert_eq "A: HEAD 前進 → commit_pushed=true" "true" "$cp_a"
assert_eq "A: commit_pushed=true / prev=2 → streak=0（Req 2.1）" \
  "0" \
  "$(pi_next_no_progress_streak "$cp_a" 2)"

# シナリオ B（Req 2.2）: HEAD 不変 round で streak が加算される
cp_b=$(pi_round_commit_pushed "$SHA_A" "$SHA_A")
assert_eq "B: HEAD 不変 → commit_pushed=false" "false" "$cp_b"
assert_eq "B: commit_pushed=false / prev=1 → streak=2（Req 2.2）" \
  "2" \
  "$(pi_next_no_progress_streak "$cp_b" 1)"

# シナリオ C（Req 2.3）: auto-recovery commit 経由でも after≠before → reset
# after_sha は pi_auto_commit_and_push の後に採取されるため、auto-recovery で HEAD が
# 進めば before≠after となり、Developer 自身の commit と同等に streak=0 になる。
cp_c=$(pi_round_commit_pushed "$SHA_A" "$SHA_B")
assert_eq "C: auto-recovery commit で HEAD 前進 → commit_pushed=true" "true" "$cp_c"
assert_eq "C: commit_pushed=true / prev=2 → streak=0（auto-recovery 経由でもリセット / Req 2.3）" \
  "0" \
  "$(pi_next_no_progress_streak "$cp_c" 2)"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
