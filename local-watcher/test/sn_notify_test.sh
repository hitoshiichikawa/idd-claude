#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/slack-notify.sh の Issue #370（Slack 通知 emitter）で
#       追加した `sn_notify` public entry point（および `sn_post_webhook`）の評価順序・
#       fail-open 挙動・ログ出力規約を curl stub を用いて検証するスモークテスト。
#
#       対象関数:
#         - sn_notify       (#370 Req 1.4 / 1.5 / 2.6 / 4.3 / 4.4 / 5.1〜5.5 / NFR 1.1 / NFR 2.1)
#         - sn_post_webhook (#370 Req 4.1 / 4.2 / 4.5 / NFR 2.2 / NFR 3.4 経由)
#
#       検証する AC（docs/specs/370-feat-watcher-slack-d-18/requirements.md）:
#         - Req 1.4: SLACK_NOTIFY_ENABLED=true + URL 未設定で no-op + WARN
#         - Req 1.5: gate OFF で curl stub 不呼出（NFR 2.1）
#         - Req 2.6: 同一 tick 複数呼び出しで各 1 通発行
#         - Req 4.1: HTTP 4xx/5xx で fail-open + WARN
#         - Req 4.2: curl 非ゼロ exit (transport-error) で fail-open + WARN
#         - Req 4.4: 通知失敗 / 成功どちらでも sn_notify は rc=0
#         - Req 5.1: 成功時に構造化 1 行ログ
#         - Req 5.3: URL 未設定時の WARN
#         - Req 5.4: 失敗時の WARN
#         - Req 5.5 / NFR 3.4: ログに webhook URL 全体を含めない
#
# 配置先: local-watcher/test/sn_notify_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/sn_notify_test.sh

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

# 関数本体を全て source（curl は stub で置き換える）。
# トップレベル副作用を持たない module 設計のため、source しても安全。
# shellcheck source=/dev/null
. "$MODULE_SH"

# shellcheck disable=SC2034  # sn_notify / sn_log は $REPO を読むため間接的に使用される
REPO="owner/test-repo"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ─────────────────────────────────────────────────────────────────────────────
# curl stub harness
#   STUB_DIR にダミーの curl を置き、PATH の先頭にして本物の curl より優先させる。
#   stub の挙動は env で制御:
#     - STUB_HTTP_STATUS: -w で出力する HTTP status code（既定 "200"）
#     - STUB_EXIT_CODE  : curl の exit code（既定 "0"。タイムアウトを模す場合 "28"）
#   stub は呼び出されたら STUB_CALL_COUNT_FILE に "1" を 1 行追記し、
#   STUB_PAYLOAD_FILE に stdin の payload を書き出す（観測用）。
# ─────────────────────────────────────────────────────────────────────────────
STUB_DIR=$(mktemp -d -t sn_notify_stub.XXXXXX)
trap 'rm -rf "$STUB_DIR" 2>/dev/null || true' EXIT

cat >"$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# stub curl: HTTP status / exit code を env で制御し、stdin payload と call count を記録する。
status="${STUB_HTTP_STATUS:-200}"
ec="${STUB_EXIT_CODE:-0}"
if [ -n "${STUB_CALL_COUNT_FILE:-}" ]; then
  echo "1" >>"$STUB_CALL_COUNT_FILE"
fi
if [ -n "${STUB_PAYLOAD_FILE:-}" ]; then
  cat - >"$STUB_PAYLOAD_FILE" 2>/dev/null || true
else
  cat - >/dev/null 2>/dev/null || true
fi
# -w '%{http_code}' を見つけたら status を stdout
for arg in "$@"; do
  case "$arg" in
    "%{http_code}") printf '%s' "$status"; break ;;
  esac
done
exit "$ec"
STUB
chmod +x "$STUB_DIR/curl"

export PATH="$STUB_DIR:$PATH"

# helper: stub state を reset し、sn_notify を呼んで結果を観測
reset_stub() {
  : >"$STUB_CALL_COUNT_FILE"
  : >"$STUB_PAYLOAD_FILE"
  : >"$STDOUT_FILE"
  : >"$STDERR_FILE"
}

stub_call_count() {
  if [ -f "$STUB_CALL_COUNT_FILE" ]; then
    wc -l <"$STUB_CALL_COUNT_FILE" | tr -d ' '
  else
    echo "0"
  fi
}

