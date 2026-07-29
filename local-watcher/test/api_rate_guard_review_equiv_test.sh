#!/usr/bin/env bash
#
# 用途: Issue #521 task 3 で PR snapshot 参加へ差し替えた review 系 module
#       （pr-iteration / pr-reviewer / pr-design-reviewer / security-review）の
#       「snapshot 参照 client jq が server search と等価集合を返す」ことを fixture で検証する
#       スモークテスト（live GitHub API なし / NFR 6.2）。
#
#       検証観点（docs/specs/521-feat-watcher-github-api-rate-limit/requirements.md）:
#         - Req 2.3: pr-iteration の超集合 client jq が server search
#                    （label:needs-iteration 包含 / -label:failed / -label:needs-rebase 除外 /
#                    -draft:true）と等価集合を返すことを実 pi_fetch_candidate_prs で確認。
#         - Req 2.3: pr-reviewer / pr-design-reviewer / security-review は server search が
#                    `-draft:true` のみで client jq の isDraft==false が完全再現するため
#                    追加 client jq 不要。grl_pr_snapshot_or_live 経由化 + isDraft==false 存在を
#                    ソース走査で確認（drift 検出）。
#
# 配置先: local-watcher/test/api_rate_guard_review_equiv_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/api_rate_guard_review_equiv_test.sh

# 抽出関数・stub 変数の多用で SC2034 を、ソース走査 grep の単一クォート jq リテラルで SC2016 を
# file-wide 抑止する。
# shellcheck disable=SC2034,SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
MOD_DIR="$SCRIPT_DIR/../bin/modules"
PI_MOD="$MOD_DIR/pr-iteration.sh"
PR_MOD="$MOD_DIR/pr-reviewer.sh"
PDR_MOD="$MOD_DIR/pr-design-reviewer.sh"
SEC_MOD="$MOD_DIR/security-review.sh"

for f in "$PI_MOD" "$PR_MOD" "$PDR_MOD" "$SEC_MOD"; do
  if [ ! -f "$f" ]; then echo "ERROR: cannot find $f" >&2; exit 2; fi
done
if ! command -v jq >/dev/null 2>&1; then echo "ERROR: jq required" >&2; exit 2; fi

for fn in pi_log pi_warn pi_error pi_fetch_candidate_prs; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$PI_MOD" "$fn")"
done
if ! declare -F pi_fetch_candidate_prs >/dev/null; then
  echo "ERROR: pi_fetch_candidate_prs not loaded" >&2; exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

# ── グローバル env ──
REPO="owner/test-repo"
PR_ITERATION_GIT_TIMEOUT="60"
PR_ITERATION_HEAD_PATTERN="^claude/issue-[0-9]+-impl-"
PR_ITERATION_DESIGN_HEAD_PATTERN="^claude/issue-[0-9]+-design-"
PR_ITERATION_DESIGN_ENABLED="true"
LABEL_NEEDS_ITERATION="needs-iteration"
LABEL_FAILED="claude-failed"
LABEL_NEEDS_REBASE="needs-rebase"

# 全 open PR 超集合（needs-iteration 無し / failed 併存 / needs-rebase 併存 / draft / fork /
# design PR を含む）。
PR_SUPERSET='[
  {"number":1,"headRefName":"claude/issue-1-impl-a","baseRefName":"main","isDraft":false,"url":"u1","labels":[{"name":"needs-iteration"}],"headRepositoryOwner":{"login":"owner"},"body":"b1"},
  {"number":2,"headRefName":"claude/issue-2-impl-a","baseRefName":"main","isDraft":false,"url":"u2","labels":[],"headRepositoryOwner":{"login":"owner"},"body":"b2"},
  {"number":3,"headRefName":"claude/issue-3-impl-a","baseRefName":"main","isDraft":false,"url":"u3","labels":[{"name":"needs-iteration"},{"name":"claude-failed"}],"headRepositoryOwner":{"login":"owner"},"body":"b3"},
  {"number":4,"headRefName":"claude/issue-4-impl-a","baseRefName":"main","isDraft":false,"url":"u4","labels":[{"name":"needs-iteration"},{"name":"needs-rebase"}],"headRepositoryOwner":{"login":"owner"},"body":"b4"},
  {"number":5,"headRefName":"claude/issue-5-impl-a","baseRefName":"main","isDraft":true,"url":"u5","labels":[{"name":"needs-iteration"}],"headRepositoryOwner":{"login":"owner"},"body":"b5"},
  {"number":6,"headRefName":"claude/issue-6-impl-a","baseRefName":"main","isDraft":false,"url":"u6","labels":[{"name":"needs-iteration"}],"headRepositoryOwner":{"login":"forkuser"},"body":"b6"},
  {"number":7,"headRefName":"claude/issue-7-design-a","baseRefName":"main","isDraft":false,"url":"u7","labels":[{"name":"needs-iteration"}],"headRepositoryOwner":{"login":"owner"},"body":"b7"}
]'
grl_pr_snapshot_or_live() { echo "$PR_SUPERSET"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. pr-iteration: 超集合 → client jq が server search と等価集合（Req 2.3）
#    期待: PR#1（impl+needs-iteration）と #7（design+needs-iteration、design_enabled=true）。
# ─────────────────────────────────────────────────────────────────────────────
out="$(pi_fetch_candidate_prs)"
nums="$(echo "$out" | jq -c '[.[].number]')"
assert_eq "pr-iteration 等価集合: needs-iteration 包含/failed・needs-rebase・draft・fork 除外" "[1,7]" "$nums"

# design_enabled=false のとき design PR (#7) が候補から外れる（既存挙動維持の確認）
PR_ITERATION_DESIGN_ENABLED="false"
out="$(pi_fetch_candidate_prs)"
nums="$(echo "$out" | jq -c '[.[].number]')"
assert_eq "pr-iteration: design_enabled=false で design PR 除外" "[1]" "$nums"
PR_ITERATION_DESIGN_ENABLED="true"

# ─────────────────────────────────────────────────────────────────────────────
# 2. draft-only 3 module: grl_pr_snapshot_or_live 経由化 + isDraft==false 存在（Req 2.3）
# ─────────────────────────────────────────────────────────────────────────────
for pair in "pr-reviewer:$PR_MOD" "pr-design-reviewer:$PDR_MOD" "security-review:$SEC_MOD"; do
  name="${pair%%:*}"; mod="${pair##*:}"
  assert_rc "$name: grl_pr_snapshot_or_live 経由" 0 grep -q 'grl_pr_snapshot_or_live' "$mod"
  assert_rc "$name: client jq に isDraft==false 存在（-draft:true 再現）" 0 \
    grep -q 'select(.isDraft == false)' "$mod"
  # 旧 raw fetch（timeout ... gh pr list）が残っていない
  assert_eq "$name: raw 'timeout ... gh pr list' 消失" "0" \
    "$(grep -c 'timeout .* gh pr list' "$mod" || true)"
done

# pr-iteration も grl 経由化を確認
assert_rc "pr-iteration: grl_pr_snapshot_or_live 経由" 0 grep -q 'grl_pr_snapshot_or_live' "$PI_MOD"

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "api_rate_guard_review_equiv_test: all passed"
