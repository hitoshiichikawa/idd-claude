#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の Issue #442（Reviewer turn 切れ拡張リトライ）
#       で追加した 2 つの純粋ヘルパーを fixture で検証するスモークテスト。
#         - reviewer_normalize_extended_max_turns: 拡張 turn 予算の決定的正規化
#           （未設定→2×base / 不正値→2×base / base 未満→base に丸め / 正常値はそのまま）
#         - reviewer_is_error_max_turns: claude stream-json 出力の最後の result イベントが
#           error_max_turns か判定（turn 切れ起因の非ゼロ exit のみ拡張リトライ対象にするため）
#
# 配置先: local-watcher/test/reviewer_max_turns_retry_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/reviewer_max_turns_retry_test.sh
#
# 検証対象 AC: Req 2.4 / Req 4.1〜4.4 / NFR 4.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
TU_SH="$SCRIPT_DIR/../bin/modules/token-usage.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi
if [ ! -f "$TU_SH" ]; then
  echo "ERROR: cannot find token-usage.sh at $TU_SH" >&2
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

# reviewer_normalize_extended_max_turns / reviewer_is_error_max_turns を隔離抽出。
# reviewer_is_error_max_turns は tu_extract_last_result_json に依存するため、その依存関数も
# token-usage.sh から抽出して同一プロセスに source する（隔離抽出の依存追随規約）。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "reviewer_normalize_extended_max_turns")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "reviewer_is_error_max_turns")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$TU_SH" "tu_extract_last_result_json")"

for _fn in reviewer_normalize_extended_max_turns reviewer_is_error_max_turns tu_extract_last_result_json; do
  if ! declare -F "$_fn" >/dev/null; then
    echo "ERROR: $_fn not loaded" >&2
    exit 2
  fi