STUB_CALL_COUNT_FILE="$STUB_DIR/calls.log"
STUB_PAYLOAD_FILE="$STUB_DIR/payload.log"
STDOUT_FILE="$STUB_DIR/stdout.log"
STDERR_FILE="$STUB_DIR/stderr.log"
export STUB_CALL_COUNT_FILE STUB_PAYLOAD_FILE

# テスト用 webhook URL placeholder（実 webhook には到達しない / stub が捕捉）
TEST_WEBHOOK_URL="https://hooks.slack.com/services/TEST/TEST/secrettokenxxxxxxxxxxxxxxxxxx"

# ============================================================
# Section 1: gate OFF で curl stub 不呼出（Req 1.5 / NFR 1.1 / NFR 2.1）
# ============================================================
echo "--- Section 1: gate OFF で curl 不呼出（Req 1.5 / NFR 2.1） ---"

SLACK_NOTIFY_ENABLED="false"
SLACK_WEBHOOK_URL="$TEST_WEBHOOK_URL"
reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(stub_call_count)" = "0" ]; then
  pass "Req 1.5 / NFR 2.1: gate OFF で curl 呼び出しゼロ + rc=0"
else
  fail "Req 1.5: gate OFF だが curl が $(stub_call_count) 回呼ばれた / rc=$rc"
fi
# 追加ログも出ない（Req 5.2）
if [ ! -s "$STDOUT_FILE" ] && [ ! -s "$STDERR_FILE" ]; then
  pass "Req 5.2: gate OFF 時に追加ログを出さない"
else
  fail "Req 5.2: gate OFF だがログ出力あり stdout=$(cat "$STDOUT_FILE") stderr=$(cat "$STDERR_FILE")"
fi

# 未設定でも同じ
unset SLACK_NOTIFY_ENABLED
reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >/dev/null 2>&1
if [ "$(stub_call_count)" = "0" ]; then
  pass "Req 1.5: SLACK_NOTIFY_ENABLED 未設定で curl 呼び出しゼロ"
else
  fail "Req 1.5: 未設定だが curl が呼ばれた"
fi

# ============================================================
# Section 2: gate ON + URL 未設定で no-op + WARN（Req 1.4 / 5.3）
# ============================================================
echo ""
echo "--- Section 2: gate ON + URL 未設定（Req 1.4 / 5.3） ---"

SLACK_NOTIFY_ENABLED="true"
SLACK_WEBHOOK_URL=""
reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(stub_call_count)" = "0" ]; then
  pass "Req 1.4: URL 未設定で curl 不呼出 + rc=0（fail-open）"
else
  fail "Req 1.4: URL 未設定だが curl 呼出 or rc非0: calls=$(stub_call_count) rc=$rc"
fi
if grep -q "url-unset" "$STDERR_FILE"; then
  pass "Req 5.3: URL 未設定 WARN ログ 1 行（reason=url-unset）を出力"
else
  fail "Req 5.3: url-unset WARN が出力されない: $(cat "$STDERR_FILE")"
fi

unset SLACK_WEBHOOK_URL
reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
if [ "$(stub_call_count)" = "0" ] && grep -q "url-unset" "$STDERR_FILE"; then
  pass "Req 1.4: SLACK_WEBHOOK_URL 未設定（unset）でも no-op + WARN"
else
  fail "Req 1.4: unset で挙動が違う"
fi

# ============================================================
# Section 3: gate ON + URL 設定済 + HTTP 200 で 1 通発行（Req 2.x / 5.1）
# ============================================================
echo ""
echo "--- Section 3: 正常系（HTTP 200 / Req 2.x / 5.1） ---"

SLACK_NOTIFY_ENABLED="true"
SLACK_WEBHOOK_URL="$TEST_WEBHOOK_URL"
SLACK_NOTIFY_TIMEOUT="5"
STUB_HTTP_STATUS="200"
STUB_EXIT_CODE="0"
export STUB_HTTP_STATUS STUB_EXIT_CODE

reset_stub
sn_notify "auto-merge" "123" "https://github.com/owner/test-repo/pull/123" "success" "head=feature" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(stub_call_count)" = "1" ]; then
  pass "Req 2.1 / NFR 5.1: 正常系で curl 1 回呼出 + rc=0"
else
  fail "Req 2.1: calls=$(stub_call_count) rc=$rc"
