#!/usr/bin/env bash
#
# 用途: Issue #417 で導入した Failed Recovery Processor の terminate cross-cycle
#       べき等化を検証する回帰テスト。
#
#       対象関数:
#         - fr_is_terminated                     (#417 純粋関数)
#         - fr_terminate_max_attempts            (#417 Req 1.1 / 1.3 / 1.5 / 2.3 / 2.6 / 3.1〜3.3)
#         - fr_terminate_no_progress             (#417 Req 1.2 / 1.4 / 1.6 / 2.3 / 2.6 / 3.1〜3.3)
#         - fr_filter_terminated_candidates      (#417 Req 2.1〜2.6 列挙除外)
#
#       検証する AC（docs/specs/417--bug-failed-recovery-processor-attempt-c/requirements.md）:
#         Req 1.1 / 1.2: 2 回目以降のサイクルで終端コメントを新たに投稿しない
#         Req 1.3 / 1.4: 生涯で最大 1 件しか投稿しない
#         Req 1.5 / 1.6: 終端済みを永続化（state JSON last_status）
#         Req 2.3:      terminate 後サイクルで着手 / 結果コメントを新たに投稿しない（fetch 段階で除外）
#         Req 2.4:      Slack 通知 emitter を新たに発火しない
#         Req 2.5:      attempt カウンタを加算しない（claude session 自体起動しない）
#         Req 2.6:      run-summary 確定を新たに行わない（rs_set_result 多重発火なし）
#         Req 3.1〜3.3: 永続化情報源（state JSON）
#         Req 4.1〜4.3: claude-failed ラベルを除去しない（既存 fr_terminate_test.sh と並行検証）
#         Req 5.1〜5.3: state 破損 / 欠落で fail-open
#         Req 6.1〜6.3: NFR 2.1 観測ログ + gate OFF 副作用ゼロは別 test で検証
#         NFR 2.1:      抑止時に `failed-recovery:` prefix 付き 1 行ログ
#         NFR 4.2:      rs_set_result 多重発火なし
#         NFR 1.1:      既存 schema 維持
#
# 配置先: local-watcher/test/fr_terminate_idempotent_test.sh
# 依存:   bash 4+, awk, jq, mktemp
# 実行:   bash local-watcher/test/fr_terminate_idempotent_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
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

# 対象: terminate 関数 + 依存ヘルパー + 状態管理関数
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_state_path")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_load_state")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_save_state")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_is_terminated")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_filter_terminated_candidates")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_post_attempt_comment")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_terminate_max_attempts")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_terminate_no_progress")"

for fn in fr_state_path fr_load_state fr_save_state fr_is_terminated \
          fr_filter_terminated_candidates fr_post_attempt_comment \
          fr_terminate_max_attempts fr_terminate_no_progress; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# ── グローバル env（遅延束縛で抽出関数本体から参照される） ──
# shellcheck disable=SC2034
REPO="owner/test-repo"
# shellcheck disable=SC2034
LABEL_FAILED="claude-failed"
# shellcheck disable=SC2034
FAILED_RECOVERY_GIT_TIMEOUT=60
# shellcheck disable=SC2034
FAILED_RECOVERY_MAX_ATTEMPTS=4

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

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  local actual_rc="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  pattern: $pattern"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    echo "FAIL: $label"
    echo "  unexpected match for pattern: $pattern"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

count_pattern() {
  local pattern="$1"
  local file="$2"
  local n
  n=$(grep -cE -- "$pattern" "$file" 2>/dev/null || true)
  n="${n//[[:space:]]/}"
  if [ -z "$n" ]; then
    n="0"
  fi
  printf '%s' "$n"
}

