#!/usr/bin/env bash
#
# 用途: Design PR Reviewer (#407) の parse / validate 関数群の挙動を検証する
#       スモークテスト。
#
#       検証対象関数:
#         - pdr_parse_verdict（text / JSON 両形式で verdict + 3 観点 reason を抽出）
#         - pdr_validate_verdict（schema 検証）
#
#       検証する受入基準（docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/requirements.md）:
#         - Req 2.2 3 観点いずれか違反で reject 検出
#         - Req 2.3 違反なしで approve 検出
#         - Req 2.4 parse 失敗時の保守的 approve fallback（呼び出し元責務、本テストでは
#           parse 失敗 → rc=1 を確認）
#         - Req 2.5 verdict + 3 観点 reason を 1:1 で出力する形式の検証
#
#       検証ケース:
#         text 形式:
#           T.1 全観点 approve + VERDICT: approve → rc=0 verdict=approve
#           T.2 1 観点 reject + VERDICT: reject → rc=0 verdict=reject
#           T.3 VERDICT 行不在 → rc=1（parse 失敗 / fallback シグナル）
#           T.4 VERDICT: foo（不正値）→ rc=1
#           T.5 装飾付き VERDICT 行（VERDICT: approve.） → 末尾文字で reject 検出失敗 → rc=1
#               （Req 2.4 装飾禁止規約と整合）
#           T.6 3 観点 reason 部分欠落 → rc=0 だが pdr_validate_verdict が rc=1
#         JSON 形式:
#           J.1 valid JSON approve → rc=0 verdict=approve
#           J.2 valid JSON reject → rc=0 verdict=reject
#           J.3 code fence で囲んだ JSON → rc=0（前置き散文 / fence の剥がし）
#           J.4 invalid JSON → fallback で text parse を試行（VERDICT 行不在で rc=1）
#
#       pdr_validate_verdict:
#           V.1 approve + 3 reason 揃い → rc=0
#           V.2 reject + 3 reason 揃い → rc=0
#           V.3 verdict 不正 → rc=1
#           V.4 reason 空 → rc=1
#
#       template 存在確認:
#           P.1 design-review-prompt.tmpl が存在し、9 プレースホルダが揃う
#
# 配置先: local-watcher/test/pdr_parse_verdict_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pdr_parse_verdict_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDR_SH="$SCRIPT_DIR/../bin/modules/pr-design-reviewer.sh"
TMPL_PATH="$SCRIPT_DIR/../bin/design-review-prompt.tmpl"

if [ ! -f "$PDR_SH" ]; then
  echo "ERROR: cannot find pr-design-reviewer.sh at $PDR_SH" >&2
  exit 2
fi

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
eval "$(extract_function "$PDR_SH" "pdr_parse_verdict")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PDR_SH" "pdr_validate_verdict")"

for fn in pdr_parse_verdict pdr_validate_verdict; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# pdr_warn stub: 静音化（test 内では呼ばれることがあっても assert 対象外）
# shellcheck disable=SC2317
pdr_warn() { :; }

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

# ─── P.1: template 存在 + 9 プレースホルダ確認 ────────────────────────────────
echo "--- P.1: design-review-prompt.tmpl の必須プレースホルダ揃いを確認 ---"
if [ -f "$TMPL_PATH" ]; then
  for ph in '{PR}' '{SHA}' '{BASE}' '{HEAD}' '{ISSUE_NUMBER}' '{SPEC_DIR}' '{REQUIREMENTS_MD}' '{DESIGN_MD}' '{TASKS_MD}'; do
    if grep -F -q "$ph" "$TMPL_PATH"; then
      echo "PASS: template に $ph が含まれる"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      echo "FAIL: template に $ph が含まれない"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
else
  echo "FAIL: template ファイル $TMPL_PATH が存在しない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ─── text 形式 ────────────────────────────────────────────────────────────────
echo ""
echo "--- text 形式（Req 2.2, 2.3, 2.4, 2.5） ---"

# T.1: 全観点 approve + VERDICT: approve
TEXT_APPROVE="## Design Review

### AC カバレッジ
- 該当: approve
- 根拠: 全 AC ID（1.1, 2.1）が design.md / tasks.md でカバーされている。

### design⇄tasks 整合
- 該当: approve
- 根拠: Components が tasks.md の _Boundary:_ に反映されている。

