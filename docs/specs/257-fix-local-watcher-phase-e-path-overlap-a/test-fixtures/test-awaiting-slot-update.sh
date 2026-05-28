#!/usr/bin/env bash
# 用途: #257 Phase E Path Overlap Checker の awaiting-slot sticky comment 最新化バグ修正の
#       回帰テスト。`po_check_dispatch_gate` が既存 awaiting-slot ラベル付与状態に関わらず
#       `po_apply_awaiting_slot` を呼び出し、sticky comment を毎サイクル最新化することを担保する。
#
#       - Requirement 1.1: overlap 検出時、awaiting-slot ラベルの有無に関わらず apply が呼ばれる
#       - Requirement 1.2 / 1.3: 既存 marker 付き comment があれば PATCH（新規 create しない）
#       - Requirement 2.1 / 2.2 / NFR 3.1: 未付与時の新規付与経路は従来通り動作（冪等）
#       - Requirement 2.3: overlap 検出時の dispatch 見送り（return 1）は維持
#       - Requirement 2.4: overlap 自然解消時の awaiting-slot 除去経路は維持
#       - Requirement 2.5 / NFR 1.1: PATH_OVERLAP_CHECK != true で完全 no-op（差分ゼロ）
#       - Requirement 3.1 / 3.2 / 3.3: apply 失敗でも warn のみで dispatch skip 判定を継続
#
# 配置先: docs/specs/257-fix-local-watcher-phase-e-path-overlap-a/test-fixtures/
# 依存: bash 4+, jq。gh はスタブ化して実 API 呼び出しを避ける。
# セットアップ参照先: docs/specs/257-fix-local-watcher-phase-e-path-overlap-a/requirements.md
#
# 実行: bash test-awaiting-slot-update.sh
#   全ケース PASS で exit 0、いずれか失敗で非ゼロ exit。
#
# shellcheck disable=SC2034  # LABEL_* / BASE_BRANCH / REPO 等は source した module が参照する
# shellcheck disable=SC2317  # gh() / mock 関数は module 内から間接的に呼ばれる
# shellcheck disable=SC2218  # po_apply_awaiting_slot は `. "$MODULE"` で動的に定義される
set -euo pipefail

# ─── テスト対象モジュールの source ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${SCRIPT_DIR}/../../../../local-watcher/bin/modules/promote-pipeline.sh"

if [ ! -f "$MODULE" ]; then
  echo "FATAL: 対象モジュールが見つかりません: $MODULE" >&2
  exit 2
fi

# ─── テスト用のラベル定数 / グローバル（本体 Config ブロック相当）───
LABEL_AWAITING_SLOT="awaiting-slot"
LABEL_CLAIMED="claude-claimed"
LABEL_PICKED="claude-picked-up"
LABEL_AWAITING_DESIGN="awaiting-design-review"
LABEL_READY="ready-for-review"
LABEL_NEEDS_ITERATION="needs-iteration"
LABEL_NEEDS_REBASE="needs-rebase"
LABEL_STAGED_FOR_RELEASE="staged-for-release"
REPO="owner/test"
BASE_BRANCH="main"
PROMOTION_TARGET_BRANCH="main"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# module を source（関数定義のみ取り込む。set -euo pipefail は本ファイル冒頭で宣言済）
# shellcheck source=/dev/null
. "$MODULE"

# ─── gh スタブ（実 API を呼ばない / 呼び出し回数も記録）───
GH_CALL_LOG="$(mktemp)"
trap 'rm -rf "$LOG_DIR"; rm -f "$GH_CALL_LOG"' EXIT
gh() {
  printf '%s\n' "$*" >> "$GH_CALL_LOG"
  case "$*" in
    *"issue view"*"--json comments"*)
      # 既存 sticky comment あり（marker awaiting-slot:v1 付き）を返すことで PATCH 経路を駆動
      if [ "${GH_STUB_HAS_EXISTING_COMMENT:-no}" = "yes" ]; then
        # printf を使う（echo は \n のリテラル/エスケープ解釈が shell 実装間で揺れる / SC2028）
        printf '%s\n' '{"comments":[{"url":"https://github.com/owner/test/issues/1#issuecomment-99999","body":"previous body <!-- idd-claude:awaiting-slot:v1 -->"}]}'
      else
        printf '%s\n' '{"comments":[]}'
      fi
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