assert_count() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  local expected="$4"
  local actual
  actual=$(count_pattern "$pattern" "$file")
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label (count=$actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  pattern : $pattern"
    echo "  expected: $expected"
    echo "  actual  : $actual"
    echo "  --- contents ---"
    cat "$file"
    echo "  --- /contents ---"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ── stub state ──
GH_CALL_LOG=""
FR_WARN_TRACE=""
FR_LOG_TRACE=""
RS_TRACE=""
SN_NOTIFY_TRACE=""

# state directory（fr_save_state / fr_load_state は実体を扱う）
FAILED_RECOVERY_STATE_DIR=""

reset_stub_state() {
  GH_CALL_LOG="$(mktemp)"
  FR_WARN_TRACE="$(mktemp)"
  FR_LOG_TRACE="$(mktemp)"
  RS_TRACE="$(mktemp)"
  SN_NOTIFY_TRACE="$(mktemp)"
  FAILED_RECOVERY_STATE_DIR=$(mktemp -d)
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$FR_WARN_TRACE" "$FR_LOG_TRACE" "$RS_TRACE" "$SN_NOTIFY_TRACE" 2>/dev/null || true
  if [ -n "$FAILED_RECOVERY_STATE_DIR" ] && [ -d "$FAILED_RECOVERY_STATE_DIR" ]; then
    rm -rf "$FAILED_RECOVERY_STATE_DIR" 2>/dev/null || true
  fi
}

# fr_warn / fr_log stub
# shellcheck disable=SC2317
fr_warn() {
  echo "fr_warn: $*" >> "$FR_WARN_TRACE"
}
# shellcheck disable=SC2317
fr_log() {
  echo "[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery: $*" >> "$FR_LOG_TRACE"
}
# shellcheck disable=SC2317
rs_set_result() {
  echo "rs_set_result $*" >> "$RS_TRACE"
  return 0
}
# shellcheck disable=SC2317
sn_notify() {
  echo "sn_notify $*" >> "$SN_NOTIFY_TRACE"
  return 0
}
# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}
# shellcheck disable=SC2317
gh() {
  echo "gh $*" >> "$GH_CALL_LOG"
  return 0
}

# ============================================================
# Section 1: fr_is_terminated 純粋関数の振る舞い
# ============================================================
echo "--- Section 1: fr_is_terminated 純粋関数 ---"

# 1-A: 空 / 不在 → 未終端
set +e
reason=$(fr_is_terminated "")
rc=$?
set -e
assert_rc "fr_is_terminated 空文字 → rc=1（未終端 / fail-open）" "1" "$rc"
assert_eq "fr_is_terminated 空文字 → stdout 空" "" "$reason"

# 1-B: `{}` → 未終端
set +e
reason=$(fr_is_terminated "{}")
rc=$?
set -e
assert_rc "fr_is_terminated {} → rc=1（未終端）" "1" "$rc"

# 1-C: last_status="in-progress" → 未終端
set +e
reason=$(fr_is_terminated '{"last_status":"in-progress"}')
rc=$?
set -e
assert_rc "fr_is_terminated in-progress → rc=1（未終端）" "1" "$rc"

# 1-D: last_status="succeeded" → 未終端
set +e
reason=$(fr_is_terminated '{"last_status":"succeeded"}')
rc=$?
set -e
assert_rc "fr_is_terminated succeeded → rc=1（未終端）" "1" "$rc"

# 1-E: last_status="max-attempts" → 終端
set +e
reason=$(fr_is_terminated '{"last_status":"max-attempts"}')
rc=$?
set -e
assert_rc "fr_is_terminated max-attempts → rc=0（終端）" "0" "$rc"
assert_eq "fr_is_terminated max-attempts → stdout=\"max-attempts\"" "max-attempts" "$reason"

# 1-F: last_status="no-progress" → 終端
set +e
reason=$(fr_is_terminated '{"last_status":"no-progress"}')
rc=$?
set -e
assert_rc "fr_is_terminated no-progress → rc=0（終端）" "0" "$rc"
assert_eq "fr_is_terminated no-progress → stdout=\"no-progress\"" "no-progress" "$reason"

# 1-G: last_status="immediate-failure-streak" → 未終端（#411 の終端は本 #417 のスコープ外）
set +e
reason=$(fr_is_terminated '{"last_status":"immediate-failure-streak"}')
rc=$?
set -e
assert_rc "fr_is_terminated immediate-failure-streak → rc=1（本 Issue #417 のスコープ外）" "1" "$rc"

# 1-H: JSON parse 失敗（不正 JSON）→ 未終端（fail-open / Req 5.1）
set +e
reason=$(fr_is_terminated '{not json')
rc=$?
set -e
assert_rc "fr_is_terminated 不正 JSON → rc=1（fail-open / Req 5.1）" "1" "$rc"

# ============================================================
# Section 2: 初回 terminate（state 不在）→ コメント投稿 + state 永続化
# ============================================================
echo ""
echo "--- Section 2: 初回 terminate（state 不在 / Req 1.5 / 3.1〜3.3） ---"

reset_stub_state
trap 'cleanup_stub_state' EXIT

# state 不在の状態で fr_terminate_max_attempts を呼ぶ → 初回終端
set +e
fr_terminate_max_attempts "issue" "417" "4"
rc=$?
set -e

assert_rc "Req 4.6: 初回 max-attempts → rc=0" "0" "$rc"
assert_count "Req 1.3 (初回): gh issue comment が 1 件発火" "gh issue comment 417" "$GH_CALL_LOG" "1"
assert_count "Req 1.3 (初回): rs_set_result が 1 件発火" "^rs_set_result " "$RS_TRACE" "1"
assert_count "Req 2.4 (初回): sn_notify が 1 件発火" "^sn_notify " "$SN_NOTIFY_TRACE" "1"

# Req 1.5: state JSON に last_status="max-attempts" が永続化されている
state_file="$FAILED_RECOVERY_STATE_DIR/417.json"
if [ -f "$state_file" ]; then
  status=$(jq -r '.last_status // ""' "$state_file" 2>/dev/null || echo "<parse-err>")
  assert_eq "Req 1.5 / 3.1: state JSON の last_status=\"max-attempts\" が永続化" "max-attempts" "$status"
  total=$(jq -r '.total_attempts // ""' "$state_file" 2>/dev/null || echo "")
  assert_eq "Req 3.1: state JSON の total_attempts=4 が記録" "4" "$total"
else
  echo "FAIL: Req 1.5: state file が存在しない: $state_file"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

cleanup_stub_state

# ============================================================
# Section 3: 2 サイクル目（既終端 state あり）→ 完全に no-op
# ============================================================
echo ""
echo "--- Section 3: 2 サイクル目（既 max-attempts）→ Req 1.1 / 2.3 / 2.4 / 2.6 ---"

reset_stub_state

# 事前条件: state JSON に last_status="max-attempts" を既に永続化済み
fr_save_state "417" "4" "max-attempts" "abc" "" "0" >/dev/null

# 2 サイクル目で再度 fr_terminate_max_attempts を呼ぶ
set +e
fr_terminate_max_attempts "issue" "417" "4"
rc=$?
set -e

assert_rc "Req 1.1: 2 サイクル目 max-attempts → rc=0（no-op）" "0" "$rc"

# Req 1.1 / 2.3: コメントが再投稿されない
assert_count "Req 1.1 / 2.3: 2 サイクル目で gh comment が呼ばれない" "gh issue comment" "$GH_CALL_LOG" "0"
# Req 2.6: rs_set_result が再発火しない（NFR 4.2 多重発火なし）
assert_count "Req 2.6: 2 サイクル目で rs_set_result が呼ばれない" "^rs_set_result " "$RS_TRACE" "0"
# Req 2.4: sn_notify が再発火しない
assert_count "Req 2.4: 2 サイクル目で sn_notify が呼ばれない" "^sn_notify " "$SN_NOTIFY_TRACE" "0"
# Req 6.1 / NFR 2.1 / 2.2: 抑止ログが残る（運用者が grep で確認可能）
assert_grep "NFR 2.1: 抑止ログに 'failed-recovery:' prefix" "failed-recovery:" "$FR_LOG_TRACE"
assert_grep "NFR 2.2: 抑止ログに 'reason=max-attempts'" "reason=max-attempts" "$FR_LOG_TRACE"
assert_grep "NFR 2.2: 抑止ログに 'suppressed='" "suppressed=" "$FR_LOG_TRACE"
assert_grep "NFR 2.1: 抑止ログに 'issue=#417'" "issue=#417" "$FR_LOG_TRACE"

cleanup_stub_state

# ============================================================
# Section 4: fr_terminate_no_progress も同様の no-op（Req 1.2 / 2.3 / 2.4 / 2.6）
# ============================================================
echo ""
echo "--- Section 4: 2 サイクル目（既 no-progress）→ Req 1.2 / 2.3 / 2.4 / 2.6 ---"

reset_stub_state
fr_save_state "555" "3" "no-progress" "sig_aaa" "" "0" >/dev/null

set +e
fr_terminate_no_progress "pr" "555" "3" "sig_aaa"
rc=$?
set -e

assert_rc "Req 1.2: 2 サイクル目 no-progress → rc=0（no-op）" "0" "$rc"
assert_count "Req 1.2 / 2.3: 2 サイクル目で gh comment が呼ばれない" "gh pr comment" "$GH_CALL_LOG" "0"
assert_count "Req 2.6: 2 サイクル目で rs_set_result が呼ばれない" "^rs_set_result " "$RS_TRACE" "0"
assert_count "Req 2.4: 2 サイクル目で sn_notify が呼ばれない" "^sn_notify " "$SN_NOTIFY_TRACE" "0"
assert_grep "NFR 2.1: 抑止ログに 'failed-recovery:' prefix" "failed-recovery:" "$FR_LOG_TRACE"
assert_grep "NFR 2.2: 抑止ログに 'reason=no-progress'" "reason=no-progress" "$FR_LOG_TRACE"
assert_grep "NFR 2.1: 抑止ログに 'pr=#555'" "pr=#555" "$FR_LOG_TRACE"

cleanup_stub_state

# ============================================================
# Section 5: cross-status no-op
#   既に max-attempts で終端済みなら no_progress 関数も no-op
#   既に no-progress で終端済みなら max_attempts 関数も no-op
# ============================================================
echo ""
echo "--- Section 5: cross-status no-op (Req 1.3 / 1.4 生涯 1 件契約) ---"

# 5-A: max-attempts 永続化済 → no_progress も no-op
reset_stub_state
fr_save_state "700" "4" "max-attempts" "sig" "" "0" >/dev/null
set +e
fr_terminate_no_progress "issue" "700" "4" "sig"
set -e
assert_count "Req 1.3: cross-status max→no_progress でも comment 抑止" "gh issue comment" "$GH_CALL_LOG" "0"
assert_count "Req 1.3: cross-status max→no_progress でも rs_set_result 抑止" "^rs_set_result " "$RS_TRACE" "0"
cleanup_stub_state

# 5-B: no-progress 永続化済 → max_attempts も no-op
reset_stub_state
fr_save_state "701" "3" "no-progress" "sig" "" "0" >/dev/null
set +e
fr_terminate_max_attempts "issue" "701" "3"
set -e
assert_count "Req 1.4: cross-status no_progress→max でも comment 抑止" "gh issue comment" "$GH_CALL_LOG" "0"
assert_count "Req 1.4: cross-status no_progress→max でも rs_set_result 抑止" "^rs_set_result " "$RS_TRACE" "0"
cleanup_stub_state

# ============================================================
# Section 6: fail-open（Req 5.1〜5.3）
#   state ファイル破損時 / 欠落時に従来通り終端コメントが投稿される
# ============================================================
echo ""
echo "--- Section 6: state 破損 / 欠落で fail-open (Req 5.1〜5.3) ---"

# 6-A: state ファイル欠落（初回） → 従来通り投稿（Section 2 で検証済みなのでここでは subset）
reset_stub_state
set +e
fr_terminate_max_attempts "issue" "800" "4"
set -e
assert_count "Req 5.2: state 欠落 → 従来通り gh comment が 1 件発火" "gh issue comment 800" "$GH_CALL_LOG" "1"
assert_count "Req 5.2: state 欠落 → 従来通り rs_set_result が 1 件発火" "^rs_set_result " "$RS_TRACE" "1"
cleanup_stub_state

# 6-B: state ファイル破損（不正 JSON）→ fr_load_state が `{}` を返し fail-open
reset_stub_state
mkdir -p "$FAILED_RECOVERY_STATE_DIR"
printf 'NOT VALID JSON {{{' > "$FAILED_RECOVERY_STATE_DIR/801.json"
set +e
fr_terminate_max_attempts "issue" "801" "4"
set -e
assert_count "Req 5.1: state 破損 → 従来通り gh comment が 1 件発火（fail-open）" "gh issue comment 801" "$GH_CALL_LOG" "1"
assert_count "Req 5.1: state 破損 → 従来通り rs_set_result が 1 件発火（fail-open）" "^rs_set_result " "$RS_TRACE" "1"
cleanup_stub_state

# 6-C: 既存 schema（last_status field 不在 / 旧 schema）→ 未終端扱いで投稿
reset_stub_state
mkdir -p "$FAILED_RECOVERY_STATE_DIR"
printf '%s' '{"issue":802,"total_attempts":2}' > "$FAILED_RECOVERY_STATE_DIR/802.json"
set +e
fr_terminate_max_attempts "issue" "802" "4"
set -e
assert_count "NFR 1.1: last_status 不在の旧 schema → 未終端扱いで投稿" "gh issue comment 802" "$GH_CALL_LOG" "1"
cleanup_stub_state

# ============================================================
# Section 7: fr_filter_terminated_candidates 候補列挙除外
# ============================================================
echo ""
echo "--- Section 7: fr_filter_terminated_candidates (Req 2.1〜2.6 物理担保) ---"

# 7-A: 終端済みなし → 入力をそのまま返す
reset_stub_state
input='[{"number":900,"labels":[]},{"number":901,"labels":[]}]'
filtered=$(fr_filter_terminated_candidates "issue" "$input")
len=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo "0")
assert_eq "Req 2.6: 終端済みなし → 2 件残る" "2" "$len"
cleanup_stub_state

