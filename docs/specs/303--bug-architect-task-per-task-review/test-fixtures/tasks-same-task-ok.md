# Implementation Plan (fixture: 同 task 内テスト指示で合法なパターン)

このフィクスチャは、behavior-changing task が同 task の詳細項目に「テスト追加」「regression」
等のテスト指示を持ち、partial 明示なしで合法な canonical パターンを表現する。

- [ ] 1. 新エラーハンドリング実装（同 task 内 regression テストあり）
  - 詳細項目: ErrorHandler の failure path 分岐を追加
  - 詳細項目: stale data safety のチェックを追加
  - 詳細項目: failure path / stale data safety の regression テスト追加
  - _Requirements: 2.1, 2.2_
  - _Boundary: ErrorHandler_
