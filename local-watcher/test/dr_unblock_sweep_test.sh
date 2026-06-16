#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #346（依存全解決時に `blocked`
#       ラベルを自動解除するスイープ機能）で追加した `dr_unblock_*` 関数群を
#       fixture で検証するスモークテスト。
#
#       対象関数:
#         - dr_unblock_gate_enabled        (Req 1.2 / 1.3 / NFR 1.1 gate 正規化)
#         - dr_unblock_has_orphan_marker   (Req 5.3 / 6.1 冪等性判定)
#         - dr_unblock_post_unblocked_comment  (Req 3.2 / 3.3 / NFR 4.2 自動解除コメント)
#         - dr_unblock_post_orphan_marker_comment (Req 5.2 / 5.4 空依存通知コメント)
#         - dr_unblock_resolve_one_issue   (Req 3.1〜3.4 / 4.1 / 4.2 / 5.1〜5.3 / 7.1〜7.4 分岐)
#         - dr_unblock_sweep               (Req 1.1〜1.4 / 2.1 / 2.3 / NFR 2.1 起動 gate + 列挙)
#         - dr_format_unresolved_comment   (Req 8.1 / 8.2 エスカレーション文面分岐)
#
#       検証する AC（docs/specs/346-feat-watcher-blocked-unblock/requirements.md）:
#         - AT-a: 全依存 resolved + gate ON → 除去 + 解除コメント 1 件
#         - AT-b: 1 件以上 unresolved + gate ON → 何もしない
#         - AT-c: gate OFF（未設定 / `false` / typo）→ gh API ゼロ呼び出し
#         - AT-d: 空依存 + 未通知 + gate ON → orphan marker コメント 1 件のみ
#         - AT-e: 空依存 + 通知済 + gate ON → コメント投稿なし
#         - AT-f: 連続 2 回スイープ実行 → 累積なし
#         - AT-g: ラベル除去成功 + コメント投稿失敗 → 警告ログ + 次 Issue へ
#         - AT-h: エスカレーションコメント文面分岐（gate ON / OFF 別）
#
#       既存テスト（po_apply_awaiting_slot_test.sh / pt_extract_findings_block_test.sh）
#       と同じ「awk による関数抽出 + eval 読み込み + gh/dr_log/dr_warn stub」イディオム
#       を踏襲する。トップレベル副作用は回避する。
#
# 配置先: local-watcher/test/dr_unblock_sweep_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/dr_unblock_sweep_test.sh

set -euo pipefail

# 本テストは抽出関数（dr_unblock_resolve_one_issue / dr_unblock_sweep / dr_unblock_gate_enabled）
# と stub から indirect 参照（`${!key}` / `case "${DEP_AUTO_UNBLOCK_ENABLED:-false}"`）される
# 変数を多用するため、static 解析（shellcheck）からは未使用に見える。本ファイル全体で
# SC2034（unused variable）を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を読み込む。dr_extract_deps と dr_resolve_one は dr_unblock_resolve_one_issue
# が遅延束縛で呼ぶため明示的に読み込む。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_gate_enabled")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_has_orphan_marker")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_post_unblocked_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_post_orphan_marker_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_resolve_one_issue")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_unblock_sweep")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_extract_deps")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_format_unresolved_comment")"

for fn in dr_unblock_gate_enabled dr_unblock_has_orphan_marker \
          dr_unblock_post_unblocked_comment dr_unblock_post_orphan_marker_comment \
          dr_unblock_resolve_one_issue dr_unblock_sweep dr_extract_deps \
          dr_format_unresolved_comment; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（遅延束縛で抽出関数本体から参照される）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_TRIGGER="auto-dev"
