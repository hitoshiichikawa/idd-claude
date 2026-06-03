# Implementation Notes (#281)

## Implementation Notes

### Task 1

- 採用方針: LABELS 配列末尾（`hotfix` 行直後）に `needs-security-fix` を 1 行追加し、既存 16 行の name / color / description は一切変更しない（NFR 1.2）。color は既存 PR 用警告色との一貫性のため `d73a4a`（`st-failed` と同色）を採用、description は仕様文字列をそのまま使用し 83 chars（100 chars 上限内）であることを確認。
- 重要な判断:
  - `repo-template/.github/scripts/idd-claude-labels.sh` は design.md「Modified Files」の対象外（design.md line 257-262 で明示的に repo-template 側不変と宣言）かつ root とは既に系統的に乖離している（root のみ 【PR 用】/【Issue 用】prefix 運用）ため、本 task では編集しない。二重管理規約（CLAUDE.md）が対象とするのは `.claude/{agents,rules}` のみで `.github/scripts/` は対象外であることも確認済み。
  - shellcheck はラベル配列追加のみのため警告ゼロを維持。
- 残存課題: なし（task 2 以降は別 task として独立しており、本 task の判断が後続に伝播する事項はない）。
