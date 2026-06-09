# Implementation Plan

擬似 tasks.md。`cm_resolve_boundary` / `_cm_resolve_task_name` の決定論性および
`cm_generate` の AC カバレッジ（Req 2.2〜2.7）を fixture ベースで検証するためのもの。

- [ ] 1. context-map モジュールを追加する
  - 詳細項目 A
  - 詳細項目 B
  - _Requirements: 1.1, 2.1, 2.2_
  - _Boundary: context-map.sh_

- [ ] 2. issue-watcher.sh 本体に wiring する
  - 詳細項目
  - _Requirements: 2.1, 3.1_
  - _Boundary: issue-watcher.sh_

- [ ] 3. `_Boundary:_` 不在ケース（境界値）
  - 詳細項目
  - _Requirements: 2.9_

## Verify

verify ブロックは本 fixture では検証しない。
