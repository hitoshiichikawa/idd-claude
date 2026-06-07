# Implementation Notes — #294 PreToolUse Guard Hook (base 初版)

## Implementation Notes

### Task 1

- **採用方針**: design.md の指示通り、`idd-guard.sh` は jq で stdin JSON を読み `tool_name`
  で分岐し、Bash の token 分割（top-level のみ）→ git global option skip → push 引数解析の
  順で G1/G2 を判定する純 bash 実装。G0 は Edit/Write/NotebookEdit を path prefix 一致で
  robust に、Bash を mutation keyword + install dir literal の両方一致で best-effort に deny。
- **重要判断**:
  - decision JSON は PoC 準拠の `{"decision":"block","reason":"..."}` を採用。`reason` は
    `jq -n --arg` でエスケープ安全に組み立て、jq 不在時のみ手書きフォールバック。
  - shellcheck SC2088/SC2016 は意図的な `~` / `$HOME` literal substring 検出のため、行単位の
    `# shellcheck disable=` 注釈で抑止（プロジェクト `.shellcheckrc` を汚さない方針）。
  - `--force-with-lease` と `-f` が同時指定された場合は無条件 force と同等扱いで deny
    （design G2 ロジック 2 項）。fixture/driver は Task 2 で形式化するが、24 件の手動
    smoke ですべて期待通りの decision/reason を確認。
- **残存課題**: fixture 29 件と run-tests.sh の整備は Task 2 のスコープ。Task 3 以降の watcher
  module 統合と install.sh 配置は本 commit 範囲外。
