#!/usr/bin/env bash
# =============================================================================
# watcher_config_unattended_timeouts_test.sh — 無人運用の停止防止 env の config 正規化
#   回帰テスト（無人運用改善提案 P0-2 / P0-3）
#
# 対象: local-watcher/bin/watcher-config.sh の
#   - WATCHER_GIT_TIMEOUT / WATCHER_GH_TIMEOUT / DISPATCHER_KILL_GRACE_SEC（P0-2 / P0-3）
#   - STAGE_WALL_TIMEOUT（P0-3）
#   の定義・正規化ブロック。watcher-config.sh はトップレベル副作用を持ち単体 source
#   できないため、awk で当該ブロックのみを抽出し、env を差し替えた bash -c 内で eval して
#   source 後の値を検証する（watcher_config_spec_html_test.sh と同じイディオム）。
#
# 検証内容:
#   - 未設定 → 既定（300 / 60 / 10 / 0）
#   - 非整数 / 空文字 / 負値 → 既定へ正規化（安全側）
#   - `0` / 正の整数 → そのまま（0 は「timeout なし」= 導入前と同一挙動）
#   - WATCHER_GH_TIMEOUT は MERGE_QUEUE_GIT_TIMEOUT を連鎖参照する
#
# 配置先: local-watcher/test/watcher_config_unattended_timeouts_test.sh
# 実行:   bash local-watcher/test/watcher_config_unattended_timeouts_test.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"

CONFIG="$SCRIPT_DIR/../bin/watcher-config.sh"

PASS_COUNT=0
FAIL_COUNT=0

if [ ! -f "$CONFIG" ]; then
  echo "FATAL: watcher-config.sh not found at $CONFIG" >&2
  exit 1
fi

# 2 ブロックを個別に抽出して連結する（コメント行は含めない / eval 対象は実コードのみ）:
#   (A) WATCHER_GIT_TIMEOUT の代入行から 3 つ目の `esac`（DISPATCHER_KILL_GRACE_SEC）まで
#   (B) STAGE_WALL_TIMEOUT の代入行から直後の `esac` まで
extract_block() {
  local start_re="$1" esac_count="$2"
  awk -v start="$start_re" -v want="$esac_count" '
    $0 ~ start { f = 1 }
    f { print }
    f && /^esac$/ { if (++n == want) exit }
  ' "$CONFIG"
}
TIMEOUT_BLOCK="$(extract_block '^WATCHER_GIT_TIMEOUT=' 3)
$(extract_block '^STAGE_WALL_TIMEOUT=' 1)"

if ! printf '%s' "$TIMEOUT_BLOCK" | grep -q '^STAGE_WALL_TIMEOUT=' \
   || ! printf '%s' "$TIMEOUT_BLOCK" | grep -q '^DISPATCHER_KILL_GRACE_SEC='; then
  echo "FATAL: timeout 正規化ブロックを watcher-config.sh から抽出できませんでした" >&2
  printf '%s\n' "$TIMEOUT_BLOCK" >&2
  exit 1
fi

# normalized <var> [ENV=VAL ...]
normalized() {
  local var="$1"
  shift
  env -i PATH="$PATH" "$@" bash -c "set -uo pipefail; $TIMEOUT_BLOCK
printf '%s' \"\${$var}\"" 2>/dev/null
}

echo "--- defaults (unset) ---"
assert_eq "WATCHER_GIT_TIMEOUT default 300" "300" "$(normalized WATCHER_GIT_TIMEOUT)"
assert_eq "WATCHER_GH_TIMEOUT default 60" "60" "$(normalized WATCHER_GH_TIMEOUT)"
assert_eq "DISPATCHER_KILL_GRACE_SEC default 10" "10" "$(normalized DISPATCHER_KILL_GRACE_SEC)"
assert_eq "STAGE_WALL_TIMEOUT default 0 (disabled)" "0" "$(normalized STAGE_WALL_TIMEOUT)"

echo "--- explicit values ---"
assert_eq "WATCHER_GIT_TIMEOUT=45" "45" "$(normalized WATCHER_GIT_TIMEOUT WATCHER_GIT_TIMEOUT=45)"
assert_eq "WATCHER_GIT_TIMEOUT=0 kept (no timeout)" "0" "$(normalized WATCHER_GIT_TIMEOUT WATCHER_GIT_TIMEOUT=0)"
assert_eq "WATCHER_GH_TIMEOUT=15" "15" "$(normalized WATCHER_GH_TIMEOUT WATCHER_GH_TIMEOUT=15)"
assert_eq "WATCHER_GH_TIMEOUT inherits MERGE_QUEUE_GIT_TIMEOUT=90" "90" "$(normalized WATCHER_GH_TIMEOUT MERGE_QUEUE_GIT_TIMEOUT=90)"
assert_eq "DISPATCHER_KILL_GRACE_SEC=0 kept (immediate KILL)" "0" "$(normalized DISPATCHER_KILL_GRACE_SEC DISPATCHER_KILL_GRACE_SEC=0)"
assert_eq "STAGE_WALL_TIMEOUT=3600" "3600" "$(normalized STAGE_WALL_TIMEOUT STAGE_WALL_TIMEOUT=3600)"

echo "--- invalid values normalize to defaults ---"
assert_eq "WATCHER_GIT_TIMEOUT=abc -> 300" "300" "$(normalized WATCHER_GIT_TIMEOUT WATCHER_GIT_TIMEOUT=abc)"
assert_eq "WATCHER_GIT_TIMEOUT='' -> 300" "300" "$(normalized WATCHER_GIT_TIMEOUT WATCHER_GIT_TIMEOUT=)"
assert_eq "WATCHER_GIT_TIMEOUT=-5 -> 300" "300" "$(normalized WATCHER_GIT_TIMEOUT WATCHER_GIT_TIMEOUT=-5)"
assert_eq "WATCHER_GH_TIMEOUT=1.5 -> 60" "60" "$(normalized WATCHER_GH_TIMEOUT WATCHER_GH_TIMEOUT=1.5)"
assert_eq "DISPATCHER_KILL_GRACE_SEC=x -> 10" "10" "$(normalized DISPATCHER_KILL_GRACE_SEC DISPATCHER_KILL_GRACE_SEC=x)"
assert_eq "STAGE_WALL_TIMEOUT=abc -> 0" "0" "$(normalized STAGE_WALL_TIMEOUT STAGE_WALL_TIMEOUT=abc)"
assert_eq "STAGE_WALL_TIMEOUT=-1 -> 0" "0" "$(normalized STAGE_WALL_TIMEOUT STAGE_WALL_TIMEOUT=-1)"
assert_eq "STAGE_WALL_TIMEOUT='' -> 0" "0" "$(normalized STAGE_WALL_TIMEOUT STAGE_WALL_TIMEOUT=)"

echo
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
