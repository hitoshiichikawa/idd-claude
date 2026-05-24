#!/usr/bin/env bash
# =============================================================================
# idd-claude #200: Dispatcher 候補ソート（FIFO + hotfix 優先）スモークテスト
#
# 用途: issue-watcher.sh の _dispatcher_run 内で使用する「2 クエリ結合 + 2 段
#       ソート」jq ロジックが、hotfix ティア優先 + 各ティア内 Issue 番号昇順を
#       返すことを固定 fixture で検証する。limit 境界をまたぐケースを含む。
# 配置: docs/specs/200-feat-watcher-dispatcher-fifo-hotfix/test-order.sh
# 依存: jq
# 実行: bash docs/specs/200-feat-watcher-dispatcher-fifo-hotfix/test-order.sh
# 注意: issue-watcher.sh 本体の jq 式とロジックを一致させること（本体変更時に追従）。
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/test-fixtures"
LABEL_HOTFIX="hotfix"

PASS=0
FAIL=0

# 本体 (_dispatcher_run) と同一の結合 + 2 段ソート jq ロジック。
order_issues() {
  local hotfix_issues="$1"
  local all_issues="$2"
  local limit="$3"
  jq -c -n \
    --argjson limit "$limit" \
    --arg hotfix "$LABEL_HOTFIX" \
    --slurpfile hf <(printf '%s' "$hotfix_issues") \
    --slurpfile al <(printf '%s' "$all_issues") '
    ([ $hf[0][]?, $al[0][]? ])
    | map(. + { _is_hotfix: ((.labels // []) | map(.name) | index($hotfix) != null) })
    | unique_by(.number)
    | sort_by([ (if ._is_hotfix then 0 else 1 end), .number ])
    | .[0:$limit]
    | map(del(._is_hotfix))
  '
}

assert_order() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label -> $actual"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

numbers_of() { echo "$1" | jq -c 'map(.number)'; }

echo "== #200 dispatcher ordering smoke test =="

# --- Case A: hotfix 混在 + ラベル欠落/null を含む。limit 5 で切り詰め ---
# 期待: hotfix ティア (120, 305) を番号昇順で先頭に置き（Req 2.1/2.3）、続いて
# 非 hotfix を番号昇順 (50, 201, 202)。203 は limit=5 で切り落とされる。
# 結合母集合は 120/305(hotfix) + 50/201/202/203(normal) = 6 件 → 先頭 5 件。
hf_a="$(cat "$FIX/hotfix-query.json")"
al_a="$(cat "$FIX/all-query.json")"
res_a="$(order_issues "$hf_a" "$al_a" 5)"
assert_order "A: hotfix 優先 + tier 内番号昇順 (limit 5)" '[120,305,50,201,202]' "$(numbers_of "$res_a")"

# --- Case B: limit 2 切り詰め。hotfix ティアが先頭を占める（Req 2.1/3.1）---
# 期待: hotfix 120, 305 が番号昇順で先頭 2 件を占有する。これにより、母集団切り出しが
# あっても本来優先される hotfix（最古含む）が取りこぼされない（Req 3.2）。
res_b="$(order_issues "$hf_a" "$al_a" 2)"
assert_order "B: limit 2 で hotfix ティアが先頭占有 (Req 2.1/3.1/3.2)" '[120,305]' "$(numbers_of "$res_b")"

# --- Case C: hotfix なし → 全候補を番号昇順（Req 1.2）---
hf_c='[]'
al_c='[
  { "number": 9, "labels": [ { "name": "auto-dev" } ] },
  { "number": 3, "labels": [ { "name": "auto-dev" } ] },
  { "number": 7, "labels": [ { "name": "auto-dev" } ] }
]'
res_c="$(order_issues "$hf_c" "$al_c" 5)"
assert_order "C: hotfix 不在は全件番号昇順 (Req 1.2)" '[3,7,9]' "$(numbers_of "$res_c")"

# --- Case D: 複数 hotfix は hotfix 同士でも番号昇順（Req 2.3）---
hf_d='[
  { "number": 88, "labels": [ { "name": "auto-dev" }, { "name": "hotfix" } ] },
  { "number": 40, "labels": [ { "name": "auto-dev" }, { "name": "hotfix" } ] }
]'
al_d='[
  { "number": 88, "labels": [ { "name": "auto-dev" }, { "name": "hotfix" } ] },
  { "number": 40, "labels": [ { "name": "auto-dev" }, { "name": "hotfix" } ] },
  { "number": 12, "labels": [ { "name": "auto-dev" } ] }
]'
res_d="$(order_issues "$hf_d" "$al_d" 5)"
assert_order "D: 複数 hotfix も番号昇順 + 非 hotfix 後置 (Req 2.3/2.1)" '[40,88,12]' "$(numbers_of "$res_d")"

# --- Case E: ラベル情報欠落/null は非 hotfix 扱い（Req 2.4 安全側）---
hf_e='[]'
al_e='[
  { "number": 5 },
  { "number": 2, "labels": null },
  { "number": 8, "labels": [ { "name": "hotfix" } ] }
]'
res_e="$(order_issues "$hf_e" "$al_e" 5)"
# 8 は all クエリにのみ現れる hotfix だが、hotfix 専用クエリ結果が空でも all 側で
# _is_hotfix=true と判定され先頭に来る。2/5 は非 hotfix 番号昇順。
assert_order "E: labels 欠落/null は非 hotfix + all 側 hotfix 判定 (Req 2.4)" '[8,2,5]' "$(numbers_of "$res_e")"

# --- Case F: 決定性（同一入力で同一順序、NFR 2.1）---
res_f1="$(order_issues "$hf_a" "$al_a" 5)"
res_f2="$(order_issues "$hf_a" "$al_a" 5)"
assert_order "F: 決定性 (NFR 2.1)" "$(numbers_of "$res_f1")" "$(numbers_of "$res_f2")"

echo ""
echo "== 結果: PASS=$PASS FAIL=$FAIL =="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
