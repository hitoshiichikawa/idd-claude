#!/usr/bin/env bash
#
# 用途: Issue #413 で追加した `pp_remove_ready_for_review_if_present`
#       （modules/promote-pipeline.sh）が、`staged-for-release` 自動付与対象として
#       確定した Issue 集合から `ready-for-review` ラベルを除去する経路を正しく
#       動作させるかを検証する近接テスト。
#
#       対象関数:
#         - pp_remove_ready_for_review_if_present（#413 単独経路 / スキップ / 失敗 WARN）
#         - pp_collect_merged_issues の per-Issue ループ統合（和集合 / 重複 1 回呼び出し）
#
#       検証する AC (docs/specs/413-fix-promote-path-overlap-default-base-me/requirements.md):
#         - Req 1.1: closingIssuesReferences 経路で確定した Issue から ready-for-review を除去
#         - Req 1.2: head ブランチ名経路で確定した Issue から ready-for-review を除去
#         - Req 1.3: 既未付与 Issue は API 再送しない（スキップ）
#         - Req 1.5: gh issue edit 失敗時の WARN ログ + 後続 Issue 継続
#         - Req 1.6: 和集合（重複 Issue は 1 回のみ API 呼び出し）
#         - Req 4.1: 成功時 `issue=#<N> action=label-remove label=ready-for-review source=auto` ログ
#         - Req 4.3: 失敗時 `issue=#<N> ready-for-review 除去に失敗（後続 Issue は継続）` WARN
#         - NFR 2.1: API 呼び出し回数最小化（既未付与は edit を呼ばない）
#         - NFR 3.2: 数値 ID `^[0-9]+$` の使用直前再検証
#
#       既存テスト（po_apply_awaiting_slot_test.sh / pp_extract_linked_issues_test.sh）
#       と同じ extract_function イディオムを踏襲する。gh / pp_log / pp_warn を stub
#       して呼び出しトレース・ログ出力を観測する。
#
# 配置先: local-watcher/test/pp_remove_ready_for_review_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/pp_remove_ready_for_review_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE_PIPELINE_SH="$SCRIPT_DIR/../bin/modules/promote-pipeline.sh"

if [ ! -f "$PROMOTE_PIPELINE_SH" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PROMOTE_PIPELINE_SH" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for this test" >&2
  exit 2
fi

# 既存テスト pp_extract_linked_issues_test.sh / po_apply_awaiting_slot_test.sh と
# 同形式の extract_function イディオム。対象関数とその依存ヘルパーを 1 関数ずつ
# 隔離抽出して読み込む。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数 + 依存ヘルパー（pp_issue_has_label）を実物で読み込む。
# pp_issue_has_label は gh / jq に依存するが、本テストでは gh を stub する。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "pp_remove_ready_for_review_if_present")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PROMOTE_PIPELINE_SH" "pp_issue_has_label")"

if ! declare -F pp_remove_ready_for_review_if_present >/dev/null; then
  echo "ERROR: pp_remove_ready_for_review_if_present not loaded" >&2
  exit 2
fi
if ! declare -F pp_issue_has_label >/dev/null; then
  echo "ERROR: pp_issue_has_label not loaded" >&2
  exit 2
fi

# グローバル env（遅延束縛で extract_function 経由の関数本体から参照される）
# shellcheck disable=SC2034  # 遅延束縛で関数本体が参照
REPO="owner/test-repo"
# shellcheck disable=SC2034  # 同上（pp_remove_ready_for_review_if_present が $LABEL_READY を参照）
LABEL_READY="ready-for-review"
# shellcheck disable=SC2034  # 同上（pp_issue_has_label / pp_remove ... が timeout に渡す）
PROMOTE_GIT_TIMEOUT=60

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

# ─── stub 状態 ───
# gh の振る舞いをケースごとに環境変数で制御:
#   GH_VIEW_LABELS_JSON_FILE : `gh issue view --json labels` が返す JSON のテンプレート
#                              （`__ISSUE__` プレースホルダで Issue 番号を埋め込み可能）
#   GH_EDIT_RC_FILE          : issue 番号 → 終了コードの map ファイル
#                              （未定義の Issue は 0 = 成功）
# 記録ファイル:
#   $GH_CALL_LOG  : gh の各呼び出しを 1 行ずつ記録
#   $WARN_LOG     : pp_warn の出力を記録
#   $LOG_LOG      : pp_log の出力を記録

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  # デフォルトはラベル空（= ready-for-review 未付与）
  # ケースごとに set_labels_for で上書きする
  declare -gA LABELS_FOR_ISSUE=()
  declare -gA EDIT_RC_FOR_ISSUE=()
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
  unset LABELS_FOR_ISSUE
  unset EDIT_RC_FOR_ISSUE
}

