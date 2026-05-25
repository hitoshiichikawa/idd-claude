#!/usr/bin/env bash
# 用途: #228 dispatch 見送り可視化のユニット/スモークテスト。
#       - Requirement 2 回帰: prefix 欠落 path が top-level 一致で overlap 検出される
#         （#221 正規化が成立していることの回帰担保）/ candidate 空配列は overlap なし
#       - Requirement 3: 多忙サイクル待ち tick カウンタ・閾値判定・reset の冪等性
#       - Requirement 5: PATH_OVERLAP_CHECK != true で本機能が一切動かない（差分ゼロ）
#       - Requirement 4 / NFR 2: 同一見送り状態での冪等性（state を破壊しない収束）
# 配置先: docs/specs/228-feat-watcher-dispatch-path-overlap-overl/
# 依存: bash 4+, jq。gh はスタブ化して実 API 呼び出しを避ける。
# セットアップ参照先: docs/specs/228-feat-watcher-dispatch-path-overlap-overl/requirements.md
#
# 実行: bash test-dispatch-visibility.sh
#   全ケース PASS で exit 0、いずれか失敗で非ゼロ exit。
#
# shellcheck disable=SC2034  # LABEL_* / BASE_BRANCH / REPO 等は source した module が参照する
# shellcheck disable=SC2317  # gh() スタブは module 内の関数から間接的に呼ばれる
set -euo pipefail

# ─── テスト対象モジュールの source ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${SCRIPT_DIR}/../../../local-watcher/bin/modules/promote-pipeline.sh"

if [ ! -f "$MODULE" ]; then
  echo "FATAL: 対象モジュールが見つかりません: $MODULE" >&2
  exit 2
fi

# ─── テスト用のラベル定数 / グローバル（本体 Config ブロック相当）───
LABEL_AWAITING_SLOT="awaiting-slot"
REPO="owner/test"
# state ディレクトリをテスト専用 tmp に隔離（実 LOG_DIR を汚さない / repo 間衝突回避）
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# module を source（関数定義のみ取り込む。set -euo pipefail は本ファイル冒頭で宣言済）
# shellcheck source=/dev/null
. "$MODULE"

# ─── gh スタブ（実 API を呼ばない / 呼び出し回数も記録）───
GH_CALL_LOG="$(mktemp)"
trap 'rm -rf "$LOG_DIR"; rm -f "$GH_CALL_LOG"' EXIT
gh() {
  # 呼び出しを記録（API 呼び出し回数検証用）。issue view --json comments には空コメントを返す。
  printf '%s\n' "$*" >> "$GH_CALL_LOG"
  case "$*" in
    *"issue view"*"--json comments"*)
      echo '{"comments": []}'
      ;;
    *)
      echo ''
      ;;
  esac
  return 0
}

# ─── アサーションヘルパー ───
PASS_COUNT=0
FAIL_COUNT=0
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name" >&2
    echo "  expected: [$expected]" >&2
    echo "  actual:   [$actual]" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ============================================================================
# Requirement 2: prefix 欠落に対する overlap 検出の頑健性（回帰検証）
# ============================================================================

# ─── Req 2.1 / 2.3: candidate が prefix 付き full path、holder が正規化済 top-level で一致 ───
# candidate ["local-watcher/bin/foo.sh"] は normalize で "local-watcher/" になり
# holder ["local-watcher/"] と top-level 粒度で一致 → overlap 検出されること。
OVERLAP=$(po_compute_overlap '["local-watcher/bin/foo.sh"]' '["local-watcher/"]')
assert_eq "Req2.1 full path candidate が holder top-level と一致して overlap 検出" \
  '["local-watcher/"]' "$OVERLAP"

# ─── Req 2.1 / 2.3: 先頭 ./ や連続スラッシュの正規化揺れがあっても同一規約で突合 ───
OVERLAP=$(po_compute_overlap '["./local-watcher//bin/foo.sh"]' '["local-watcher/"]')
assert_eq "Req2.3 ./ 連続スラッシュの揺れを同一 normalize で吸収し overlap 検出" \
  '["local-watcher/"]' "$OVERLAP"

# ─── Req 2.1: ルート直下ファイル（prefix 不要）の top-level 一致 ───
OVERLAP=$(po_compute_overlap '["README.md"]' '["README.md","local-watcher/"]')
assert_eq "Req2.1 ルート直下ファイル README.md が top-level 一致で overlap 検出" \
  '["README.md"]' "$OVERLAP"

