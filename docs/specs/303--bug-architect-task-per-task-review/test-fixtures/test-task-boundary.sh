#!/usr/bin/env bash
# 用途: Issue #303 で導入する task-test 境界整合規約を、fixture tasks.md に対して
#       機械的に検証する小さなスモーク検証スクリプト（NFR 3.1）
# 配置先: docs/specs/303--bug-architect-task-per-task-review/test-fixtures/
# 依存: bash 4+, awk (gawk / busybox awk いずれも可)
#
# 検証仕様（本検証は test-coverage 系 AC の有無に関係なく、ヒューリスティックに
# 「タスク内テスト指示の有無」と「_Requirements_partial:_ 明示の有無」を見て
# 「先行 task が test 指示なし & partial 明示なし」を違反として検出する）:
#
#   - test-coverage キーワード: テスト追加 / regression / test / fixture / E2E / 単体テスト
#   - partial 明示行: 行が `_Requirements_partial:_` で始まる
#   - 違反パターン: behavior-changing と思われる task（`_Requirements:_` を持つ
#     `- [ ]` checkbox 行を親とするブロック）が、ブロック内のいずれの行にも
#     test-coverage キーワードを含まず、かつ `_Requirements_partial:_` 行も持たない
#
# 結果: 違反 0 件 → exit 0 / 違反 >=1 件 → exit 1 + 標準出力に違反 task ID 列挙

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# fixture ごとの期待結果（0=合法 / 1=違反）
declare -A EXPECTED
EXPECTED["${SCRIPT_DIR}/tasks-violation.md"]=1
EXPECTED["${SCRIPT_DIR}/tasks-partial-ok.md"]=0
EXPECTED["${SCRIPT_DIR}/tasks-same-task-ok.md"]=0

# 検出 awk スクリプト
# 入力: tasks.md
# 出力: 違反 task の "<task ID>\t<task title>" を 1 行 1 件で出力
# 戻り値: なし（呼び出し側で行数を数えて判定）
detect_violations() {
    local file="$1"
    awk '
        # 行頭 "- [ ] N." または "- [ ] N.M" を持つ task 行を検出
        # （deferrable "- [ ]*" は test-only として違反対象外）
        function flush_current() {
            if (current_id != "") {
                # 違反判定: behavior-changing task ( _Requirements: を持つ) で
                # test-coverage キーワード無し かつ partial 明示無し
                if (has_requirements && !has_test_kw && !has_partial) {
                    printf "%s\t%s\n", current_id, current_title
                }
            }
            current_id = ""
            current_title = ""
            has_requirements = 0
            has_test_kw = 0
            has_partial = 0
        }
        BEGIN {
            current_id = ""
            current_title = ""
            has_requirements = 0
            has_test_kw = 0
            has_partial = 0
        }
        # 新しい task 行（"- [ ]" / "- [x]"、deferrable "- [ ]*" は除外）
        /^- \[[ x]\] [0-9]+(\.[0-9]+)*\.? / {
            flush_current()
            # task ID 抽出: 数字 / dot のみ
            match($0, /[0-9]+(\.[0-9]+)*/)
            current_id = substr($0, RSTART, RLENGTH)
            # title: 残り部分
            current_title = $0
            next
        }
        # deferrable task 行（test-only）は flush して処理スキップ
        /^- \[[ x]\]\* [0-9]+(\.[0-9]+)*\.? / {
            flush_current()
            next
        }
        # _Requirements: 行
        /_Requirements:[^_]*_/ {
            has_requirements = 1
        }
        # _Requirements_partial: 行
        /_Requirements_partial:[^_]*_/ {
            has_partial = 1
        }
        # test-coverage キーワード（ヒューリスティック）
        /テスト追加|regression|test|Test|fixture|Fixture|E2E|単体テスト|統合テスト/ {
            # _Requirements 行自体は除外（"test" を含まないので一旦そのまま）
            has_test_kw = 1
        }
        END {
            flush_current()
        }
    ' "$file"
}

pass=0
fail=0

for fixture in "${!EXPECTED[@]}"; do
    expected="${EXPECTED[$fixture]}"
    name="$(basename "$fixture")"

    violations="$(detect_violations "$fixture")"
    count=0
    if [[ -n "$violations" ]]; then
        count=$(printf '%s\n' "$violations" | wc -l | tr -d ' ')
    fi

    if [[ "$expected" == "0" ]]; then
        # 合法 fixture: 違反 0 件であるべき
        if [[ "$count" == "0" ]]; then
            echo "[PASS] $name: 違反 0 件（期待: 合法）"
            pass=$((pass + 1))
        else
            echo "[FAIL] $name: 違反 $count 件検出（期待: 0 件 / 合法）" >&2
            printf '%s\n' "$violations" >&2
            fail=$((fail + 1))
        fi
    else
        # 違反 fixture: 違反 >=1 件であるべき
        if [[ "$count" -ge "1" ]]; then
            echo "[PASS] $name: 違反 $count 件検出（期待: >=1 件 / 違反）"
            pass=$((pass + 1))
        else
            echo "[FAIL] $name: 違反 0 件（期待: >=1 件 / 違反）" >&2
            fail=$((fail + 1))
        fi
    fi
done

echo "----"
echo "summary: pass=$pass fail=$fail"
if [[ "$fail" -gt "0" ]]; then
    exit 1
fi
exit 0
