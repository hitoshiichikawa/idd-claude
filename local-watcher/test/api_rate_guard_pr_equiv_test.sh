#!/usr/bin/env bash
#
# 用途: Issue #521 task 2 で PR snapshot 参加へ差し替えた merge/auto-merge 系 module の
#       「snapshot 参照 client jq が server search と等価集合を返す」ことを fixture で検証する
#       スモークテスト（live GitHub API なし / NFR 6.2）。
#
#       検証観点（docs/specs/521-feat-watcher-github-api-rate-limit/requirements.md）:
#         - Req 2.3: 超集合（全 open PR）を client jq で絞り込んだ結果が、従来の server
#                    `--search` と等価集合になる。代表として auto-rebase の
#                    `label:needs-rebase` 包含 + `-label:failed` 除外 + draft/fork 除外を
#                    実 ar_fetch_candidates で行う。
#         - Req 2.3: merge-queue / auto-merge / auto-merge-design の inline client jq が
#                    server search の label 条件（index==null / index!=null）を含むことを
#                    ソース走査で確認（drift 検出）。
#         - Req 2.4: 鮮度クリティカルな Dispatcher 候補クエリは snapshot 経由へ差し替えず
#                    個別取得を維持することをソース走査で確認。
#
# 配置先: local-watcher/test/api_rate_guard_pr_equiv_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/api_rate_guard_pr_equiv_test.sh

# 抽出関数および stub から indirect 参照される変数を多用するため SC2034 を抑止（file-wide）。
# module ソース走査の grep パターンは `$needs_rebase` 等の jq 変数リテラルを意図的に単一
# クォートで保持するため SC2016（single-quote 非展開）も file-wide で抑止する。
# shellcheck disable=SC2034,SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
MOD_DIR="$SCRIPT_DIR/../bin/modules"
AR_MOD="$MOD_DIR/auto-rebase.sh"
MQ_MOD="$MOD_DIR/merge-queue.sh"
AM_MOD="$MOD_DIR/auto-merge.sh"
AMD_MOD="$MOD_DIR/auto-merge-design.sh"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

for f in "$AR_MOD" "$MQ_MOD" "$AM_MOD" "$AMD_MOD" "$WATCHER_SH"; do
  if [ ! -f "$f" ]; then echo "ERROR: cannot find $f" >&2; exit 2; fi
done
if ! command -v jq >/dev/null 2>&1; then echo "ERROR: jq required" >&2; exit 2; fi

# ar ロガー + ar_fetch_candidates を実コードから抽出
for fn in ar_log ar_warn ar_error ar_fetch_candidates; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$AR_MOD" "$fn")"
done
if ! declare -F ar_fetch_candidates >/dev/null; then
  echo "ERROR: ar_fetch_candidates not loaded" >&2; exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

# ── グローバル env ──
REPO="owner/test-repo"
AUTO_REBASE_GIT_TIMEOUT="60"
MERGE_QUEUE_HEAD_PATTERN="^claude/"
LABEL_NEEDS_REBASE="needs-rebase"
LABEL_FAILED="claude-failed"

