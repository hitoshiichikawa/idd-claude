#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/tasks-count-gate.sh に追加した
#       「escalate 時の子 Issue 分割案コメント」（#509 モデルルーティング Phase 3）の
#       近接テスト。fixture の tasks.md を入力に、純粋関数（抽出 / グルーピング /
#       本文生成）と副作用関数（冪等判定 / 投稿）を gh stub で検証する。
#
#       対象関数:
#         - tc_split_proposal_enabled        (Req 1.1〜1.3 / 1.5)
#         - tc_sanitize_text                 (NFR 4.1 / 4.2)
#         - tc_truncate_title                (NFR 3.5)
#         - tc_extract_top_level_tasks       (Req 3.1〜3.3 / 3.5)
#         - tc_group_tasks                   (Req 3.4 / 3.6 / 3.7)
#         - tc_build_split_proposal_body     (Req 4.1〜4.11 / 5.1 / NFR 3.4)
#         - tc_split_proposal_already_posted (Req 5.1〜5.4 / 5.6)
#         - tc_post_split_proposal_comment   (Req 1.4 / 2.1〜2.4 / 5.2 / 5.7 / 6.5 / 6.6 / NFR 2.x / 3.2 / 3.3)
#         - tc_run_post_architect_check      (Req 2.1〜2.3 / 6.1)
#
#       Req 8.5 が要求する 5 ケース（最上位 11 件フラット / 子タスクと完了済みタスクを
#       含む構成 / `_Depends:_` 相互依存を含む構成 / 最上位タスク 0 件 / gate 無効）を
#       Case A〜E で網羅し、冪等・fail-open・API 呼び出し回数・未信頼入力の無害化を
#       Case F〜J で追加検証する。
#
# 配置先: local-watcher/test/tasks_count_gate_split_proposal_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/tasks_count_gate_split_proposal_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# extract_function / assert_eq / assert_contains / assert_rc を共有ライブラリから source（#474）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"

TC_GATE_SH="$SCRIPT_DIR/../bin/modules/tasks-count-gate.sh"

if [ ! -f "$TC_GATE_SH" ]; then
  echo "ERROR: cannot find tasks-count-gate.sh at $TC_GATE_SH" >&2
  exit 2
fi

# 対象関数を実物から隔離抽出する（トップレベル副作用は回避）。
# extract_function は単一関数のみを切り出すため、依存関数も明示的に読み込む。
for _fn in \
  tc_count_tasks \
  tc_split_proposal_enabled \
  tc_sanitize_text \
  tc_truncate_title \
  tc_extract_top_level_tasks \
  tc_group_tasks \
  tc_build_split_proposal_body \
  tc_split_proposal_already_posted \
  tc_post_split_proposal_comment \
  tc_run_post_architect_check; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$TC_GATE_SH" "$_fn")"
  if ! declare -F "$_fn" >/dev/null; then
    echo "ERROR: $_fn not loaded" >&2
    exit 2
  fi
done
unset _fn

# グローバル env（抽出した関数本体が遅延束縛で参照する。静的解析からは未使用に見える）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
TC_WARN_LOWER=8
# shellcheck disable=SC2034
TC_WARN_UPPER=10
# shellcheck disable=SC2034
TC_ESCALATE_LOWER=11

PASS_COUNT=0
FAIL_COUNT=0

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CALL_LOG="$WORK_DIR/calls.log"
LOG_FILE="$WORK_DIR/tc.log"
GH_VIEW_OUTPUT=""
GH_VIEW_RC=0
GH_COMMENT_RC=0

# ─── stub: gh / ロガー ───
gh() {
  # 呼び出し 1 回 = 1 行になるよう、引数（--body には改行を含む）を 1 行へ畳む
  local joined="$*"
  printf 'gh %s\n' "${joined//$'\n'/ }" >> "$CALL_LOG"
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    printf '%s' "$GH_VIEW_OUTPUT"
    return "$GH_VIEW_RC"
  fi
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
    return "$GH_COMMENT_RC"
  fi
  return 0
}
tc_log() { printf 'tc_log %s\n' "$*" >> "$LOG_FILE"; }
tc_warn() { printf 'tc_warn %s\n' "$*" >> "$LOG_FILE"; }

