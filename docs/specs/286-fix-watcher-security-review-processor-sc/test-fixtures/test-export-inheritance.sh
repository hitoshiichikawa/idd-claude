#!/usr/bin/env bash
# 用途: spec #286 Req 1.1 / 1.2 の export 継承を検証する。
#       issue-watcher.sh の Config ブロックから
#       `export SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-...}"` 行を抽出して
#       eval し、`bash -c 'echo "$SECURITY_REVIEW_PROMPT"'` の子シェル出力が、
#       (a) 非空であること、(b) `Use the /security-review skill` で始まる
#       default 文字列であることを assert する。
# 配置先: docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-export-inheritance.sh
# 依存: bash 4+, grep。watcher main flow（lock 取得・cron ループ）を起動しないため、
#       Config ブロック該当行のみを sed/grep で抽出して eval する方式を採用する
#       （既存 #263 fixture の awk 関数抽出パターンと同方針）。
# セットアップ参照先: docs/specs/286-fix-watcher-security-review-processor-sc/impl-notes.md
#
# Usage:
#   bash docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-export-inheritance.sh
#
# Exit code:
#   0 = export 継承が成立（子シェルで非空 default 文字列を観測）
#   1 = 失敗（assert の詳細は stderr）

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
WATCHER="$REPO_ROOT/local-watcher/bin/issue-watcher.sh"

if [ ! -f "$WATCHER" ]; then
  echo "[FATAL] watcher script not found: $WATCHER" >&2
  exit 1
fi

# Config ブロックの該当 export 行のみを抽出する。
# 対象: `export SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-...}"`
#       既定値は 1 行に閉じている前提（現状の issue-watcher.sh の表記。改行を含む
#       場合は本 fixture は失敗 → 抽出方針を見直す）。
export_line=$(grep -E '^export SECURITY_REVIEW_PROMPT=' "$WATCHER" | head -n 1)

if [ -z "$export_line" ]; then
  echo "[FAIL] issue-watcher.sh に 'export SECURITY_REVIEW_PROMPT=' で始まる行が存在しません" >&2
  exit 1
fi

# 既定値内で `${BASE_BRANCH:-main}` を参照するため、念のため env を空にして eval する。
# parent shell の SECURITY_REVIEW_PROMPT は明示的に unset し、`${VAR:-default}` の default
# パスを通す。
unset SECURITY_REVIEW_PROMPT
unset BASE_BRANCH

# shellcheck disable=SC2294  # eval は Config 行の動的取り込みのため意図的に使用
eval "$export_line"

# parent shell で値が解決されているか
if [ -z "${SECURITY_REVIEW_PROMPT:-}" ]; then
  echo "[FAIL] eval 後の parent shell で SECURITY_REVIEW_PROMPT が空です" >&2
  exit 1
fi

# 子シェル（新規プロセス）で env が継承されるか
child_out=$(bash -c 'echo "$SECURITY_REVIEW_PROMPT"')

if [ -z "$child_out" ]; then
  echo "[FAIL] 子シェルで SECURITY_REVIEW_PROMPT が空文字列に解決されました（export 継承失敗）" >&2
  echo "        parent value: ${SECURITY_REVIEW_PROMPT:0:80}..." >&2
  exit 1
fi

# default 文字列の冒頭が想定通りであること（'Use the /security-review skill' で始まる）
case "$child_out" in
  "Use the /security-review skill"*)
    : # OK
    ;;
  *)
    echo "[FAIL] 子シェル出力が default prompt の prefix と一致しません" >&2
    echo "        expected prefix: 'Use the /security-review skill'" >&2
    echo "        actual prefix:   '${child_out:0:60}...'" >&2
    exit 1
    ;;
esac

# parent / child 同一性（Req 1.2）
if [ "$child_out" != "$SECURITY_REVIEW_PROMPT" ]; then
  echo "[FAIL] parent と child で SECURITY_REVIEW_PROMPT が一致しません（Req 1.2 違反）" >&2
  echo "        parent: ${SECURITY_REVIEW_PROMPT:0:60}..." >&2
  echo "        child:  ${child_out:0:60}..." >&2
  exit 1
fi

echo "OK: test-export-inheritance"
