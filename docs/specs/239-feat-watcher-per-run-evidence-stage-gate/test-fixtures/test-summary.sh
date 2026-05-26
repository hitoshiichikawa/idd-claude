#!/usr/bin/env bash
# test-summary.sh — run-summary.sh の rs_* / rs_emit ロジック隔離スモークテスト（Issue #239）
#
# 用途:
#   local-watcher/bin/modules/run-summary.sh を単体 source して、rs_* 記録関数を直接
#   呼び、rs_emit が出力する `run-summary:` 1 行を grep assert する。watcher 本体の起動は
#   行わず、emitter のコアロジック（1 行整形・enum 語彙・フェイルセーフ・無効化）のみを
#   隔離して回帰確認する。本スクリプトは tasks.md の `## Verify` 構造化ブロック
#   （stage-a-verify gate の input 契約）が Stage A 実装フェーズで再実行する必須対象であり、
#   いずれかの assert が失敗したら非ゼロ exit する（silent fail 禁止）。
#
# 検証ケース（design.md「Testing Strategy」L424-433 を正本とする 5 ケース）:
#   1. impl 正常        : stages=A,B,C / reviewer=independent:approve:r1 / sav=success / result=ready-for-review
#   2. degraded         : reviewer=degraded:r1 / scaffolding=missing / errors=yes / result=claude-failed
#   3. design           : mode=design / reviewer=n/a（既定維持）
#   4. 未初期化フェイルセーフ: rs_init 後 rs_emit で既定値 1 行が出る（run-summary: prefix を含む）
#   5. 無効化            : RUN_SUMMARY_ENABLED=false rs_emit → 出力が空
#
# 配置先:
#   docs/specs/239-feat-watcher-per-run-evidence-stage-gate/test-fixtures/
#
# 依存:
#   - bash 4+ / date / grep（run-summary.sh が使う POSIX CLI のみ）
#   - 被テスト対象 run-summary.sh は本体から source される前提で `set -euo pipefail` を
#     宣言しないため、本 fixture 側で `set -euo pipefail` を宣言し source する。
#   - $REPO は rs_emit の prefix 整形にのみ使うため本 fixture 内で固定値を設定する
#     （rs_emit は ${REPO:-?} で防御済み）。$LOG は本テストでは使わない（ケース 2 は
#     rs_record_error を直接呼ぶため degraded スキャン不要）。
#
# 実行:
#   bash docs/specs/239-feat-watcher-per-run-evidence-stage-gate/test-fixtures/test-summary.sh
#   全ケース PASS で exit 0 / いずれか失敗で非ゼロ exit。

set -euo pipefail

# ── テスト対象モジュールの解決 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE="$REPO_ROOT/local-watcher/bin/modules/run-summary.sh"

if [ ! -f "$MODULE" ]; then
  echo "FATAL: モジュールが見つかりません: $MODULE" >&2
  exit 1
fi

# run-summary.sh は本体から source される前提（即時実行コードなし）。source 時に
# rs_* 関数定義のみをロードする。
# shellcheck source=local-watcher/bin/modules/run-summary.sh
# shellcheck disable=SC1091
source "$MODULE"

# rs_emit の prefix 整形にのみ使う。実 repo を参照しないダミー値。run-summary.sh が
# source 経由で遅延束縛参照するため shellcheck は未使用と誤判定する（SC2034 を抑制）。
# shellcheck disable=SC2034
REPO="owner/test"

# ── テストハーネス ──
PASS=0
FAIL=0
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
ok() { echo "  ok: $*"; PASS=$((PASS + 1)); }

# 1 行出力に部分文字列 $2 が含まれることを assert する。
# Args: $1 = 出力行 / $2 = 期待する部分文字列 / $3 = ケース説明
assert_contains() {
  local out="$1" want="$2" desc="$3"
  case "$out" in
    *"$want"*) ok "$desc — '$want' を含む" ;;
    *) fail "$desc — '$want' を含まない / 実出力: [$out]" ;;
  esac
}

# ── ケース 1: impl 正常 ──
# design.md L424-426: stages=A,B,C / reviewer=independent:approve:r1 / sav=success /
# scaffolding=ok / errors=no / result=ready-for-review
echo "[case 1] impl 正常"
rs_init
rs_set_mode impl
rs_record_stage A
rs_record_stage B
rs_record_stage C
rs_record_reviewer independent approve 1
rs_record_sav success
rs_set_scaffolding ok
rs_set_result ready-for-review
out="$(rs_emit)"
assert_contains "$out" "run-summary:" "case1 prefix"
assert_contains "$out" "mode=impl" "case1 mode"
assert_contains "$out" "stages=A,B,C" "case1 stages"
assert_contains "$out" "reviewer=independent:approve:r1" "case1 reviewer"
assert_contains "$out" "stage-a-verify=success" "case1 stage-a-verify"
assert_contains "$out" "scaffolding=ok" "case1 scaffolding"
assert_contains "$out" "errors=no" "case1 errors"
assert_contains "$out" "result=ready-for-review" "case1 result"

# ── ケース 2: degraded ──
# design.md L427-429: reviewer=degraded:r1 / scaffolding=missing / errors=yes /
# result=claude-failed。前ケースの蓄積を引きずらないよう rs_init でリセット。
echo "[case 2] degraded"
rs_init
rs_record_reviewer degraded "" 1
rs_set_scaffolding missing
rs_record_error subagent-not-found
rs_set_result claude-failed
out="$(rs_emit)"
assert_contains "$out" "reviewer=degraded:r1" "case2 reviewer"
assert_contains "$out" "scaffolding=missing" "case2 scaffolding"
assert_contains "$out" "errors=yes" "case2 errors"
assert_contains "$out" "result=claude-failed" "case2 result"

# ── ケース 3: design ──
# design.md L430-431: mode=design / reviewer=n/a（design モードで Reviewer 非該当の
# 既定 n/a が維持されること）。rs_init でリセットして mode/result のみ記録。
echo "[case 3] design"
rs_init
rs_set_mode design
rs_set_result ready-for-review
out="$(rs_emit)"
assert_contains "$out" "mode=design" "case3 mode"
assert_contains "$out" "reviewer=n/a" "case3 reviewer 既定 n/a 維持"

# ── ケース 4: 未初期化フェイルセーフ ──
# design.md L432: rs_init 直後に記録なしで rs_emit → 既定値 1 行が出る
# （run-summary: prefix を含む 1 行）。
echo "[case 4] 未初期化フェイルセーフ"
rs_init
out="$(rs_emit)"
assert_contains "$out" "run-summary:" "case4 既定値 1 行 prefix"
# 1 行のみであること（複数行を吐かない / Req 1.4, 8.3）。
line_count="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$line_count" = "1" ]; then
  ok "case4 出力が 1 行"
else
  fail "case4 出力が 1 行でない / 行数: $line_count"
fi

# ── ケース 5: 無効化 ──
# design.md L433: RUN_SUMMARY_ENABLED=false rs_emit → 出力が空であること（NFR 1.3）。
echo "[case 5] 無効化"
rs_init
out="$(RUN_SUMMARY_ENABLED=false rs_emit)"
if [ -z "$out" ]; then
  ok "case5 RUN_SUMMARY_ENABLED=false で出力が空"
else
  fail "case5 RUN_SUMMARY_ENABLED=false なのに出力あり / 実出力: [$out]"
fi

# ── 集計 ──
echo "----------------------------------------"
echo "PASS: $PASS / FAIL: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL（$FAIL 件の assert が失敗）" >&2
  exit 1
fi
echo "RESULT: PASS（全 $PASS 件の assert が成功）"
exit 0
