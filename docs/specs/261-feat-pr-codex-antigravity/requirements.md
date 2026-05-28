# Requirements Document

## Introduction

idd-claude では PR の作成・更新後に Claude が反復対応する PR Iteration Processor が既に
存在するが、その手前段階で「外部 AI レビューツール（`codex` または `antigravity`）に PR を
自動レビューさせ、レビュー結果を PR コメントとして残し、修正が必要なら `needs-iteration`
ラベル付与で既存 Iteration ループへ接続する」工程は未実装である。本機能は新規の PR Reviewer
Processor を opt-in env var（`PR_REVIEWER_ENABLED=true`）で追加し、運用者が事前にインストール
／認証済みの外部レビューツールを watcher から実行可能にすることを目的とする。既存プロセッサ
（PR Iteration / Auto Rebase / Merge Queue 等）の後方互換性は維持し、未有効化 repo では
本機能導入前と完全に同一の挙動とする。

## Requirements

### Requirement 1: Opt-in による有効化と既定スキップ

**Objective:** As an idd-claude operator, I want PR Reviewer Processor を opt-in env var で
有効化したい, so that 未設定の既存リポジトリには影響を与えず段階的に導入できる

#### Acceptance Criteria

1. While `PR_REVIEWER_ENABLED` が `true` と完全一致しない（未設定 / 空文字 / `false` / `0` /
   `True` 等の typo を含む）状態である間, the PR Reviewer Processor shall 当該サイクルで自身の
   処理を一切実行せず、安全にスキップする
2. While `PR_REVIEWER_ENABLED` が `true` と完全一致している状態である間, the PR Reviewer
   Processor shall 後述の Requirement 2〜7 で定める処理を実行する
3. The PR Reviewer Processor shall opt-in がスキップされた場合でも、他の既存プロセッサ
   （PR Iteration / Auto Rebase / Merge Queue 等）の動作に副作用を与えない

### Requirement 2: レビューツールの選択と排他制御

**Objective:** As an idd-claude operator, I want 使用するレビューツール（`codex` または
`antigravity`）を選択し、両者の同時有効化を禁止したい, so that 想定外の重複レビューやコメント
の二重投稿を防止できる

#### Acceptance Criteria

1. While `codex` のみが有効化された状態である間, the PR Reviewer Processor shall `codex` を
   レビュー実行コマンドとして採用する
2. While `antigravity` のみが有効化された状態である間, the PR Reviewer Processor shall
   `antigravity` をレビュー実行コマンドとして採用する
3. If `codex` と `antigravity` の両方が同時に有効化された状態を検出した場合, the PR Reviewer
   Processor shall 排他エラーとして処理を中止し、エラーをログに出力する
4. If 排他エラー検出時に対象 PR が存在する場合, the PR Reviewer Processor shall 対象 PR に
   排他エラーである旨のコメントを 1 回投稿する（重複防止は Requirement 6 のマーカー機構に従う）
5. If `codex` と `antigravity` のいずれも有効化されていない状態を検出した場合, the PR Reviewer
   Processor shall レビューを実行せず、その旨をログに記録して当該サイクルをスキップする

### Requirement 3: ツール未インストール／未認証時のエラー通知

**Objective:** As an idd-claude operator, I want 指定したレビューツールが未インストールまたは
未認証の場合に対象 PR へ通知が残ること, so that 静かに失敗せず運用者が状況を把握して復旧でき
る

#### Acceptance Criteria

1. If 指定されたレビューツールの実行ファイルが PATH 上に存在しない状態を検出した場合, the PR
   Reviewer Processor shall 対象 PR にエラーコメントを投稿し、当該 PR のレビュー実行を中止する
2. If 指定されたレビューツールが未認証である状態を検出した場合, the PR Reviewer Processor shall
   対象 PR にエラーコメントを投稿し、当該 PR のレビュー実行を中止する
3. While 同一 PR に既にエラー通知の重複防止マーカー（Requirement 6 参照）が存在する状態である
   間, the PR Reviewer Processor shall 同種のエラーコメントを再投稿しない
