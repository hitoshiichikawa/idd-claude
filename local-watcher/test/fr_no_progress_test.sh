#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/failed-recovery.sh の Issue #359（Failed Recovery
#       Processor）で追加した Recovery Decision Layer（fr_compute_failure_signature /
#       fr_detect_no_progress）を fixture で検証するスモークテスト。
#
#       対象関数:
#         - fr_compute_failure_signature (Issue #359 Req 5.1 / 5.2 / 5.5)
#         - fr_detect_no_progress        (Issue #359 Req 5.1 / 5.2 / NFR 5.2)
#
#       検証する AC（docs/specs/359-feat-watcher-failed-recovery-sh-claude-f/requirements.md）:
#         - Req 5.1: 直前試行情報と現在情報を比較する判定基盤
#         - Req 5.2: signature 一致 + 無進捗で no-progress 判定
#         - Req 5.5: 直前試行情報（signature / head_sha）の state JSON 形状契約
#         - NFR 5.2: 破損 / 空 state でも安全側に倒し caller を落とさない
#
# 配置先: local-watcher/test/fr_no_progress_test.sh
# 依存:   bash 4+, awk, jq, sha1sum, sed
# 実行:   bash local-watcher/test/fr_no_progress_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/failed-recovery.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find failed-recovery.sh at $MODULE_SH" >&2
  exit 2
fi

# 既存テスト（fr_state_test.sh / fr_fetch_test.sh）と同じイディオム:
# 対象スクリプトから 1 関数だけを awk で切り出して eval で読み込む。
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
eval "$(extract_function "$MODULE_SH" "fr_compute_failure_signature")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$MODULE_SH" "fr_detect_no_progress")"

for fn in fr_compute_failure_signature fr_detect_no_progress; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
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