# Issue 番号 → ラベル CSV を登録（例: "ready-for-review,staged-for-release"）
set_labels_for() {
  local issue="$1"
  local labels_csv="$2"
  LABELS_FOR_ISSUE["$issue"]="$labels_csv"
}

# Issue 番号 → `gh issue edit` 終了コードを登録（既定 0）
set_edit_rc_for() {
  local issue="$1"
  local rc="$2"
  EDIT_RC_FOR_ISSUE["$issue"]="$rc"
}

# pp_log / pp_warn stub: 出力を記録ファイルへ
# stub は extract_function で読み込んだ対象関数から間接的に呼ばれるため SC2317 を抑止。
# shellcheck disable=SC2317
pp_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
pp_warn() { echo "$*" >>"$WARN_LOG"; }

# timeout stub: 単にコマンドを実行（PROMOTE_GIT_TIMEOUT の挙動は本テストでは無関係）。
# shellcheck disable=SC2317
timeout() {
  shift  # 先頭の秒数引数を捨てる
  "$@"
}

# gh stub: サブコマンドを判定して記録 + 制御された出力 / 終了コード
# shellcheck disable=SC2317
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  local issue_arg=""
  # `gh issue view <N> ...` / `gh issue edit <N> ...` から Issue 番号を抽出
  if [ "$sub" = "issue" ] && { [ "$sub2" = "view" ] || [ "$sub2" = "edit" ]; }; then
    issue_arg="${3:-}"
  fi
  case "$sub" in
    issue)
      case "$sub2" in
        view)
          # `$*` には既に "issue view ..." が含まれるため、prefix `gh ` のみ補う。
          echo "gh $*" >>"$GH_CALL_LOG"
          # `--json labels` 要求のみ扱う
          local labels="${LABELS_FOR_ISSUE[$issue_arg]:-}"
          # CSV → JSON 配列に変換
          local json
          if [ -z "$labels" ]; then
            json='{"labels":[]}'
          else
            # `,` で split → `{"name": "X"}` の配列
            json=$(printf '%s' "$labels" | jq -R -s -c '
              split(",") | map({name: (. | gsub("^\\s+|\\s+$"; ""))}) | {labels: .}')
          fi
          printf '%s' "$json"
          return 0
          ;;
        edit)
          echo "gh $*" >>"$GH_CALL_LOG"
          local rc="${EDIT_RC_FOR_ISSUE[$issue_arg]:-0}"
          return "$rc"
          ;;
        *)
          echo "gh $* (unhandled)" >>"$GH_CALL_LOG"
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
  n=$( { grep -E "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

echo "--- pp_remove_ready_for_review_if_present cases (Issue #413 Req 1.1〜1.6 / 4.1〜4.3 / NFR 2.1 / 3.2) ---"
echo ""

# ── Case 1: closingIssuesReferences 単独経路で `ready-for-review` を除去（Req 1.1） ──
# Issue #42 に ready-for-review + staged-for-release が付与済（main merge で Phase A
# が staged-for-release を確定したケースの想定）。
echo "--- Case 1: closingIssuesReferences 経路で ready-for-review 除去（Req 1.1） ---"
reset_stub_state
set_labels_for 42 "ready-for-review,staged-for-release"
pp_remove_ready_for_review_if_present 42
edit_count=$(count_calls "gh issue edit 42 .*--remove-label ready-for-review")
assert_eq "Case 1: ready-for-review 除去のため gh issue edit が 1 回呼ばれる" "1" "$edit_count"
log_out="$(cat "$LOG_LOG")"
assert_contains "Case 1: Req 4.1 形式の除去成功ログを出す" \
  "$log_out" "issue=#42 action=label-remove label=ready-for-review source=auto"
warn_out="$(cat "$WARN_LOG")"
assert_eq "Case 1: 成功時は WARN を出さない" "" "$warn_out"
cleanup_stub_state

# ── Case 2: head ブランチ名単独経路で `ready-for-review` を除去（Req 1.2） ──
# closingIssuesReferences が空（base != default branch / gitflow 想定）でも、
# 呼び出し側のループは pp_extract_linked_issues 経由で和集合に含めて渡してくる。
# 本関数の振る舞いは Case 1 と同一であることを別 Issue 番号で観測する。
echo ""
echo "--- Case 2: head ブランチ名経路で ready-for-review 除去（Req 1.2 / base != default 想定） ---"
reset_stub_state
set_labels_for 7 "ready-for-review"
pp_remove_ready_for_review_if_present 7
edit_count=$(count_calls "gh issue edit 7 .*--remove-label ready-for-review")
assert_eq "Case 2: head ブランチ名経路 Issue でも ready-for-review 除去が 1 回呼ばれる" "1" "$edit_count"
log_out="$(cat "$LOG_LOG")"
assert_contains "Case 2: 除去成功ログ" \
  "$log_out" "issue=#7 action=label-remove label=ready-for-review source=auto"
cleanup_stub_state

# ── Case 3: 和集合（同じ Issue 番号が両経路から来ても 1 回のみ除去 API 呼び出し）（Req 1.6） ──
# pp_extract_linked_issues は jq の unique で和集合 + 重複排除済みの番号配列を出力するため、
# 呼び出し側ループに同じ Issue 番号が 2 回現れることはない。ただしテストでは「2 回連続
# 呼び出された場合の挙動」を観測することで、本関数自体の冪等性（1 回目除去後の 2 回目は
# 既未付与スキップになる）を裏付ける。
echo ""
echo "--- Case 3: 同一 Issue を 2 回呼んでも edit 1 回 + skip 1 回（Req 1.6 冪等性 + Req 1.3 重複抑止） ---"
reset_stub_state
set_labels_for 99 "ready-for-review"
# 1 回目: ready-for-review 付与済 → 除去
pp_remove_ready_for_review_if_present 99
# 1 回目の除去後、Issue 状態は「ready-for-review 無し」に遷移したものとして再シミュレート
set_labels_for 99 ""
# 2 回目: 既未付与 → スキップ
pp_remove_ready_for_review_if_present 99
edit_count=$(count_calls "gh issue edit 99 .*--remove-label ready-for-review")
assert_eq "Case 3: 同一 Issue 2 回呼び出しでも除去 edit は 1 回のみ（冪等）" "1" "$edit_count"
log_out="$(cat "$LOG_LOG")"
log_count=$(printf '%s\n' "$log_out" | grep -c "action=label-remove" || true)
assert_eq "Case 3: 除去成功ログも 1 回のみ" "1" "$log_count"
cleanup_stub_state

# ── Case 4: ready-for-review 未付与 Issue は `gh issue edit` を呼ばずスキップ（Req 1.3 / NFR 2.1） ──
echo ""
echo "--- Case 4: ready-for-review 未付与 Issue は edit を呼ばずスキップ（Req 1.3 / NFR 2.1） ---"
reset_stub_state
# Issue #50 は staged-for-release のみ持つ（ready-for-review 未付与）
set_labels_for 50 "staged-for-release"
pp_remove_ready_for_review_if_present 50
# pp_issue_has_label が view を 1 回呼ぶのは許容（NFR 2.1 でも view は禁止していない）
edit_count=$(count_calls "gh issue edit 50")
assert_eq "Case 4: 既未付与 Issue では gh issue edit を呼ばない" "0" "$edit_count"
log_out="$(cat "$LOG_LOG")"
assert_eq "Case 4: 既未付与のスキップでは INFO ログを出さない（Req 4.2 選択肢）" "" "$log_out"
warn_out="$(cat "$WARN_LOG")"
assert_eq "Case 4: 既未付与のスキップでは WARN を出さない" "" "$warn_out"
cleanup_stub_state

# ── Case 5: gh issue edit 失敗時の WARN ログ + 戻り値 0（Req 1.5 / Req 4.3） ──
echo ""
echo "--- Case 5: gh issue edit 失敗で WARN ログ 1 行 + 戻り値 0（Req 1.5 / 4.3） ---"
reset_stub_state
set_labels_for 77 "ready-for-review"
set_edit_rc_for 77 1
rc=0
pp_remove_ready_for_review_if_present 77 || rc=$?
assert_eq "Case 5: edit 失敗でも戻り値は 0（fail-continue / Req 1.5）" "0" "$rc"
warn_out="$(cat "$WARN_LOG")"
warn_count=$(printf '%s\n' "$warn_out" | grep -c "ready-for-review 除去に失敗" || true)
assert_eq "Case 5: Req 4.3 形式の WARN ログを 1 行残す" "1" "$warn_count"
assert_contains "Case 5: WARN ログに候補 Issue 番号 #77 を含む" "$warn_out" "#77"
assert_contains "Case 5: WARN ログに「後続 Issue は継続」を含む" \
  "$warn_out" "後続 Issue は継続"
log_out="$(cat "$LOG_LOG")"
log_count=$(printf '%s\n' "$log_out" | grep -c "action=label-remove" || true)
assert_eq "Case 5: 失敗時は除去成功ログを出さない" "0" "$log_count"
cleanup_stub_state

# ── Case 6: 数値 ID `^[0-9]+$` 不一致は edit を呼ばずスキップ（NFR 3.2） ──
echo ""
echo "--- Case 6: 不正な Issue 番号は edit を呼ばずスキップ（NFR 3.2） ---"
reset_stub_state
# `-1` は `^[0-9]+$` 不一致（先頭ハイフン）。フラグ注入を防ぐ防御層。
pp_remove_ready_for_review_if_present "-1"
view_count=$(count_calls "gh issue view")
edit_count=$(count_calls "gh issue edit")
assert_eq "Case 6: 数値 ID 不正なら gh issue view を呼ばない" "0" "$view_count"
assert_eq "Case 6: 数値 ID 不正なら gh issue edit を呼ばない" "0" "$edit_count"
# 同様に空文字
reset_stub_state
pp_remove_ready_for_review_if_present ""
view_count=$(count_calls "gh issue view")
edit_count=$(count_calls "gh issue edit")
assert_eq "Case 6: 空 ID なら gh issue view を呼ばない" "0" "$view_count"
assert_eq "Case 6: 空 ID なら gh issue edit を呼ばない" "0" "$edit_count"
cleanup_stub_state

# ── Case 7: 連続した複数 Issue で 1 件失敗しても後続 Issue 処理が継続する（Req 1.5） ──
# 呼び出し側（pp_collect_merged_issues のループ）が本関数を per-Issue で呼ぶことを想定し、
# 「1 件目 edit 失敗 → 2 件目 edit 成功」が連続実行できることを観測する。
echo ""
echo "--- Case 7: 連続呼び出しで 1 件失敗しても 2 件目が成功する（Req 1.5 fail-continue） ---"
reset_stub_state
set_labels_for 10 "ready-for-review"
set_edit_rc_for 10 1
set_labels_for 20 "ready-for-review,staged-for-release"
set_edit_rc_for 20 0
pp_remove_ready_for_review_if_present 10
pp_remove_ready_for_review_if_present 20
# 10 は失敗 WARN、20 は成功 LOG
warn_out="$(cat "$WARN_LOG")"
log_out="$(cat "$LOG_LOG")"
assert_contains "Case 7: #10 の失敗 WARN が記録される" "$warn_out" "#10"
assert_contains "Case 7: #20 の成功 LOG が記録される" "$log_out" "#20"
edit_count_10=$(count_calls "gh issue edit 10 .*--remove-label ready-for-review")
edit_count_20=$(count_calls "gh issue edit 20 .*--remove-label ready-for-review")
assert_eq "Case 7: #10 の edit が 1 回試行される" "1" "$edit_count_10"
assert_eq "Case 7: #20 の edit が 1 回試行される（先行失敗で停止しない）" "1" "$edit_count_20"
cleanup_stub_state

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