fi
if grep -q "event=auto-merge" "$STDOUT_FILE" && grep -q "number=123" "$STDOUT_FILE" \
    && grep -q "result=success" "$STDOUT_FILE" && grep -q "http_status=200" "$STDOUT_FILE" \
    && grep -q "host=hooks.slack.com" "$STDOUT_FILE"; then
  pass "Req 5.1 / NFR 5.1: 構造化ログ 1 行に必須 field 全て含む"
else
  fail "Req 5.1: 構造化ログ field 欠落: $(cat "$STDOUT_FILE")"
fi

# 同一 tick 内複数呼び出し（Req 2.6）
reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >/dev/null 2>&1
sn_notify "failed-recovery" "2" "https://example.com" "recovered" "" >/dev/null 2>&1
sn_notify "promote" "0" "https://example.com" "promote-success" "" >/dev/null 2>&1
if [ "$(stub_call_count)" = "3" ]; then
  pass "Req 2.6: 同一 tick 3 回呼び出しで curl 3 回（各イベント 1 通）"
else
  fail "Req 2.6: 期待 3 回 / actual=$(stub_call_count)"
fi

# ============================================================
# Section 4: payload が curl の stdin に正しく渡される（NFR 3.3 副次）
# ============================================================
echo ""
echo "--- Section 4: payload は stdin (-d @-) で渡される ---"

reset_stub
sn_notify "auto-merge" "42" "https://github.com/foo/bar/pull/42" "success" "" >/dev/null 2>&1
if [ -s "$STUB_PAYLOAD_FILE" ]; then
  if jq -e . "$STUB_PAYLOAD_FILE" >/dev/null 2>&1; then
    pass "NFR 3.3: payload が stdin 経由で curl に渡される + well-formed JSON"
  else
    fail "NFR 3.3: stdin payload が JSON ではない: $(cat "$STUB_PAYLOAD_FILE")"
  fi
else
  fail "NFR 3.3: stdin payload が空（-d @- で渡されていない）"
fi

# ============================================================
# Section 5: HTTP 4xx で fail-open + WARN（Req 4.1 / 5.4）
# ============================================================
echo ""
echo "--- Section 5: HTTP 4xx で fail-open（Req 4.1 / 5.4） ---"

STUB_HTTP_STATUS="404"
STUB_EXIT_CODE="0"
export STUB_HTTP_STATUS

reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "Req 4.1 / 4.4: HTTP 404 でも sn_notify は rc=0（fail-open）"
else
  fail "Req 4.1: HTTP 404 で rc=$rc（fail-open 違反）"
fi
if grep -qE "http-4xx.*status=404" "$STDERR_FILE"; then
  pass "Req 5.4: HTTP 4xx WARN ログ（reason=http-4xx status=404）出力"
else
  fail "Req 5.4: WARN 出力なし or 形式違反: $(cat "$STDERR_FILE")"
fi

# ============================================================
# Section 6: HTTP 5xx で fail-open + WARN（Req 4.1 / 5.4）
# ============================================================
echo ""
echo "--- Section 6: HTTP 5xx で fail-open（Req 4.1 / 5.4） ---"

STUB_HTTP_STATUS="500"
STUB_EXIT_CODE="0"
export STUB_HTTP_STATUS

reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ] && grep -qE "http-5xx.*status=500" "$STDERR_FILE"; then
  pass "Req 4.1 / 5.4: HTTP 500 で fail-open + WARN（reason=http-5xx）"
else
  fail "Req 4.1: HTTP 500 で rc=$rc / WARN=$(cat "$STDERR_FILE")"
fi

# ============================================================
# Section 7: curl 非ゼロ exit (transport-error) で fail-open + WARN（Req 4.2 / 5.4）
# ============================================================
echo ""
echo "--- Section 7: transport-error fail-open（Req 4.2 / 5.4） ---"

STUB_HTTP_STATUS="000"
STUB_EXIT_CODE="28"  # curl timeout
export STUB_HTTP_STATUS STUB_EXIT_CODE

reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ] && grep -qE "transport-error.*curl_exit=28" "$STDERR_FILE"; then
  pass "Req 4.2 / 5.4: curl timeout (exit=28) で fail-open + WARN（transport-error）"
else
  fail "Req 4.2: rc=$rc / WARN=$(cat "$STDERR_FILE")"
fi

