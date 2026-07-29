#!/usr/bin/env bash
#
# 用途: Issue #521 task 4 で Issue snapshot 参加へ差し替えた 4 module
#       （dependency-resolver / path-overlap / stale-pickup-reaper / quota-aware）の
#       「snapshot 参照 client jq が server search と等価集合を返す」ことを fixture で検証する
#       スモークテスト（live GitHub API なし / NFR 6.2）。
#
#       検証観点（docs/specs/521-feat-watcher-github-api-rate-limit/requirements.md）:
#         - Req 2.3: stale-pickup-reaper の実 sr_snapshot_client_filter / sr_fetch_candidates が
#                    超集合から label:picked/claimed 包含 + exclude_filter 除外の等価集合を返す。
#         - Req 2.3: quota-aware / dependency-resolver / path-overlap の client jq（module 内と
#                    同一表現）が超集合から等価集合を返す。各 module が grl_issue_snapshot_or_live
#                    経由化されていることをソース走査で確認。
#
# 配置先: local-watcher/test/api_rate_guard_issue_equiv_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/api_rate_guard_issue_equiv_test.sh

# 抽出関数・stub 変数の多用で SC2034、ソース走査 grep の jq リテラルで SC2016 を file-wide 抑止。
# shellcheck disable=SC2034,SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"
MOD_DIR="$SCRIPT_DIR/../bin/modules"
SR_MOD="$MOD_DIR/stale-pickup-reaper.sh"
QA_MOD="$MOD_DIR/quota-aware.sh"
DR_MOD="$MOD_DIR/dependency-resolver.sh"
PO_MOD="$MOD_DIR/path-overlap.sh"
GRL_MOD="$MOD_DIR/api-rate-guard.sh"

for f in "$SR_MOD" "$QA_MOD" "$DR_MOD" "$PO_MOD" "$GRL_MOD"; do
  if [ ! -f "$f" ]; then echo "ERROR: cannot find $f" >&2; exit 2; fi
done
if ! command -v jq >/dev/null 2>&1; then echo "ERROR: jq required" >&2; exit 2; fi

for fn in sr_log sr_warn sr_error sr_snapshot_client_filter sr_fetch_candidates; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$SR_MOD" "$fn")"
done
for fn in sr_snapshot_client_filter sr_fetch_candidates; do
  if ! declare -F "$fn" >/dev/null; then echo "ERROR: $fn not loaded" >&2; exit 2; fi
done

PASS_COUNT=0
FAIL_COUNT=0

# ── グローバル env ──
REPO="owner/test-repo"
LABEL_PICKED="claude-picked-up"
LABEL_CLAIMED="claude-claimed"
LABEL_FAILED="claude-failed"
LABEL_NEEDS_DECISIONS="needs-decisions"
LABEL_AWAITING_DESIGN="awaiting-design-review"
LABEL_NEEDS_QUOTA_WAIT="needs-quota-wait"
LABEL_BLOCKED="blocked"
LABEL_STAGED_FOR_RELEASE="staged-for-release"
STALE_PICKUP_REAPER_GH_TIMEOUT="60"
STALE_PICKUP_REAPER_MAX_ISSUES="50"

# ─────────────────────────────────────────────────────────────────────────────
# 1. sr_snapshot_client_filter（実コード）: include 包含 + exclude 除外（Req 2.3）
# ─────────────────────────────────────────────────────────────────────────────
EXC_JSON='["claude-failed","needs-decisions","awaiting-design-review","needs-quota-wait","blocked","staged-for-release","hold"]'
SET='[
  {"number":10,"labels":[{"name":"claude-picked-up"}]},
  {"number":11,"labels":[{"name":"claude-picked-up"},{"name":"claude-failed"}]},
  {"number":12,"labels":[{"name":"claude-picked-up"},{"name":"hold"}]},
  {"number":13,"labels":[{"name":"ready-for-review"}]}
]'
out="$(sr_snapshot_client_filter "$SET" "claude-picked-up" "$EXC_JSON")"
nums="$(echo "$out" | jq -c '[.[].number]')"
assert_eq "reaper filter: picked 包含 + failed/hold 除外 + 非 picked 除外" "[10]" "$nums"

# ─────────────────────────────────────────────────────────────────────────────
# 2. sr_fetch_candidates（実コード / end-to-end）: 超集合 → picked+claimed 結合等価集合
# ─────────────────────────────────────────────────────────────────────────────
ISSUE_SUPERSET='[
  {"number":10,"labels":[{"name":"claude-picked-up"}],"title":"a","url":"u10","updatedAt":"2026-01-01T00:00:00Z"},
  {"number":11,"labels":[{"name":"claude-picked-up"},{"name":"claude-failed"}],"title":"b","url":"u11","updatedAt":"2026-01-01T00:00:00Z"},
  {"number":12,"labels":[{"name":"claude-claimed"}],"title":"c","url":"u12","updatedAt":"2026-01-01T00:00:00Z"},
  {"number":13,"labels":[{"name":"claude-claimed"},{"name":"needs-quota-wait"}],"title":"d","url":"u13","updatedAt":"2026-01-01T00:00:00Z"},
  {"number":14,"labels":[{"name":"ready-for-review"}],"title":"e","url":"u14","updatedAt":"2026-01-01T00:00:00Z"},
  {"number":15,"labels":[{"name":"claude-picked-up"},{"name":"blocked"}],"title":"f","url":"u15","updatedAt":"2026-01-01T00:00:00Z"}
]'
# active 相当: wrapper が超集合を返し、grl_snapshot_active=true で client 絞り込みが走る
grl_issue_snapshot_or_live() { printf '%s' "$ISSUE_SUPERSET"; }
grl_snapshot_active() { return 0; }
merged="$(sr_fetch_candidates)"
nums="$(echo "$merged" | jq -c '[.[].number] | sort')"
assert_eq "reaper end-to-end: picked(10)+claimed(12) のみ（failed/needs-quota-wait/blocked/非対象 除外）" "[10,12]" "$nums"