# 7-B: 1 件が終端済み → 除外されて 1 件残る + 抑止ログ
reset_stub_state
fr_save_state "910" "4" "max-attempts" "sig" "" "0" >/dev/null
input='[{"number":910,"labels":[]},{"number":911,"labels":[]}]'
filtered=$(fr_filter_terminated_candidates "issue" "$input")
len=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo "0")
assert_eq "Req 2.1〜2.6: 終端済み 1 件除外 → 1 件残る" "1" "$len"
remaining=$(printf '%s' "$filtered" | jq -r '.[0].number' 2>/dev/null || echo "")
assert_eq "Req 2.1〜2.6: 残ったのは未終端の 911" "911" "$remaining"
assert_grep "NFR 2.1: 列挙除外時の抑止ログ（issue=#910）" "issue=#910" "$FR_LOG_TRACE"
assert_grep "NFR 2.2: 抑止ログに reason=max-attempts + suppressed=enumeration" "suppressed=enumeration" "$FR_LOG_TRACE"
cleanup_stub_state

# 7-C: 全件終端済み → `[]` を返す
reset_stub_state
fr_save_state "920" "4" "max-attempts" "" "" "0" >/dev/null
fr_save_state "921" "3" "no-progress" "" "" "0" >/dev/null
input='[{"number":920,"labels":[]},{"number":921,"labels":[]}]'
filtered=$(fr_filter_terminated_candidates "issue" "$input")
len=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo "0")
assert_eq "Req 2.6: 全件終端済み → 0 件残る" "0" "$len"
cleanup_stub_state

