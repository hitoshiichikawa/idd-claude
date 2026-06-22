#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/promote-pipeline.sh の Issue #370（Slack 通知 emitter）で
#       追加した `pp_do_promote` の rc=0 path から `sn_notify promote` 呼び出しが発火する
#       ことを fixture で検証する近接テスト。
#
#       対象関数:
#         - pp_do_promote (#370 task 6: 親シェル rc=0 分岐に sn_notify hook を追加)
#
#       検証する AC（docs/specs/370-feat-watcher-slack-d-18/requirements.md）:
#         - Req 2.4: promote 完了で 1 通発行
#         - Req 2.5: promote 失敗（rc=1）では発火しない
#         - Req 3.1 / 3.5: event_type=promote / result=promote-success
#         - Req 3.3: number sentinel "0"（branch promotion ゆえ Issue 番号なし）
#         - NFR 1.1: hook は fail-open（|| true）でパイプラインに伝播しない
#
# 配置先: local-watcher/test/sn_callsite_promote_test.sh
# 依存:   bash 4+, awk
# 実行:   bash local-watcher/test/sn_callsite_promote_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PP_MOD="$SCRIPT_DIR/../bin/modules/promote-pipeline.sh"

if [ ! -f "$PP_MOD" ]; then
  echo "ERROR: cannot find promote-pipeline.sh at $PP_MOD" >&2
  exit 2
fi

# extract_function イディオム（既存テストと同形式）
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# pp_do_promote のみを抽出。pp_log / pp_warn / pp_notify_promote_failure は本テスト用の stub
# で上書きするため、依存関数として個別に抽出しない。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$PP_MOD" "pp_do_promote")"

if ! declare -F pp_do_promote >/dev/null; then
  echo "ERROR: pp_do_promote not loaded" >&2
  exit 2
fi

# ── stubs ──
pp_log()  { :; }
pp_warn() { :; }
pp_notify_promote_failure() { :; }

# git stub: 環境変数で挙動制御
# - GIT_FETCH_RC: fetch 戻り値（既定 0）
# - GIT_MERGE_BASE_RC: merge-base --is-ancestor 戻り値（既定 0）
# - GIT_PUSH_RC: push 戻り値（既定 0）
git() {
  case "$1" in
    fetch)        return "${GIT_FETCH_RC:-0}" ;;
    merge-base)   return "${GIT_MERGE_BASE_RC:-0}" ;;
    push)         return "${GIT_PUSH_RC:-0}" ;;
    checkout)     return 0 ;;
    *)            return 0 ;;
  esac
}

timeout() { shift; "$@"; }

# sn_notify stub: call count + 引数記録
SN_NOTIFY_CALL_COUNT=0
SN_NOTIFY_LAST_EVENT=""
SN_NOTIFY_LAST_RESULT=""
SN_NOTIFY_LAST_NUMBER=""
SN_NOTIFY_LAST_DETAIL=""
sn_notify() {
  SN_NOTIFY_CALL_COUNT=$((SN_NOTIFY_CALL_COUNT + 1))
  SN_NOTIFY_LAST_EVENT="${1:-}"
  SN_NOTIFY_LAST_NUMBER="${2:-}"
  SN_NOTIFY_LAST_RESULT="${4:-}"
  SN_NOTIFY_LAST_DETAIL="${5:-}"
  return 0
}

# pp_do_promote が遅延束縛で参照するグローバル env（shellcheck からは未使用に見える）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
BASE_BRANCH="develop"
# shellcheck disable=SC2034
PROMOTION_TARGET_BRANCH="main"
# shellcheck disable=SC2034
PROMOTE_GIT_TIMEOUT=60
# shellcheck disable=SC2034
PROMOTE_CANDIDATES=(123 456)
PP_PROMOTE_SUCCESS_COUNT=0
PP_PROMOTE_FAILED_COUNT=0

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

# ============================================================
# Section 1: 正常 path（rc=0）→ sn_notify が 1 回 promote-success で発火
# ============================================================
echo "--- Section 1: pp_do_promote 成功 path（Req 2.4 / 3.5） ---"

