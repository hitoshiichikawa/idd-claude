#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/dep-cycle-detect.sh の cycle 検出機能（Issue #368 / D-16）の
#       スモークテスト。`dc_*` 関数群を fixture で検証する。
#
#       対象関数:
#         - dc_gate_enabled            (Req 1.1〜1.3 / NFR 1.1 gate 正規化)
#         - dc_normalize_targets       (Req 2.1 / NFR 5.1 入力正規化)
#         - dc_extract_edges           (Req 2.1 / 2.2 エッジ抽出 + 対象集合フィルタ)
#         - dc_build_graph_lines       (Req 2.1 / 2.2 / NFR 2.2 グラフ構築)
#         - dc_find_cycles             (Req 3.1〜3.5 閉路検出アルゴリズム)
#         - dc_has_cycle_marker        (Req 5.2 冪等性判定)
#         - dc_format_cycle_comment    (Req 4.2 / 4.3 / NFR 5.2 説明コメント整形)
#         - dc_escalate_member         (Req 4.1〜4.6 / 5.1〜5.3 / 6.3〜6.5 個別エスカレーション)
#         - dc_cycle_sweep             (Req 2.1〜2.4 / 3.x / 4.x / 5.x / 6.x / NFR 2.x 入口)
#
#       検証する AC（docs/specs/368-feat-watcher-cycle-needs-decisions-d-16/requirements.md）:
#         - AT-a: DAG（閉路なし）→ cycle 検出ゼロ件
#         - AT-b: 自己依存（A→A）→ A に needs-decisions + 説明コメント 1 件
#         - AT-c: 2 ノード閉路（A→B→A）→ A, B にそれぞれ 1 件
#         - AT-d: 多段閉路（A→B→C→A）→ A, B, C にそれぞれ 1 件
#         - AT-e: 閉路 + 非閉路混在 → 閉路メンバーのみ対象
#         - AT-f: 複数独立閉路 → 全メンバー対象
#         - AT-g: 連続 2 回スイープ → 累積なし（冪等）
#         - AT-h: gate OFF → cycle 検出走らない（dr_unblock_sweep の早期 return）
#         - AT-i: ラベル付与成功 + コメント投稿失敗 → 警告ログ 1 行
#         - AT-j: 閉路メンバーは auto-unblock の blocked 解除対象から除外
#
# 配置先: local-watcher/test/dc_cycle_sweep_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/dc_cycle_sweep_test.sh

set -euo pipefail

# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
MODULE_SH="$SCRIPT_DIR/../bin/modules/dep-cycle-detect.sh"

if [ ! -f "$WATCHER_SH" ] || [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find watcher or module" >&2
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

# dep-cycle-detect.sh の関数群を抽出ロード
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_gate_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_normalize_targets")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_extract_edges")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_build_graph_lines")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_find_cycles")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_has_cycle_marker")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_format_cycle_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_escalate_member")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "dc_cycle_sweep")"

# issue-watcher.sh から遅延束縛で呼ばれる関数を抽出ロード
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_extract_deps")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_gate_enabled")"

for fn in dc_gate_enabled dc_normalize_targets dc_extract_edges dc_build_graph_lines \
          dc_find_cycles dc_has_cycle_marker dc_format_cycle_comment \
          dc_escalate_member dc_cycle_sweep dr_extract_deps dr_unblock_gate_enabled; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（抽出関数から遅延束縛で参照される）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_NEEDS_DECISIONS="needs-decisions"
DC_CYCLE_MARKER='<!-- idd-claude:dep-cycle-detected:v1 -->'

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

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL: $label"
      echo "  forbidden: $(printf '%q' "$needle")"
      echo "  actual   : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    *)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
}

# ── stub state ──
reset_stub_state() {
  GH_EDIT_RC="${1:-0}"
  GH_COMMENT_RC="${2:-0}"
  GH_VIEW_COMMENTS_JSON="${3:-}"
  if [ -z "$GH_VIEW_COMMENTS_JSON" ]; then
    GH_VIEW_COMMENTS_JSON='{"comments": []}'
  fi
  GH_VIEW_RC="${4:-0}"
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
}

