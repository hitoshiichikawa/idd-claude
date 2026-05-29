# Implementation Plan (fixture: unchecked あり)

このファイルは Issue #273 の `sc_tasks_unchecked_count` 判定 regex
(`^- \[ \]\*? [0-9]+\. `) の回帰テスト用 fixture。

期待値: 最上位 numeric ID の未チェックタスク（`- [ ] 1. ...` / `- [ ] 2. ...`）が
**2 件** マッチする。子タスク (`1.1`) / 完了済み (`- [x] 3. ...`) はマッチしない。

- [ ] 1. 最上位タスク A (unchecked, count されるべき)
  - 詳細項目はカウント対象外
  - _Requirements: 2.1_
- [ ] 1.1 子タスク (numeric ID 階層、count されないべき)
  - 子タスクは `- [ ] 1.1 ` 形式で末尾の `.` がないため正本 regex にマッチしない
- [ ] 2. 最上位タスク B (unchecked, count されるべき)
  - _Requirements: 2.4_
- [x] 3. 最上位タスク C (完了済み、count されないべき)
  - `- [x]` で始まるため正本 regex `^- \[ \]\*? [0-9]+\. ` にマッチしない