# ─── Req 2.1 回帰（#221 false-negative の再現と非再発確認）───
# #221 実例: candidate Triage 予測 ["modules/","README.md"]（prefix 欠落）vs
# holder ["local-watcher/","README.md"]。modules vs local-watcher は top-level 不一致なので
# 当該 path は overlap しないが、README.md は top-level 一致で overlap 検出される。
# = 「false-negative により見送りもコメントも一切発生しない」事故が再発しないこと
#   （README.md という共通 top-level が必ず overlap として残る）を担保する。
OVERLAP=$(po_compute_overlap '["modules/","README.md"]' '["local-watcher/","README.md"]')
assert_eq "Req2.1 回帰: prefix 欠落 modules/ は不一致でも共通 README.md は overlap 検出（見送り成立）" \
  '["README.md"]' "$OVERLAP"

# ─── Req 2.4: candidate edit_paths が空なら overlap を検出せず dispatch を阻止しない ───
OVERLAP=$(po_compute_overlap '[]' '["local-watcher/","README.md"]')
assert_eq "Req2.4 candidate 空配列は overlap 空（dispatch 阻止しない）" \
  '[]' "$OVERLAP"

# ─── Req 2.3: candidate / holder の双方を同一 normalize で突合（両側 prefix 付き）───
OVERLAP=$(po_compute_overlap '["local-watcher/bin/a.sh"]' '["local-watcher/bin/modules/b.sh"]')
assert_eq "Req2.3 candidate/holder 双方を同一規約で top-level 化し overlap 検出" \
  '["local-watcher/"]' "$OVERLAP"

# ============================================================================
# Requirement 3: 多忙サイクル待ちの可視化（tick カウンタ / 閾値 / reset）
# ============================================================================

ISSUE=4242

# ─── Req 3.1 / NFR 4: 連続見送りで tick が単調増加し、GitHub API を呼ばない ───
GH_BEFORE=$(wc -l < "$GH_CALL_LOG")
T1=$(po_busy_wait_tick "$ISSUE")
T2=$(po_busy_wait_tick "$ISSUE")
T3=$(po_busy_wait_tick "$ISSUE")
GH_AFTER=$(wc -l < "$GH_CALL_LOG")
assert_eq "Req3.1 tick が 1→2→3 と単調増加する" "1 2 3" "$T1 $T2 $T3"
assert_eq "NFR4 tick カウントは GitHub API を一切呼ばない（呼び出し回数増えない）" \
  "$GH_BEFORE" "$GH_AFTER"

# ─── Req 3.3 / 3.4: reset で tick state が消え、次回は 1 から数え直す ───
po_busy_wait_reset "$ISSUE"
T_AFTER_RESET=$(po_busy_wait_tick "$ISSUE")
assert_eq "Req3.3 reset 後は tick が 1 から数え直す（transient 区別）" "1" "$T_AFTER_RESET"
po_busy_wait_reset "$ISSUE"

# ─── Req 3.4 / NFR 1.1: 閾値未満（transient）では可視化シグナルを残さない ───
PATH_OVERLAP_CHECK="true"
PATH_OVERLAP_BUSY_WAIT_THRESHOLD=5
GH_BEFORE=$(wc -l < "$GH_CALL_LOG")
# 4 回見送り（閾値 5 未満）→ シグナル（gh 呼び出し）は発生しないはず
po_check_busy_wait "$ISSUE" "全 slot busy" >/dev/null
po_check_busy_wait "$ISSUE" "全 slot busy" >/dev/null
po_check_busy_wait "$ISSUE" "全 slot busy" >/dev/null
po_check_busy_wait "$ISSUE" "全 slot busy" >/dev/null
GH_AFTER=$(wc -l < "$GH_CALL_LOG")
assert_eq "Req3.4 閾値未満では gh 呼び出し（コメント/ラベル）が発生しない（transient 抑制）" \
  "$GH_BEFORE" "$GH_AFTER"

# ─── Req 3.1 / 3.2: 閾値到達でシグナル（gh 呼び出し）が発生する ───
GH_BEFORE=$(wc -l < "$GH_CALL_LOG")
# 5 回目で閾値 5 に到達 → シグナル発生（ラベル付与 + comment 検索 + 投稿で gh が呼ばれる）
po_check_busy_wait "$ISSUE" "全 slot busy" >/dev/null
GH_AFTER=$(wc -l < "$GH_CALL_LOG")
if [ "$GH_AFTER" -gt "$GH_BEFORE" ]; then
  echo "PASS: Req3.1 閾値到達で可視化シグナル（gh 呼び出し）が発生する"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Req3.1 閾値到達で可視化シグナルが発生しなかった" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