# 7-D: 入力が空配列 / 空文字 / 非配列 → `[]` を返す
reset_stub_state
filtered=$(fr_filter_terminated_candidates "issue" "[]")
assert_eq "境界値: 空配列 → []" "[]" "$filtered"
filtered=$(fr_filter_terminated_candidates "issue" "")
assert_eq "境界値: 空文字 → []" "[]" "$filtered"
filtered=$(fr_filter_terminated_candidates "issue" "not json")
assert_eq "境界値: 非 JSON → []" "[]" "$filtered"
cleanup_stub_state

# 7-E: kind 不正値ガード
reset_stub_state
filtered=$(fr_filter_terminated_candidates "foo" '[{"number":930}]')
assert_eq "NFR 3.1: 不正 kind → []" "[]" "$filtered"
assert_grep "NFR 3.1: 不正 kind で fr_warn 1 件" "fr_warn:" "$FR_WARN_TRACE"
cleanup_stub_state

# 7-F: state 破損時 → fail-open（未終端扱いで残す / Req 5.1）
reset_stub_state
mkdir -p "$FAILED_RECOVERY_STATE_DIR"
printf 'NOT VALID' > "$FAILED_RECOVERY_STATE_DIR/940.json"
input='[{"number":940,"labels":[]}]'
filtered=$(fr_filter_terminated_candidates "issue" "$input")
len=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo "0")
assert_eq "Req 5.1: state 破損時 fail-open → 未終端扱いで残る" "1" "$len"
cleanup_stub_state