### Traceability
- 該当: approve
- 根拠: tasks.md の _Requirements:_ が requirements.md に実在する ID のみを参照している。

## Verdict
VERDICT: approve"

rc=0
tsv=$(printf '%s' "$TEXT_APPROVE" | pdr_parse_verdict text) || rc=$?
verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
ac_r=$(printf '%s' "$tsv" | awk -F'\t' '{print $2}')
dt_r=$(printf '%s' "$tsv" | awk -F'\t' '{print $3}')
tr_r=$(printf '%s' "$tsv" | awk -F'\t' '{print $4}')
assert_eq "T.1: rc=0" "0" "$rc"
assert_eq "T.1: verdict=approve" "approve" "$verdict"
assert_eq "T.1: ac_reason 抽出（先頭部一致）" "全 AC ID（1.1, 2.1）が design.md / tasks.md でカバーされている。" "$ac_r"
assert_eq "T.1: dt_reason 抽出" "Components が tasks.md の _Boundary:_ に反映されている。" "$dt_r"
assert_eq "T.1: tr_reason 抽出" "tasks.md の _Requirements:_ が requirements.md に実在する ID のみを参照している。" "$tr_r"

# T.2: 1 観点 reject + VERDICT: reject
TEXT_REJECT="## Design Review

### AC カバレッジ
- 該当: reject
- 根拠: requirements.md の 2.4 が design.md / tasks.md のいずれにも現れていない。

### design⇄tasks 整合
- 該当: approve
- 根拠: 全 Components が反映されている。

### Traceability
- 該当: approve
- 根拠: 全 ID が実在する。

## Verdict
VERDICT: reject"

rc=0
tsv=$(printf '%s' "$TEXT_REJECT" | pdr_parse_verdict text) || rc=$?
verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
assert_eq "T.2: rc=0" "0" "$rc"
assert_eq "Req 2.2: verdict=reject" "reject" "$verdict"

# T.3: VERDICT 行不在 → rc=1
TEXT_NO_VERDICT="## Design Review

### AC カバレッジ
- 該当: approve
- 根拠: cover

### design⇄tasks 整合
- 該当: approve
- 根拠: align

### Traceability
- 該当: approve
- 根拠: trace"

rc=0
_=$(printf '%s' "$TEXT_NO_VERDICT" | pdr_parse_verdict text) || rc=$?
assert_eq "Req 2.4: T.3 VERDICT 行不在 → rc=1 (parse 失敗 / 保守的 approve fallback シグナル)" "1" "$rc"

# T.4: VERDICT: foo 不正値 → rc=1
TEXT_INVALID="## Design Review
### AC カバレッジ
- 該当: approve
- 根拠: foo
### design⇄tasks 整合
- 該当: approve
- 根拠: bar
### Traceability
- 該当: approve
- 根拠: baz
## Verdict
VERDICT: foo"

rc=0
_=$(printf '%s' "$TEXT_INVALID" | pdr_parse_verdict text) || rc=$?
assert_eq "T.4: VERDICT 不正値 → rc=1" "1" "$rc"

# T.5: 装飾付き VERDICT（末尾ピリオド） → 末尾文字で reject → rc=0 で extract できる
# 規約上は末尾装飾禁止だが、grep の word boundary（`[^[:alnum:]_]|$`）で `approve.` の
# `.` を境界扱いで approve を抽出する。これは Reviewer の prompt 上の装飾禁止規約と独立に、
# parse 側は寛容に倒す設計（impl 用 parse_review_result と同方針）。
TEXT_DECOR="## Design Review
### AC カバレッジ
- 該当: approve
- 根拠: cover
### design⇄tasks 整合
- 該当: approve
- 根拠: align
### Traceability
- 該当: approve
- 根拠: trace
## Verdict
VERDICT: approve."

rc=0
tsv=$(printf '%s' "$TEXT_DECOR" | pdr_parse_verdict text) || rc=$?
verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
assert_eq "T.5: 装飾付き VERDICT → rc=0（parse 寛容）" "0" "$rc"
assert_eq "T.5: verdict=approve 抽出" "approve" "$verdict"

# T.6: 3 観点 reason 一部欠落 → parse は rc=0 だが validate が rc=1
TEXT_PARTIAL="## Design Review

