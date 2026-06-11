# 要件定義: docs-only 差分での Reviewer ステージスキップ（REVIEWER_SKIP_PATTERN, opt-in）

- Issue: [#333](https://github.com/hitoshiichikawa/idd-claude/issues/333)
- 対象ファイル想定: `local-watcher/bin/issue-watcher.sh`、`local-watcher/test/reviewer_skip_files_match_test.sh`（新規）、`README.md`

## Introduction

Reviewer ゲート（既定 Opus、最大 2 round + per-task 経路）は全 impl Issue で必ず起動するが、ドキュメントのみの変更では AC カバレッジ判定の費用対効果が低い。アプリ系 consumer repo（feedman / altpocket / keynest 等）の docs-only 差分に限定して Stage B をスキップできる opt-in env `REVIEWER_SKIP_PATTERN` を導入する。idd-claude 自身は markdown が成果物本体のため有効化しない（README に明記）。

## Requirements

### Requirement 1: スキップ判定（fail-safe）

#### Acceptance Criteria

1. The watcher shall `REVIEWER_SKIP_PATTERN`（POSIX ERE、既定 空 = 無効）を持つ
2. While `REVIEWER_SKIP_PATTERN` が非空であるとき, when Stage B（round=1）へ進む直前, the watcher shall `git diff --name-only origin/<BASE_BRANCH>..HEAD` の全ファイルがパターンに一致するかを判定する
3. If 全変更ファイル（1 件以上）がパターンに一致した場合, the watcher shall Stage B（独立 Reviewer の claude 起動）をスキップし approve 経路に進む
4. If 1 ファイルでも不一致 / 変更ファイル 0 件 / git diff 失敗 / パターン空 のいずれかの場合, the watcher shall スキップせず従来どおり Reviewer を起動する（fail-safe）
5. The watcher shall round=2 以降（reject 差し戻し後）にはスキップ判定を適用しない（round=1 入口のみ）

### Requirement 2: スキップ時の成果物・観測性

#### Acceptance Criteria

1. When スキップが適用されたとき, the watcher shall hidden marker `<!-- idd-claude:reviewer-skip:v1 ... -->` と最終行 `RESULT: approve` を含む review-notes.md を生成する（`parse_review_result` / Stage C の commit 契約 / Stage Checkpoint と互換）
2. When スキップが適用されたとき, the watcher shall `reviewer: round=1 result=approve reason=skip-pattern ...` 形式のログを出力する
3. While スキップが適用されたとき, the watcher shall run-summary の `stages` に B を記録しない（実行実態との一致）
4. The review-notes.md shall 独立レビューが省略された旨と人間レビューへの委任を明記する

### Requirement 3: テスト・ドキュメント

#### Acceptance Criteria

1. The build pipeline shall 判定純粋関数のテスト（全一致 / 部分不一致 / 空リスト / 空パターン / `-` 始まり path のフラグ注入耐性 / 代替 ERE）を持つ
2. The README shall env の用途・fail-safe 条件・idd-claude 自身では有効化しない旨を記載する

## Non-Functional Requirements

1. While `REVIEWER_SKIP_PATTERN` が空（既定）であるとき, the watcher shall 本機能導入前と完全に同一の挙動を保つ
2. When `shellcheck` を実行したとき, the build pipeline shall 新規警告 0 件にする
3. The build pipeline shall 既存テストスイートを全 PASS のまま維持する

## Out of Scope

- 軽量モデルでのレビュー継続（スキップでなく `REVIEWER_MODEL` 切替で代替可能）
- per-task Reviewer 経路への適用（別経路。単発経路での運用実績後に検討）
- idd-claude 自身での有効化