# ─────────────────────────────────────────────────────────────────────────────
# 3. quota-aware client jq（module と同一表現）: needs-quota-wait 包含（Req 2.3）
# ─────────────────────────────────────────────────────────────────────────────
QA_SET='[
  {"number":20,"labels":[{"name":"needs-quota-wait"}]},
  {"number":21,"labels":[{"name":"auto-dev"}]},
  {"number":22,"labels":[{"name":"needs-quota-wait"},{"name":"auto-dev"}]}
]'
qa_out="$(printf '%s' "$QA_SET" | jq -c \
  --arg needs_quota "needs-quota-wait" \
  '[.[] | select((.labels // [] | map(.name) | index($needs_quota)) != null)]')"
assert_eq "quota-aware filter: needs-quota-wait 包含のみ" "[20,22]" "$(echo "$qa_out" | jq -c '[.[].number]')"
# module が該当 select を持つ
assert_rc "quota-aware: needs_quota include select 存在" 0 grep -q 'index($needs_quota)) != null' "$QA_MOD"

# ─────────────────────────────────────────────────────────────────────────────
# 4. dependency-resolver client jq（module と同一表現）: blocked 包含 + 除外 + number 整列
# ─────────────────────────────────────────────────────────────────────────────
DR_SET='[
  {"number":33,"body":"x","labels":[{"name":"auto-dev"},{"name":"blocked"}]},
  {"number":30,"body":"y","labels":[{"name":"auto-dev"},{"name":"blocked"}]},
  {"number":31,"body":"z","labels":[{"name":"auto-dev"},{"name":"blocked"},{"name":"claude-failed"}]},
  {"number":32,"body":"w","labels":[{"name":"auto-dev"}]}
]'
dr_out="$(printf '%s' "$DR_SET" | jq -c \
  --arg blocked "blocked" --arg failed "claude-failed" --arg nd "needs-decisions" \
  '[.[] | (.labels // [] | map(.name)) as $n
     | select(($n | index($blocked)) != null)
     | select(($n | index($failed)) == null)
     | select(($n | index($nd)) == null)
  ] | sort_by(.number)')"
assert_eq "dependency-resolver filter: blocked 包含/failed 除外/非 blocked 除外 + number 昇順" "[30,33]" "$(echo "$dr_out" | jq -c '[.[].number]')"
assert_rc "dependency-resolver: blocked include + sort_by(.number) 存在" 0 grep -q 'sort_by(.number)' "$DR_MOD"

# ─────────────────────────────────────────────────────────────────────────────
# 5. path-overlap client jq（module と同一表現）: holder OR + st-failed/awaiting-slot 除外
# ─────────────────────────────────────────────────────────────────────────────
PO_SET='[
  {"number":40,"labels":[{"name":"claude-claimed"}]},
  {"number":41,"labels":[{"name":"needs-iteration"}]},
  {"number":42,"labels":[{"name":"claude-picked-up"},{"name":"st-failed"}]},
  {"number":43,"labels":[{"name":"ready-for-review"},{"name":"awaiting-slot"}]},
  {"number":44,"labels":[{"name":"auto-dev"}]}
]'
HOLDERS='["claude-claimed","claude-picked-up","awaiting-design-review","ready-for-review","needs-iteration","needs-rebase","staged-for-release"]'
po_out="$(printf '%s' "$PO_SET" | jq -c \
  --argjson holders "$HOLDERS" \
  '[.[] | (.labels // [] | map(.name)) as $n
     | select($holders | any(. as $h | ($n | index($h)) != null))
     | select(($n | index("st-failed")) == null)
     | select(($n | index("awaiting-slot")) == null)
  ]')"
assert_eq "path-overlap filter: holder OR 包含 / st-failed・awaiting-slot・非 holder 除外" "[40,41]" "$(echo "$po_out" | jq -c '[.[].number]')"
assert_rc "path-overlap: holder OR any() select 存在" 0 grep -q 'any(. as \$h' "$PO_MOD"

# ─────────────────────────────────────────────────────────────────────────────
# 6. 各 module が snapshot に参加 / 超集合 union に updatedAt を含む
#    reaper は wrapper grl_issue_snapshot_or_live 経由（server search 形が一致し byte 等価）、
#    quota/dep/path は grl_snapshot_active 分岐で snapshot 参照（gate off は原コマンドを温存し
#    byte 等価 / NFR 1.1）。いずれも snapshot active 時のみ client 絞り込みが走る。
# ─────────────────────────────────────────────────────────────────────────────
assert_rc "stale-pickup-reaper.sh: grl_issue_snapshot_or_live 経由（wrapper）" 0 \
  grep -q 'grl_issue_snapshot_or_live' "$SR_MOD"
for m in "$QA_MOD" "$DR_MOD" "$PO_MOD"; do
  assert_rc "$(basename "$m"): grl_snapshot_active 分岐で snapshot 参照" 0 \
    grep -q 'grl_snapshot_active' "$m"
  assert_rc "$(basename "$m"): active 時 grl_snapshot_issues を参照" 0 \
    grep -q 'grl_snapshot_issues' "$m"
done
assert_rc "Issue 超集合 union に updatedAt を含む（reaper 参加のため）" 0 \
  grep -q 'number,title,body,url,labels,author,updatedAt' "$GRL_MOD"

# ── サマリ ──
echo "----------------------------------------"
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "api_rate_guard_issue_equiv_test: all passed"