# ── stub: grl_pr_snapshot_or_live を active 相当（超集合を返す）に固定 ──
# 全 open PR 超集合（draft / fork / 非 approved / needs-rebase 無し / failed 併存 を含む）。
PR_SUPERSET='[
  {"number":1,"headRefName":"claude/issue-1-impl","baseRefName":"main","labels":[{"name":"needs-rebase"}],"url":"u1","isDraft":false,"reviewDecision":"APPROVED","headRepositoryOwner":{"login":"owner"},"title":"t1","headRefOid":"a1"},
  {"number":2,"headRefName":"claude/issue-2-impl","baseRefName":"main","labels":[],"url":"u2","isDraft":false,"reviewDecision":"APPROVED","headRepositoryOwner":{"login":"owner"},"title":"t2","headRefOid":"a2"},
  {"number":3,"headRefName":"claude/issue-3-impl","baseRefName":"main","labels":[{"name":"needs-rebase"},{"name":"claude-failed"}],"url":"u3","isDraft":false,"reviewDecision":"APPROVED","headRepositoryOwner":{"login":"owner"},"title":"t3","headRefOid":"a3"},
  {"number":4,"headRefName":"claude/issue-4-impl","baseRefName":"main","labels":[{"name":"needs-rebase"}],"url":"u4","isDraft":true,"reviewDecision":"APPROVED","headRepositoryOwner":{"login":"owner"},"title":"t4","headRefOid":"a4"},
  {"number":5,"headRefName":"claude/issue-5-impl","baseRefName":"main","labels":[{"name":"needs-rebase"}],"url":"u5","isDraft":false,"reviewDecision":null,"headRepositoryOwner":{"login":"owner"},"title":"t5","headRefOid":"a5"},
  {"number":6,"headRefName":"claude/issue-6-impl","baseRefName":"main","labels":[{"name":"needs-rebase"}],"url":"u6","isDraft":false,"reviewDecision":"APPROVED","headRepositoryOwner":{"login":"forkuser"},"title":"t6","headRefOid":"a6"}
]'
grl_pr_snapshot_or_live() { echo "$PR_SUPERSET"; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. auto-rebase: 超集合 → client jq が server search と等価集合を返す（Req 2.3）
#    期待: PR#1 のみ（approved + needs-rebase 包含 + failed 除外 + 非 draft + owner 一致）。
# ─────────────────────────────────────────────────────────────────────────────
out="$(ar_fetch_candidates)"
nums="$(echo "$out" | jq -c '[.[].number]')"
assert_eq "auto-rebase 等価集合: needs-rebase 包含/failed 除外/draft 除外/fork 除外" "[1]" "$nums"

# 個別根拠の可視化
assert_eq "auto-rebase: 総数 1" "1" "$(echo "$out" | jq 'length')"

# ─────────────────────────────────────────────────────────────────────────────
# 2. merge-queue の inline client jq に label 除外条件が含まれる（Req 2.3 / drift 検出）
# ─────────────────────────────────────────────────────────────────────────────
assert_rc "merge-queue: needs-rebase 除外 select 存在" 0 \
  grep -q 'index($needs_rebase)) == null' "$MQ_MOD"
assert_rc "merge-queue: failed 除外 select 存在" 0 \
  grep -q 'index($failed)) == null' "$MQ_MOD"
# recheck 側は needs-rebase 包含
assert_rc "merge-queue-recheck: needs-rebase 包含 select 存在" 0 \
  grep -q 'index($needs_rebase)) != null' "$MQ_MOD"

# ─────────────────────────────────────────────────────────────────────────────
# 3. auto-merge / auto-merge-design の inline client jq に label 条件が含まれる（Req 2.3）
# ─────────────────────────────────────────────────────────────────────────────
assert_rc "auto-merge: ready 包含 select 存在" 0 \
  grep -q 'index($ready)) != null' "$AM_MOD"
assert_rc "auto-merge: needs-decisions 除外 select 存在" 0 \
  grep -q 'index($needs_decisions)) == null' "$AM_MOD"
assert_rc "auto-merge-design: needs-iteration 除外 select 存在" 0 \
  grep -q 'index($needs_iteration)) == null' "$AMD_MOD"

# ─────────────────────────────────────────────────────────────────────────────
# 4. 各 module が grl_pr_snapshot_or_live 経由へ差し替え済み（snapshot 参加 / Req 2.3）
# ─────────────────────────────────────────────────────────────────────────────
for m in "$MQ_MOD" "$AM_MOD" "$AMD_MOD" "$AR_MOD" "$MOD_DIR/auto-merge-disarm.sh"; do
  assert_rc "$(basename "$m"): grl_pr_snapshot_or_live 経由" 0 \
    grep -q 'grl_pr_snapshot_or_live' "$m"
done

# ─────────────────────────────────────────────────────────────────────────────
# 5. Req 2.4: Dispatcher 候補クエリは snapshot 経由へ差し替えず個別取得を維持
#    （issue-watcher.sh 本体の Dispatcher が grl_issue_snapshot_or_live を使わない）。
# ─────────────────────────────────────────────────────────────────────────────
assert_eq "Dispatcher 候補クエリは snapshot 非参加（grl 未使用）" "0" \
  "$(grep -c 'grl_issue_snapshot_or_live' "$WATCHER_SH" || true)"

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "api_rate_guard_pr_equiv_test: all passed"
