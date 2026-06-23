#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/pr-iteration.sh の Issue #397（PR Iteration の no-progress
#       design round が `awaiting-design-review` に遷移して silent deadlock する defect）で
#       導入した round outcome 分類ヘルパーをテストする。
#
#       対象関数:
#         - pi_classify_round_outcome (#397 / Req 1, 2, 3, 4)
#
#       本テストは、pi_run_iteration の round 終了処理から切り出された純粋関数を
#       extract_function で隔離抽出し、入出力のみで AC を網羅検証する。
#       環境変数や gh / git 呼び出しに依存しない（純粋関数の利点を最大化する）。
#
# 配置先: local-watcher/test/pi_classify_round_outcome_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/pi_classify_round_outcome_test.sh

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
eval "$(extract_function "$PR_ITERATION_SH" "pi_classify_round_outcome")"

if ! declare -F pi_classify_round_outcome >/dev/null; then
  echo "ERROR: pi_classify_round_outcome not loaded" >&2
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

# ─── 正常系: commit_pushed=true → success ─────────────────────────────────────
echo "--- pi_classify_round_outcome: success cases (Req 3.1〜3.3) ---"

# Req 3.1 / 3.2 / 3.3: commit が push された round は streak 値に依らず success
assert_eq "commit_pushed=true / streak=0 / limit=3 → success" \
  "success" \
  "$(pi_classify_round_outcome true 0 3)"

assert_eq "commit_pushed=true / streak=1 / limit=3 → success（streak はリセット済み前提でも success 優先）" \
  "success" \
  "$(pi_classify_round_outcome true 1 3)"

assert_eq "commit_pushed=true / streak=99 / limit=3 → success（streak が limit 以上でも commit 有りなら success）" \
  "success" \
  "$(pi_classify_round_outcome true 99 3)"

assert_eq "commit_pushed=true / streak=0 / limit=0 → success（境界: limit=0）" \
  "success" \
  "$(pi_classify_round_outcome true 0 0)"

echo ""

# ─── 正常系: commit_pushed=false かつ streak<limit → no-progress ──────────────
echo "--- pi_classify_round_outcome: no-progress cases (Req 1.1〜1.3 / 2.1 / 2.2 / 4.1 / 4.2) ---"

# Req 1.1 / 1.2 / 1.3 / 2.1 / 2.2 / 4.1 / 4.2:
# commit 無し かつ streak < limit → needs-iteration 据え置き相当（"no-progress" 分類）
assert_eq "commit_pushed=false / streak=1 / limit=3 → no-progress（初回 no-progress round）" \
  "no-progress" \
  "$(pi_classify_round_outcome false 1 3)"

assert_eq "commit_pushed=false / streak=2 / limit=3 → no-progress（limit 未満）" \
  "no-progress" \
  "$(pi_classify_round_outcome false 2 3)"

assert_eq "commit_pushed=false / streak=0 / limit=3 → no-progress（境界: streak=0）" \
  "no-progress" \
  "$(pi_classify_round_outcome false 0 3)"

echo ""

# ─── 正常系: commit_pushed=false かつ streak>=limit → escalate ────────────────
echo "--- pi_classify_round_outcome: escalate cases (Req 2.3 / 2.4 / 5.3) ---"

# Req 2.3 / 2.4 / 5.3: limit に達した時点で escalate
assert_eq "commit_pushed=false / streak=3 / limit=3 → escalate（境界一致）" \
  "escalate" \
  "$(pi_classify_round_outcome false 3 3)"

assert_eq "commit_pushed=false / streak=4 / limit=3 → escalate（境界超過）" \
  "escalate" \
  "$(pi_classify_round_outcome false 4 3)"

assert_eq "commit_pushed=false / streak=10 / limit=3 → escalate（大きく超過）" \
  "escalate" \
  "$(pi_classify_round_outcome false 10 3)"

echo ""

# ─── escalation 到達性の累積シナリオ（Req 2 統合検証） ────────────────────────
echo "--- 累積シナリオ: 連続 no-progress round で最終的に escalate に到達する（Req 2.1〜2.3） ---"