po_busy_wait_reset "$ISSUE"

# ─── Req 3.4 補強: 閾値の非数値 / 0 はフォールバックで既定 5 に倒れる（連投しない）───
PATH_OVERLAP_BUSY_WAIT_THRESHOLD=0
GH_BEFORE=$(wc -l < "$GH_CALL_LOG")
po_check_busy_wait "$ISSUE" "全 slot busy" >/dev/null   # ticks=1 < 5 → 無音のはず
GH_AFTER=$(wc -l < "$GH_CALL_LOG")
assert_eq "Req3.4 閾値 0 は既定 5 にフォールバック（1 tick 目で連投しない）" \
  "$GH_BEFORE" "$GH_AFTER"
po_busy_wait_reset "$ISSUE"

PATH_OVERLAP_BUSY_WAIT_THRESHOLD="abc"
GH_BEFORE=$(wc -l < "$GH_CALL_LOG")
po_check_busy_wait "$ISSUE" "全 slot busy" >/dev/null   # ticks=1 < 5 → 無音のはず
GH_AFTER=$(wc -l < "$GH_CALL_LOG")
assert_eq "Req3.4 閾値 非数値 は既定 5 にフォールバック（1 tick 目で連投しない）" \
  "$GH_BEFORE" "$GH_AFTER"
po_busy_wait_reset "$ISSUE"

# ============================================================================
# Requirement 5: PATH_OVERLAP_CHECK != true で本機能が一切動かない（差分ゼロ）
# ============================================================================

# ─── Req 5.1 / 5.2: off では tick state を作らず gh も呼ばない（完全 no-op）───
ISSUE_OFF=9999
PATH_OVERLAP_BUSY_WAIT_THRESHOLD=1   # 即発火する閾値でも off なら動かないことを示す
STATE_DIR="$(po_busy_wait_state_dir)"
rm -f "${STATE_DIR}/issue-${ISSUE_OFF}.tick"
for v in "off" "" "false" "0" "True" "1" "enabled"; do
  PATH_OVERLAP_CHECK="$v"
  GH_BEFORE=$(wc -l < "$GH_CALL_LOG")
  po_check_busy_wait "$ISSUE_OFF" "全 slot busy" >/dev/null
  GH_AFTER=$(wc -l < "$GH_CALL_LOG")
  STATE_EXISTS="no"
  [ -f "${STATE_DIR}/issue-${ISSUE_OFF}.tick" ] && STATE_EXISTS="yes"
  assert_eq "Req5.1 PATH_OVERLAP_CHECK='${v}' では gh を呼ばない（差分ゼロ）" \
    "$GH_BEFORE" "$GH_AFTER"
  assert_eq "Req5.2 PATH_OVERLAP_CHECK='${v}' では tick state を作らない（no-op）" \
    "no" "$STATE_EXISTS"
done

# ============================================================================
# Requirement 4 / NFR 2: 冪等性（同一見送り状態で state を破壊せず収束）
# ============================================================================

# ─── NFR 2.1: 閾値到達後も繰り返し評価で tick は単調増加するが state ファイルは 1 件のまま ───
PATH_OVERLAP_CHECK="true"
PATH_OVERLAP_BUSY_WAIT_THRESHOLD=2
ISSUE_IDEM=5555
po_busy_wait_reset "$ISSUE_IDEM"
po_check_busy_wait "$ISSUE_IDEM" "全 slot busy" >/dev/null   # tick 1
po_check_busy_wait "$ISSUE_IDEM" "全 slot busy" >/dev/null   # tick 2 (発火)
po_check_busy_wait "$ISSUE_IDEM" "全 slot busy" >/dev/null   # tick 3 (発火/更新)
STATE_FILE_COUNT=$(find "$STATE_DIR" -name "issue-${ISSUE_IDEM}.tick" | wc -l)
assert_eq "NFR2.1 同一 Issue の見送り state ファイルは 1 件に保たれる（連投せず収束）" \
  "1" "$STATE_FILE_COUNT"
FINAL_TICK=$(cat "${STATE_DIR}/issue-${ISSUE_IDEM}.tick")
assert_eq "NFR2.1 繰り返し評価で tick は累積する（3 回見送り = 3）" "3" "$FINAL_TICK"
po_busy_wait_reset "$ISSUE_IDEM"

# ─── 結果サマリ ───
echo "----"
echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
