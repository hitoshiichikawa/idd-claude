#!/usr/bin/env bash
# run-tests.sh
#
# 用途: docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/cases/*.json
#       を順次 stdin に流して `local-watcher/hooks/idd-guard.sh` を起動し、stdout の
#       decision JSON と expected.tsv の期待値（verdict + reason 部分文字列）を突合する
#       29 件マトリクスのドライバ。
#
# 配置先: docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh
#
# 依存: bash 4+, jq
#
# 環境変数:
#   IDD_HOOK_BASE_BRANCH    base ブランチ名（既定 main を export）
#   IDD_CLAUDE_HOOKS_DIR    G0 で保護する install dir（既定 $HOME/.idd-claude/hooks を export）
#
# 終了コード:
#   0 = 全 case green (29/29)
#   1 = 1 件以上 mismatch
#   2 = fixture / driver の前提不一致（expected.tsv 不在、hook 不在、jq 不在 等）
#
# セットアップ参照先: ../impl-notes.md

set -euo pipefail

# 1) このスクリプトの絶対ディレクトリを解決
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES_DIR="$SCRIPT_DIR/cases"
EXPECTED_TSV="$SCRIPT_DIR/expected.tsv"

# 2) hook の絶対パスを解決（このスクリプトから ../../../../local-watcher/hooks/idd-guard.sh）
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HOOK_PATH="$REPO_ROOT/local-watcher/hooks/idd-guard.sh"

# 3) 前提チェック
if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq not found in PATH\n' >&2
  exit 2
fi

if [ ! -f "$HOOK_PATH" ]; then
  printf 'ERROR: hook not found at %s\n' "$HOOK_PATH" >&2
  exit 2
fi

if [ ! -f "$EXPECTED_TSV" ]; then
  printf 'ERROR: expected.tsv not found at %s\n' "$EXPECTED_TSV" >&2
  exit 2
fi

if [ ! -d "$CASES_DIR" ]; then
  printf 'ERROR: cases dir not found at %s\n' "$CASES_DIR" >&2
  exit 2
fi

# 4) hook が参照する env を export
export IDD_HOOK_BASE_BRANCH="${IDD_HOOK_BASE_BRANCH:-main}"
export IDD_CLAUDE_HOOKS_DIR="${IDD_CLAUDE_HOOKS_DIR:-$HOME/.idd-claude/hooks}"

# 5) expected.tsv を走査
pass=0
fail=0
total=0

# ヘッダ行を skip して読む
# 形式: case_file \t verdict \t reason_substring(optional)
while IFS=$'\t' read -r case_file expected_verdict expected_reason || [ -n "${case_file:-}" ]; do
  # ヘッダ・空行を skip
  [ -z "${case_file:-}" ] && continue
  [ "$case_file" = "case_file" ] && continue

  total=$((total + 1))
  case_path="$CASES_DIR/$case_file"

  if [ ! -f "$case_path" ]; then
    printf 'FAIL\t%s\t(case file missing)\n' "$case_file"
    fail=$((fail + 1))
    continue
  fi

  # hook を起動。stdin に case JSON を渡す。hook は常に exit 0
  hook_stdout="$(bash "$HOOK_PATH" <"$case_path" 2>/dev/null || true)"

  # decision JSON を parse。
  # - 空 stdout (allow) は jq に渡すと parse 失敗するため空文字をデフォルトで扱う
  # - decision フィールドの値を抽出（無ければ空文字 = allow）
  if [ -z "$hook_stdout" ]; then
    actual_decision=""
  else
    actual_decision="$(printf '%s' "$hook_stdout" | jq -r '.decision // empty' 2>/dev/null || true)"
  fi

  if [ "$actual_decision" = "block" ]; then
    actual_verdict="deny"
    actual_reason="$(printf '%s' "$hook_stdout" | jq -r '.reason // empty' 2>/dev/null || true)"
  else
    actual_verdict="allow"
    actual_reason=""
  fi

  # verdict 突合
  if [ "$actual_verdict" != "$expected_verdict" ]; then
    printf 'FAIL\t%s\texpected=%s actual=%s reason=%s\n' \
      "$case_file" "$expected_verdict" "$actual_verdict" "$actual_reason"
    fail=$((fail + 1))
    continue
  fi

  # deny ケースは reason substring を確認
  if [ "$expected_verdict" = "deny" ]; then
    expected_reason="${expected_reason:-}"
    if [ -z "$expected_reason" ]; then
      printf 'FAIL\t%s\tdeny expected but reason_substring is empty in expected.tsv\n' "$case_file"
      fail=$((fail + 1))
      continue
    fi
    case "$actual_reason" in
      *"$expected_reason"*)
        : # ok
        ;;
      *)
        printf 'FAIL\t%s\treason mismatch: expected_substring=%q actual=%q\n' \
          "$case_file" "$expected_reason" "$actual_reason"
        fail=$((fail + 1))
        continue
        ;;
    esac
  fi

  printf 'PASS\t%s\t%s\n' "$case_file" "$actual_verdict"
  pass=$((pass + 1))

done <"$EXPECTED_TSV"

# 6) サマリ
printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '%d/%d green\n' "$pass" "$total"
  exit 0
else
  printf '%d/%d green, %d mismatch\n' "$pass" "$total" "$fail"
  exit 1
fi
