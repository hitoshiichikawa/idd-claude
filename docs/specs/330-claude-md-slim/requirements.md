# 要件定義: CLAUDE.md のスリム化と重複 Read 指示の削除

- Issue: [#330](https://github.com/hitoshiichikawa/idd-claude/issues/330)
- 対象ファイル想定: `CLAUDE.md`、`repo-template/CLAUDE.md`、`.claude/agents/{developer,reviewer,project-manager}.md`（repo-template 同期）

## Introduction

CLAUDE.md（self 約 27K 字 / template 約 21K 字）は全コンテキストに自動ロードされるにもかかわらず、冒頭で「作業開始前に読み直してください」と再 Read を指示し、developer.md / reviewer.md も明示 Read を要求している。再 Read はツール結果として**同内容を二重注入**するだけであり、developer / reviewer の実行ごとに 21〜27K 字の純粋なムダが発生する。また「PR 品質チェック」（PjM 専用）等のロール特化節が全コンテキストに常時載っている。

## Requirements

### Requirement 1: 重複 Read 指示の削除

#### Acceptance Criteria

1. The CLAUDE.md（self / template とも） shall 冒頭の「作業開始前にこのファイルを読み直してください」指示を、自動ロード前提（追加 Read 不要）の記述に置き換える
2. The developer.md shall Feature Flag Protocol 採否確認を「自動ロード済み CLAUDE.md の該当節を確認（追加 Read 不要）」に変更する
3. The reviewer.md shall 必読ファイルリストから CLAUDE.md の Read を除去し、自動ロード済みである旨と参照すべき節（テスト規約 / 禁止事項 / Feature Flag Protocol）を明記する
4. The 変更 shall agent が CLAUDE.md の規約内容へ到達する経路（自動ロード）を損なわない

### Requirement 2: ロール特化節の移設と重複解消

#### Acceptance Criteria

1. The CLAUDE.md（self / template とも） shall 「PR 品質チェック」チェックリストを project-manager.md へ移設し、1 段落のポインタに置き換える
2. The project-manager.md shall 移設されたチェックリスト（bash repo / アプリ repo の読み替え注記付き）を持つ
3. The self CLAUDE.md shall 「idd-claude 特有の設計上の注意」内の root ↔ repo-template 二重管理の長文規定を、「機能追加ガイドライン §4」（#322 で導入済みの同内容）へのポインタ + 要点 1 行に統合する（ファイル内重複の解消）
4. The CLAUDE.md（self / template とも） shall 「エージェントが参照する共通ルール」の導入文を #327 の条件ロードと明示 Read の二重到達保証を説明する記述へ更新する

## Non-Functional Requirements

1. The 変更 shall 規約の実体（禁止事項 / コード規約 / 言語方針 / 機能追加ガイドライン本文）を削除しない（移設と重複解消のみ）
2. The リポジトリ shall `.claude/agents` と `repo-template/.claude/agents` を byte 一致で同期する
3. The 変更 shall watcher スクリプト（issue-watcher.sh のプロンプト内 CLAUDE.md 言及含む）を変更しない（#329 ブランチとの競合回避。プロンプト側の整理は同 PR merge 後の派生課題）

## Out of Scope

- 言語方針・機能追加ガイドライン（#322）の本文削減（実体規約のため）
- issue-watcher.sh 内プロンプトの CLAUDE.md 言及整理（#329 と競合するため別途）
- 「機能追加ガイドライン」の paths 付きルール化（root ↔ template の byte 一致鉄則と矛盾するため見送り。検討経緯は impl-notes）
