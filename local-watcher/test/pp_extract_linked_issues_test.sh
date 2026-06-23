#!/usr/bin/env bash
#
# 用途: Issue #389 で追加した `pp_extract_linked_issues`（modules/promote-pipeline.sh）が
#       merged PR の `closingIssuesReferences` と `headRefName` の両経路から Issue 番号を
#       和集合 + 重複排除で抽出する純関数として正しく動作することを検証する近接テスト。
#
#       対象関数:
#         - pp_extract_linked_issues (#389 head ブランチ名導出 + closingIssuesReferences 併用)
#
#       検証する AC (docs/specs/389-fix-promote-pipeline-staged-for-release/requirements.md):
#         - Req 1.1: head ブランチ名 `^claude/issue-([0-9]+)-impl-` から Issue 番号導出
#         - Req 1.2: closingIssuesReferences と head 経路の和集合・重複排除
#         - Req 1.3: head パターン不一致 PR は head 経路導出しない
#         - Req 1.4: BASE_BRANCH != default のとき closingIssuesReferences=[] でも head 経路で導出
#         - Req 1.5 / NFR 4.2: 数値 ID `^[0-9]+$` の検証（jq capture で保証）
#         - Req 2.3 / NFR 4.1: fork PR 除外を head 経路にも適用
#         - Req 5.1 / 5.2: 4 ケース + fork PR ケースの観測
#
# 配置先: local-watcher/test/pp_extract_linked_issues_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pp_extract_linked_issues_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PP_MOD="$SCRIPT_DIR/../bin/modules/promote-pipeline.sh"