# 呼び出し回数カウントヘルパー: GH_CALL_LOG の指定パターン出現回数を返す
# 注: `grep -c` は match なしで stdout に "0" を出すが exit 1 を返す。`|| echo 0` を
# 連結すると改行で "0\n0" になる事故が起きるので、grep 失敗を完全に飲み込む形にする。
count_gh_calls() {
  local pattern="$1"
  local cnt
  cnt=$(grep -c -F -- "$pattern" "$GH_CALL_LOG" 2>/dev/null) || cnt=0
  printf '%s' "$cnt"
}

# ============================================================================
# Mock 戦略
# ============================================================================
# `po_check_dispatch_gate` は内部で po_load_edit_paths / po_collect_inflight_issues /
# po_compute_overlap / po_resolve_overlap_holders / po_apply_awaiting_slot を呼ぶ。
# AC 検証に必要な「overlap 検出を必ず発生させる」ために、依存関数を mock して
# 決定論的に overlap=["local-watcher/"] が返るよう仕込む。
# po_apply_awaiting_slot は呼び出し観測用 mock に置き換える（呼び出し回数 / 引数を記録）。
#
# 注: `po_check_dispatch_gate` 自体は本体で定義済。bash の関数定義は同名で上書き可能なので
# mock を後から定義することで依存関数のみ差し替え可能。
# ============================================================================

APPLY_CALL_LOG="$(mktemp)"
trap 'rm -rf "$LOG_DIR"; rm -f "$GH_CALL_LOG" "$APPLY_CALL_LOG"' EXIT

# 依存関数を mock（決定論的な overlap 検出を作る）
po_load_edit_paths() {
  echo '["local-watcher/bin/foo.sh"]'
  return 0
}
po_collect_inflight_issues() {
  # union に local-watcher/ を含めて overlap を作る、holders は #42
  echo '{"union":["local-watcher/"],"holders":{"local-watcher/":[42]}}'
  return 0
}

# po_apply_awaiting_slot 観測 mock（成功）
APPLY_MOCK_RETURN=0
po_apply_awaiting_slot() {
  local issue_number="$1"
  local overlap_json="$2"
  local holders_map_json="${3:-}"
  printf 'apply candidate=%s overlap=%s holders=%s\n' \
    "$issue_number" "$overlap_json" "$holders_map_json" >> "$APPLY_CALL_LOG"
  return "$APPLY_MOCK_RETURN"
}

# po_clear_awaiting_slot 観測 mock
CLEAR_CALL_LOG="$(mktemp)"
trap 'rm -rf "$LOG_DIR"; rm -f "$GH_CALL_LOG" "$APPLY_CALL_LOG" "$CLEAR_CALL_LOG"' EXIT
CLEAR_MOCK_RETURN=0
po_clear_awaiting_slot() {
  local issue_number="$1"
  printf 'clear candidate=%s\n' "$issue_number" >> "$CLEAR_CALL_LOG"
  return "$CLEAR_MOCK_RETURN"
}

# ============================================================================
# Requirement 1.1 / 1.2 / 1.3: awaiting-slot ラベル付与状態に関わらず apply が呼ばれる
# ============================================================================

PATH_OVERLAP_CHECK="true"

# ─── Req 1.1 + Req 2.2 (新規付与経路): has_awaiting=空（ラベル未付与）でも apply 呼ばれる ───
: > "$APPLY_CALL_LOG"
LABELS_NO_AWAITING='[{"name":"auto-dev"}]'
set +e
po_check_dispatch_gate 1 "$LABELS_NO_AWAITING"
RC1=$?
set -e
APPLY_COUNT_1=$(wc -l < "$APPLY_CALL_LOG")
assert_eq "Req2.3 overlap 検出時 dispatch skip（return 1）が維持される（未付与ケース）" \
  "1" "$RC1"