# shellcheck disable=SC2034
LABEL_BLOCKED="blocked"
# 終端ラベル除外（Req 2.2）。dr_unblock_sweep が --search に展開するため必要。
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
LABEL_NEEDS_DECISIONS="needs-decisions"
# 通知マーカー（issue-watcher.sh のグローバル定義と一致させる）
# 抽出関数 dr_unblock_post_unblocked_comment / dr_unblock_post_orphan_marker_comment が
# 遅延束縛で参照するため、static 解析からは未使用に見える。
# shellcheck disable=SC2034
DR_UNBLOCK_MARKER_CLEARED='<!-- idd-claude:dep-unblock-cleared:v1 -->'
DR_UNBLOCK_MARKER_ORPHAN='<!-- idd-claude:dep-unblock-orphan-marker:v1 -->'

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
#   GH_EDIT_RC                : `gh issue edit` の終了コード（0=成功 / 非0=失敗）
#   GH_COMMENT_RC             : `gh issue comment` の終了コード
#   GH_LIST_JSON              : `gh issue list` が返す JSON
#   GH_LIST_RC                : `gh issue list` の終了コード
#   GH_VIEW_COMMENTS_JSON     : `gh issue view --json comments` が返す JSON（per-issue）
#   GH_VIEW_RC                : `gh issue view` の終了コード
# resolve_one stub:
#   DR_RESOLVE_VERDICTS_<N>   : Issue 番号 N の依存先について順に返す verdict
#
# 記録ファイル（呼び出しトレース）:
#   $GH_CALL_LOG  : gh の各呼び出しを 1 行ずつ記録
#   $WARN_LOG     : dr_warn の出力
#   $LOG_LOG      : dr_log の出力

reset_stub_state() {
  GH_EDIT_RC="${1:-0}"
  GH_COMMENT_RC="${2:-0}"
  GH_LIST_JSON="${3:-[]}"
  GH_LIST_RC="${4:-0}"
  # ${5:-DEFAULT} で DEFAULT 内に `}` を含むとパラメータ展開のブレース解釈が壊れるため、
  # 既定値の合成は別 1 行で行う（{"comments":[]} を含む default を inline 記述しない）。
  if [ -z "${5:-}" ]; then
    GH_VIEW_COMMENTS_JSON='{"comments": []}'
  else
    GH_VIEW_COMMENTS_JSON="$5"
  fi
  GH_VIEW_RC="${6:-0}"
  GH_CALL_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$WARN_LOG" "$LOG_LOG"
}

# dr_log / dr_warn stub: 出力を記録ファイルへ
# shellcheck disable=SC2317
dr_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
dr_warn() { echo "$*" >>"$WARN_LOG"; }

# gh stub: サブコマンドを判定して記録 + 制御された終了コードを返す
# shellcheck disable=SC2317
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  case "$sub" in
    issue)
      case "$sub2" in
        list)
          echo "gh issue list $*" >>"$GH_CALL_LOG"
          if [ "${GH_LIST_RC:-0}" -ne 0 ]; then
            return "${GH_LIST_RC}"
          fi
          printf '%s' "${GH_LIST_JSON}"
          return 0
          ;;
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

# dr_resolve_one stub: env var DR_RESOLVE_VERDICTS（依存先ごとの verdict CSV）を順に返す。
# Issue 番号ごとに別個に管理したいときは `DR_RESOLVE_VERDICTS_<dep_num>` を使う。
# `DR_RESOLVE_VERDICTS_DEFAULT` が定義されていればそれが使われる。
# shellcheck disable=SC2317
dr_resolve_one() {
  local dep_num="$1"
  local key="DR_RESOLVE_VERDICTS_${dep_num}"
  local verdict="${!key:-${DR_RESOLVE_VERDICTS_DEFAULT:-open}}"
  echo "$verdict"
}