4. The PR Reviewer Processor shall エラーコメントの冒頭に `## 自動レビューエラー` 等の運用者が
   人間判断で識別できる見出しを含める

### Requirement 4: レビュー実行とコメント投稿

**Objective:** As an idd-claude operator, I want 対象 PR の head ブランチに対してレビュー
ツールを実行し、その出力結果を PR コメントとして残したい, so that PR 作成者・レビュワーが
レビュー結果を GitHub 上で確認できる

#### Acceptance Criteria

1. When 対象 PR がレビュー実行対象として確定した場合, the PR Reviewer Processor shall 当該 PR
   の head ブランチをローカル作業ディレクトリで checkout する
2. When head ブランチ checkout 後にレビュー実行段階に進んだ場合, the PR Reviewer Processor
   shall 運用者が env var で指定した実行コマンドを呼び出し、その標準出力をレビュー結果として
   収集する
3. Where 実行コマンドに base ブランチ名のプレースホルダ（例: `{BASE}`）が含まれる場合, the PR
   Reviewer Processor shall 当該プレースホルダを実行時の base ブランチ名（`BASE_BRANCH` の
   既定 `main` 等）に置換する
4. When レビュー結果テキストが収集された場合, the PR Reviewer Processor shall 当該テキストを
   対象 PR にコメントとして 1 回投稿する
5. If レビュー実行コマンドが非ゼロ終了コードで失敗した場合, the PR Reviewer Processor shall
   失敗である旨のエラーコメントを対象 PR に投稿し、当該 PR のレビューを中止する

### Requirement 5: `needs-iteration` ラベル自動付与

**Objective:** As an idd-claude operator, I want レビュー結果に修正要求のキーワードが含まれる
場合に `needs-iteration` ラベルを自動付与したい, so that 既存の PR Iteration Processor が
シームレスに後続処理を引き継げる

#### Acceptance Criteria

1. When レビュー結果テキストに運用者が env var で指定したキーワード（既定値は運用設計時に
   決定する）が 1 件以上含まれていた場合, the PR Reviewer Processor shall 対象 PR に
   `needs-iteration` ラベルを付与する
2. If 対象 PR に既に `needs-iteration` ラベルが付与されている場合, the PR Reviewer Processor
   shall 当該ラベルの重複付与を行わず冪等に振る舞う
3. When レビュー結果テキストにキーワードが 1 件も含まれていなかった場合, the PR Reviewer
   Processor shall `needs-iteration` ラベルを付与しない
4. The PR Reviewer Processor shall キーワード検出結果（マッチした語と件数）をログに記録する

### Requirement 6: コミット SHA に基づく重複レビュー防止

**Objective:** As an idd-claude operator, I want 同一コミット状態の PR に対する重複レビューを
回避したい, so that 同じ内容のレビューコメントが何度も投稿されず PR が読みづらくなることを
防げる

#### Acceptance Criteria

1. When レビューコメントまたはエラーコメントを投稿する場合, the PR Reviewer Processor shall
   コメント本文中に `sha=<headRefOid>` を含む非表示 HTML マーカーを埋め込む
2. While 対象 PR の既存コメント群に当該コミット SHA を含む同種マーカーが存在する状態である
   間, the PR Reviewer Processor shall 当該 PR に対する同種のコメント投稿およびレビュー実行を
   行わない
3. When 対象 PR の head コミットが更新され、結果として `headRefOid` が変化した場合, the PR
   Reviewer Processor shall 新しい SHA に対する処理を新規実行として扱う
4. The PR Reviewer Processor shall マーカーの文字列形式を運用者が GitHub UI で目視確認可能な
   非表示コメント（HTML コメント形式）として実装する

### Requirement 7: 対象イベントの限定

**Objective:** As an idd-claude operator, I want 本機能の対象を PR 作成・更新時に限定したい,
so that スコープが肥大化せず、検証・運用負荷を最小に保てる

#### Acceptance Criteria

1. The PR Reviewer Processor shall 評価対象を「watcher サイクル時点で open 状態にある PR」に
   限定する
2. If 対象 PR が draft 状態である場合の扱いは Open Questions に従って運用設計時に決定する
   ものとし、確定するまでは安全側として処理をスキップする