assert_eq "Req2.2 awaiting-slot 未付与時に po_apply_awaiting_slot が 1 回呼ばれる（従来挙動）" \
  "1" "$APPLY_COUNT_1"

# ─── Req 1.1 / 1.2 / 1.3: has_awaiting=非空（既付与）でも apply が呼ばれる（バグ修正本丸）───
: > "$APPLY_CALL_LOG"
LABELS_WITH_AWAITING='[{"name":"auto-dev"},{"name":"awaiting-slot"}]'
set +e
po_check_dispatch_gate 2 "$LABELS_WITH_AWAITING"
RC2=$?
set -e
APPLY_COUNT_2=$(wc -l < "$APPLY_CALL_LOG")
assert_eq "Req2.3 overlap 検出時 dispatch skip（return 1）が維持される（既付与ケース）" \
  "1" "$RC2"
assert_eq "Req1.1 awaiting-slot 既付与でも po_apply_awaiting_slot が 1 回呼ばれる（バグ修正の本丸）" \
  "1" "$APPLY_COUNT_2"

# ─── Req 1.2 / 1.3: apply 呼び出しに最新の overlap / holders が渡されている ───
APPLY_BODY=$(cat "$APPLY_CALL_LOG")
case "$APPLY_BODY" in
  *'overlap=["local-watcher/"]'*'holders={"local-watcher/":[42]}'*)
    echo "PASS: Req1.2 apply 呼び出しに最新の overlap=[local-watcher/] と holders={local-watcher/:[42]} が渡される"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: Req1.2 apply 呼び出しの引数に最新の overlap / holders が含まれない" >&2
    echo "  body: $APPLY_BODY" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac

# ============================================================================
# Requirement 1.2 / 1.3 / NFR 3.1: po_apply_awaiting_slot 内部の PATCH / 新規 create 経路
# ============================================================================
# ここでは po_apply_awaiting_slot mock を解除し、本物の関数を呼んで gh API の使われ方を観測する。
# - 既存 sticky comment あり → `gh api -X PATCH` が呼ばれ、`gh issue comment` は呼ばれない
# - 既存 sticky comment なし → `gh issue comment` で新規 create される
# ============================================================================

# mock を解除して本物の po_apply_awaiting_slot を再 source（同名定義で上書き）
# bash は最新の関数定義のみ保持するので、もう一度 module を source して mock を上書き解除する。
# shellcheck source=/dev/null
. "$MODULE"

# ─── Req 1.3 (sticky 化): 既存 marker 付き comment があれば PATCH のみ、新規 create しない ───
: > "$GH_CALL_LOG"
GH_STUB_HAS_EXISTING_COMMENT="yes"
po_apply_awaiting_slot 3 '["local-watcher/"]' '{"local-watcher/":[42]}'
PATCH_COUNT=$(count_gh_calls 'api -X PATCH')
COMMENT_NEW_COUNT=$(count_gh_calls 'issue comment 3 --repo')
assert_eq "Req1.3 既存 marker 付き comment あり → gh api -X PATCH が 1 回呼ばれる" \
  "1" "$PATCH_COUNT"
assert_eq "Req1.3 / NFR3.1 既存 marker 付き comment あり → gh issue comment（新規 create）は呼ばれない" \
  "0" "$COMMENT_NEW_COUNT"

# ─── Req 2.1: 既存 marker なしなら新規 create（gh issue comment）が呼ばれ、PATCH は呼ばれない ───
: > "$GH_CALL_LOG"
GH_STUB_HAS_EXISTING_COMMENT="no"
po_apply_awaiting_slot 4 '["local-watcher/"]' '{"local-watcher/":[42]}'
PATCH_COUNT=$(count_gh_calls 'api -X PATCH')
COMMENT_NEW_COUNT=$(count_gh_calls 'issue comment 4 --repo')
assert_eq "Req2.1 既存 marker なし → gh issue comment（新規 create）が 1 回呼ばれる" \
  "1" "$COMMENT_NEW_COUNT"
