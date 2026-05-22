#!/usr/bin/env bash
# =============================================================================
# Smoke test for detect_partial_status() helper
#
# 用途:
#   docs/specs/148-feat-harness-developer-partial-blocked-p/ 配下の 8 種類 fixture を
#   `detect_partial_status` の grep 規約と同形式で検証する。
#
# 検証ケース:
#   1) status-complete.md         → return 0 / stdout=complete
#   2) status-partial-blocked.md  → return 0 / stdout=partial_blocked
#   3) status-partial-overrun.md  → return 0 / stdout=partial_overrun
#   4) status-absent.md           → return 1 / stdout=""
#   5) (ファイル不在)             → return 2 / stdout=""
#   6) status-invalid.md          → return 0 / stdout=foo
#   7) status-multiple.md         → return 0 / stdout=complete（最終行採用）
#   8) status-list-marker.md      → return 1 / stdout=""（list/blockquote/インデント除外）
#
# 実行: bash docs/specs/148-feat-harness-developer-partial-blocked-p/test-detect.sh
# =============================================================================
set -uo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$THIS_DIR/test-fixtures"

# detect_partial_status の参照実装（issue-watcher.sh と同一ロジック）
detect_partial_status() {
  local impl_notes="$1"
  if [ ! -f "$impl_notes" ]; then
    return 2
  fi
  local line
  line=$(grep -E '^STATUS: .+$' "$impl_notes" 2>/dev/null | tail -n 1 || true)
  if [ -z "$line" ]; then
    return 1
  fi
  local value="${line#STATUS: }"
  # trim leading/trailing whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
  return 0
}

PASS=0
FAIL=0
run_case() {
  local name="$1" path="$2" expect_rc="$3" expect_stdout="$4"
  local got_stdout got_rc
  got_stdout=$(detect_partial_status "$path") && got_rc=0 || got_rc=$?
  if [ "$got_rc" = "$expect_rc" ] && [ "$got_stdout" = "$expect_stdout" ]; then
    printf '  PASS: %s (rc=%s stdout="%s")\n' "$name" "$got_rc" "$got_stdout"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected rc=%s stdout="%s"\n    got      rc=%s stdout="%s"\n' \
      "$name" "$expect_rc" "$expect_stdout" "$got_rc" "$got_stdout"
    FAIL=$((FAIL + 1))
  fi
}

echo "==> detect_partial_status fixture tests"
run_case "1) complete"        "$FIXTURES_DIR/status-complete.md"        0 "complete"
run_case "2) partial_blocked" "$FIXTURES_DIR/status-partial-blocked.md" 0 "partial_blocked"
run_case "3) partial_overrun" "$FIXTURES_DIR/status-partial-overrun.md" 0 "partial_overrun"
run_case "4) status 行不在"   "$FIXTURES_DIR/status-absent.md"          1 ""
run_case "5) ファイル不在"    "$FIXTURES_DIR/nonexistent.md"            2 ""
run_case "6) 不正値 foo"      "$FIXTURES_DIR/status-invalid.md"         0 "foo"
run_case "7) 複数行 → 最終行" "$FIXTURES_DIR/status-multiple.md"        0 "complete"
run_case "8) list marker 装飾は対象外" "$FIXTURES_DIR/status-list-marker.md" 1 ""

echo ""
echo "==> 結果: $PASS pass / $FAIL fail"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