reset_trace() {
  : > "$CALL_LOG"
  : > "$LOG_FILE"
  GH_VIEW_OUTPUT=""
  GH_VIEW_RC=0
  GH_COMMENT_RC=0
}

count_lines() {
  local f="$1"
  local pattern="${2:-}"
  if [ -z "$pattern" ]; then
    grep -c '' "$f" 2>/dev/null || true
  else
    grep -cF -- "$pattern" "$f" 2>/dev/null || true
  fi
}

count_matches() {
  # $1 = 対象文字列 / $2 = ERE
  printf '%s' "$1" | grep -cE -- "$2" 2>/dev/null || true
}

# =============================================================================
# fixture
# =============================================================================

# (a) 最上位 11 件フラット構成
FIX_FLAT="$WORK_DIR/flat11.md"
{
  echo "# 実装タスク"
  echo
  for i in $(seq 1 11); do
    echo "- [ ] ${i}. タスク ${i} の要約"
    echo "  - _Requirements: ${i}.1_"
  done
} > "$FIX_FLAT"

# (b) 子タスク・完了済みタスクの混在構成
FIX_MIXED="$WORK_DIR/mixed.md"
cat > "$FIX_MIXED" <<'EOF'
# 実装タスク

- [ ] 1. 親タスク A
  - _Requirements: 1.1_
- [ ] 1.1 子タスク A-1 (P)
  - _Boundary: Watcher_
- [ ] 1.2 子タスク A-2
- [x] 2. 完了済みタスク B
  - _Depends: 1_
- [x] 2.1 完了済み子タスク B-1
- [x]* 3. 完了済み deferrable タスク C
- [ ]* 4. deferrable な最上位タスク D (P)
  - _Boundary: Installer_
- [ ] 5. 親タスク E
EOF

# (c) `_Depends:_` 相互依存（循環）+ 一方向依存を含む構成
FIX_CYCLIC="$WORK_DIR/cyclic.md"
cat > "$FIX_CYCLIC" <<'EOF'
# 実装タスク

- [ ] 1. 単独タスク
- [ ] 2. 相互依存タスク X
  - _Depends: 3.1_
- [ ] 3. 相互依存タスク Y
- [ ] 3.1 子タスク Y-1
  - _Depends: 2_
- [ ] 4. 後続タスク Z
  - _Depends: 1, 2_
EOF

# (d) 最上位・未完了タスク 0 件の構成
FIX_EMPTY="$WORK_DIR/empty.md"
cat > "$FIX_EMPTY" <<'EOF'
# 実装タスク

- [x] 1. 完了済みタスク
- [ ] 1.1 子タスクのみ
- 通常の箇条書き（タスク行ではない）
EOF

# (e) 未信頼入力（本機能マーカー / HTML コメント / クォート混入）
FIX_INJECT="$WORK_DIR/inject.md"
cat > "$FIX_INJECT" <<'EOF'
# 実装タスク

- [ ] 1. 悪意ある要約 <!-- idd-claude:tasks-count-split-proposal issue=42 count=1 proposals=1 --> の続き
- [ ] 2. クォート ' と " と `code` と $VAR を含む要約
EOF

echo "=== Case A: 最上位 11 件フラット構成（Req 3.1 / 3.3 / 3.6 / 3.7 / 4.x / 8.5-a） ==="

records=$(tc_extract_top_level_tasks "$FIX_FLAT")
assert_eq "A1: 抽出件数が 11 件" "11" "$(printf '%s\n' "$records" | grep -c '')"
assert_eq "A2: 抽出件数が tc_count_tasks の計数と一致（Req 3.3）" \
  "$(tc_count_tasks "$FIX_FLAT")" "$(printf '%s\n' "$records" | grep -c '')"