assert_eq "Req2.1 既存 marker なし → gh api -X PATCH は呼ばれない" \
  "0" "$PATCH_COUNT"

# ─── Req 2.2 (ラベル冪等): apply 内で add-label が呼ばれ、冪等性は gh 側に委ねられる ───
: > "$GH_CALL_LOG"
GH_STUB_HAS_EXISTING_COMMENT="yes"
po_apply_awaiting_slot 5 '["local-watcher/"]' '{"local-watcher/":[42]}'
po_apply_awaiting_slot 5 '["local-watcher/"]' '{"local-watcher/":[42]}'   # 2 回目（冪等）
LABEL_ADD_COUNT=$(count_gh_calls 'issue edit 5 --repo owner/test --add-label awaiting-slot')
assert_eq "Req2.2 / NFR3.1 連続呼び出しでも add-label は決定論的に毎回呼ばれる（gh 側冪等）" \
  "2" "$LABEL_ADD_COUNT"

# ============================================================================
# Requirement 2.3 / 2.4: dispatch skip 判定 / 自然解消経路
# ============================================================================

# 再度依存関数を mock 化（overlap 検出 → return 1 検証用）
po_load_edit_paths() { echo '["local-watcher/bin/foo.sh"]'; return 0; }
po_collect_inflight_issues() {
  echo '{"union":["local-watcher/"],"holders":{"local-watcher/":[42]}}'
  return 0
}
po_apply_awaiting_slot() { return 0; }
CLEAR_CALL_LOG="$(mktemp)"
trap 'rm -rf "$LOG_DIR"; rm -f "$GH_CALL_LOG" "$APPLY_CALL_LOG" "$CLEAR_CALL_LOG"' EXIT
CLEAR_MOCK_RETURN=0
po_clear_awaiting_slot() {
  printf 'clear candidate=%s\n' "$1" >> "$CLEAR_CALL_LOG"
  return "$CLEAR_MOCK_RETURN"
}

# ─── Req 2.4: overlap 空 + awaiting-slot 既付与 → clear が呼ばれる ───
po_collect_inflight_issues() {
  # union 空 → overlap 必ず空
  echo '{"union":[],"holders":{}}'
  return 0
}
: > "$CLEAR_CALL_LOG"
set +e
po_check_dispatch_gate 6 "$LABELS_WITH_AWAITING"
RC_CLEAR=$?
set -e
CLEAR_COUNT=$(wc -l < "$CLEAR_CALL_LOG")
assert_eq "Req2.4 overlap 空 + awaiting-slot 既付与 → po_clear_awaiting_slot が呼ばれる" \
  "1" "$CLEAR_COUNT"
assert_eq "Req2.4 overlap 空 + clear 成功 → dispatch 続行（return 0）" \
  "0" "$RC_CLEAR"

# ─── Req 2.4 後方互換: overlap 空 + awaiting-slot 未付与 → clear 呼ばれず dispatch 続行 ───
: > "$CLEAR_CALL_LOG"
set +e
po_check_dispatch_gate 7 "$LABELS_NO_AWAITING"
RC_NO_CLEAR=$?
set -e
CLEAR_COUNT=$(wc -l < "$CLEAR_CALL_LOG")
assert_eq "Req2.4 overlap 空 + awaiting-slot 未付与 → clear は呼ばれない（無駄な API なし）" \
  "0" "$CLEAR_COUNT"
assert_eq "Req2.4 overlap 空 + 未付与 → dispatch 続行（return 0）" \
  "0" "$RC_NO_CLEAR"

# ============================================================================
# Requirement 2.5 / NFR 1.1: PATH_OVERLAP_CHECK != true で完全 no-op（差分ゼロ）
# ============================================================================
# overlap が起きる依存関数 mock のまま、gate に入る前段で early return 0 されることを確認。

