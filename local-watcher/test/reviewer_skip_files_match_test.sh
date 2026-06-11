#!/usr/bin/env bash
#
# 用途: local-watcher/bin/issue-watcher.sh の reviewer_skip_files_match（#333
#       REVIEWER_SKIP_PATTERN による Stage B 条件スキップの純粋判定関数）を
#       fixture で検証するスモークテスト。
#
#       判定契約: stdin の変更ファイル一覧が「1 件以上 かつ 全行が POSIX ERE に一致」の
#       ときのみ rc=0（スキップ適用可）。pattern 空 / リスト空 / 1 行でも不一致は rc=1。
#
# 配置先: local-watcher/test/reviewer_skip_files_match_test.sh
# 依存:   bash 4+, awk, grep
# 実行:   bash local-watcher/test/reviewer_skip_files_match_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
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

# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "reviewer_skip_files_match")"
if ! declare -F reviewer_skip_files_match >/dev/null; then
  echo "ERROR: reviewer_skip_files_match not loaded" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

assert_rc() {
  local label="$1"
  local expected_rc="$2"
  shift 2
  local actual_rc=0
  reviewer_skip_files_match "$@" || actual_rc=$?
  if [ "$expected_rc" -eq "$actual_rc" ]; then
    echo "PASS: $label (rc=$actual_rc)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc / actual rc: $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# 正常系: 全行一致 → 0
assert_rc "全ファイルが ^docs/ に一致なら 0" 0 '^docs/' <<'EOF'
docs/specs/1-foo/requirements.md
docs/README.md
EOF

# 異常系: 1 行でも不一致 → 1
assert_rc "1 ファイルでも不一致なら 1" 1 '^docs/' <<'EOF'
docs/specs/1-foo/requirements.md
local-watcher/bin/issue-watcher.sh
EOF

# 境界値: リスト空 → 1（fail-safe）
assert_rc "リスト空なら 1" 1 '^docs/' < /dev/null

# 境界値: 空行のみ → 1（実質空リスト）
assert_rc "空行のみなら 1" 1 '^docs/' <<'EOF'

EOF

# 異常系: pattern 空 → 1（無効）
assert_rc "pattern 空なら 1" 1 '' <<'EOF'
docs/a.md
EOF

# hardening: `-` 始まりの path / pattern でもフラグ注入されない（grep -- 区切り）
assert_rc "ハイフン始まり path + ハイフン始まり pattern でも判定可能" 0 '^-' <<'EOF'
-leading-dash.md
EOF

# 複合 ERE: 代替（|）パターン
assert_rc "代替 ERE（docs か *.md）全一致で 0" 0 '^docs/|\.md$' <<'EOF'
docs/a.txt
README.md
EOF

echo ""
echo "================================"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