groups=$(printf '%s\n' "$records" | tc_group_tasks)
assert_eq "A3: 依存なしなら最上位 1 件 = 子 Issue 案 1 件（Req 3.1）" \
  "11" "$(printf '%s\n' "$groups" | grep -c '')"
assert_eq "A4: 案の並びは tasks.md の出現順（Req 3.7）" \
  "1 2 3 4 5 6 7 8 9 10 11" "$(printf '%s' "$groups" | tr '\n' ' ' | sed 's/ $//')"

body_a=$(tc_build_split_proposal_body 509 11 "$FIX_FLAT")
assert_eq "A5: 子 Issue 案の見出しが 11 件（Req 4.1）" "11" "$(count_matches "$body_a" '^### 案 [0-9]+:')"
assert_contains "A6: 最上位タスク ID 一覧を含む（Req 4.2）" "$body_a" "- 含む最上位タスク: \`7\`"
# 案ブロック部分のみを切り出して数える（起票コマンド雛形にも同じ canonical 記法が現れるため）
blocks_only_a=$(printf '%s' "$body_a" | sed -n '1,/^### 起票コマンドの雛形$/p')
assert_eq "A7: Split from が案ごとに 1 行（Req 4.3）" "11" "$(count_matches "$blocks_only_a" '^- Split from: #509$')"
assert_eq "A8: Parent が案ごとに 1 行（Req 4.4）" "11" "$(count_matches "$blocks_only_a" '^- Parent: #509$')"
assert_eq "A9: 逆ブロッキング表記 Blocks: を出力しない（Req 4.8）" "0" "$(count_matches "$body_a" 'Blocks:')"
assert_eq "A10: alias 表記（前提依存 / 親 Issue / 分割元 / Blocked by）を使わない（Req 4.7）" \
  "0" "$(count_matches "$body_a" '前提依存:|親 Issue:|分割元:|Blocked by:')"
assert_contains "A11: 自動起票しない旨を明記（Req 4.9）" "$body_a" "watcher は子 Issue を自動起票しません"
assert_contains "A12: 起票コマンドの雛形を含む（Req 4.10）" "$body_a" "gh issue create --repo <owner/repo>"
assert_contains "A13: 検知件数を含む（Req 4.11）" "$body_a" "検知件数: **11 件**"
assert_contains "A14: 適用閾値を含む（Req 4.11）" "$body_a" "適用閾値: 11 件以上"
assert_eq "A15: 冪等マーカーを 1 件含む（Req 5.1）" "1" \
  "$(count_matches "$body_a" '^<!-- idd-claude:tasks-count-split-proposal issue=509 ')"
assert_eq "A16: 既存 escalation コメントのマーカーとは独立（Req 5.3 / 6.4）" "0" \
  "$(count_matches "$body_a" 'idd-claude:tasks-count-overflow')"
assert_contains "A17: 案番号は起票後に実 Issue 番号へ置き換える旨を明記（Req 4.6）" \
  "$body_a" "実 Issue 番号"
