# Requirements Document

## Introduction

Architect エージェントは、外部ツール・ライブラリ・API・CLI コマンド等の挙動に依拠した設計
判断を行う場面がある。しかしモデル知識のカットオフや細部仕様の曖昧さにより、根拠を確認しない
まま推測ベースで design.md を確定し、Developer フェーズで仕様乖離が判明する事故が起きうる。
本機能は、Architect エージェント定義および設計原則ルールに「不確実な仕様は Web 検索で一次情報
を確認する」旨の指示を追加し、設計品質の取りこぼしを減らすことを目的とする。検索義務化の対象は
Architect のみで、リンク記録は推奨止め（義務化しない）とする。idd-claude は root の
`.claude/{agents,rules}/` と `repo-template/.claude/{agents,rules}/` の二重管理規約に従うため、
両系統の byte 一致を維持することも本機能の必須条件に含む。

## Requirements

### Requirement 1: Architect エージェント定義への Web 検索指示の追加

**Objective:** As an Architect エージェント運用者, I want Architect が不確実な外部仕様を Web
検索で確認するよう促す指示が `architect.md` に明記されている状態, so that 推測ベースの設計判断
による下流フェーズでの仕様乖離を減らせる

#### Acceptance Criteria

1. The `.claude/agents/architect.md` shall 外部ツール・ライブラリ・API・CLI コマンドを伴う設計時に
   不確実な仕様について Web 検索で一次情報を検証するよう指示する節を含む
2. The `repo-template/.claude/agents/architect.md` shall root と同一内容の Web 検索指示節を含む
3. When Architect が外部ツール・ライブラリ・API・CLI コマンドの仕様に依拠した設計判断を行うとき,
   the Architect エージェント shall 不確実な箇所について Web 検索で一次情報を確認する
4. Where 設計判断の対象が idd-claude 内部の既存仕様・既存実装である場合, the Architect エージェント
   shall Web 検索を必須とせず既存ドキュメント・既存コードの参照を優先する
5. The Web 検索指示節 shall 「不明な場合・新規ツール導入時に限定」して必要最小限に留めることを
   明記する

### Requirement 2: 設計原則ルールへの Web 検索節の追加

**Objective:** As an Architect エージェント運用者, I want 設計原則ルール `design-principles.md`
にも Web 検索方針が明文化されている状態, so that Architect が `design-principles.md` を Read した
時点で同方針を参照できる

#### Acceptance Criteria

1. The `.claude/rules/design-principles.md` shall 外部仕様の不確実性を解消するための Web 検索方針を
   記述した節を含む
2. The `repo-template/.claude/rules/design-principles.md` shall root と同一内容の Web 検索方針節を
   含む
3. The Web 検索方針節 shall Web 検索の対象を「外部ツール・ライブラリ・API・CLI コマンドの仕様」に
   限定する旨を明記する
4. The Web 検索方針節 shall 検索結果のリンクを design.md に残すことを推奨として記述する
5. If 検索結果のリンクを design.md に残すか否かが議論になる場合, the Web 検索方針節 shall リンク
   記録を義務化せず Architect の裁量に委ねる旨を明記する

### Requirement 3: 二重管理規約との整合

**Objective:** As an idd-claude メンテナ, I want root と `repo-template/` の両系統が byte 一致で
更新されている状態, so that consumer repo にも同じ Web 検索方針が配布される

#### Acceptance Criteria

1. The `.claude/agents/architect.md` と `repo-template/.claude/agents/architect.md` shall byte
   一致である
2. The `.claude/rules/design-principles.md` と `repo-template/.claude/rules/design-principles.md`
   shall byte 一致である
3. When 本機能の変更を含む PR が作成されるとき, the PR 本文 shall `diff -r .claude/agents
   repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` の差分が
   空であることを確認した記録を含む

### Requirement 4: 既存セクション・既存挙動への非干渉

**Objective:** As an idd-claude メンテナ, I want 既存の Architect 指示と設計原則ルールの他セク
ションが本変更で意味を変えない状態, so that 後方互換性を保ち既稼働の Architect 実行を壊さない

#### Acceptance Criteria

1. The `architect.md` の既存セクション（要件読み込み手順, design.md / tasks.md テンプレート,
   自己レビューゲート参照等） shall 本変更の前後で意味的に同一である
2. The `design-principles.md` の既存セクション（必須セクション一覧, File Structure Plan の書き方
   等） shall 本変更の前後で意味的に同一である
3. Where 既存の `.claude/rules/*.md` 他ファイル（`ears-format.md` / `design-review-gate.md` /
   `tasks-generation.md` 等）が存在する場合, the 本変更 shall それらのファイルを編集しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The 本変更 shall 既存 env var 名・既存ラベル名・既存 cron 登録文字列を変更しない
2. The 本変更 shall watcher スクリプト (`local-watcher/bin/*.sh`) を編集しない
3. The 本変更 shall 既存 Architect が生成した過去の `design.md` に対する遡及的な書き換えを要求
   しない

### NFR 2: 言語方針との整合

1. The 追加される Web 検索指示節および Web 検索方針節 shall CLAUDE.md「言語方針」に従い日本語
   ベースで記述する
2. The 追加節中で識別子・コマンド名・ファイルパス・ツール名を引用する箇所 shall 英語固定の表記を
   保つ

## Out of Scope

- Developer エージェント定義 (`developer.md`) への Web 検索指示の追加
- Product Manager エージェント定義 (`product-manager.md`) への Web 検索指示の追加
- Reviewer / Project Manager / Debugger エージェント定義の変更
- `local-watcher/bin/issue-watcher.sh` 等 watcher スクリプトの書き換え
- 新規 Web 検索ツール・MCP サーバの実装や導入
- 既存 design.md 群への遡及的なリンク追記
- Web 検索結果リンクのフォーマット規定や lint
- Web 検索の自動実行（Architect が必要と判断したときのみ実施する手動相当の運用）

## Open Questions

- なし（Issue コメントで「Option B: リンク記録は推奨止め」が確定済み）