# ============================================================
# Section 8: webhook URL 全体をログに含めない（Req 5.5 / NFR 3.4）
# ============================================================
echo ""
echo "--- Section 8: webhook URL 全体非出力（Req 5.5 / NFR 3.4） ---"

# 全てのテスト stdout/stderr で webhook URL の secret token 部分が出ないことを再確認。
# 各 section の log を再生成して grep する（最後のテストは transport-error）。
SECRET_TOKEN="secrettokenxxxxxxxxxxxxxxxxxx"

# 成功 case
STUB_HTTP_STATUS="200"
STUB_EXIT_CODE="0"
export STUB_HTTP_STATUS STUB_EXIT_CODE
reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
if ! grep -q "$SECRET_TOKEN" "$STDOUT_FILE" && ! grep -q "$SECRET_TOKEN" "$STDERR_FILE"; then
  pass "Req 5.5 / NFR 3.4: 成功時ログに webhook URL の secret token を含まない"
else
  fail "Req 5.5: 成功時ログに webhook secret 漏洩"
fi
# ホスト部のみ含む（成功ログには `host=hooks.slack.com` だけ）
if grep -q "host=hooks.slack.com" "$STDOUT_FILE"; then
  pass "Req 5.5: 成功ログに host=hooks.slack.com のみ（path は出さない）"
else
  fail "Req 5.5: 成功ログに host が含まれない: $(cat "$STDOUT_FILE")"
fi

# 失敗 case (4xx)
STUB_HTTP_STATUS="403"
export STUB_HTTP_STATUS
reset_stub
sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
if ! grep -q "$SECRET_TOKEN" "$STDERR_FILE"; then
  pass "NFR 3.4: 失敗 WARN にも webhook URL の secret token を含まない"
else
  fail "NFR 3.4: 失敗 WARN に webhook secret 漏洩: $(cat "$STDERR_FILE")"
fi

# ============================================================
# Section 9: 不正な引数で fail-open（NFR 3.2 / Req 4.3）
# ============================================================
echo ""
echo "--- Section 9: 不正引数 fail-open（NFR 3.2 / Req 4.3） ---"

STUB_HTTP_STATUS="200"
STUB_EXIT_CODE="0"
export STUB_HTTP_STATUS STUB_EXIT_CODE
# shellcheck disable=SC2034  # sn_notify 内部で参照される
SLACK_NOTIFY_ENABLED="true"
# shellcheck disable=SC2034  # sn_notify 内部で参照される
SLACK_WEBHOOK_URL="$TEST_WEBHOOK_URL"

# 不正な event_type
reset_stub
sn_notify "unknown" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(stub_call_count)" = "0" ]; then
  pass "Req 4.3: 不正 event_type で curl 不呼出 + rc=0（fail-open）"
else
  fail "Req 4.3: 不正 event_type で curl=$(stub_call_count) / rc=$rc"
fi

# 不正な number
reset_stub
sn_notify "auto-merge" "abc" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(stub_call_count)" = "0" ]; then
  pass "NFR 3.2: 不正 number で curl 不呼出 + rc=0（fail-open）"
else
  fail "NFR 3.2: 不正 number で curl=$(stub_call_count) / rc=$rc"
fi

# ============================================================
# Section 10: SLACK_NOTIFY_TIMEOUT 非数値 / 負数の正規化
# ============================================================
echo ""
echo "--- Section 10: SLACK_NOTIFY_TIMEOUT 不正値正規化 ---"

STUB_HTTP_STATUS="200"
STUB_EXIT_CODE="0"
export STUB_HTTP_STATUS STUB_EXIT_CODE

for badval in "abc" "-5" "" "0"; do
  # shellcheck disable=SC2034  # sn_post_webhook 内部で参照される
  SLACK_NOTIFY_TIMEOUT="$badval"
  reset_stub
  sn_notify "auto-merge" "1" "https://example.com" "success" "" >"$STDOUT_FILE" 2>"$STDERR_FILE"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(stub_call_count)" = "1" ]; then
    pass "Req 4.5: SLACK_NOTIFY_TIMEOUT=$(printf '%q' "$badval") でも通知発火（既定 5 正規化）"
  else
    fail "Req 4.5: 不正 timeout=$(printf '%q' "$badval") で挙動異常 rc=$rc calls=$(stub_call_count)"
  fi
done

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