assert_ne() {
  local label="$1"
  local a="$2"
  local b="$3"
  if [ "$a" != "$b" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: a != b"
    echo "  a: $a"
    echo "  b: $b"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ============================================================
# Section 1: fr_compute_failure_signature — sed 正規化が揮発要素を除去（Req 5.2 / 5.5）
# ============================================================
echo "--- Section 1: fr_compute_failure_signature 正規化 ---"

# 入力 A と B は揮発要素（timestamp / SHA / URL / 行番号 / Run #）だけが異なる。
# 正規化後の hash が同一であれば「同原因」として認識される（Req 5.2）。
INPUT_A=$(cat <<'EOS'
2026-06-22T10:34:56Z ERROR: build failed
  at /home/runner/work/repo/src/foo.sh:123 (commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
  see https://github.com/owner/repo/actions/runs/9999 for details
  GitHub Actions Run #42 failed
EOS
)
INPUT_B=$(cat <<'EOS'
2026-07-01T22:00:00Z ERROR: build failed
  at /tmp/other-runner/src/foo.sh:456 (commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
  see https://example.com/different/path for details
  GitHub Actions Run #123 failed
EOS
)

sig_a=$(printf '%s\n' "$INPUT_A" | fr_compute_failure_signature)
sig_b=$(printf '%s\n' "$INPUT_B" | fr_compute_failure_signature)

# SHA-1 hex は 40 桁固定（基本契約）
sig_a_len=${#sig_a}
assert_eq "Req 5.2: signature は SHA-1 hex 40 桁" "40" "$sig_a_len"

# 揮発要素のみの差は signature を変えない
assert_eq "Req 5.2: timestamp / SHA / 行番号 / URL / Run # 差は signature を変えない" "$sig_a" "$sig_b"

# 一方、本質的な失敗理由文の差は signature を変える
INPUT_C=$(cat <<'EOS'
2026-06-22T10:34:56Z ERROR: lint failed
  at /home/runner/work/repo/src/foo.sh:123
EOS
)
sig_c=$(printf '%s\n' "$INPUT_C" | fr_compute_failure_signature)
assert_ne "Req 5.2: 本質的なエラー文の差は signature を変える（build vs lint）" "$sig_a" "$sig_c"

# ============================================================
# Section 2: fr_detect_no_progress — (a) signature 一致 + head 同一 → no-progress
# ============================================================
echo ""
echo "--- Section 2: signature 一致 + head 同一 → no-progress ---"

sig="abc123def456"
head_sha="1111111111111111111111111111111111111111"
prev_state=$(jq -n --arg sig "$sig" --arg head "$head_sha" '{
  issue: 42,
  total_attempts: 2,
  last_status: "in-progress",
  last_failure_signature: $sig,
  last_head_sha: $head,
  last_attempt_at: "2026-06-22T00:00:00Z",
  history: []
}')

set +e
fr_detect_no_progress "$sig" "$head_sha" "$prev_state"
rc=$?
set -e
assert_rc "Req 5.2 (a): signature 一致 + head 同一 → no-progress (rc=0)" "0" "$rc"

# ============================================================
# Section 3: fr_detect_no_progress — (b) signature 異 → progress
# ============================================================
echo ""
echo "--- Section 3: signature 異 → progress ---"

set +e
fr_detect_no_progress "different_signature" "$head_sha" "$prev_state"
rc=$?
set -e
assert_rc "Req 5.2 (b): signature 異 → progress (rc=1)" "1" "$rc"

# ============================================================
# Section 4: fr_detect_no_progress — (c) Issue 経路（head_sha 空 / 現在も空）の挙動
# ============================================================
echo ""
echo "--- Section 4: Issue 経路（head_sha なし）の挙動 ---"

issue_prev_state=$(jq -n --arg sig "$sig" '{
  issue: 100,
  total_attempts: 1,
  last_status: "in-progress",
  last_failure_signature: $sig,
  last_head_sha: "",
  last_attempt_at: "2026-06-22T00:00:00Z",
  history: []
}')

# Issue 経路: 現在 head_sha 空 + 直前 head_sha 空 + signature 一致 → no-progress
set +e
fr_detect_no_progress "$sig" "" "$issue_prev_state"
rc=$?
set -e
assert_rc "Req 5.2 (c): Issue 経路で signature 一致のみで no-progress (rc=0)" "0" "$rc"

# Issue 経路 + signature 異 → progress
set +e
fr_detect_no_progress "other_signature" "" "$issue_prev_state"
rc=$?
set -e
assert_rc "Req 5.2 (c): Issue 経路で signature 異 → progress (rc=1)" "1" "$rc"

# ============================================================
# Section 5: fr_detect_no_progress — (d) prev state なし → progress
# ============================================================
echo ""
echo "--- Section 5: prev state なし → progress ---"

# 空 state（fr_load_state が `{}` を返した場合の fail-open path）
set +e
fr_detect_no_progress "$sig" "$head_sha" "{}"
rc=$?
set -e
assert_rc "Req 5.2 (d): 空 state ({}) → progress (rc=1)" "1" "$rc"

# 引数省略時も {} 既定で progress
set +e
fr_detect_no_progress "$sig" "$head_sha"
rc=$?
set -e
assert_rc "Req 5.2 (d): prev_state 引数省略時 → progress (rc=1)" "1" "$rc"

# last_failure_signature が null/欠落 → progress
prev_no_sig='{"issue":1,"total_attempts":0,"last_status":"in-progress","last_failure_signature":"","last_head_sha":"","last_attempt_at":"2026-06-22T00:00:00Z","history":[]}'
set +e
fr_detect_no_progress "$sig" "$head_sha" "$prev_no_sig"
rc=$?
set -e
assert_rc "Req 5.2 (d): last_failure_signature 空 → progress (rc=1)" "1" "$rc"

# 破損 JSON (jq parse 失敗) → 安全側 fallback で progress
set +e
fr_detect_no_progress "$sig" "$head_sha" "not a json"
rc=$?
set -e
assert_rc "NFR 5.2: 破損 prev_state JSON → 安全側 fallback で progress (rc=1)" "1" "$rc"

# ============================================================
# Section 6: fr_detect_no_progress — (e) signature 一致 + head 進捗あり → progress
# ============================================================
echo ""
echo "--- Section 6: signature 一致 + head 進捗 → progress ---"

new_head_sha="2222222222222222222222222222222222222222"
set +e
fr_detect_no_progress "$sig" "$new_head_sha" "$prev_state"
rc=$?
set -e
assert_rc "Req 5.2 (e): PR 経路で signature 一致 + head 進捗あり → progress (rc=1)" "1" "$rc"

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