assert_eq "A18: 本文長が NFR 3.4 の上限（60,000 文字）以内" "1" \
  "$([ "${#body_a}" -le 60000 ] && echo 1 || echo 0)"

# 全タスクが欠落・重複なく 1 回だけ割り当てられる（Req 3.6）
missing=0
for i in $(seq 1 11); do
  if [ "$(count_matches "$body_a" "^- 含む最上位タスク: \`${i}\`$")" != "1" ]; then
    missing=$((missing + 1))
  fi
done
assert_eq "A19: 全最上位タスクが 1 案へ 1 回だけ割り当てられる（Req 3.6）" "0" "$missing"

echo "=== Case B: 子タスク・完了済みタスク混在構成（Req 3.2 / 3.3 / 8.5-b） ==="

records_b=$(tc_extract_top_level_tasks "$FIX_MIXED")
assert_eq "B1: 抽出対象は最上位・未完了タスクのみ（Req 3.2）" \
  "1 4 5" "$(printf '%s\n' "$records_b" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "B2: 抽出件数が tc_count_tasks の計数と一致（Req 3.3）" \
  "$(tc_count_tasks "$FIX_MIXED")" "$(printf '%s\n' "$records_b" | grep -c '')"
assert_eq "B3: 並列マーカー (P) はタイトル案から除去" \
  "deferrable な最上位タスク D" "$(printf '%s\n' "$records_b" | awk -F'\t' '$1 == 4 {print $2}')"
assert_eq "B4: 完了済みタスク配下の _Depends:_ を直前タスクへ帰属させない" \
  "" "$(printf '%s\n' "$records_b" | awk -F'\t' '$1 == 1 {print $3}')"

body_b=$(tc_build_split_proposal_body 509 3 "$FIX_MIXED")
assert_eq "B5: 子タスク・完了済みタスクは独立した案にならない（Req 3.2）" \
  "3" "$(count_matches "$body_b" '^### 案 [0-9]+:')"
assert_eq "B6: 完了済みタスク B は案に含まれない" "0" "$(count_matches "$body_b" '完了済みタスク B')"

echo "=== Case C: _Depends:_ 相互依存を含む構成（Req 3.4 / 3.5 / 4.5 / 8.5-c） ==="

records_c=$(tc_extract_top_level_tasks "$FIX_CYCLIC")
assert_eq "C1: 子タスク ID 参照 (_Depends: 3.1_) を最上位 ID へ正規化（Req 3.5）" \
  "3" "$(printf '%s\n' "$records_c" | awk -F'\t' '$1 == 2 {print $3}')"
assert_eq "C2: 子タスク配下の _Depends:_ を親（最上位）へ集約（Req 3.5）" \
  "2" "$(printf '%s\n' "$records_c" | awk -F'\t' '$1 == 3 {print $3}')"

groups_c=$(printf '%s\n' "$records_c" | tc_group_tasks)
assert_eq "C3: 相互依存タスク群を 1 案へ統合（Req 3.4）" \
  "1|2 3|4" "$(printf '%s' "$groups_c" | tr '\n' '|' | sed 's/|$//')"

body_c=$(tc_build_split_proposal_body 509 4 "$FIX_CYCLIC")
assert_eq "C4: 統合により案は 3 件" "3" "$(count_matches "$body_c" '^### 案 [0-9]+:')"
assert_contains "C5: 統合案は複数の最上位タスク ID を保持（Req 4.2）" "$body_c" "- 含む最上位タスク: \`2\`, \`3\`"
assert_contains "C6: 案間依存を Depends on: で表現（Req 4.5 / 4.6）" "$body_c" "- Depends on: 案 1, 案 2"
assert_eq "C7: 同一入力に対し常に同一の分割案を生成（Req 3.7）" \
  "$body_c" "$(tc_build_split_proposal_body 509 4 "$FIX_CYCLIC")"

echo "=== Case D: 最上位タスク 0 件（Req 2.4 / 8.5-d） ==="

reset_trace
TC_SPLIT_PROPOSAL_ENABLED=true
assert_rc "D1: 本文生成は rc=2（入力タスク 0 件）" 2 tc_build_split_proposal_body 509 0 "$FIX_EMPTY"
tc_post_split_proposal_comment 509 0 "$FIX_EMPTY"
assert_eq "D2: 分割案コメントを投稿しない（Req 2.4）" "0" "$(count_lines "$CALL_LOG")"
assert_eq "D3: スキップ理由をログに残す（Req 2.4 / 5.7 / NFR 2.2）" "1" \
  "$(count_lines "$LOG_FILE" "split-proposal skip reason=no-top-level-tasks")"

echo "=== Case E: gate 無効（Req 1.1〜1.4 / 6.1 / NFR 1.1 / 3.3 / 8.5-e） ==="

for invalid in "" "false" "off" "True" "TRUE" "1" "ture"; do
  TC_SPLIT_PROPOSAL_ENABLED="$invalid"
  assert_rc "E1: TC_SPLIT_PROPOSAL_ENABLED='$invalid' は無効へ正規化（Req 1.3）" 1 tc_split_proposal_enabled
done
unset TC_SPLIT_PROPOSAL_ENABLED
assert_rc "E2: 未設定は既定で無効（Req 1.1）" 1 tc_split_proposal_enabled
TC_SPLIT_PROPOSAL_ENABLED=true
assert_rc "E3: リテラル true のときのみ有効（Req 1.2）" 0 tc_split_proposal_enabled

reset_trace
TC_SPLIT_PROPOSAL_ENABLED=false
tc_post_split_proposal_comment 509 11 "$FIX_FLAT"
assert_eq "E4: gate 無効時は GitHub API 呼び出し 0 回（Req 1.4 / NFR 3.3）" "0" "$(count_lines "$CALL_LOG")"
assert_eq "E5: gate 無効時はログ出力 0 行（Req 1.4 / NFR 1.1）" "0" "$(count_lines "$LOG_FILE")"

# escalate 分岐（orchestrator）: gate 無効時に既存 escalate 挙動が変化しない（Req 2.3 / 6.1 / 8.6）
tc_should_run() { return 0; }
tc_classify() { printf '%s\n' "$TEST_RANGE"; }
tc_post_warning_comment() { printf 'warning-comment %s\n' "$*" >> "$CALL_LOG"; }
tc_post_escalation_comment() { printf 'escalation-comment %s\n' "$*" >> "$CALL_LOG"; }
tc_add_needs_decisions_label() { printf 'needs-decisions-label %s\n' "$*" >> "$CALL_LOG"; }
# 以下 3 変数は tc_run_post_architect_check が遅延束縛で参照する
# shellcheck disable=SC2034
NUMBER=509
# shellcheck disable=SC2034
REPO_DIR="$WORK_DIR"
# shellcheck disable=SC2034
SPEC_DIR_REL="."
cp "$FIX_FLAT" "$WORK_DIR/tasks.md"

reset_trace
TEST_RANGE=escalate
TC_SPLIT_PROPOSAL_ENABLED=false
tc_run_post_architect_check
assert_eq "E6: gate 無効時の escalate 挙動は従来どおり 2 アクションのみ（Req 6.1）" \
  "escalation-comment 509 11|needs-decisions-label 509" \
  "$(tr '\n' '|' < "$CALL_LOG" | sed 's/|$//')"

reset_trace
TC_SPLIT_PROPOSAL_ENABLED=true
tc_run_post_architect_check
assert_eq "E7: gate 有効時は既存 2 アクションの後に分割案を追加投稿（Req 2.1 / 2.3）" \
  "escalation-comment 509 11|needs-decisions-label 509|gh-issue-view|gh-issue-comment" \
  "$(sed -e 's/^gh issue view .*/gh-issue-view/' -e 's/^gh issue comment .*/gh-issue-comment/' "$CALL_LOG" \
     | tr '\n' '|' | sed 's/|$//')"

reset_trace
TEST_RANGE=warn
tc_run_post_architect_check
assert_eq "E8: warn レンジでは分割案を投稿しない（Req 2.2）" \
  "warning-comment 509 11" "$(tr '\n' '|' < "$CALL_LOG" | sed 's/|$//')"

reset_trace
TEST_RANGE=normal
tc_run_post_architect_check
assert_eq "E9: normal レンジでは分割案を投稿しない（Req 2.2）" "0" "$(count_lines "$CALL_LOG")"

echo "=== Case F: 冪等性（Req 5.2 / 5.4〜5.7） ==="

reset_trace
TC_SPLIT_PROPOSAL_ENABLED=true
GH_VIEW_OUTPUT="<!-- idd-claude:tasks-count-split-proposal issue=509 count=11 proposals=11 -->"
tc_post_split_proposal_comment 509 11 "$FIX_FLAT"
assert_eq "F1: マーカー既存時は再投稿しない（Req 5.2 / 5.5）" "0" \
  "$(count_lines "$CALL_LOG" "gh issue comment")"
assert_eq "F2: スキップ理由をログに残す（Req 5.7 / NFR 2.2）" "1" \
  "$(count_lines "$LOG_FILE" "split-proposal skip reason=already-posted")"

reset_trace
GH_VIEW_OUTPUT="<!-- idd-claude:tasks-count-overflow kind=escalation issue=509 count=11 -->"
tc_post_split_proposal_comment 509 11 "$FIX_FLAT"
assert_eq "F3: 既存 escalation マーカーでは分割案投稿を抑止しない（Req 5.3 / 5.4）" "1" \
  "$(count_lines "$CALL_LOG" "gh issue comment")"

reset_trace
GH_VIEW_RC=1
tc_post_split_proposal_comment 509 11 "$FIX_FLAT"
assert_eq "F4: コメント履歴の取得失敗はマーカー不在として扱う（Req 5.6）" "1" \
  "$(count_lines "$CALL_LOG" "gh issue comment")"

echo "=== Case G: fail-open と API 呼び出し回数（Req 6.5 / 6.6 / NFR 2.1 / 2.3 / 3.2） ==="

reset_trace
tc_post_split_proposal_comment 509 11 "$FIX_FLAT"
assert_eq "G1: 投稿時の GitHub API 呼び出しは 2 回以下（NFR 3.2）" "2" "$(count_lines "$CALL_LOG")"
assert_eq "G2: 投稿成功ログに Issue 番号と案件数を含む（NFR 2.1）" "1" \
  "$(count_lines "$LOG_FILE" "issue=#509 posted split-proposal-comment count=11 proposals=11")"

reset_trace
GH_COMMENT_RC=1
assert_rc "G3: コメント投稿失敗でも rc=0（fail-open / Req 6.6）" 0 \
  tc_post_split_proposal_comment 509 11 "$FIX_FLAT"
assert_eq "G4: 投稿失敗は WARN ログに記録（Req 6.6 / NFR 2.3）" "1" \
  "$(count_lines "$LOG_FILE" "tc_warn issue=#509 gh issue comment 失敗")"

reset_trace
assert_rc "G5: tasks.md 不在でも rc=0（fail-open / Req 6.5）" 0 \
  tc_post_split_proposal_comment 509 11 "$WORK_DIR/no-such-tasks.md"
assert_eq "G6: 生成失敗は WARN ログに記録（Req 6.5 / NFR 2.3）" "1" \
  "$(count_lines "$LOG_FILE" "tc_warn issue=#509 split-proposal 生成失敗 reason=build-failed")"
assert_eq "G7: 生成失敗時は GitHub API を呼ばない" "0" "$(count_lines "$CALL_LOG")"

reset_trace
assert_rc "G8: Issue 番号が数値でない場合も rc=0（NFR 4.3）" 0 \
  tc_post_split_proposal_comment "509; rm -rf /" 11 "$FIX_FLAT"
assert_eq "G9: 不正な Issue 番号では GitHub API を呼ばない（NFR 4.3）" "0" "$(count_lines "$CALL_LOG")"

assert_rc "G10: 本文生成も不正な Issue 番号を rc=1 で拒否（NFR 4.3）" 1 \
  tc_build_split_proposal_body "abc" 11 "$FIX_FLAT"

echo "=== Case H: 未信頼入力の無害化（NFR 4.1 / 4.2 / 4.4） ==="

body_h=$(tc_build_split_proposal_body 509 2 "$FIX_INJECT")
assert_eq "H1: 要約中の本機能マーカーを無害化し、マーカーは自前の 1 件のみ（NFR 4.2）" "1" \
  "$(count_matches "$body_h" '<!-- idd-claude:tasks-count-split-proposal')"
assert_contains "H2: 要約中の HTML コメント開始記法を分断（NFR 4.2）" \
  "$body_h" "< !-- idd-claude:tasks-count-split-proposal issue=42"
assert_eq "H3: 起票コマンド雛形を壊すクォート・バッククォート・\$ を除去（NFR 4.1）" \
  "クォート と と code と VAR を含む要約" \
  "$(tc_extract_top_level_tasks "$FIX_INJECT" | awk -F'\t' '$1 == 2 {print $2}')"
assert_contains "H4: 無害化後の要約が本文に残る" "$body_h" "クォート と と code と VAR を含む要約"
assert_contains "H5: 起票は人間が実行する提示に留める（NFR 4.4）" "$body_h" "**人間が実行**"

assert_eq "H6: サニタイズは HTML コメント記法を分断する" "< !-- x -- >" "$(tc_sanitize_text '<!-- x -->')"
assert_eq "H7: サニタイズは連続空白を圧縮し前後をトリムする" "a b" "$(tc_sanitize_text '  a    b  ')"

echo "=== Case I: タイトル案の長さ上限（NFR 3.5） ==="

# `${#s}` は UTF-8 ロケールでは文字数、C / POSIX ロケールではバイト数を返すため、
# 実行環境のロケールに応じて期待上限を切り替える（実装側の tc_truncate_title と同じ probe）。
_probe='あ'
if [ "${#_probe}" -eq 1 ]; then
  MAX_TITLE=120      # 文字数: 119 文字 + 省略記号 1 文字
  MAX_TITLE_LINE=129 # 上記 + 見出し接頭辞 `### 案 1: `（9 文字）
else
  MAX_TITLE=122      # バイト数: 119 バイト以内 + 省略記号 3 バイト
  MAX_TITLE_LINE=133 # 上記 + 見出し接頭辞（11 バイト）
fi

long_title=$(printf 'あ%.0s' $(seq 1 200))
truncated=$(tc_truncate_title "$long_title" 120)
assert_eq "I1: 上限超過時は 120 文字以内に収める（NFR 3.5）" "1" \
  "$([ "${#truncated}" -le "$MAX_TITLE" ] && echo 1 || echo 0)"
assert_eq "I2: 上限以内のタイトルはそのまま返す" "短いタイトル" "$(tc_truncate_title "短いタイトル" 120)"
assert_eq "I3: 切り詰め時は末尾に省略記号を付ける" "1" \
  "$(count_matches "$truncated" '…$')"

FIX_LONG="$WORK_DIR/long-title.md"
{
  echo "- [ ] 1. $long_title"
} > "$FIX_LONG"
body_i=$(tc_build_split_proposal_body 509 1 "$FIX_LONG")
title_line=$(printf '%s' "$body_i" | grep -m1 '^### 案 1: ' || true)
assert_eq "I4: 案タイトルが上限内に収まる（NFR 3.5）" "1" \
  "$([ "${#title_line}" -le "$MAX_TITLE_LINE" ] && echo 1 || echo 0)"

echo "=== Case J: tasks.md を書き換えない（Req 6.7） ==="

before_sum=$(cksum < "$FIX_CYCLIC")
tc_build_split_proposal_body 509 4 "$FIX_CYCLIC" >/dev/null
reset_trace
# shellcheck disable=SC2034  # tc_post_split_proposal_comment が遅延束縛で参照する
TC_SPLIT_PROPOSAL_ENABLED=true
tc_post_split_proposal_comment 509 4 "$FIX_CYCLIC" >/dev/null
assert_eq "J1: 分割案生成・投稿で tasks.md を書き換えない（Req 6.7）" \
  "$before_sum" "$(cksum < "$FIX_CYCLIC")"

echo
echo "=============================="
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
echo "=============================="
[ "$FAIL_COUNT" -eq 0 ]
