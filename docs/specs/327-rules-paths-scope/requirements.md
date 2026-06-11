# 要件定義: .claude/rules への paths: スコープ導入（常時自動ロードの解消）

- Issue: [#327](https://github.com/hitoshiichikawa/idd-claude/issues/327) "claude: .claude/rules に paths: スコープを導入して全コンテキスト常時ロードを解消する"
- 対象ファイル想定: `.claude/rules/*.md`（7 ファイル）、`repo-template/.claude/rules/*.md`（byte 一致同期）、`README.md`

## Introduction

Claude Code 2.x は `.claude/rules/*.md` を CLAUDE.md と同格のプロジェクト指示として、**全セッションおよび全サブエージェント**（Explore / Plan を除く）の context に自動注入する。本リポジトリのルール 7 ファイル（合計約 30K 字）はロール特化（ears-format は要件定義時のみ、design-principles は設計時のみ等）だが、現状 Triage / Developer / Reviewer / PjM を含む全コンテキストに毎回載っており、watcher の 1 Issue 処理（8〜12 コンテキスト）あたり推定数万〜十数万トークンの固定費になっている。`feature-flag.md` は「opt-in 宣言したプロジェクトでのみ Read される」という自身の前提が崩れている。

Claude Code のルールは YAML frontmatter の `paths` キー（glob）で**条件ロード**（該当パスのファイルに触れたセッションにのみ付与）に切り替えられる。本機能は各ルールに役割対応の `paths` を付与し、明示 Read 指示（agent 定義側に既存）を主経路として維持したまま、無関係コンテキストへの常時注入を解消する。

## Requirements

### Requirement 1: ルールファイルへの paths frontmatter 付与

**Objective:** As a watcher 運用者, I want ロール特化ルールが関係するコンテキストにだけロードされてほしい, so that 全 stage に載る固定トークン費を削減できる

#### Acceptance Criteria

1. The ルールファイル shall 以下の対応で YAML frontmatter `paths:` をファイル先頭に持つ:
   - `ears-format.md` / `requirements-review-gate.md` → `docs/specs/**/requirements.md`
   - `design-principles.md` / `design-review-gate.md` → `docs/specs/**/design.md`
   - `tasks-generation.md` → `docs/specs/**/tasks.md` と `docs/specs/**/design.md`
   - `feature-flag.md` → `.claude/rules/feature-flag.md`（明示 Read 時のみ付与される自己参照スコープ）
   - `issue-dependency.md` → `.claude/rules/issue-dependency.md`（同上）
2. The ルールファイル shall frontmatter 以下の本文（SPDX ヘッダ含む既存内容）を変更しない
3. The リポジトリ shall `.claude/rules/` と `repo-template/.claude/rules/` を byte 一致で同期する（`diff -r` が空）
4. The ルールファイル shall frontmatter 直後に条件ロードの旨を示す 1 行コメントを持つ（将来の編集者が誤って frontmatter を削除しないため）

### Requirement 2: 明示 Read 経路の維持（ルールが必要なロールへの到達保証）

**Objective:** As a PM / Architect / Developer / Reviewer エージェント, I want 自分の作業に必要なルールへ確実に到達したい, so that 記法・ゲートの一貫性が劣化しない

#### Acceptance Criteria

1. The リポジトリ shall agent 定義（`.claude/agents/*.md`）内の既存の明示 Read 指示・ルール参照を変更しない（新規ファイル作成時は paths トリガーが発火しないため、明示 Read が主経路）
2. The リポジトリ shall Triage prompt template 内の `issue-dependency.md` への参照（パス記載 + エイリアス要約のインライン記述）を変更しない（Triage は必要時に当該パスを Read できる）

### Requirement 3: 運用ドキュメント

#### Acceptance Criteria

1. The README shall ルールの条件ロード化（#327）の migration note を記載する（挙動: 該当ファイルに触れないセッションにはルールが注入されなくなる / 明示 Read は従来どおり機能する）

## Non-Functional Requirements

1. The リポジトリ shall watcher スクリプト・installer・workflow を変更しない
2. The リポジトリ shall ルール本文のセマンティクス（EARS 記法・ゲート手順・正準 regex）を変更しない（ハーネス側 mirror regex との整合に影響しない）

## Out of Scope

- CLAUDE.md のルール表更新（#330 スリム化と競合するため、そちらで実施）
- ルール本文の分量削減（#331）
- `paths` 非対応の旧 Claude Code バージョンでの挙動最適化（frontmatter は無害に無視またはルール全文ロードのまま）
