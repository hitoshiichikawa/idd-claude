#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/slack-notify.sh の Issue #370（Slack 通知 emitter）で
#       追加した `sn_build_payload` / `sn_scrub_secrets` 関数の payload 整形・secret scrub
#       挙動を fixture で検証するスモークテスト。
#
#       対象関数:
#         - sn_scrub_secrets (#370 NFR 3.3)
#         - sn_build_payload (#370 Req 3.1〜3.6 / NFR 3.2 / NFR 3.3 / NFR 4.2)
#
#       検証する AC（docs/specs/370-feat-watcher-slack-d-18/requirements.md）:
#         - Req 3.1: payload に event_type 識別子を含む
#         - Req 3.2: payload に repo 識別子を含む
#         - Req 3.3: payload に Issue/PR 番号を含む
#         - Req 3.4: payload に GitHub URL を含む
#         - Req 3.5: 終端遷移には result status を含む
#         - Req 3.6 / NFR 3.3: secret 候補値を [REDACTED] 置換する
#         - NFR 3.2: jq --arg sanitize（quote 含む未信頼入力を安全に展開）
#         - NFR 4.2: well-formed JSON が出力される
#
# 配置先: local-watcher/test/sn_build_payload_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/sn_build_payload_test.sh

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

# 関数抽出イディオム（fr_is_enabled_test.sh と同形式）
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# sn_warn / sn_log は env 由来副作用なし & stderr/stdout 出力のみ → スタブで /dev/null に流す
sn_warn() { :; }
sn_log() { :; }

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sn_scrub_secrets")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "sn_build_payload")"

if ! declare -F sn_scrub_secrets >/dev/null; then
  echo "ERROR: sn_scrub_secrets not loaded" >&2
  exit 2
fi
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
# Section 1: sn_scrub_secrets — secret 候補値の検出と置換（NFR 3.3）
# ============================================================
echo "--- Section 1: sn_scrub_secrets（NFR 3.3） ---"

scrubbed=$(sn_scrub_secrets "ghp_abcdefghijklmnopqrstuvwxyz0123456789")
case "$scrubbed" in
  *"[REDACTED]"*) pass "NFR 3.3: GitHub token (ghp_) prefix を [REDACTED] 置換" ;;
  *) fail "NFR 3.3: ghp_ token を置換できず: $scrubbed" ;;
esac

scrubbed=$(sn_scrub_secrets "head=foo gho_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA tail=bar")
case "$scrubbed" in
  *"head=foo"*"[REDACTED]"*"tail=bar"*) pass "NFR 3.3: gho_ token 周辺を保持しつつ置換" ;;
  *) fail "NFR 3.3: gho_ token 置換結果が想定外: $scrubbed" ;;
esac

scrubbed=$(sn_scrub_secrets "url=https://hooks.slack.com/services/T123/B456/abcdefghijklmnop")
case "$scrubbed" in
  *"[REDACTED]"*) pass "NFR 3.3: Slack webhook URL prefix を [REDACTED] 置換" ;;
  *) fail "NFR 3.3: Slack webhook URL を置換できず: $scrubbed" ;;
esac
case "$scrubbed" in
  *"hooks.slack.com"*) fail "NFR 3.3: Slack webhook URL host を残してしまった: $scrubbed" ;;
  *) pass "NFR 3.3: Slack webhook host も含めて redact 済" ;;
esac

scrubbed=$(sn_scrub_secrets "head=feature-branch sha=abc123")
if [ "$scrubbed" = "head=feature-branch sha=abc123" ]; then
  pass "NFR 3.3: 短い英数字（32 桁未満）は redact しない（false-positive 抑制）"
else
  fail "NFR 3.3: 短い英数字を誤 redact: $scrubbed"
fi

# 32 桁以上の連続英数字（best-effort / API key 風）
scrubbed=$(sn_scrub_secrets "key=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789AB")
case "$scrubbed" in
  *"[REDACTED]"*) pass "NFR 3.3: 32 桁以上の連続英数字を [REDACTED] 置換" ;;
  *) fail "NFR 3.3: 32 桁以上を置換できず: $scrubbed" ;;
esac

scrubbed=$(sn_scrub_secrets "")
if [ -z "$scrubbed" ]; then
  pass "NFR 3.3: 空文字入力は空文字を返す"
else
  fail "NFR 3.3: 空文字入力で非空: $(printf '%q' "$scrubbed")"
fi

# ============================================================
# Section 2: sn_build_payload — 正常系（必須フィールドの存在 / Req 3.1〜3.5）
# ============================================================
echo ""
echo "--- Section 2: sn_build_payload 正常系（Req 3.1〜3.5 / NFR 4.2） ---"