SN_NOTIFY_CALL_COUNT=0
SN_NOTIFY_LAST_EVENT=""
SN_NOTIFY_LAST_RESULT=""
SN_NOTIFY_LAST_NUMBER=""
SN_NOTIFY_LAST_DETAIL=""
PP_PROMOTE_SUCCESS_COUNT=0
PP_PROMOTE_FAILED_COUNT=0
GIT_FETCH_RC=0
GIT_MERGE_BASE_RC=0
GIT_PUSH_RC=0

rc=0
pp_do_promote || rc=$?

assert_eq "正常 path → rc=0" "0" "$rc"
assert_eq "正常 path → PP_PROMOTE_SUCCESS_COUNT インクリメント" "1" "$PP_PROMOTE_SUCCESS_COUNT"
assert_eq "#370 Req 2.4: sn_notify が 1 回発火" "1" "$SN_NOTIFY_CALL_COUNT"
assert_eq "#370 Req 3.1: event_type=promote" "promote" "$SN_NOTIFY_LAST_EVENT"
assert_eq "#370 Req 3.5: result=promote-success" "promote-success" "$SN_NOTIFY_LAST_RESULT"
assert_eq "#370 Req 3.3: number sentinel '0'" "0" "$SN_NOTIFY_LAST_NUMBER"

# detail に base / target / candidates 件数を含む
case "$SN_NOTIFY_LAST_DETAIL" in
  *"base=develop"*"target=main"*"candidates=2"*)
    echo "PASS: #370 task 6: detail に base/target/candidates 件数を含む"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: detail 構造が想定外: $SN_NOTIFY_LAST_DETAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac

# ============================================================
# Section 2: 失敗 path（git push 失敗）→ sn_notify は発火しない（Req 2.5）
# ============================================================
echo ""
echo "--- Section 2: pp_do_promote 失敗 path（Req 2.5） ---"

SN_NOTIFY_CALL_COUNT=0
PP_PROMOTE_SUCCESS_COUNT=0
PP_PROMOTE_FAILED_COUNT=0
GIT_FETCH_RC=0
GIT_MERGE_BASE_RC=0
GIT_PUSH_RC=1  # push 失敗

rc=0
pp_do_promote || rc=$?

assert_eq "失敗 path → rc=1" "1" "$rc"
assert_eq "失敗 path → PP_PROMOTE_FAILED_COUNT インクリメント" "1" "$PP_PROMOTE_FAILED_COUNT"
assert_eq "失敗 path → PP_PROMOTE_SUCCESS_COUNT 不変" "0" "$PP_PROMOTE_SUCCESS_COUNT"
assert_eq "#370 Req 2.5: 失敗 path で sn_notify は呼ばれない" "0" "$SN_NOTIFY_CALL_COUNT"

# ============================================================
# Section 3: 失敗 path（merge-base 失敗 = non-fast-forward）→ sn_notify 発火しない
# ============================================================
echo ""
echo "--- Section 3: pp_do_promote non-fast-forward 失敗（Req 2.5） ---"

SN_NOTIFY_CALL_COUNT=0
PP_PROMOTE_SUCCESS_COUNT=0
PP_PROMOTE_FAILED_COUNT=0
GIT_FETCH_RC=0
GIT_MERGE_BASE_RC=1  # 祖先関係なし
GIT_PUSH_RC=0

rc=0
pp_do_promote || rc=$?

assert_eq "non-ff 失敗 → rc=1" "1" "$rc"
assert_eq "#370 Req 2.5: non-ff 失敗で sn_notify は呼ばれない" "0" "$SN_NOTIFY_CALL_COUNT"

# ============================================================
# Section 4: 失敗 path（fetch 失敗）→ sn_notify 発火しない
# ============================================================
echo ""
echo "--- Section 4: pp_do_promote fetch 失敗（Req 2.5） ---"

SN_NOTIFY_CALL_COUNT=0
PP_PROMOTE_SUCCESS_COUNT=0
PP_PROMOTE_FAILED_COUNT=0
GIT_FETCH_RC=1  # fetch 失敗
GIT_MERGE_BASE_RC=0
GIT_PUSH_RC=0

rc=0
pp_do_promote || rc=$?

assert_eq "fetch 失敗 → rc=1" "1" "$rc"
assert_eq "#370 Req 2.5: fetch 失敗で sn_notify は呼ばれない" "0" "$SN_NOTIFY_CALL_COUNT"

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