# 7-G: PR 経路でも同様に動く
reset_stub_state
fr_save_state "950" "4" "max-attempts" "" "" "0" >/dev/null
input='[{"number":950,"headRefName":"claude/issue-x"},{"number":951,"headRefName":"claude/issue-y"}]'
filtered=$(fr_filter_terminated_candidates "pr" "$input")
len=$(printf '%s' "$filtered" | jq -r 'length' 2>/dev/null || echo "0")
assert_eq "Req 2.1〜2.6: PR 経路でも除外が機能" "1" "$len"
assert_grep "NFR 2.1: PR 経路の抑止ログ（pr=#950）" "pr=#950" "$FR_LOG_TRACE"
cleanup_stub_state

# ============================================================
# Section 8: claude-failed ラベルを除去しない（Req 4.1〜4.3）
# ============================================================
echo ""
echo "--- Section 8: claude-failed ラベル据え置き（Req 4.1〜4.3） ---"

# 8-A: 初回 max-attempts → label 除去しない
reset_stub_state
set +e
fr_terminate_max_attempts "issue" "960" "4"
set -e
assert_not_grep "Req 4.1: 初回 max-attempts → --remove-label claude-failed が呼ばれない" "--remove-label claude-failed" "$GH_CALL_LOG"
cleanup_stub_state

