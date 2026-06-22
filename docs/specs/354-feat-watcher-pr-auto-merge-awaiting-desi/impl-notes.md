# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `local-watcher/bin/modules/auto-merge.sh` (#352) を雛形にコピーし、`am_` → `amd_` /
  `AUTO_MERGE_` → `AUTO_MERGE_DESIGN_` / `auto-merge:` → `auto-merge-design:` の mechanical
  rename + design 用差分（ready-for-review 必須を削除、needs-iteration 除外を追加）で構築
- 重要な判断:
  - `amd_should_enable_for_pr` から `LABEL_READY` 必須チェックを削除（design PR に
    `ready-for-review` ラベルを付与しないため）
  - `LABEL_NEEDS_ITERATION` 除外を追加（Req 6.4 / 設計 PR iteration 中は merge 抑止）。
    server-side `gh pr list --search` 文字列にも `-label:"$LABEL_NEEDS_ITERATION"` を追加
  - head pattern による排他は `AUTO_MERGE_DESIGN_HEAD_PATTERN` (`^claude/issue-.*-design`)
    の client-side filter で impl PR と自然分離（Req 2.6, 6.7）。impl PR の
    `^claude/issue-.*-impl` head は本 pattern にマッチしないため二重防御として機能
  - tempfile prefix も `am-merge-stderr-` → `amd-merge-stderr-` に置換し、#352 との
    同時実行時にも一意性を保つ
- 残存課題: 本 task では module 単体の関数定義のみで、本体 Config / loader / call site への
  配線（task 2 / 3 / 4）が未完。`LABEL_NEEDS_ITERATION` は本体 `issue-watcher.sh` 側で
  既存定義済みであることを確認済み（line 73 で `LABEL_NEEDS_ITERATION="needs-iteration"`
  として定義されており、本 module 内では遅延束縛で参照可能）
