#!/usr/bin/env bash
#
# 用途: Issue #388（armed/merged 通知の区別）で slack-notify.sh に追加された
#       event_type の enum 拡張と armed/merged の payload 構造を検証するスモークテスト。
#
#       対象関数:
#         - sn_build_payload (#388 で enum に
#                             `auto-merge-merged` / `auto-merge-design-merged` を追加 /
#                             Req 2.1, 2.2, 3.2, 3.5)
#
#       検証する AC（docs/specs/388-fix-slack-notify-auto-merge-result-succe/requirements.md）:
#         - Req 2.1: 新 event_type `auto-merge-merged` が受理される
#         - Req 2.2: 新 event_type `auto-merge-design-merged` が受理される
#         - Req 3.2 / 3.5: 既存 5 event_type は引き続き受理される（後方互換 / NFR 4.1）
#         - Req 3.5 / NFR 4.1: 既存 enum 検証ロジックと同形（不正値は rejection）
#         - Req 1.1 / 1.2: armed 通知の result=armed が payload に正しく含まれる
#         - Req 2.3 / 4.3: merged 通知の result=merged が payload に正しく含まれる
#         - Req 4.3: detail の secret scrub は新 event_type でも適用される
#
# 配置先: local-watcher/test/sn_build_payload_388_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/sn_build_payload_388_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/slack-notify.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find slack-notify.sh at $MODULE_SH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH" >&2
  exit 2
fi

# 関数抽出イディオム
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# sn_warn / sn_log は env 由来副作用なし → スタブで /dev/null
sn_warn() { :; }
sn_log() { :; }

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sn_scrub_secrets")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sn_build_payload")"

if ! declare -F sn_build_payload >/dev/null; then
  echo "ERROR: sn_build_payload not loaded" >&2
  exit 2
fi

# shellcheck disable=SC2034  # sn_build_payload は $REPO を読むため間接的に使用される
REPO="owner/test-repo"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ============================================================
# Section 1: 新 event_type は受理される（Req 2.1, 2.2）
# ============================================================
echo "--- Section 1: 新 event_type 受理（Req 2.1, 2.2） ---"

for evt in "auto-merge-merged" "auto-merge-design-merged"; do
  if sn_build_payload "$evt" "1" "https://example.com" "merged" "" >/dev/null 2>&1; then
    pass "Req 2.x: event_type=$evt は受理される"
  else
    fail "Req 2.x: 新 event_type=$evt が rejection"
  fi
done

# ============================================================
# Section 2: 既存 5 event_type は引き続き受理される（後方互換 / Req 3.2 / NFR 4.1）
# ============================================================
echo ""
echo "--- Section 2: 既存 event_type 後方互換（Req 3.2 / NFR 4.1） ---"

for evt in "auto-merge" "auto-merge-design" "failed-recovery" "needs-decisions-auto-continue" "promote"; do
  if sn_build_payload "$evt" "1" "https://example.com" "success" "" >/dev/null 2>&1; then
    pass "後方互換: 既存 event_type=$evt は引き続き受理"
  else
    fail "後方互換: 既存 event_type=$evt が rejection"
  fi
done

# ============================================================
# Section 3: 不正値（typo / 大文字化 / 空）は rejected（既存規約と同形 / Req 3.5）
# ============================================================
echo ""
echo "--- Section 3: 不正 event_type は rejected（Req 3.5） ---"

for evt in "" "auto-merge-MERGED" "Auto-Merge-Merged" "merged" "auto_merge_merged" "auto-merged" "merge"; do
  if sn_build_payload "$evt" "1" "https://example.com" "merged" "" >/dev/null 2>&1; then
    fail "Req 3.5: 不正 event_type=$(printf '%q' "$evt") が受理されてしまった"
  else
    pass "Req 3.5: 不正 event_type=$(printf '%q' "$evt") は rejected"
  fi
done

# ============================================================
# Section 4: armed 通知 payload の構造検証（Req 1.1, 1.2）
# ============================================================
echo ""
echo "--- Section 4: armed 通知 payload（Req 1.1, 1.2） ---"

