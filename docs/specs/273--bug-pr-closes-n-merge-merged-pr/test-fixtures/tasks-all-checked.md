# Implementation Plan (fixture: 全完了)

このファイルは Issue #273 の `sc_tasks_unchecked_count` 判定 regex
(`^- \[ \]\*? [0-9]+\. `) の回帰テスト用 fixture。

期待値: すべて `- [x]` 完了済みのため、判定 regex に **0 件** マッチする
（Req 2.4: tasks.md の全最上位タスクが完了済み → MERGED PR を terminal として採用）。

- [x] 1. 最上位タスク A (完了済み)
  - _Requirements: 2.4_
- [x] 2. 最上位タスク B (完了済み)
  - _Requirements: 2.4_
- [x] 3. 最上位タスク C (完了済み)
  - _Requirements: 2.4_
