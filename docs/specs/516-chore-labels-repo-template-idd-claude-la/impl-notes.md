# 実装ノート

## 概要

`repo-template/.github/scripts/idd-claude-labels.sh` を root 側
`.github/scripts/idd-claude-labels.sh` に byte 一致させた。#54 で root に導入された
`【Issue 用】` / `【PR 用】` description prefix と、直前の 4 行コメントブロックが
repo-template 側に未反映だったドリフトを解消する単純同期修正。design.md / tasks.md は
作成されていない（Architect 不要の単純同期修正のため、Issue 記載どおり）。

## 変更内容

- `repo-template/.github/scripts/idd-claude-labels.sh` の `LABELS=()` 配列直前に、root 側と
  同一の 4 行コメントブロック（Issue #54 Req 2.1/2.2/2.3 の説明・description 100 文字上限・
  name/color 不変の言及）を追加（Requirement 1 / AC 1.1）
- 以下 9 ラベルの description 先頭に `【Issue 用】` prefix を付与: `auto-dev` /
  `needs-decisions` / `awaiting-design-review` / `claude-claimed` / `claude-picked-up` /
  `ready-for-review` / `claude-failed` / `skip-triage` / `hotfix`（Requirement 2 / AC 2.1, 2.2）
- 以下 2 ラベルの description 先頭に `【PR 用】` prefix を付与: `needs-rebase` /
  `needs-iteration`（Requirement 3 / AC 3.1, 3.2）
- `size:small` / `size:medium` / `size:large` の 3 行、その他既存ラベル
  （`needs-quota-wait` / `staged-for-release` / `st-failed` / `awaiting-slot` / `blocked` /
  `needs-security-fix` / `needs-merge-gate-attention`）、オプション解析・依存チェック・
  ラベル作成ロジック・結果集計・ヘルプ表示等は変更なし（Requirement 4 / AC 4.1〜4.4）
- root 側 `.github/scripts/idd-claude-labels.sh` は一切変更していない（Requirement 4 / AC 4.1）

## 検証結果

| コマンド | 結果 |
|---|---|
| `diff .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` | 出力なし・exit code 0（byte 一致確認、Requirement 5 / AC 5.1） |
| `shellcheck repo-template/.github/scripts/idd-claude-labels.sh` | 警告ゼロ・exit code 0 |
| 既存テスト | `local-watcher/test/` 配下に本スクリプト専用のテストは存在せず、影響なし |

## AC Traceability

| Requirement / AC | 対応内容 |
|---|---|
| 1.1 | root 側 4 行コメントブロックを repo-template の同一位置に同一文字列で追加 |
| 2.1, 2.2 | 対象 9 ラベルの description に `【Issue 用】` prefix を付与し、root と完全一致 |
| 3.1, 3.2 | 対象 2 ラベルの description に `【PR 用】` prefix を付与し、root と完全一致 |
| 4.1 | root 側ファイルは無変更（`git diff` 未使用箇所として確認） |
| 4.2 | `size:*` 3 行は編集対象から除外し無変更 |
| 4.3 | LABELS 定義ブロック以外（オプション解析等）は無変更 |
| 4.4 | 対象 11 ラベル・`size:*` 以外の既存 7 ラベルの name/color/description は無変更 |
| 5.1 | `diff` コマンドで空出力・exit code 0 を確認 |
| NFR 1.1 | 変更は description prefix / コメント追加のみで name・color は不変 |
| NFR 1.2 | `--force` なし実行時の skip / 新規作成ロジック自体は無編集のため動作不変 |

## 確認事項

なし（root/repo-template の byte 一致を機械的に確認済みで、要件に対する解釈の曖昧さは
発生しなかった）。

STATUS: complete