count_calls() {
  local pattern="$1"
  local n
  # `--` でオプション解釈を打ち切り、pattern が `--foo` で始まっても安全に grep する
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

# ============================================================
# AT-h: エスカレーションコメント文面分岐（Req 8.1 / 8.2）
# ============================================================
echo "--- AT-h: dr_format_unresolved_comment 文面分岐（Req 8.1 / 8.2） ---"

UNRESOLVED_FIXTURE=$'#100|open\n#200|closed unmerged'

# gate OFF（未設定）→ 従来文面（「手動で除去」）を維持
unset DEP_AUTO_UNBLOCK_ENABLED
out_off=$(dr_format_unresolved_comment "$UNRESOLVED_FIXTURE")
assert_contains "Req 8.2: gate OFF（未設定）で「手動で除去」文面を維持" \
  "$out_off" "手動で除去してください"
assert_not_contains "Req 8.2: gate OFF で「自動で外れます」文面が出ない" \
  "$out_off" "自動で外れます"

# gate OFF（typo: True）→ 安全側で従来文面
DEP_AUTO_UNBLOCK_ENABLED="True"
out_typo=$(dr_format_unresolved_comment "$UNRESOLVED_FIXTURE")
assert_contains "Req 1.3 / 8.2: gate=True（typo）も従来文面" \
  "$out_typo" "手動で除去してください"

# gate ON → 自動解除文面に分岐
DEP_AUTO_UNBLOCK_ENABLED="true"
out_on=$(dr_format_unresolved_comment "$UNRESOLVED_FIXTURE")
assert_contains "Req 8.1: gate ON で「自動で外れます」文面に分岐" \
  "$out_on" "自動で外れます"
assert_not_contains "Req 8.1: gate ON で「手動で除去してください」文面は出さない" \
  "$out_on" "手動で除去してください"

unset DEP_AUTO_UNBLOCK_ENABLED

# ============================================================
# AT-c: gate OFF（未設定 / 不正値）→ gh API 呼び出しゼロ（Req 1.2 / NFR 1.1 / NFR 2.1）
# ============================================================
echo ""
echo "--- AT-c: gate OFF で gh API ゼロ呼び出し（NFR 1.1 / 2.1） ---"

# (1) 未設定
reset_stub_state
unset DEP_AUTO_UNBLOCK_ENABLED
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "NFR 2.1: 未設定で gh 呼び出しゼロ" "0" "$gh_count"
log_count=$(count_logs ".")
assert_eq "Req 1.2: 未設定でログ出力ゼロ" "0" "$log_count"
cleanup_stub_state

# (2) 明示的 false
reset_stub_state
DEP_AUTO_UNBLOCK_ENABLED="false"
dr_unblock_sweep
gh_count=$(count_calls "^gh ")
assert_eq "Req 1.2: =false で gh 呼び出しゼロ" "0" "$gh_count"
cleanup_stub_state

# (3) typo: TRUE / 1 / on
for bad in "TRUE" "1" "on" "True" "tRuE" "yes"; do
  reset_stub_state
  DEP_AUTO_UNBLOCK_ENABLED="$bad"
  dr_unblock_sweep
  gh_count=$(count_calls "^gh ")
  assert_eq "Req 1.3: =${bad}（typo）で gh 呼び出しゼロ（OFF に正規化）" "0" "$gh_count"
  cleanup_stub_state
done

unset DEP_AUTO_UNBLOCK_ENABLED

# ============================================================
# AT-i: 終端ラベル付き Issue を sweep の対象から除外する（Req 2.2）
#
#   dr_unblock_sweep の `gh issue list --search` 引数に `-label:"claude-failed"`
#   および `-label:"needs-decisions"` 除外フィルタが含まれること。`mark_issue_failed`
#   は `claude-failed` 付与時に `auto-dev` を除去しないため、`auto-dev` + `blocked`
#   + `claude-failed` の 3 ラベル組合せが実運用で発生し得る。AND クエリだけでは
#   終端 Issue が pickup されるため、`--search` の `-label:"..."` 除外が必要。
# ============================================================
echo ""
echo "--- AT-i: 終端ラベル付き Issue を sweep 対象から除外（Req 2.2） ---"

DEP_AUTO_UNBLOCK_ENABLED="true"
reset_stub_state 0 0 "[]" 0 '{"comments": []}' 0
dr_unblock_sweep

# `gh issue list` 呼び出しの記録を取得
list_call_line=$(grep -E "^gh issue list" "$GH_CALL_LOG" | head -1)

assert_contains "Req 2.2: --search 引数に -label:\"claude-failed\" 除外が含まれる" \
  "$list_call_line" '-label:"claude-failed"'
assert_contains "Req 2.2: --search 引数に -label:\"needs-decisions\" 除外が含まれる（既存メインクエリ整合）" \
  "$list_call_line" '-label:"needs-decisions"'
# 既存 AND クエリの label 指定はそのまま維持されていることを確認（regression 防止）
assert_contains "Req 2.1: --label auto-dev 指定は維持" \
  "$list_call_line" "--label auto-dev"
assert_contains "Req 2.1: --label blocked 指定は維持" \
  "$list_call_line" "--label blocked"
assert_contains "Req 2.1: --state open 指定は維持" \
  "$list_call_line" "--state open"

cleanup_stub_state
unset DEP_AUTO_UNBLOCK_ENABLED

# ============================================================
# AT-a: 全依存 resolved + gate ON → 除去 + 自動解除コメント 1 件（Req 3.1 / 3.2 / 3.3）
# ============================================================
echo ""
echo "--- AT-a: 全依存 resolved + gate ON → 除去 + 解除コメント（Req 3.1 / 3.2 / 3.3） ---"

DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_ALL_RESOLVED=$'Depends on: #100\nBlocked by: #200'
LIST_JSON=$(jq -cn --arg b "$BODY_ALL_RESOLVED" \
  '[{"number":42,"body":$b}]')
reset_stub_state 0 0 "$LIST_JSON" 0 '{"comments": []}' 0
DR_RESOLVE_VERDICTS_100="resolved"
DR_RESOLVE_VERDICTS_200="resolved"

dr_unblock_sweep

edit_count=$(count_calls "gh issue edit.*--remove-label.*blocked")
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 3.1: 全依存 resolved → gh issue edit --remove-label blocked が 1 回" "1" "$edit_count"
assert_eq "Req 3.2: 全依存 resolved → 自動解除コメント投稿が 1 回" "1" "$comment_count"

# 構造化ログ verdict=unblock_cleared を 1 行
cleared_log=$(count_logs "verdict=unblock_cleared")
assert_eq "Req 7.1: verdict=unblock_cleared のログ 1 行" "1" "$cleared_log"

# 自動解除コメントにマーカーが含まれる
# （call log には body の改行がそのまま入るため、ファイル全体を grep する）
if grep -qF -- "idd-claude:dep-unblock-cleared:v1" "$GH_CALL_LOG"; then
  echo "PASS: NFR 4.2: 自動解除コメントマーカー含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: NFR 4.2: 自動解除コメントマーカー含む"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

unset DR_RESOLVE_VERDICTS_100 DR_RESOLVE_VERDICTS_200
cleanup_stub_state

# ============================================================
# AT-b: 1 件 unresolved + gate ON → 何もしない（Req 4.1 / 6.2）
# ============================================================
echo ""
echo "--- AT-b: 1 件 unresolved → 何もしない（Req 4.1 / 6.2） ---"

DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_MIXED=$'Depends on: #100\nDepends on: #200'
LIST_JSON=$(jq -cn --arg b "$BODY_MIXED" '[{"number":50,"body":$b}]')
reset_stub_state 0 0 "$LIST_JSON" 0 '{"comments": []}' 0
DR_RESOLVE_VERDICTS_100="resolved"
DR_RESOLVE_VERDICTS_200="open"

dr_unblock_sweep

edit_count=$(count_calls "gh issue edit.*--remove-label.*blocked")
comment_count=$(count_calls "gh issue comment")
assert_eq "Req 4.1: unresolved 残存時はラベル除去なし" "0" "$edit_count"
assert_eq "Req 4.1: unresolved 残存時はコメント投稿なし" "0" "$comment_count"
keep_log=$(count_logs "verdict=unblock_keep")
assert_eq "Req 7.3: verdict=unblock_keep のログ 1 行" "1" "$keep_log"

unset DR_RESOLVE_VERDICTS_100 DR_RESOLVE_VERDICTS_200
cleanup_stub_state

# api error / closed unmerged も unresolved 扱い（Req 4.1 / 4.2 / NFR 3.1）
DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_APIERR=$'Depends on: #999'
LIST_JSON=$(jq -cn --arg b "$BODY_APIERR" '[{"number":60,"body":$b}]')
reset_stub_state 0 0 "$LIST_JSON" 0 '{"comments": []}' 0
# dr_resolve_one stub が ${!key} で indirect 参照する（static 解析からは未使用に見える）
# shellcheck disable=SC2034
DR_RESOLVE_VERDICTS_999="api error"

dr_unblock_sweep

edit_count=$(count_calls "gh issue edit.*--remove-label.*blocked")
assert_eq "NFR 3.1: api error は unresolved 扱い（ラベル除去なし）" "0" "$edit_count"
unset DR_RESOLVE_VERDICTS_999
cleanup_stub_state

# 未知 verdict も unresolved 扱い（Req 4.2）
DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_UNK=$'Depends on: #888'
LIST_JSON=$(jq -cn --arg b "$BODY_UNK" '[{"number":70,"body":$b}]')
reset_stub_state 0 0 "$LIST_JSON" 0 '{"comments": []}' 0
# shellcheck disable=SC2034
DR_RESOLVE_VERDICTS_888="something_strange"

dr_unblock_sweep

edit_count=$(count_calls "gh issue edit.*--remove-label.*blocked")
assert_eq "Req 4.2: 未知 verdict は unresolved 扱い（ラベル除去なし）" "0" "$edit_count"
warn_count=$(count_warns "未知の verdict")
assert_eq "Req 4.2: 未知 verdict で警告ログ 1 行" "1" "$warn_count"
unset DR_RESOLVE_VERDICTS_888
cleanup_stub_state

# ============================================================
# AT-d: 空依存マーカー + 未通知 + gate ON → orphan コメント 1 件のみ（Req 5.1 / 5.2）
# ============================================================
echo ""
echo "--- AT-d: 空依存 + 未通知 → orphan コメント 1 件（Req 5.1 / 5.2） ---"

DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_EMPTY="本文に依存記法はない。"
LIST_JSON=$(jq -cn --arg b "$BODY_EMPTY" '[{"number":80,"body":$b}]')
reset_stub_state 0 0 "$LIST_JSON" 0 '{"comments": []}' 0

dr_unblock_sweep

edit_count=$(count_calls "gh issue edit.*--remove-label.*blocked")
comment_count=$(count_calls "gh issue comment")
view_count=$(count_calls "gh issue view")
assert_eq "Req 5.1: 空依存はラベル除去しない" "0" "$edit_count"
assert_eq "Req 5.2: 空依存 + 未通知で orphan コメント 1 件" "1" "$comment_count"
assert_eq "Req 5.3: 既存コメント確認のため gh issue view 1 回" "1" "$view_count"
if grep -qF -- "idd-claude:dep-unblock-orphan-marker:v1" "$GH_CALL_LOG"; then
  echo "PASS: Req 5.4: orphan コメントマーカー含む"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req 5.4: orphan コメントマーカー含む"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
orphan_log=$(count_logs "verdict=unblock_orphan_marker")
assert_eq "Req 7.2: verdict=unblock_orphan_marker のログ 1 行" "1" "$orphan_log"

cleanup_stub_state

# ============================================================
# AT-e: 空依存 + 通知済 + gate ON → コメント投稿なし（Req 5.3 / 冪等）
# ============================================================
echo ""
echo "--- AT-e: 空依存 + 通知済 → コメント投稿なし（Req 5.3 / NFR 5.1 冪等） ---"

DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_EMPTY="本文に依存記法はない。"
LIST_JSON=$(jq -cn --arg b "$BODY_EMPTY" '[{"number":90,"body":$b}]')
EXISTING_ORPHAN_COMMENTS=$(jq -cn --arg m "$DR_UNBLOCK_MARKER_ORPHAN" \
  '{"comments":[{"body":("⚠️ 過去通知\n" + $m)}]}')
reset_stub_state 0 0 "$LIST_JSON" 0 "$EXISTING_ORPHAN_COMMENTS" 0

dr_unblock_sweep

comment_count=$(count_calls "gh issue comment")
assert_eq "Req 5.3: 通知済なら orphan コメント投稿なし" "0" "$comment_count"
notified_log=$(count_logs "verdict=unblock_orphan_notified")
assert_eq "Req 7.2: verdict=unblock_orphan_notified のログ 1 行" "1" "$notified_log"

cleanup_stub_state

# ============================================================
# AT-f: 連続 2 回スイープ実行 → 累積なし（NFR 5.1 / Req 6.1）
# ============================================================
echo ""
echo "--- AT-f: 連続 2 回スイープ → 累積なし（NFR 5.1） ---"

# (1) 解除条件を満たす Issue + 同じ fixture を 2 回。
#     1 回目: gh issue edit と gh issue comment が各 1 回呼ばれる
#     2 回目: 1 回目で blocked が外れたため、`gh issue list` の結果（実運用）には
#             もう含まれない（同 fixture を 2 度返すと冪等性検証として弱いため、
#             2 回目は `gh issue list` が空 list を返すようにする = 実運用近似）
DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_ALL_RESOLVED=$'Depends on: #100'
LIST_JSON_FULL=$(jq -cn --arg b "$BODY_ALL_RESOLVED" \
  '[{"number":42,"body":$b}]')
reset_stub_state 0 0 "$LIST_JSON_FULL" 0 '{"comments": []}' 0
DR_RESOLVE_VERDICTS_100="resolved"

dr_unblock_sweep

edit_count_1=$(count_calls "gh issue edit.*--remove-label.*blocked")
comment_count_1=$(count_calls "gh issue comment")
assert_eq "NFR 5.1: 1 回目で除去 1 件" "1" "$edit_count_1"
assert_eq "NFR 5.1: 1 回目で解除コメント 1 件" "1" "$comment_count_1"

# 2 回目: 同 Issue は label 上 unblocked 済みになっているため list 結果から消える
GH_LIST_JSON="[]"
dr_unblock_sweep

edit_count_2=$(count_calls "gh issue edit.*--remove-label.*blocked")
comment_count_2=$(count_calls "gh issue comment")
assert_eq "NFR 5.1 / Req 6.1: 2 回目は累積なし（除去 1 件のまま）" "1" "$edit_count_2"
assert_eq "NFR 5.1 / Req 6.1: 2 回目は累積なし（コメント 1 件のまま）" "1" "$comment_count_2"

unset DR_RESOLVE_VERDICTS_100
cleanup_stub_state

# 空依存 orphan 通知の連続実行も冪等であること（AT-e の応用）
DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_EMPTY="本文に依存記法はない。"
LIST_JSON=$(jq -cn --arg b "$BODY_EMPTY" '[{"number":91,"body":$b}]')
COMMENTS_AFTER_FIRST=$(jq -cn --arg m "$DR_UNBLOCK_MARKER_ORPHAN" \
  '{"comments":[{"body":("⚠️ 過去通知\n" + $m)}]}')

# 1 回目: コメントなし → orphan 投稿
reset_stub_state 0 0 "$LIST_JSON" 0 '{"comments": []}' 0
dr_unblock_sweep
c1=$(count_calls "gh issue comment")
assert_eq "NFR 5.1: 空依存 1 回目 orphan 1 件" "1" "$c1"
cleanup_stub_state

# 2 回目: 既に orphan marker 付きコメントが存在 → 投稿なし
reset_stub_state 0 0 "$LIST_JSON" 0 "$COMMENTS_AFTER_FIRST" 0
dr_unblock_sweep
c2=$(count_calls "gh issue comment")
assert_eq "NFR 5.1: 空依存 2 回目 投稿なし（冪等）" "0" "$c2"
cleanup_stub_state

# ============================================================
# AT-g: ラベル除去成功 + コメント投稿失敗 → 警告ログ + 次 Issue へ（Req 3.4 / NFR 3.2）
# ============================================================
echo ""
echo "--- AT-g: ラベル除去成功 + コメント投稿失敗 → 警告ログ + 次 Issue へ（NFR 3.2） ---"

DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_A=$'Depends on: #100'
BODY_B=$'Depends on: #200'
LIST_JSON=$(jq -cn --arg a "$BODY_A" --arg b "$BODY_B" \
  '[{"number":100,"body":$a},{"number":200,"body":$b}]')
# gh issue comment は失敗（rc=1）
reset_stub_state 0 1 "$LIST_JSON" 0 '{"comments": []}' 0
# shellcheck disable=SC2034
DR_RESOLVE_VERDICTS_100="resolved"
# shellcheck disable=SC2034
DR_RESOLVE_VERDICTS_200="resolved"

dr_unblock_sweep

edit_count=$(count_calls "gh issue edit.*--remove-label.*blocked")
comment_count=$(count_calls "gh issue comment")
assert_eq "NFR 3.2: コメント失敗でもラベル除去は両 Issue で実行" "2" "$edit_count"
assert_eq "NFR 3.2: コメント投稿は両 Issue で試行" "2" "$comment_count"
warn_count=$(count_warns "自動解除コメント投稿に失敗")
assert_eq "NFR 3.2: ラベル除去成功 + コメント失敗で警告ログを 2 件残す" "2" "$warn_count"
# verdict=unblock_cleared ログは（既存挙動と整合し）ラベル除去後に出る
cleared_log=$(count_logs "verdict=unblock_cleared")
assert_eq "Req 7.1: 各 Issue で cleared ログ" "2" "$cleared_log"

unset DR_RESOLVE_VERDICTS_100 DR_RESOLVE_VERDICTS_200
cleanup_stub_state

# ラベル除去失敗時はコメント投稿せず skip（Req 3.4）
DEP_AUTO_UNBLOCK_ENABLED="true"
BODY_X=$'Depends on: #300'
LIST_JSON=$(jq -cn --arg b "$BODY_X" '[{"number":300,"body":$b}]')
reset_stub_state 1 0 "$LIST_JSON" 0 '{"comments": []}' 0
# shellcheck disable=SC2034
DR_RESOLVE_VERDICTS_300="resolved"

dr_unblock_sweep

comment_count=$(count_calls "gh issue comment")
assert_eq "Req 3.4: ラベル除去失敗時はコメント投稿せず skip" "0" "$comment_count"
warn_count=$(count_warns "--remove-label.*blocked.*失敗")
assert_eq "Req 3.4: ラベル除去失敗で警告ログ 1 行" "1" "$warn_count"

unset DR_RESOLVE_VERDICTS_300
cleanup_stub_state

# ============================================================
# 補助: gh issue list がゼロ件 → 追加 API ゼロ（NFR 2.1）
# ============================================================
echo ""
echo "--- 補助: ゼロ件 → 追加 API ゼロ（NFR 2.1） ---"

DEP_AUTO_UNBLOCK_ENABLED="true"
reset_stub_state 0 0 "[]" 0 '{"comments": []}' 0
dr_unblock_sweep
list_count=$(count_calls "gh issue list")
other_count=$(count_calls "gh issue (edit|comment|view)")
assert_eq "NFR 2.1: ゼロ件で list クエリ 1 回のみ" "1" "$list_count"
assert_eq "NFR 2.1: ゼロ件で他 gh 呼び出しゼロ" "0" "$other_count"
cleanup_stub_state

# ============================================================
# 補助: dr_unblock_gate_enabled の戻り値検証（Req 1.2 / 1.3）
# ============================================================
echo ""
echo "--- 補助: dr_unblock_gate_enabled 戻り値（Req 1.2 / 1.3） ---"

unset DEP_AUTO_UNBLOCK_ENABLED
rc=0; dr_unblock_gate_enabled || rc=$?
assert_eq "Req 1.2: 未設定で gate OFF (rc=1)" "1" "$rc"

DEP_AUTO_UNBLOCK_ENABLED=""
rc=0; dr_unblock_gate_enabled || rc=$?
assert_eq "Req 1.2: 空文字で gate OFF" "1" "$rc"

DEP_AUTO_UNBLOCK_ENABLED="true"
rc=0; dr_unblock_gate_enabled || rc=$?
assert_eq "Req 1.1: =true で gate ON (rc=0)" "0" "$rc"

DEP_AUTO_UNBLOCK_ENABLED="TRUE"
rc=0; dr_unblock_gate_enabled || rc=$?
assert_eq "Req 1.3: =TRUE は OFF" "1" "$rc"

DEP_AUTO_UNBLOCK_ENABLED="True"
rc=0; dr_unblock_gate_enabled || rc=$?
assert_eq "Req 1.3: =True は OFF" "1" "$rc"

# dr_unblock_gate_enabled が ${DEP_AUTO_UNBLOCK_ENABLED:-false} を case 文で読むが、
# 末尾の最終 assignment + 即実行で shellcheck が "未使用" 判定するため明示的に抑止する。
# shellcheck disable=SC2034
DEP_AUTO_UNBLOCK_ENABLED="1"
rc=0; dr_unblock_gate_enabled || rc=$?
assert_eq "Req 1.3: =1 は OFF" "1" "$rc"

unset DEP_AUTO_UNBLOCK_ENABLED

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
