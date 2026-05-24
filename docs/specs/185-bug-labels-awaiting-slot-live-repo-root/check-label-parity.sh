#!/usr/bin/env bash
# 用途: root (.github/scripts/idd-claude-labels.sh) と template
#       (repo-template/.github/scripts/idd-claude-labels.sh) の name|color 集合 parity 検証
# 配置先: docs/specs/185-bug-labels-awaiting-slot-live-repo-root/check-label-parity.sh
# 依存: bash 4+, grep (POSIX ERE), sort, diff
# セットアップ参照先: docs/specs/185-bug-labels-awaiting-slot-live-repo-root/impl-notes.md
#
# 注意: このスクリプトは手動 / 将来の CI 化用の fixture であり、現時点では
#       どの自動導線（install.sh / watcher / GitHub Actions）からも自動実行されない。
#       parity の回帰を疑ったときに運用者が手動で実行する想定（NFR 2.1）。
#
# Usage:
#   bash docs/specs/185-bug-labels-awaiting-slot-live-repo-root/check-label-parity.sh
#
# Exit code:
#   0 = root と template の name|color 集合が完全一致（parity OK）
#   1 = name|color 集合に差分あり（standard error に diff を出力）
#   2 = 対象スクリプトが見つからない等の前提エラー

set -euo pipefail

# repo root を本スクリプトの位置（docs/specs/185-.../）から 3 階層上に解決する。
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

ROOT_LABELS="$REPO_ROOT/.github/scripts/idd-claude-labels.sh"
TEMPLATE_LABELS="$REPO_ROOT/repo-template/.github/scripts/idd-claude-labels.sh"

# name|color ペアを抽出する正規表現（requirements.md NFR 2.1 / Issue 本文の検証コマンドと同一）。
#   "<name>|<6 桁 hex color>|  形式の先頭部分のみを取り出し、description の差分は無視する。
readonly PAIR_REGEX='"[a-z-]+\|[0-9a-f]{6}\|'

for f in "$ROOT_LABELS" "$TEMPLATE_LABELS"; do
  if [ ! -f "$f" ]; then
    echo "Error: labels スクリプトが見つかりません: $f" >&2
    exit 2
  fi
done

# 差分を取得（一致すれば空文字列）。
diff_output=""
if ! diff_output=$(diff \
  <(grep -oE "$PAIR_REGEX" "$ROOT_LABELS" | sort) \
  <(grep -oE "$PAIR_REGEX" "$TEMPLATE_LABELS" | sort)); then
  echo "Error: root と template の name|color 集合に差分があります（parity NG）:" >&2
  printf '%s\n' "$diff_output" >&2
  echo "" >&2
  echo "  < root:     $ROOT_LABELS" >&2
  echo "  > template: $TEMPLATE_LABELS" >&2
  exit 1
fi

echo "OK: root と template の name|color 集合は完全一致しています（parity OK）"