payload=$(sn_build_payload "auto-merge" "123" "https://github.com/owner/test-repo/pull/123" "success" "head=feature-x" 2>/dev/null)
if [ -z "$payload" ]; then
  fail "Req 3.x: payload 出力が空"
elif printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  pass "NFR 4.2: well-formed JSON が出力される"
else
  fail "NFR 4.2: payload が well-formed JSON ではない: $payload"
fi

# event_type の含有（Req 3.1）
case "$payload" in
  *"auto-merge"*) pass "Req 3.1: payload に event_type=auto-merge を含む" ;;
  *) fail "Req 3.1: event_type を含まず: $payload" ;;
esac

# repo の含有（Req 3.2）
case "$payload" in
  *"owner/test-repo"*) pass "Req 3.2: payload に repo 識別子を含む" ;;
  *) fail "Req 3.2: repo を含まず" ;;
esac

# 番号の含有（Req 3.3）
case "$payload" in
  *"#123"*) pass "Req 3.3: payload に Issue/PR 番号 #123 を含む" ;;
  *) fail "Req 3.3: 番号を含まず" ;;
esac

# URL の含有（Req 3.4）
case "$payload" in
  *"https://github.com/owner/test-repo/pull/123"*) pass "Req 3.4: payload に GitHub URL を含む" ;;
  *) fail "Req 3.4: URL を含まず" ;;
esac

# result の含有（Req 3.5）
case "$payload" in
  *"success"*) pass "Req 3.5: payload に result=success を含む" ;;
  *) fail "Req 3.5: result を含まず" ;;
esac

# text / blocks 構造の確認（design.md Slack Payload Schema）
text_field=$(printf '%s' "$payload" | jq -r '.text')
case "$text_field" in
  *"auto-merge"*"owner/test-repo"*"#123"*"success"*) pass "design.md: text フィールドに 4 要素を含む" ;;
  *) fail "design.md: text フィールド構造が想定外: $text_field" ;;
esac

block_text=$(printf '%s' "$payload" | jq -r '.blocks[0].text.text')
case "$block_text" in
  *"auto-merge"*"feature-x"*) pass "design.md: blocks[0].text.text に detail を含む" ;;
  *) fail "design.md: blocks[0].text.text 構造が想定外: $block_text" ;;
esac

# ─────────────────────────────────────────────────────────────
# Issue #390: claude-pickup 正常系（Req 1〜3 / payload 必須フィールド）
#   - event_type=claude-pickup が enum で受理され well-formed JSON が出力されること
#   - Issue 番号 / Issue URL / mode 識別子（detail 中の mode=impl）/ event_type が含まれること
# ─────────────────────────────────────────────────────────────
payload_pickup=$(sn_build_payload "claude-pickup" "390" "https://github.com/owner/test-repo/issues/390" "success" "mode=impl slot=1" 2>/dev/null)
if [ -z "$payload_pickup" ]; then
  fail "#390 Req 3.2: claude-pickup payload 出力が空"
elif printf '%s' "$payload_pickup" | jq -e . >/dev/null 2>&1; then
  pass "#390 Req 3.2: claude-pickup payload が well-formed JSON"
else
  fail "#390 Req 3.2: claude-pickup payload が well-formed JSON ではない: $payload_pickup"
fi
case "$payload_pickup" in
  *"claude-pickup"*) pass "#390 Req 3.1: payload に event_type=claude-pickup を含む" ;;
  *) fail "#390 Req 3.1: claude-pickup event_type を含まず: $payload_pickup" ;;
esac
case "$payload_pickup" in
  *"#390"*) pass "#390 Req 2.1: payload に Issue 番号 #390 を含む" ;;
  *) fail "#390 Req 2.1: Issue 番号を含まず" ;;
esac
case "$payload_pickup" in
  *"https://github.com/owner/test-repo/issues/390"*) pass "#390 Req 2.2: payload に Issue URL を含む" ;;
  *) fail "#390 Req 2.2: Issue URL を含まず" ;;
esac
block_text_pickup=$(printf '%s' "$payload_pickup" | jq -r '.blocks[0].text.text' 2>/dev/null || echo "")
case "$block_text_pickup" in
  *"mode=impl"*) pass "#390 Req 2.3: detail 内に mode 識別子（mode=impl）を含む" ;;
  *) fail "#390 Req 2.3: detail に mode 識別子が無い: $block_text_pickup" ;;
esac

# ============================================================
# Section 3: sn_build_payload — event_type enum 検証（Req 3.1）
# ============================================================
echo ""
echo "--- Section 3: event_type enum 検証（Req 3.1） ---"