### AC カバレッジ
- 該当: approve

### design⇄tasks 整合
- 該当: approve

### Traceability
- 該当: approve

## Verdict
VERDICT: approve"

rc=0
tsv=$(printf '%s' "$TEXT_PARTIAL" | pdr_parse_verdict text) || rc=$?
verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
ac_r=$(printf '%s' "$tsv" | awk -F'\t' '{print $2}')
assert_eq "T.6: rc=0（VERDICT 行はある）" "0" "$rc"
assert_eq "T.6: verdict=approve" "approve" "$verdict"
assert_eq "T.6: ac_reason は空（根拠行不在）" "" "$ac_r"

# pdr_validate_verdict は 3 観点 reason 空で rc=1
rc=0
pdr_validate_verdict "approve" "" "" "" || rc=$?
assert_eq "Req 2.5: T.6' validate: 3 観点 reason 空 → rc=1" "1" "$rc"

# ─── JSON 形式 ──────────────────────────────────────────────────────────────
echo ""
echo "--- JSON 形式（Req 2.2, 2.3, 2.4） ---"

JSON_APPROVE='{"verdict":"approve","ac_coverage":{"result":"approve","reason":"全 AC カバー"},"design_tasks_alignment":{"result":"approve","reason":"全 Components 反映"},"traceability":{"result":"approve","reason":"全 ID 実在"}}'
rc=0
tsv=$(printf '%s' "$JSON_APPROVE" | pdr_parse_verdict json) || rc=$?
verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
ac_r=$(printf '%s' "$tsv" | awk -F'\t' '{print $2}')
assert_eq "J.1: rc=0" "0" "$rc"
assert_eq "Req 2.3: J.1 verdict=approve" "approve" "$verdict"
assert_eq "J.1: ac_reason 抽出" "全 AC カバー" "$ac_r"

JSON_REJECT='{"verdict":"reject","ac_coverage":{"result":"reject","reason":"AC 2.4 未カバー"},"design_tasks_alignment":{"result":"approve","reason":"OK"},"traceability":{"result":"approve","reason":"OK"}}'
rc=0
tsv=$(printf '%s' "$JSON_REJECT" | pdr_parse_verdict json) || rc=$?
verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
assert_eq "Req 2.2: J.2 verdict=reject" "reject" "$verdict"

# J.3: code fence で囲んだ JSON
JSON_FENCED='前置きの散文
```json
{"verdict":"approve","ac_coverage":{"result":"approve","reason":"カバー OK"},"design_tasks_alignment":{"result":"approve","reason":"整合 OK"},"traceability":{"result":"approve","reason":"trace OK"}}
```
後書き'
rc=0
tsv=$(printf '%s' "$JSON_FENCED" | pdr_parse_verdict json) || rc=$?
verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
assert_eq "J.3: 装飾 + fence ある JSON → verdict 抽出可能" "approve" "$verdict"

# J.4: invalid JSON で text fallback も VERDICT 不在 → rc=1
JSON_INVALID="not a json at all"
rc=0
_=$(printf '%s' "$JSON_INVALID" | pdr_parse_verdict json) || rc=$?
assert_eq "Req 2.4: J.4 invalid JSON + text fallback 失敗 → rc=1（保守的 approve fallback シグナル）" "1" "$rc"

# ─── pdr_validate_verdict ───────────────────────────────────────────────────
echo ""
echo "--- pdr_validate_verdict（Req 2.5） ---"

rc=0
pdr_validate_verdict "approve" "ok1" "ok2" "ok3" || rc=$?
assert_eq "V.1: approve + 3 reason 揃い → rc=0" "0" "$rc"

rc=0
pdr_validate_verdict "reject" "r1" "r2" "r3" || rc=$?
assert_eq "V.2: reject + 3 reason 揃い → rc=0" "0" "$rc"

rc=0
pdr_validate_verdict "foo" "r1" "r2" "r3" || rc=$?
assert_eq "Req 2.5: V.3 verdict 不正 → rc=1" "1" "$rc"

rc=0
pdr_validate_verdict "approve" "" "r2" "r3" || rc=$?
assert_eq "Req 2.5: V.4 reason 空 → rc=1" "1" "$rc"

echo ""
echo "================================"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
