# Implementation Plan (fixture: 違反パターン)

このフィクスチャは、`_Requirements:_` に regression coverage / failure path 系 AC を含む
behavior-changing task が、同 task 内テスト指示 (`テスト追加` / `regression` / `test`) を
持たず、かつ `_Requirements_partial:_` でも partial 明示していない違反パターンを表現する。

- [ ] 1. 新エラーハンドリング実装（同 task テストなし、partial 明示なし → 違反）
  - 詳細項目: ErrorHandler の failure path 分岐を追加
  - 詳細項目: stale data safety のチェックを追加
  - _Requirements: 2.1, 2.2_
  - _Boundary: ErrorHandler_

- [ ]* 2. テスト追加（dedicated regression test task / 先行 task の partial 解消なし）
  - 詳細項目: failure path の単体テストを追加
  - _Requirements: 2.1, 2.2_
