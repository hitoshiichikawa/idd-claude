#!/usr/bin/env bash
# test-detect.sh — Issue #259 claude_log_detect_529 のスモークテスト
#
# 用途:
#   core_utils.sh の claude_log_detect_529 関数を fixture ファイル群に対して
#   実行し、検知パターン群が期待通り発火・非発火することを確認する。
#
# 実行:
#   bash docs/specs/259-claude-api-529-issue-pr/test-fixtures/test-detect.sh
#
# 戻り値: 0 = 全 case PASS / 1 = いずれかの case FAIL
#
# 想定 case:
#   - log-529-api-error-status.log     : 検知 (rc=0)
#   - log-529-error-status.log         : 検知 (rc=0)
#   - log-529-status-numeric.log       : 検知 (rc=0)
#   - log-529-overloaded-error-type.log: 検知 (rc=0)
#   - log-529-overloaded-word.log      : 検知 (rc=0)
#   - log-normal-error.log             : 検知なし (rc=1)
#   - log-empty.log                    : 検知なし (rc=1)
#   - log-false-positive-529.log       : 検知なし (rc=1)
#   - <存在しないパス>                  : ログ不在 (rc=2)
#   - <空文字列>                        : ログ不在 (rc=2)

set -euo pipefail

# fixture dir / module path 解決
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." >/dev/null 2>&1 && pwd)"
MODULE_PATH="$REPO_ROOT/local-watcher/bin/modules/core_utils.sh"

if [ ! -f "$MODULE_PATH" ]; then
  echo "ERROR: core_utils.sh not found: $MODULE_PATH" >&2
  exit 1
fi

# core_utils.sh は本体側で定義される $REPO に依存するロガーを定義するが、
# claude_log_detect_529 は $REPO を参照しないため、source 時に副作用を起こさない。
# 念のため REPO を空文字で初期化しておく（ロガーの未使用関数定義は何もしない）。
REPO="${REPO:-test/repo}"
export REPO

# shellcheck source=/dev/null
. "$MODULE_PATH"

pass=0
fail=0
total=0

# assert_rc <expected_rc> <fixture_path> <label>
assert_rc() {
  local expected="$1"
  local path="$2"
  local label="$3"
  total=$((total + 1))
  local actual=0
  claude_log_detect_529 "$path" || actual=$?
  if [ "$actual" = "$expected" ]; then
    echo "PASS: ${label} (expected rc=${expected}, got rc=${actual})"
    pass=$((pass + 1))
  else
    echo "FAIL: ${label} (expected rc=${expected}, got rc=${actual}, path=${path})" >&2
    fail=$((fail + 1))
  fi
}

# 検知ケース (rc=0)
assert_rc 0 "$HERE/log-529-api-error-status.log"      "log-529-api-error-status: api_error_status:529"
assert_rc 0 "$HERE/log-529-error-status.log"          "log-529-error-status: error_status:529"
assert_rc 0 "$HERE/log-529-status-numeric.log"        "log-529-status-numeric: 'status: 529' plain text"
assert_rc 0 "$HERE/log-529-overloaded-error-type.log" "log-529-overloaded-error-type: type:overloaded_error"
assert_rc 0 "$HERE/log-529-overloaded-word.log"       "log-529-overloaded-word: Overloaded word boundary"

# 非検知ケース (rc=1)
assert_rc 1 "$HERE/log-normal-error.log"              "log-normal-error: 通常の TypeError 等は誤検知しない"
assert_rc 1 "$HERE/log-empty.log"                     "log-empty: 空ファイルは検知なし"
assert_rc 1 "$HERE/log-false-positive-529.log"        "log-false-positive-529: 単独 529 数値は誤検知しない"

# ログ不在ケース (rc=2)
assert_rc 2 "$HERE/nonexistent-file.log"              "存在しないパスは rc=2"
assert_rc 2 ""                                        "空文字列パスは rc=2"

echo ""
echo "--- Summary ---"
echo "total=${total} pass=${pass} fail=${fail}"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