# shellcheck disable=SC2317
dr_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
dr_warn() { echo "$*" >>"$WARN_LOG"; }

# shellcheck disable=SC2317
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  case "$sub" in
    issue)
      case "$sub2" in
        edit)
          echo "gh issue edit $*" >>"$GH_CALL_LOG"
          return "${GH_EDIT_RC:-0}"
          ;;
        view)
          echo "gh issue view $*" >>"$GH_CALL_LOG"
          if [ "${GH_VIEW_RC:-0}" -ne 0 ]; then
            return "${GH_VIEW_RC}"
          fi
          printf '%s' "${GH_VIEW_COMMENTS_JSON}"
          return 0
          ;;
        comment)
          echo "gh issue comment $*" >>"$GH_CALL_LOG"
          return "${GH_COMMENT_RC:-0}"
          ;;
        *)
          echo "gh issue $* (unhandled)" >>"$GH_CALL_LOG"
          return 0
          ;;
      esac
      ;;
    *)
      echo "gh $* (unhandled)" >>"$GH_CALL_LOG"
      return 0
      ;;
  esac
}

count_calls() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_warns() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$WARN_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

count_logs() {
  local pattern="$1"
  local n
  n=$( { grep -E -- "$pattern" "$LOG_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# Helper: 候補集合 JSON を作る
make_issues_json() {
  # 引数: (issue_num body) ペアの繰り返し
  local args=("$@")
  local i n issue body json='[]'
  n=${#args[@]}
  for ((i=0; i<n; i+=2)); do
    issue="${args[i]}"
    body="${args[i+1]}"
    json=$(jq -c --argjson num "$issue" --arg b "$body" \
      '. + [{"number":$num,"body":$b}]' <<<"$json")
  done
  printf '%s' "$json"
}

# ============================================================
# Pure: dc_normalize_targets
# ============================================================
echo "--- dc_normalize_targets: 入力正規化 ---"

out=$(dc_normalize_targets "100 200,300
400")
assert_eq "Req 2.1: 任意区切り混在 → 空白区切り昇順" "100 200 300 400" "$out"

out=$(dc_normalize_targets "300 100 200 100")
assert_eq "Req 2.1 / NFR 5.1: 重複排除 + 昇順" "100 200 300" "$out"

out=$(dc_normalize_targets "abc 100 def 200")
assert_eq "NFR 5.1: 数値以外を除外（^[0-9]+\$）" "100 200" "$out"

out=$(dc_normalize_targets "")
assert_eq "空入力 → 空出力" "" "$out"

# ============================================================
# Pure: dc_extract_edges
# ============================================================
echo ""
echo "--- dc_extract_edges: 単一 Issue エッジ抽出 ---"

# 対象集合 {100, 200, 300}、本文に 100 / 200 / 999 への依存（999 は対象外）
BODY1=$'Depends on: #100\nBlocked by: #200\n前提依存: #999'
out=$(dc_extract_edges "50" "$BODY1" "100 200 300")
# 出力順は dr_extract_deps の昇順 + フィルタ後の順序
assert_contains "Req 2.1: 対象集合内エッジ #50→#100 抽出" "$out" "50 100"
assert_contains "Req 2.1: 対象集合内エッジ #50→#200 抽出" "$out" "50 200"
assert_not_contains "Req 2.2: 対象集合外 #999 は除外" "$out" "50 999"

# 自己ループ
BODY_SELF=$'Depends on: #42'
out=$(dc_extract_edges "42" "$BODY_SELF" "42 100")
assert_eq "Req 3.1: 自己ループ #42→#42 抽出" "42 42" "$out"

# 依存記法なし
out=$(dc_extract_edges "50" "本文に依存記法はない" "100 200")
assert_eq "依存記法なし → 空出力" "" "$out"

# ============================================================
# Pure: dc_build_graph_lines
# ============================================================
echo ""
echo "--- dc_build_graph_lines: グラフ構築 ---"

JSON_DAG=$(make_issues_json \
  1 $'Depends on: #2' \
  2 $'Depends on: #3' \
  3 $'')
edges=$(dc_build_graph_lines "$JSON_DAG")
expected_dag=$'1 2\n2 3'
assert_eq "Req 2.1: DAG（A→B→C）エッジ抽出" "$expected_dag" "$edges"

# 対象集合外を含む本文（外部 #999 は除外）
JSON_FILTER=$(make_issues_json \
  10 $'Depends on: #20\nDepends on: #999' \
  20 $'')
edges=$(dc_build_graph_lines "$JSON_FILTER")
assert_eq "Req 2.2: 対象集合外エッジ除外" "10 20" "$edges"

# 空入力
edges=$(dc_build_graph_lines "[]")
assert_eq "Req 2.4: 空候補集合 → 空エッジ" "" "$edges"

# ============================================================
# Pure: dc_find_cycles
# ============================================================
echo ""
echo "--- dc_find_cycles: 閉路検出 ---"

# AT-a: DAG → no cycles
EDGES_DAG=$'1 2\n2 3'
cycles=$(dc_find_cycles "$EDGES_DAG")
assert_eq "AT-a: DAG（A→B→C）→ 閉路ゼロ" "" "$cycles"

# AT-b: 自己ループ
EDGES_SELF=$'42 42'
cycles=$(dc_find_cycles "$EDGES_SELF")
assert_eq "AT-b: 自己ループ #42→#42 → cycle {42}" "42" "$cycles"

# AT-c: A→B→A
EDGES_2N=$'10 20\n20 10'
cycles=$(dc_find_cycles "$EDGES_2N")
assert_eq "AT-c: 2 ノード閉路 → cycle {10, 20}" "10 20" "$cycles"

# AT-d: A→B→C→A
EDGES_3N=$'1 2\n2 3\n3 1'
cycles=$(dc_find_cycles "$EDGES_3N")
assert_eq "AT-d: 3 ノード閉路 → cycle {1, 2, 3}" "1 2 3" "$cycles"

# AT-e: 閉路 + 非閉路混在
EDGES_MIX=$'1 2\n2 1\n4 5'
cycles=$(dc_find_cycles "$EDGES_MIX")
assert_eq "AT-e: 混在 → 閉路 {1,2} のみ列挙" "1 2" "$cycles"

# AT-f: 複数独立閉路（{1,2} と {3,4}）
EDGES_MULTI=$'1 2\n2 1\n3 4\n4 3'
cycles=$(dc_find_cycles "$EDGES_MULTI")
# 出力順: SCC root（最小 idx）昇順 → 番号小さい SCC 先
expected_multi=$'1 2\n3 4'
assert_eq "AT-f: 複数独立閉路 → 2 行出力（各 SCC ソート済み）" "$expected_multi" "$cycles"

# 長さ 4 の閉路
EDGES_4N=$'1 2\n2 3\n3 4\n4 1'
cycles=$(dc_find_cycles "$EDGES_4N")
assert_eq "Req 3.2: 長さ 4 の閉路 → 全メンバー" "1 2 3 4" "$cycles"

# Req 3.4: 閉路 + DAG 部分（1→2→1 cycle + 3→cycle into 1 from outside）
EDGES_INTO=$'1 2\n2 1\n3 1'
cycles=$(dc_find_cycles "$EDGES_INTO")
# 3 は閉路でない（SCC サイズ 1 で自己ループなし）
assert_eq "Req 3.4: 非閉路 DAG 部分は除外" "1 2" "$cycles"

# Req 3.5: 入力空 → 即終了
cycles=$(dc_find_cycles "")
assert_eq "Req 3.5: 空入力 → 空出力（無限ループしない）" "" "$cycles"

# ============================================================
# Pure: dc_format_cycle_comment
# ============================================================
echo ""
echo "--- dc_format_cycle_comment: 説明コメント整形 ---"

out=$(dc_format_cycle_comment "10" "10 20 30")
assert_contains "Req 4.2: コメントに閉路メンバー #10 含む" "$out" "#10"
assert_contains "Req 4.2: コメントに閉路メンバー #20 含む" "$out" "#20"
assert_contains "Req 4.2: コメントに閉路メンバー #30 含む" "$out" "#30"
assert_contains "Req 4.3 / NFR 4.2: 説明コメントに本機能由来マーカー含む" \
  "$out" "$DC_CYCLE_MARKER"
assert_contains "Req 4.2: needs-decisions ラベルへの言及" "$out" "needs-decisions"

# ============================================================
# dc_gate_enabled: gate 正規化
# ============================================================
echo ""
echo "--- dc_gate_enabled: gate 正規化（Req 1.1〜1.3） ---"

unset DEP_AUTO_UNBLOCK_ENABLED
rc=0; dc_gate_enabled || rc=$?
assert_eq "Req 1.2: 未設定で gate OFF (rc=1)" "1" "$rc"

DEP_AUTO_UNBLOCK_ENABLED="true"
rc=0; dc_gate_enabled || rc=$?
assert_eq "Req 1.1: =true で gate ON (rc=0)" "0" "$rc"

DEP_AUTO_UNBLOCK_ENABLED="True"
rc=0; dc_gate_enabled || rc=$?
assert_eq "Req 1.3: =True（typo）は OFF に正規化" "1" "$rc"

DEP_AUTO_UNBLOCK_ENABLED="1"
rc=0; dc_gate_enabled || rc=$?
assert_eq "Req 1.3: =1 は OFF に正規化" "1" "$rc"

# dc_gate_enabled は ${DEP_AUTO_UNBLOCK_ENABLED:-false} を case 文で読むため、
# 静的解析からは「未使用」判定される。末尾の最終 assignment + 即実行で抑止する
# （dr_unblock_sweep_test.sh と同パターン）。
# shellcheck disable=SC2034
DEP_AUTO_UNBLOCK_ENABLED="false"
rc=0; dc_gate_enabled || rc=$?
assert_eq "Req 1.2: =false は OFF" "1" "$rc"

unset DEP_AUTO_UNBLOCK_ENABLED

# ============================================================
# dc_has_cycle_marker: 冪等性判定
# ============================================================
echo ""
echo "--- dc_has_cycle_marker: 既通知判定（Req 5.2） ---"

reset_stub_state
# 未通知（コメントなし）
rc=0; dc_has_cycle_marker "42" || rc=$?
assert_eq "Req 5.2: 未通知 → rc=1（未検出）" "1" "$rc"
cleanup_stub_state

# 通知済（マーカーあり）
EXIST_COMMENTS=$(jq -cn --arg m "$DC_CYCLE_MARKER" \
  '{"comments":[{"body":("過去通知\n" + $m)}]}')
reset_stub_state 0 0 "$EXIST_COMMENTS" 0
rc=0; dc_has_cycle_marker "42" || rc=$?
assert_eq "Req 5.2: 通知済 → rc=0（検出）" "0" "$rc"
cleanup_stub_state

# gh 失敗 → 安全側で「投稿済扱い」（NFR 3.2）
reset_stub_state 0 0 "" 1
rc=0; dc_has_cycle_marker "42" || rc=$?
assert_eq "NFR 3.2: gh 失敗 → 安全側で投稿済扱い (rc=0)" "0" "$rc"
cleanup_stub_state

# ============================================================
# dc_escalate_member: 個別エスカレーション
# ============================================================
echo ""
echo "--- dc_escalate_member: 個別エスカレーション（Req 4.1〜4.6） ---"

# 未通知 → ラベル付与 + コメント投稿
reset_stub_state 0 0 '{"comments": []}' 0
dc_escalate_member "100" "100 200"
edit_count=$(count_calls "gh issue edit.*--add-label.*needs-decisions")
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 4.1: 未通知 → needs-decisions 付与 1 回" "1" "$edit_count"
assert_eq "Req 4.2: 未通知 → 説明コメント投稿 1 回" "1" "$comment_count"
escalated_log=$(count_logs "verdict=cycle_escalated")
assert_eq "Req 6.3: verdict=cycle_escalated ログ 1 行" "1" "$escalated_log"
# コメント本文にマーカー含む
if grep -qF -- "$DC_CYCLE_MARKER" "$GH_CALL_LOG"; then
  echo "PASS: NFR 4.2: 説明コメントにマーカー含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 4.2: 説明コメントにマーカー含む"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_stub_state

# 通知済 → skip
EXIST_COMMENTS=$(jq -cn --arg m "$DC_CYCLE_MARKER" \
  '{"comments":[{"body":("通知済\n" + $m)}]}')
reset_stub_state 0 0 "$EXIST_COMMENTS" 0
dc_escalate_member "100" "100 200"
edit_count=$(count_calls "gh issue edit")
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 5.3: 通知済 → ラベル付与 API 呼ばない" "0" "$edit_count"
assert_eq "Req 5.2: 通知済 → コメント投稿しない" "0" "$comment_count"
already_log=$(count_logs "verdict=cycle_already_notified")
assert_eq "Req 6.4: verdict=cycle_already_notified ログ 1 行" "1" "$already_log"
cleanup_stub_state

# AT-i: ラベル付与成功 + コメント投稿失敗 → 警告ログ
reset_stub_state 0 1 '{"comments": []}' 0
dc_escalate_member "100" "100 200"
warn_count=$(count_warns "cycle 説明コメント投稿に失敗")
assert_eq "AT-i / Req 4.6: コメント投稿失敗 → 警告ログ 1 行" "1" "$warn_count"
cleanup_stub_state

# ラベル付与失敗 → コメント投稿せず skip（Req 4.5）
reset_stub_state 1 0 '{"comments": []}' 0
dc_escalate_member "100" "100 200"
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 4.5: ラベル付与失敗 → コメント投稿せず skip" "0" "$comment_count"
warn_count=$(count_warns "add-label.*needs-decisions.*失敗")
assert_eq "Req 4.5: ラベル付与失敗 → 警告ログ 1 行" "1" "$warn_count"
cleanup_stub_state

# 不正な番号 → 警告 + skip（NFR 5.1）
reset_stub_state 0 0 '{"comments": []}' 0
dc_escalate_member "abc" "100 200"
warn_count=$(count_warns "数値検証失敗")
assert_eq "NFR 5.1: 不正番号 → 警告ログ + skip" "1" "$warn_count"
edit_count=$(count_calls "gh issue edit")
assert_eq "NFR 5.1: 不正番号 → gh 呼び出しゼロ" "0" "$edit_count"
cleanup_stub_state

# ============================================================
# dc_cycle_sweep: 入口（fixture ベース統合）
# ============================================================
echo ""
echo "--- dc_cycle_sweep: 入口統合（AT-a〜AT-f, AT-g, AT-j 基盤） ---"

# AT-a: DAG → 閉路ゼロ
JSON_DAG=$(make_issues_json \
  1 $'Depends on: #2' \
  2 $'Depends on: #3' \
  3 $'')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_DAG"
edit_count=$(count_calls "gh issue edit")
assert_eq "AT-a: DAG → ラベル付与ゼロ" "0" "$edit_count"
assert_eq "AT-a: DAG → _DC_CYCLE_MEMBERS 空" "" "$_DC_CYCLE_MEMBERS"
cycles_log=$(count_logs "cycles=0")
# 1 行: "cycles=0 targets=..." または 2 行（no edges + cycles=0）
if [ "$cycles_log" -ge 1 ]; then
  echo "PASS: Req 6.2: cycles=0 サマリログ 1 行以上"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 6.2: cycles=0 サマリログ 1 行以上 (actual=$cycles_log)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_stub_state

# AT-b: 自己依存
JSON_SELF=$(make_issues_json 42 $'Depends on: #42')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_SELF"
edit_count=$(count_calls "gh issue edit.*--add-label.*needs-decisions")
comment_count=$(count_calls "gh issue comment")
assert_eq "AT-b: 自己依存 → ラベル付与 1 回" "1" "$edit_count"
assert_eq "AT-b: 自己依存 → コメント投稿 1 回" "1" "$comment_count"
assert_eq "AT-b: _DC_CYCLE_MEMBERS=42" "42" "$_DC_CYCLE_MEMBERS"
cleanup_stub_state

# AT-c: 2 ノード閉路 A→B→A
JSON_2N=$(make_issues_json \
  10 $'Depends on: #20' \
  20 $'Depends on: #10')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_2N"
edit_count=$(count_calls "gh issue edit.*--add-label.*needs-decisions")
comment_count=$(count_calls "gh issue comment")
assert_eq "AT-c: A→B→A → ラベル付与 2 回" "2" "$edit_count"
assert_eq "AT-c: A→B→A → コメント投稿 2 回" "2" "$comment_count"
assert_eq "AT-c: _DC_CYCLE_MEMBERS=10 20" "10 20" "$_DC_CYCLE_MEMBERS"
cleanup_stub_state

# AT-d: 3 ノード閉路
JSON_3N=$(make_issues_json \
  1 $'Depends on: #2' \
  2 $'Depends on: #3' \
  3 $'Depends on: #1')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_3N"
edit_count=$(count_calls "gh issue edit.*--add-label.*needs-decisions")
assert_eq "AT-d: A→B→C→A → ラベル付与 3 回" "3" "$edit_count"
assert_eq "AT-d: _DC_CYCLE_MEMBERS=1 2 3" "1 2 3" "$_DC_CYCLE_MEMBERS"
cleanup_stub_state

# AT-e: 閉路 + 非閉路混在（A→B→A, D→E）
JSON_MIX=$(make_issues_json \
  1 $'Depends on: #2' \
  2 $'Depends on: #1' \
  4 $'Depends on: #5' \
  5 $'')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_MIX"
edit_count=$(count_calls "gh issue edit.*--add-label.*needs-decisions")
assert_eq "AT-e: 閉路メンバーのみ対象（D, E は除外） → 付与 2 回" "2" "$edit_count"
assert_eq "AT-e: _DC_CYCLE_MEMBERS=1 2（4, 5 含まず）" "1 2" "$_DC_CYCLE_MEMBERS"
cleanup_stub_state

# AT-f: 複数独立閉路
JSON_MULTI=$(make_issues_json \
  1 $'Depends on: #2' \
  2 $'Depends on: #1' \
  3 $'Depends on: #4' \
  4 $'Depends on: #3')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_MULTI"
edit_count=$(count_calls "gh issue edit.*--add-label.*needs-decisions")
assert_eq "AT-f: 2 独立閉路 → 4 メンバー全員付与" "4" "$edit_count"
assert_eq "AT-f: _DC_CYCLE_MEMBERS=1 2 3 4" "1 2 3 4" "$_DC_CYCLE_MEMBERS"
# 閉路ごとのログ 2 行（Req 6.1 / NFR 4.1）
cycle_logs=$(count_logs "dc_cycle_sweep: cycle=")
assert_eq "Req 6.1 / NFR 4.1: 閉路ごとのログ 2 行" "2" "$cycle_logs"
cleanup_stub_state

# AT-g: 連続 2 回スイープ → 累積なし（NFR 6.1 / Req 5.1）
JSON_2N=$(make_issues_json \
  10 $'Depends on: #20' \
  20 $'Depends on: #10')

# 1 回目: 未通知（コメントなし）
reset_stub_state 0 0 '{"comments": []}' 0
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_2N"
edit_count_1=$(count_calls "gh issue edit.*--add-label.*needs-decisions")
comment_count_1=$(count_calls "gh issue comment")
assert_eq "AT-g: 1 回目 → 付与 2 件" "2" "$edit_count_1"
assert_eq "AT-g: 1 回目 → コメント 2 件" "2" "$comment_count_1"
cleanup_stub_state

# 2 回目: 通知済（マーカー付き）
EXIST_COMMENTS=$(jq -cn --arg m "$DC_CYCLE_MARKER" \
  '{"comments":[{"body":("通知済\n" + $m)}]}')
reset_stub_state 0 0 "$EXIST_COMMENTS" 0
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_2N"
edit_count_2=$(count_calls "gh issue edit")
comment_count_2=$(count_calls "gh issue comment")
assert_eq "AT-g / Req 5.3: 2 回目 → ラベル付与ゼロ（冪等）" "0" "$edit_count_2"
assert_eq "AT-g / Req 5.1: 2 回目 → コメント投稿ゼロ（冪等）" "0" "$comment_count_2"
notified_logs=$(count_logs "verdict=cycle_already_notified")
assert_eq "Req 6.4: 2 回目で cycle_already_notified ログ 2 行" "2" "$notified_logs"
cleanup_stub_state

# AT-h（gate OFF）は dr_unblock_sweep 側で評価され、本関数が呼ばれない。
# ここでは dc_gate_enabled で代替検証済み（既述）。

# Req 2.4: 空候補集合 → API ゼロ
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "[]"
gh_count=$(count_calls "^gh ")
assert_eq "Req 2.4 / NFR 2.1: 空候補集合 → gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# ============================================================
# AT-j: 閉路メンバーは auto-unblock の blocked 解除対象から除外
# （dr_unblock_sweep の skip 分岐を確認）
# ============================================================
echo ""
echo "--- AT-j: 閉路メンバー auto-unblock 除外（Req 4.4 / NFR 3.3） ---"

# dr_unblock_sweep / dr_unblock_resolve_one_issue は dr_unblock_sweep_test.sh で検証済み。
# 本テストでは _DC_CYCLE_MEMBERS が空白区切りで cycle 検出後に正しく export されること、
# および値が auto-unblock 側の grep に渡せる形式であることを検証する。

JSON_2N=$(make_issues_json \
  10 $'Depends on: #20' \
  20 $'Depends on: #10')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_2N"

# _DC_CYCLE_MEMBERS は空白区切りの数値リストで、grep -xF で検索可能
case " $_DC_CYCLE_MEMBERS " in
  *" 10 "*)
    echo "PASS: AT-j: _DC_CYCLE_MEMBERS に member=10 含む（auto-unblock skip 入力として使用可能）"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: AT-j: _DC_CYCLE_MEMBERS に member=10 含まれない (value=$_DC_CYCLE_MEMBERS)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
case " $_DC_CYCLE_MEMBERS " in
  *" 20 "*)
    echo "PASS: AT-j: _DC_CYCLE_MEMBERS に member=20 含む"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: AT-j: _DC_CYCLE_MEMBERS に member=20 含まれない (value=$_DC_CYCLE_MEMBERS)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac

# grep -xF（dr_unblock_sweep が使う検索方法）で個別検索できることを確認
lines=$(printf '%s\n' "$_DC_CYCLE_MEMBERS" | tr ' ' '\n')
if printf '%s\n' "$lines" | grep -qxF -- "10"; then
  echo "PASS: AT-j: grep -xF で member=10 ヒット（dr_unblock_sweep の skip 条件と整合）"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: AT-j: grep -xF で member=10 ヒットせず"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_stub_state

# ============================================================
# NFR 3.1: 依存マーカー解析が空 → ノード登録するがエッジ追加せず
# （Issue 本文に依存記法がない Issue を含む混在 fixture で確認）
# ============================================================
echo ""
echo "--- NFR 3.1: 空依存 Issue は閉路から自然に除外 ---"

JSON_EMPTY=$(make_issues_json \
  100 "本文に依存記法はない" \
  200 "これも依存なし")
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_EMPTY"
edit_count=$(count_calls "gh issue edit")
assert_eq "NFR 3.1: 空依存のみ → ラベル付与ゼロ" "0" "$edit_count"
assert_eq "NFR 3.1: 空依存のみ → _DC_CYCLE_MEMBERS 空" "" "$_DC_CYCLE_MEMBERS"
cleanup_stub_state

# ============================================================
# NFR 2.2: 同一 issues_json で repeated invocation でも本文取得 API 0 回
# （dc_cycle_sweep は input JSON のみを使い、gh issue view --body を呼ばない）
# ============================================================
echo ""
echo "--- NFR 2.2: 本文取得 API 0 回 ---"

JSON_2N=$(make_issues_json \
  10 $'Depends on: #20' \
  20 $'Depends on: #10')
reset_stub_state
_DC_CYCLE_MEMBERS=""
dc_cycle_sweep "$JSON_2N"
# `gh issue view --json comments` は冪等性判定に使うため 2 回呼ばれるが、
# `gh issue view --json body` 等の本文取得は 0 回（dc_cycle_sweep は input JSON を使う）
body_fetch=$(count_calls "gh issue view.*--json body")
assert_eq "NFR 2.2: 本文取得 API 呼び出しゼロ" "0" "$body_fetch"
cleanup_stub_state

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
