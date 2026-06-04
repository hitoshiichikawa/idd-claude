#!/usr/bin/env bash
# 用途: spec #286 NFR 1.3 の minimal env（`env -i HOME=$HOME PATH=/usr/bin:/bin`）
#       環境下で、`SECURITY_REVIEW_PROMPT=test-prompt` を明示設定した watcher
#       起動 env が Config ブロック解決（`${VAR:-default}` の override 経路）と
#       export 化を経て、子シェルで `test-prompt` として観測されることを assert する。
# 配置先: docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-env-i-minimal.sh
# 依存: bash 4+, env, grep。watcher main flow を起動しないため、Config 行抽出 + eval
#       の方式を採用する（既存 test-export-inheritance.sh と同方針）。
# セットアップ参照先: docs/specs/286-fix-watcher-security-review-processor-sc/impl-notes.md
#
# Usage:
#   bash docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-env-i-minimal.sh
#
# Exit code:
#   0 = minimal env 下で override 値が子シェルに継承される
#   1 = 失敗（assert の詳細は stderr）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
WATCHER="$REPO_ROOT/local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER" ]; then
  echo "[FATAL] watcher script not found: $WATCHER" >&2
  exit 1
fi

# minimal env 配下で実行する内部スクリプトを一時ファイルに書き出す。
# 内容: Config ブロックの `export SECURITY_REVIEW_PROMPT=...` 行を抽出 + eval し、
# 子シェル経由で `$SECURITY_REVIEW_PROMPT` が `test-prompt` 値を観測することを assert。
INNER=$(mktemp -t idd-claude-sec286-env-i.XXXXXX.sh)
cleanup() {
  rm -f "$INNER"
}
trap cleanup EXIT

cat > "$INNER" <<'INNER_EOF'
set -euo pipefail
WATCHER="$1"

export_line=$(grep -E '^export SECURITY_REVIEW_PROMPT=' "$WATCHER" | head -n 1)
if [ -z "$export_line" ]; then
  echo "[FAIL] watcher Config に 'export SECURITY_REVIEW_PROMPT=' 行が見つかりません" >&2
  exit 1
fi

# shellcheck disable=SC2294
eval "$export_line"

# 子シェルへ env 継承されているか
child_out=$(bash -c 'echo "$SECURITY_REVIEW_PROMPT"')

if [ "$child_out" != "test-prompt" ]; then
  echo "[FAIL] minimal env 下で override 値が子シェルに継承されていません" >&2
  echo "        expected: 'test-prompt'" >&2
  echo "        actual:   '${child_out}'" >&2
  exit 1
fi

# SECURITY_REVIEW_ENABLED も明示設定値を保持していること（subprocess 経由ではなく
# inner script 自身の env として）
if [ "${SECURITY_REVIEW_ENABLED:-}" != "true" ]; then
  echo "[FAIL] SECURITY_REVIEW_ENABLED が 'true' に解決されていません: '${SECURITY_REVIEW_ENABLED:-}'" >&2
  exit 1
fi

exit 0
INNER_EOF

# minimal env で起動。SECURITY_REVIEW_ENABLED / SECURITY_REVIEW_PROMPT を明示注入し、
# `${VAR:-default}` の override 経路で test-prompt が採用されることを確認する。
if ! env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    SECURITY_REVIEW_ENABLED=true \
    SECURITY_REVIEW_PROMPT=test-prompt \
    bash "$INNER" "$WATCHER"; then
  echo "[FAIL] minimal env 下の inner script が失敗しました" >&2
  exit 1
fi

echo "OK: test-env-i-minimal"
