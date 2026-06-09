# Design Document（fixture）

擬似 design.md。`cm_resolve_candidate_files` / `cm_resolve_candidate_tests` の
File Structure Plan 解析を fixture ベースで検証するためのもの。

## File Structure Plan

### Directory Structure

```
local-watcher/bin/
├── issue-watcher.sh                # 本体
└── modules/
    └── context-map.sh              # 新規モジュール

docs/specs/313-fixture/
├── requirements.md
├── design.md
├── tasks.md
└── test-fixtures/
    ├── tasks-sample.md
    └── test-cm-generate.sh         # test スクリプト
```

## Other section

本セクションは fence の外。boundary token を含んでいても fenced block 外なので拾われない。