done

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label (=$actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: '$expected' / actual: '$actual'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  shift 2
  local actual_rc=0
  "$@" || actual_rc=$?
  if [ "$expected_rc" -eq "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc / actual rc: $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo "=== reviewer_normalize_extended_max_turns ==="

# Req 4.2: 未設定（空）→ base の 2 倍
assert_eq "未設定なら base×2" "100" "$(reviewer_normalize_extended_max_turns 50 '')"
# Req 4.3: 数値非解釈の不正値 → base の 2 倍にフォールバック
assert_eq "不正値(abc)なら base×2" "100" "$(reviewer_normalize_extended_max_turns 50 'abc')"
assert_eq "不正値(12x)なら base×2" "60" "$(reviewer_normalize_extended_max_turns 30 '12x')"
assert_eq "不正値(負号)なら base×2" "100" "$(reviewer_normalize_extended_max_turns 50 '-5')"
# Req 4.4: 明示値が base 未満 → base に引き上げ
assert_eq "base 未満なら base に丸め" "50" "$(reviewer_normalize_extended_max_turns 50 '40')"
assert_eq "base 未満(0)なら base に丸め" "30" "$(reviewer_normalize_extended_max_turns 30 '0')"
# Req 4.1: 正常値（base 以上）はそのまま採用
assert_eq "正常値(base 以上)はそのまま" "120" "$(reviewer_normalize_extended_max_turns 50 '120')"
assert_eq "正常値(base と同値)はそのまま" "50" "$(reviewer_normalize_extended_max_turns 50 '50')"
# 防御: base 自体が不正なら 50 に丸めてから判定
assert_eq "base 不正かつ raw 未設定なら 50×2=100" "100" "$(reviewer_normalize_extended_max_turns 'xx' '')"
assert_eq "base 不正かつ raw 正常(80)はそのまま" "80" "$(reviewer_normalize_extended_max_turns 'xx' '80')"
assert_eq "base=0 は安全側 50 に丸め→100" "100" "$(reviewer_normalize_extended_max_turns 0 '')"

echo ""
echo "=== reviewer_is_error_max_turns ==="

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# error_max_turns の result 行が最後 → 検出 0
LOG_MT="$TMPDIR_T/log_max_turns.txt"
cat > "$LOG_MT" <<'EOF'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{}}
{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":31}
EOF
assert_rc "最後の result が error_max_turns なら検出(rc=0)" 0 reviewer_is_error_max_turns "$LOG_MT" 0

# success の result 行が最後 → 非検出 1
LOG_OK="$TMPDIR_T/log_success.txt"
cat > "$LOG_OK" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":12}
EOF
assert_rc "result が success なら非検出(rc=1)" 1 reviewer_is_error_max_turns "$LOG_OK" 0

# 別 subtype（error_during_execution）→ 非検出 1
LOG_OTHER="$TMPDIR_T/log_other.txt"
cat > "$LOG_OTHER" <<'EOF'
{"type":"result","subtype":"error_during_execution","is_error":true}
EOF
assert_rc "別 subtype なら非検出(rc=1)" 1 reviewer_is_error_max_turns "$LOG_OTHER" 0

# result 行なし → 非検出 1
LOG_NORES="$TMPDIR_T/log_nores.txt"
cat > "$LOG_NORES" <<'EOF'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{}}
EOF
assert_rc "result 行なしなら非検出(rc=1)" 1 reviewer_is_error_max_turns "$LOG_NORES" 0

# offset により直前 stage の error_max_turns を無視（offset 以降に success のみ）→ 非検出 1
LOG_OFFSET="$TMPDIR_T/log_offset.txt"
cat > "$LOG_OFFSET" <<'EOF'
{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":31}
{"type":"result","subtype":"success","is_error":false,"num_turns":8}
EOF
# offset=1 → 1 行目（直前 stage の error_max_turns）を除外し、success のみを見る
assert_rc "offset で直前 stage の error_max_turns を無視(rc=1)" 1 reviewer_is_error_max_turns "$LOG_OFFSET" 1

# 複数 result 混在で最後が error_max_turns → 検出 0
LOG_MIX="$TMPDIR_T/log_mix.txt"
cat > "$LOG_MIX" <<'EOF'
{"type":"result","subtype":"success","is_error":false}
{"type":"assistant","message":{}}
{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":50}
EOF
assert_rc "混在で最後が error_max_turns なら検出(rc=0)" 0 reviewer_is_error_max_turns "$LOG_MIX" 0

# logfile 不在 → 非検出 1（安全側）
assert_rc "logfile 不在なら非検出(rc=1)" 1 reviewer_is_error_max_turns "$TMPDIR_T/nonexistent.txt" 0

# 空 logfile → 非検出 1
LOG_EMPTY="$TMPDIR_T/log_empty.txt"
: > "$LOG_EMPTY"
assert_rc "空 logfile なら非検出(rc=1)" 1 reviewer_is_error_max_turns "$LOG_EMPTY" 0

# tu_extract_last_result_json 未ロード時は安全側で非検出 → 別プロセスで検証
ISOLATED_RC=0
bash -c '
  set -euo pipefail
  SCRIPT_DIR="'"$SCRIPT_DIR"'"
  WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
  extract_function() {
    awk -v fn="$2() {" '\''
      $0 == fn { in_fn = 1 }
      in_fn { print }
      in_fn && $0 == "}" { in_fn = 0 }
    '\'' "$1"
  }
  eval "$(extract_function "$WATCHER_SH" "reviewer_is_error_max_turns")"
  LOG="$(mktemp)"
  printf "%s\n" "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true}" > "$LOG"
  # tu_extract_last_result_json は未 source。declare -F ガードで非検出(rc=1)に倒れるはず
  if reviewer_is_error_max_turns "$LOG" 0; then
    rm -f "$LOG"
    exit 0  # 検出されてしまった = NG
  fi
  rm -f "$LOG"
  exit 1  # 非検出 = OK
' || ISOLATED_RC=$?
assert_eq "tu_* 未ロード時は安全側で非検出(rc=1)" "1" "$ISOLATED_RC"

echo ""
echo "================================"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
