# Implementation Plan (fixture: partial 明示で合法化されたパターン)

このフィクスチャは、behavior-changing task が `_Requirements_partial:_` で deferred test
AC を明示し、後続 test task で解消する canonical な合法パターンを表現する。

- [ ] 1. 新エラーハンドリング実装（テストは task 2 で追加 / partial 明示あり）
  - 詳細項目: ErrorHandler の failure path 分岐を追加
  - 詳細項目: stale data safety のチェックを追加
  - _Requirements: 2.1, 2.2_
  - _Requirements_partial: 2.2_
  - _Boundary: ErrorHandler_

- [ ] 2. dedicated regression test task（task 1 の partial 解消）
  - 詳細項目: task 1 で partial 明示された 2.2 の regression test を追加
  - 詳細項目: failure path / stale data safety の E2E テスト
  - _Requirements: 2.2_