for evt in "auto-merge" "auto-merge-design" "failed-recovery" "needs-decisions-auto-continue" "promote" "claude-pickup"; do
  if sn_build_payload "$evt" "1" "https://example.com" "success" "" >/dev/null 2>&1; then
    pass "Req 3.1: event_type=$evt は受理される"
  else
    fail "Req 3.1: event_type=$evt が rejection"
  fi
done

for evt in "" "Auto-Merge" "unknown" "auto_merge" "AUTO-MERGE" "merge"; do
  if sn_build_payload "$evt" "1" "https://example.com" "success" "" >/dev/null 2>&1; then
    fail "Req 3.1: 不正な event_type=$(printf '%q' "$evt") が受理された"
  else
    pass "Req 3.1: 不正な event_type=$(printf '%q' "$evt") は rejected"
  fi
done

# ============================================================
# Section 4: sn_build_payload — number 検証（^[0-9]+$ / NFR 3.2）
# ============================================================
echo ""
echo "--- Section 4: number ^[0-9]+$ 検証（NFR 3.2） ---"

for num in "0" "1" "123" "999999"; do
  if sn_build_payload "auto-merge" "$num" "https://example.com" "success" "" >/dev/null 2>&1; then
    pass "NFR 3.2: number=$num は受理"
  else
    fail "NFR 3.2: number=$num が rejection"
  fi
done

for num in "" "abc" "-1" "1.5" "12a" "a1" " 1" "1 "; do
  if sn_build_payload "auto-merge" "$num" "https://example.com" "success" "" >/dev/null 2>&1; then
    fail "NFR 3.2: 不正な number=$(printf '%q' "$num") が受理された"
  else
    pass "NFR 3.2: 不正な number=$(printf '%q' "$num") は rejected"
  fi
done

# ============================================================
# Section 5: secret scrub の payload 経由検証（Req 3.6 / NFR 3.3）
# ============================================================
echo ""
echo "--- Section 5: payload 経由の secret scrub（Req 3.6 / NFR 3.3） ---"

payload=$(sn_build_payload "failed-recovery" "42" "https://github.com/owner/test-repo/issues/42" "recovered" "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789 kind=issue" 2>/dev/null)
block_text=$(printf '%s' "$payload" | jq -r '.blocks[0].text.text' 2>/dev/null || echo "")
case "$block_text" in
  *"[REDACTED]"*) pass "Req 3.6: detail 内の ghp_ token が [REDACTED] に置換" ;;
  *) fail "Req 3.6: payload に ghp_ token が残置: $block_text" ;;
esac
case "$block_text" in
  *"ghp_abcdefghijklmnopqrstuvwxyz"*) fail "Req 3.6: payload に ghp_ token 値が残置: $block_text" ;;
  *) pass "Req 3.6: payload に ghp_ token 値が残っていない" ;;
esac
case "$block_text" in
  *"kind=issue"*) pass "Req 3.6: detail 内の non-secret 部分は保持される" ;;
  *) fail "Req 3.6: non-secret 部分が消失: $block_text" ;;
esac

# webhook URL を detail に紛れ込ませた場合
payload=$(sn_build_payload "auto-merge" "1" "https://example.com" "success" "Slack URL leak: https://hooks.slack.com/services/T1/B2/secrettokenxxx" 2>/dev/null)
block_text=$(printf '%s' "$payload" | jq -r '.blocks[0].text.text' 2>/dev/null || echo "")
case "$block_text" in
  *"hooks.slack.com/services/T1"*) fail "Req 3.6: detail に webhook URL が残置" ;;
  *"[REDACTED]"*) pass "Req 3.6: detail 内の webhook URL が [REDACTED] に置換" ;;
  *) fail "Req 3.6: 置換結果が想定外: $block_text" ;;
esac

# ============================================================
# Section 6: jq --arg sanitize — 危険文字を含む未信頼入力（NFR 3.2）
# ============================================================
echo ""
echo "--- Section 6: jq --arg sanitize（NFR 3.2） ---"

# detail に JSON 構造を壊す可能性のある文字（" / \ / 改行 / バックスラッシュ）を入れる
dangerous='detail with "quote" and \\backslash and { brace }'
payload=$(sn_build_payload "auto-merge" "1" "https://example.com" "success" "$dangerous" 2>/dev/null)
if printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  pass "NFR 3.2: 危険文字含む detail でも well-formed JSON"
else
  fail "NFR 3.2: 危険文字含む detail で JSON 壊れた: $payload"
fi

# url に quote 等を入れた場合も同様（実運用では無いが防御）
payload=$(sn_build_payload "promote" "0" 'https://example.com/"injected"' "promote-success" "" 2>/dev/null)
if printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  pass "NFR 3.2: url 中の quote も jq sanitize で吸収"
else
  fail "NFR 3.2: url 中の quote で JSON 壊れた: $payload"
fi

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