# 8-B: 2 サイクル目 max-attempts → label 除去しない（no-op で何も呼ばれない）
reset_stub_state
fr_save_state "961" "4" "max-attempts" "" "" "0" >/dev/null
set +e
fr_terminate_max_attempts "issue" "961" "4"
set -e
assert_not_grep "Req 4.3: 2 サイクル目でも --remove-label claude-failed が呼ばれない" "--remove-label claude-failed" "$GH_CALL_LOG"
cleanup_stub_state

# ============================================================
# Section 9: 初回 no-progress の state 永続化（Req 1.6）
# ============================================================
echo ""
echo "--- Section 9: 初回 no-progress の state 永続化（Req 1.6 / 3.1〜3.3） ---"

reset_stub_state
set +e
fr_terminate_no_progress "issue" "970" "2" "deadbeef0000000000000000000000000000beef"
set -e

state_file="$FAILED_RECOVERY_STATE_DIR/970.json"
if [ -f "$state_file" ]; then
  status=$(jq -r '.last_status // ""' "$state_file" 2>/dev/null || echo "<parse-err>")
  assert_eq "Req 1.6 / 3.1: state JSON の last_status=\"no-progress\" が永続化" "no-progress" "$status"
  sig=$(jq -r '.last_failure_signature // ""' "$state_file" 2>/dev/null || echo "")
  assert_eq "NFR 1.1: signature が引数値で上書きされる" "deadbeef0000000000000000000000000000beef" "$sig"
else
  echo "FAIL: Req 1.6: state file が存在しない"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
cleanup_stub_state

# ============================================================
# Section 10: 既存 streak / immediate_failure_streak 継承（NFR 1.1）
# ============================================================
echo ""
echo "--- Section 10: terminate 前後で streak 等の既存フィールドが破壊されない（NFR 1.1） ---"

reset_stub_state
# 事前条件: in-progress + streak=2 の state
fr_save_state "980" "3" "in-progress" "old_sig" "abc123" "2" >/dev/null

set +e
fr_terminate_max_attempts "issue" "980" "4"
set -e

state_file="$FAILED_RECOVERY_STATE_DIR/980.json"
status=$(jq -r '.last_status // ""' "$state_file")
streak=$(jq -r '.immediate_failure_streak // ""' "$state_file")
sig=$(jq -r '.last_failure_signature // ""' "$state_file")
head_sha=$(jq -r '.last_head_sha // ""' "$state_file")
total=$(jq -r '.total_attempts // ""' "$state_file")

assert_eq "NFR 1.1: last_status が max-attempts に更新される" "max-attempts" "$status"
assert_eq "NFR 1.1: immediate_failure_streak が前回値 2 を保持" "2" "$streak"
assert_eq "NFR 1.1: last_failure_signature が前回値を保持" "old_sig" "$sig"
assert_eq "NFR 1.1: last_head_sha が前回値を保持" "abc123" "$head_sha"
assert_eq "NFR 1.1: total_attempts が引数値で記録される" "4" "$total"
cleanup_stub_state

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
