# Implementation Notes — Issue #279

本 spec の per-task 実装中に発生した learning / 判断 / 残存課題を、Implementer
（fresh context 起動）が後続 task に引き継ぐためのメモ。

## Implementation Notes

### Task 1

- 採用方針: `core_utils.sh` 末尾の pr-reviewer 専用ロガー（`pr_log` / `pr_warn` /
  `pr_error`）の直後に `sec_log` / `sec_warn` / `sec_error` を追記し、prefix のみ
  `security-review:` に差し替えた。既存ロガー群（`qa_log` / `mq_log` / `pi_log` /
  `pr_log` 等）と完全に同じ 3 関数セットの形を踏襲。
- 重要な判断:
  - 関数の配置は `pr_log` 群の直後（既存の pr-reviewer 関連まとまりの末尾）に置き、
    `claude_log_detect_529` セクション（`# ─── Issue #259: ...` 罫線見出し）の前に
    挿入することで、ロガー群の連続性を保ちつつ既存 detector セクションへの干渉を避けた。
  - prefix 文字列は spec 指定どおり `security-review:`（ハイフン区切り、`:` の後に
    半角スペース 1 個）。これは後続 task で `sec_resolve_*` / `sec_run_review_for_pr`
    のログ出力でそのまま使われる。
  - `set -euo pipefail` は本モジュールでは宣言せず、本体 (`issue-watcher.sh`) 側の
    宣言を継承する既存規約に従った（モジュール冒頭の依存コメントに明記されている方針）。
- 残存課題:
  - なし。後続 task 2 以降は `sec_log` / `sec_warn` / `sec_error` を `modules/security-review.sh`
    から自由に呼び出せる前提で実装してよい（bash の遅延束縛により、本体 source 完了後に解決される）。