if [ ! -f "$PP_MOD" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PP_MOD" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for this test" >&2
  exit 2
fi

# extract_function イディオム（既存テスト sn_callsite_promote_test.sh と同形式）
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# pp_extract_linked_issues のみを抽出（純関数なので依存関数 stub は不要）
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PP_MOD" "pp_extract_linked_issues")"

if ! declare -F pp_extract_linked_issues >/dev/null; then
  echo "ERROR: pp_extract_linked_issues not loaded" >&2
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

REPO_OWNER="owner"

# ============================================================
# Case 1: closingIssuesReferences 単独で導出（既存挙動・base=main 想定）
# ============================================================
echo "--- Case 1: closingIssuesReferences 単独（既存挙動の維持 / Req 3.2） ---"

INPUT_C1=$(cat <<'JSON'
[
  {
    "number": 100,
    "headRefName": "claude/issue-42-impl-foo",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": [ { "number": 42 } ]
  }
]
JSON
)

ACTUAL_C1=$(pp_extract_linked_issues "$INPUT_C1" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
assert_eq "Case 1: closingIssuesReferences の #42 を抽出" "42" "$ACTUAL_C1"

# ============================================================
# Case 2: head ブランチ名単独で導出（BASE_BRANCH=develop 想定 / Req 1.4）
# ============================================================
echo ""
echo "--- Case 2: head ブランチ名単独（closingIssuesReferences=[] / Req 1.1, 1.4） ---"

INPUT_C2=$(cat <<'JSON'
[
  {
    "number": 200,
    "headRefName": "claude/issue-7-impl-bar",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  }
]
JSON
)

ACTUAL_C2=$(pp_extract_linked_issues "$INPUT_C2" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
assert_eq "Case 2: head ブランチ名からの #7 を抽出（base=develop 想定）" "7" "$ACTUAL_C2"

# ============================================================
# Case 3: 両方から同一 #N → 和集合 + 重複排除（Req 1.2）
# ============================================================
echo ""
echo "--- Case 3: 両経路から同一 #N → 和集合で重複排除（Req 1.2） ---"

INPUT_C3=$(cat <<'JSON'
[
  {
    "number": 300,
    "headRefName": "claude/issue-99-impl-baz",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": [ { "number": 99 } ]
  }
]
JSON
)

ACTUAL_C3=$(pp_extract_linked_issues "$INPUT_C3" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
assert_eq "Case 3: 両経路で同じ #99 → unique で 1 件のみ" "99" "$ACTUAL_C3"

# ============================================================
# Case 4: head パターン不一致 → head 経路は導出されない（Req 1.3）
# ============================================================
echo ""
echo "--- Case 4: head パターン不一致 PR の head 経路除外（Req 1.3） ---"

INPUT_C4=$(cat <<'JSON'
[
  {
    "number": 400,
    "headRefName": "feature/manual-fix",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  },
  {
    "number": 401,
    "headRefName": "claude/issue-50-design-spec",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  },
  {
    "number": 402,
    "headRefName": "claude/issue-51-impl-good",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  }
]
JSON
)

ACTUAL_C4=$(pp_extract_linked_issues "$INPUT_C4" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
# feature/manual-fix と claude/issue-50-design-spec は除外され、#51 のみ
assert_eq "Case 4: 不一致 PR を除外、#51 のみ抽出" "51" "$ACTUAL_C4"

# ============================================================
# Case 5: fork PR は head ブランチ名が `claude/issue-<N>-impl-` でも除外（Req 2.3）
# ============================================================
echo ""
echo "--- Case 5: fork PR の head 経路除外（Req 2.3 / NFR 4.1） ---"

INPUT_C5=$(cat <<'JSON'
[
  {
    "number": 500,
    "headRefName": "claude/issue-77-impl-fork",
    "headRepositoryOwner": { "login": "external-fork-user" },
    "closingIssuesReferences": [ { "number": 77 } ]
  },
  {
    "number": 501,
    "headRefName": "claude/issue-88-impl-internal",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  }
]
JSON
)

ACTUAL_C5=$(pp_extract_linked_issues "$INPUT_C5" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
# fork PR (#500) の #77 は head 経路でも closingIssuesReferences 経路でも除外、#88 のみ
assert_eq "Case 5: fork PR を除外、内部 PR の #88 のみ抽出" "88" "$ACTUAL_C5"

# ============================================================
# Case 6: 複数 PR の混合 → 全 Issue 番号を unique + 昇順で抽出（Req 1.2 包括）
# ============================================================
echo ""
echo "--- Case 6: 複数 PR 混合 → 全 Issue 番号を unique 昇順抽出 ---"

INPUT_C6=$(cat <<'JSON'
[
  {
    "number": 600,
    "headRefName": "claude/issue-10-impl-a",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": [ { "number": 10 } ]
  },
  {
    "number": 601,
    "headRefName": "claude/issue-20-impl-b",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  },
  {
    "number": 602,
    "headRefName": "feature/random",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": [ { "number": 30 } ]
  },
  {
    "number": 603,
    "headRefName": "claude/issue-10-impl-dup",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  }
]
JSON
)

ACTUAL_C6=$(pp_extract_linked_issues "$INPUT_C6" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
# #10 (closing + head + 重複 head), #20 (head), #30 (closing on non-claude head) → 10 20 30
assert_eq "Case 6: 和集合 + unique で 10/20/30 を昇順抽出" "10 20 30" "$ACTUAL_C6"

# ============================================================
# Case 7: 空入力 / null フィールド耐性
# ============================================================
echo ""
echo "--- Case 7: 空配列入力で空出力 / null 耐性 ---"

ACTUAL_C7A=$(pp_extract_linked_issues "[]" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
assert_eq "Case 7a: 空配列入力で空出力" "" "$ACTUAL_C7A"

# headRefName が欠落、closingIssuesReferences が欠落しても落ちない
INPUT_C7B=$(cat <<'JSON'
[
  {
    "number": 700,
    "headRepositoryOwner": { "login": "owner" }
  }
]
JSON
)
ACTUAL_C7B=$(pp_extract_linked_issues "$INPUT_C7B" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
assert_eq "Case 7b: フィールド欠落 PR は空出力（クラッシュしない）" "" "$ACTUAL_C7B"

# ============================================================
# Case 8: head ブランチ名のサフィックス境界 / 数値 ID 検証
# ============================================================
echo ""
echo "--- Case 8: head パターン境界（hyphen 必須・数値 ID のみ） ---"

INPUT_C8=$(cat <<'JSON'
[
  {
    "number": 800,
    "headRefName": "claude/issue-1-impl-x",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  },
  {
    "number": 801,
    "headRefName": "claude/issue-abc-impl-x",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  },
  {
    "number": 802,
    "headRefName": "claude/issue-2-implfoo",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  }
]
JSON
)

ACTUAL_C8=$(pp_extract_linked_issues "$INPUT_C8" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
# #800 は `claude/issue-1-impl-x` → #1, #801 は `abc` で不一致, #802 は `-impl-`（hyphen 必須）に
# 一致しないので不一致 → 結果 #1 のみ
assert_eq "Case 8: 数値 ID のみ採用、hyphen 必須で #1 のみ抽出" "1" "$ACTUAL_C8"

# ============================================================
# Case 9: BASE_BRANCH=develop の代表シナリオ（Req 5.4 fail-condition 観測）
# ============================================================
echo ""
echo "--- Case 9: BASE_BRANCH=develop / closingIssuesReferences=[] / head=claude/issue-1-impl-x ---"

INPUT_C9=$(cat <<'JSON'
[
  {
    "number": 900,
    "headRefName": "claude/issue-1-impl-x",
    "headRepositoryOwner": { "login": "owner" },
    "closingIssuesReferences": []
  }
]
JSON
)

ACTUAL_C9=$(pp_extract_linked_issues "$INPUT_C9" "$REPO_OWNER" | tr '\n' ' ' | sed 's/ $//')
if [ "$ACTUAL_C9" = "1" ]; then
  echo "PASS: Case 9: develop 運用 #1 が staged-for-release 対象集合に含まれる"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Case 9 (#389 Req 5.4): develop 運用で #1 が抽出されない"
  echo "  PR number       : 900"
  echo "  headRefName     : claude/issue-1-impl-x"
  echo "  expected Issue  : 1"
  echo "  actual          : $(printf '%q' "$ACTUAL_C9")"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

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