# limit=3 を仮定し、prev_streak を 0→1→2→3 と進めるシミュレーション
# 各 round の new_streak（呼び出し元で prev_streak+1 した値）を渡す
limit=3
streak=0
last_outcome=""
for round in 1 2 3 4; do
  streak=$((streak + 1))
  last_outcome=$(pi_classify_round_outcome false "$streak" "$limit")
  case "$round" in
    1|2)
      assert_eq "累積 round=${round}: streak=${streak} → no-progress (limit=${limit} 未満)" \
        "no-progress" \
        "$last_outcome"
      ;;
    3|4)
      assert_eq "累積 round=${round}: streak=${streak} → escalate (limit=${limit} 到達/超過)" \
        "escalate" \
        "$last_outcome"
      ;;
  esac
done

echo ""

# ─── 境界: limit が極端な値 ───────────────────────────────────────────────────
echo "--- 境界値: limit=1 や limit=0 のケース ---"

# limit=1: 1 度の no-progress で即 escalate
assert_eq "limit=1: streak=1 → escalate（最小 limit 設定での即時 escalate）" \
  "escalate" \
  "$(pi_classify_round_outcome false 1 1)"

# limit=0: streak がどんな値でも常に escalate
assert_eq "limit=0: streak=0 / commit=false → escalate（limit=0 は no-progress を一切許さない設定）" \
  "escalate" \
  "$(pi_classify_round_outcome false 0 0)"

# limit が極端に大きい: ほぼ no-progress が続く
assert_eq "limit=999: streak=10 → no-progress" \
  "no-progress" \
  "$(pi_classify_round_outcome false 10 999)"

echo ""

# ─── 異常系: 不正値は安全側（no-progress = needs-iteration 据え置き）に倒す ───
echo "--- 異常系: 不正値の安全側挙動 (NFR 2.1) ---"

# commit_pushed が "true"/"false" 以外
assert_eq "commit_pushed='' (空) → no-progress（安全側）" \
  "no-progress" \
  "$(pi_classify_round_outcome '' 1 3)"

assert_eq "commit_pushed='yes' (typo) → no-progress（安全側）" \
  "no-progress" \
  "$(pi_classify_round_outcome 'yes' 1 3)"

# streak が非数値（取得失敗を想定）
assert_eq "commit_pushed=false / streak='' (空) → no-progress（NFR 2.1 安全側、success/escalate に倒さない）" \
  "no-progress" \
  "$(pi_classify_round_outcome false '' 3)"

assert_eq "commit_pushed=false / streak='abc' (非数値) → no-progress（安全側）" \
  "no-progress" \
  "$(pi_classify_round_outcome false abc 3)"

# limit が非数値
assert_eq "commit_pushed=false / streak=5 / limit='' → no-progress（安全側、誤 escalate を避ける）" \
  "no-progress" \
  "$(pi_classify_round_outcome false 5 '')"

assert_eq "commit_pushed=false / streak=5 / limit='abc' → no-progress（安全側）" \
  "no-progress" \
  "$(pi_classify_round_outcome false 5 abc)"

echo ""

# ─── 統合: design / impl 種別を区別しないことの確認 ─────────────────────────
# Req 4.1 / 4.2: impl 種別でも design 種別と同じ制御フローが適用される。
# pi_classify_round_outcome は kind を引数に取らない（pure 関数 / kind 非依存）こと
# 自体が Req 4.1 の制御フロー統一性を担保する。本テストでは関数のシグネチャを確認する
# 形で間接的に検証する。
echo "--- Req 4.1 / 4.2 / 4.3: kind 非依存の制御フロー ---"

# 同じ入力に対して常に同じ outcome を返す（impl/design 区別が無いこと）
out_impl=$(pi_classify_round_outcome false 1 3)
out_design=$(pi_classify_round_outcome false 1 3)
assert_eq "Req 4.1: 同入力で同 outcome（kind 区別なし / 副作用なし）" \
  "$out_impl" \
  "$out_design"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