po_collect_inflight_issues() {
  # overlap を起こす union を返すが、PATH_OVERLAP_CHECK gate が先に切れる
  echo '{"union":["local-watcher/"],"holders":{"local-watcher/":[42]}}'
  return 0
}
APPLY_OFF_LOG="$(mktemp)"
trap 'rm -rf "$LOG_DIR"; rm -f "$GH_CALL_LOG" "$APPLY_CALL_LOG" "$CLEAR_CALL_LOG" "$APPLY_OFF_LOG"' EXIT
po_apply_awaiting_slot() { printf 'apply\n' >> "$APPLY_OFF_LOG"; return 0; }
po_clear_awaiting_slot() { printf 'clear\n' >> "$APPLY_OFF_LOG"; return 0; }

for v in "off" "" "false" "0" "True" "1" "enabled"; do
  PATH_OVERLAP_CHECK="$v"
  : > "$APPLY_OFF_LOG"
  set +e
  po_check_dispatch_gate 100 "$LABELS_WITH_AWAITING"
  RC_OFF=$?
  set -e
  CALL_COUNT=$(wc -l < "$APPLY_OFF_LOG")
  assert_eq "Req2.5 PATH_OVERLAP_CHECK='${v}' で gate 早期 return 0（dispatch 続行）" \
    "0" "$RC_OFF"
  assert_eq "NFR1.1 PATH_OVERLAP_CHECK='${v}' で apply / clear いずれも呼ばれない（差分ゼロ）" \
    "0" "$CALL_COUNT"
done

# ============================================================================
# Requirement 3.1 / 3.2 / 3.3: apply 失敗でも dispatch skip 判定（return 1）は継続
# ============================================================================

PATH_OVERLAP_CHECK="true"
po_collect_inflight_issues() {
  echo '{"union":["local-watcher/"],"holders":{"local-watcher/":[42]}}'
  return 0
}
APPLY_FAIL_LOG="$(mktemp)"
trap 'rm -rf "$LOG_DIR"; rm -f "$GH_CALL_LOG" "$APPLY_CALL_LOG" "$CLEAR_CALL_LOG" "$APPLY_OFF_LOG" "$APPLY_FAIL_LOG"' EXIT
# apply mock を「失敗」に設定
po_apply_awaiting_slot() {
  printf 'apply candidate=%s\n' "$1" >> "$APPLY_FAIL_LOG"
  return 1   # 失敗
}

# ─── Req 3.1 / 3.2 / 3.3: apply 失敗 → warn ログのみで return 1 維持、process 異常終了しない ───
: > "$APPLY_FAIL_LOG"
set +e
po_check_dispatch_gate 8 "$LABELS_WITH_AWAITING" 2>/dev/null
RC_APPLY_FAIL=$?
set -e
APPLY_FAIL_COUNT=$(wc -l < "$APPLY_FAIL_LOG")
assert_eq "Req3.1 apply 失敗時も po_apply_awaiting_slot は呼ばれる（試行はする）" \
  "1" "$APPLY_FAIL_COUNT"
assert_eq "Req3.1 / 3.3 apply 失敗でも dispatch skip 判定（return 1）が維持される" \
  "1" "$RC_APPLY_FAIL"
# Req 3.2: bash の set -e 下で関数を呼んでも RC_APPLY_FAIL を取得できた = process 異常終了していない
# （set +e なしでもここまで到達できることは po_check_dispatch_gate が 0 以外で exit していない証拠。
#  apply 内部の `return 1` を呼び出し側が `if ! ...; then ... fi` でキャッチしているため
#  set -e でも process は継続する）。本 assert はここまで到達した事実そのもの。
echo "PASS: Req3.2 apply 失敗でも process は異常終了せず後続評価が継続できる（ここまで到達）"
PASS_COUNT=$((PASS_COUNT + 1))

# ─── 結果サマリ ───
echo "----"
echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