3. The PR Reviewer Processor shall Issue 単体（PR を伴わない Issue）に対しては動作しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `PR_REVIEWER_ENABLED` が `true` と完全一致しない状態である間, the watcher shall 本機能
   導入前と完全に同一の挙動を維持する（既存のラベル遷移・コメント投稿・他プロセッサ起動順序を
   含む観測可能挙動が等価）
2. The PR Reviewer Processor shall 既存 env var（`REPO` / `REPO_DIR` / `BASE_BRANCH` /
   `PR_ITERATION_ENABLED` / `LABEL_NEEDS_ITERATION` 等）の名前・意味・既定値を変更しない

### NFR 2: 静的解析品質

1. While 本機能の新規／変更ファイル群に対して `shellcheck` を実行した状態である間, the static
   analysis result shall 警告ゼロで完了する（既存リポジトリ運用と同じ `.shellcheckrc` 抑止
   方針に従う）

### NFR 3: 観測可能性

1. The PR Reviewer Processor shall 主要な分岐点（スキップ理由 / 排他エラー / ツール未検出 /
   レビュー実行 / コメント投稿 / ラベル付与 / 重複検出）を運用者がログから判定できる形で記録
   する

### NFR 4: 冪等性

1. The PR Reviewer Processor shall 同一 PR 同一 SHA に対して watcher を複数回起動しても、
   観測可能な副作用（コメント / ラベル / ログ以外の外部書き込み）が 1 回分のみとなることを
   保証する（重複防止機構は Requirement 6 に従う）

## Out of Scope

- `codex` / `antigravity` 自体のインストール・セットアップ・認証フローの自動化（運用者が
  事前にインストール・認証済みである前提）
- PR 作成・更新以外の任意イベント（schedule trigger / 手動 dispatch / Issue 駆動の任意実行
  等）でのレビュー実行
- 外部 AI レビューサービス（`codex` / `antigravity` 以外）の対応拡張
- レビュー結果テキストの言語別分類・優先度付け・自動分割等の高度な後処理
- 既存の PR Iteration Processor 本体の動作変更（本機能は `needs-iteration` ラベル付与までで
  あり、その後の反復は既存 PR Iteration Processor に委譲する）

## Open Questions

- レビューツール選択用の env var 名（仮: `PR_REVIEWER_CODEX_ENABLED` /
  `PR_REVIEWER_ANTIGRAVITY_ENABLED` の 2 変数か、`PR_REVIEWER_TOOL=codex|antigravity` の単一
  変数か）が未確定。Issue 本文の受入基準候補 2 では両表記が併記されており、Architect 段階で
  既存命名規約（`*_ENABLED` 系）と整合する形を選定する必要がある
- 実行コマンド本体の env var 名（仮: `PR_REVIEWER_CODEX_CMD` / `PR_REVIEWER_ANTIGRAVITY_CMD`）
  および `{BASE}` 以外に必要なプレースホルダ（例: `{HEAD}` / `{PR_NUMBER}` 等）の要否が未確定
- ツール未認証判定に用いる「認証状況確認コマンド」の標準仕様（例: `<tool> auth status` 等）が
  未確定。Issue 本文「判断を委ねたい点」に該当
- `needs-iteration` ラベル付与のトリガとなるキーワード（`PR_REVIEWER_ITERATION_PATTERN` の
  既定値）が未確定。`needs-iteration` 単語そのものでよいか、より広い正規表現にするかは Architect
  段階で決定する
- draft 状態 PR を対象に含めるかどうか（Requirement 7.2）が未確定。既存 PR Iteration では draft
  を除外しているため、整合性を考慮した運用判断が必要
- 認証エラーとツール未インストールエラーを 1 種のコメントにまとめるか、分けて投稿するかが
  未確定（Requirement 3）
- レビューを実行する watcher サイクルでの上限件数（既存 `PR_ITERATION_MAX_PRS` / `MERGE_QUEUE_MAX_PRS`
  類似の `PR_REVIEWER_MAX_PRS` の要否と既定値）が未確定