payload=$(sn_build_payload "auto-merge" "100" "https://github.com/owner/test-repo/pull/100" "armed" "armed (squash on green checks) head=feature sha=abc123" 2>/dev/null)
if [ -z "$payload" ]; then
  fail "Req 1.1: armed payload 出力が空"
elif printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  pass "Req 1.1: armed 通知 well-formed JSON"
else
  fail "Req 1.1: armed payload が壊れた JSON: $payload"
fi

text_field=$(printf '%s' "$payload" | jq -r '.text' 2>/dev/null || echo "")
case "$text_field" in
  *"auto-merge"*"#100"*"armed"*) pass "Req 1.1: armed text field に event_type=auto-merge / PR 番号 / result=armed を含む" ;;
  *) fail "Req 1.1: armed text field 構造が想定外: $text_field" ;;
esac

block_text=$(printf '%s' "$payload" | jq -r '.blocks[0].text.text' 2>/dev/null || echo "")
case "$block_text" in
  *"armed (squash on green checks)"*) pass "Req 1.3: armed blocks[0].text に「armed (squash on green checks)」を含み merge 完了との誤読を防ぐ" ;;
  *) fail "Req 1.3: armed blocks[0].text に armed の明示なし: $block_text" ;;
esac

# Result フィールドにも armed が含まれる
case "$block_text" in
  *"Result"*"armed"*) pass "Req 1.1: armed blocks 内に Result: armed の表示" ;;
  *) fail "Req 1.1: armed result フィールド表記なし: $block_text" ;;
esac

# ============================================================
# Section 5: merged 通知 payload の構造検証（Req 2.1, 2.2）
# ============================================================
echo ""
echo "--- Section 5: merged 通知 payload（Req 2.1, 2.2） ---"

payload=$(sn_build_payload "auto-merge-merged" "100" "https://github.com/owner/test-repo/pull/100" "merged" "merged via auto-merge at 2026-06-23T12:00:00Z" 2>/dev/null)
if printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  pass "Req 2.1: merged 通知 well-formed JSON"
else
  fail "Req 2.1: merged payload が壊れた JSON"
fi

text_field=$(printf '%s' "$payload" | jq -r '.text' 2>/dev/null || echo "")
case "$text_field" in
  *"auto-merge-merged"*"#100"*"merged"*) pass "Req 2.1: merged text field に event_type=auto-merge-merged / PR 番号 / result=merged を含む" ;;
  *) fail "Req 2.1: merged text field 構造が想定外: $text_field" ;;
esac

# design 版 merged
payload=$(sn_build_payload "auto-merge-design-merged" "200" "https://github.com/owner/test-repo/pull/200" "merged" "merged via auto-merge at 2026-06-23T12:00:00Z" 2>/dev/null)
text_field=$(printf '%s' "$payload" | jq -r '.text' 2>/dev/null || echo "")
case "$text_field" in
  *"auto-merge-design-merged"*"#200"*"merged"*) pass "Req 2.2: design merged text field に event_type=auto-merge-design-merged を含む" ;;
  *) fail "Req 2.2: design merged text field 構造が想定外: $text_field" ;;
esac

# ============================================================
# Section 6: detail の secret scrub は新 event_type でも適用される（Req 4.3）
# ============================================================
echo ""
echo "--- Section 6: 新 event_type の detail secret scrub（Req 4.3） ---"

payload=$(sn_build_payload "auto-merge-merged" "1" "https://example.com" "merged" "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789 head=feature" 2>/dev/null)
block_text=$(printf '%s' "$payload" | jq -r '.blocks[0].text.text' 2>/dev/null || echo "")
case "$block_text" in
  *"[REDACTED]"*) pass "Req 4.3: 新 event_type でも detail 内の ghp_ token が [REDACTED] に置換" ;;
  *) fail "Req 4.3: 新 event_type で secret scrub が適用されない: $block_text" ;;
esac
case "$block_text" in
  *"ghp_abcdefghij"*) fail "Req 4.3: ghp_ token が payload に残置" ;;
  *) pass "Req 4.3: ghp_ token 値は payload に残っていない" ;;
esac

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
