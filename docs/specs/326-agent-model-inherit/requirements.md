# 要件定義: agent frontmatter の model ハードコード削除（inherit 化）

- Issue: [#326](https://github.com/hitoshiichikawa/idd-claude/issues/326) "claude: agent frontmatter の model ハードコードを削除し DEV_MODEL/REVIEWER_MODEL の契約を回復する"
- 対象ファイル想定: `.claude/agents/*.md`、`repo-template/.claude/agents/*.md`（byte 一致同期）、`README.md`

## Introduction

`.claude/agents/` の全エージェント定義（project-manager を除く 6 つ: product-manager / architect / developer / reviewer / qa / debugger）は frontmatter に `model: claude-opus-4-7` をハードコードしている。Claude Code のサブエージェントモデル解決順位は「`CLAUDE_CODE_SUBAGENT_MODEL` env > 呼び出しパラメータ > **frontmatter** > メイン会話のモデル」であるため、watcher が `--model "$DEV_MODEL"` / `--model "$REVIEWER_MODEL"` で渡すモデルは**オーケストレーターセッションにのみ効き、実作業を行うサブエージェントには届かない**。これは CLAUDE.md 禁止事項「モデル ID のハードコード（env default で override 可能にする）」と矛盾し、運用者がモデル切替でトークン消費を制御するレバーを塞いでいる。

frontmatter の `model:` キーは省略時 `inherit`（メイン会話のモデルを継承）として扱われる（Claude Code 公式 docs）。本機能は `model:` 行を削除して env 契約を回復する。既定の有効モデルは不変（`DEV_MODEL` 既定 = `claude-opus-4-7` を継承するため）。

## Requirements

### Requirement 1: frontmatter の model ハードコード削除

**Objective:** As a watcher 運用者, I want `DEV_MODEL` / `REVIEWER_MODEL` の値が実作業サブエージェントまで届いてほしい, so that env 設定だけでステージ別のモデル（＝トークン消費）を制御できる

#### Acceptance Criteria

1. The agent 定義 shall `product-manager.md` / `architect.md` / `developer.md` / `reviewer.md` / `qa.md` / `debugger.md` の frontmatter から `model:` 行を削除する（省略 = inherit）
2. The agent 定義 shall `project-manager.md` の `model:` をフルモデル ID（`claude-sonnet-4-6`）からエイリアス（`sonnet`）へ変更する（design ルートでは PjM が Opus セッション内のサブエージェントとして起動されるため、軽量モデル固定は維持しつつバージョン陳腐化を防ぐ）
3. The agent 定義 shall `reviewer.md` 本文の review-notes テンプレート例にあるモデル ID 逐語（`model=claude-opus-4-7`）をプレースホルダ（`model=<model-id>`）へ変更する
4. The リポジトリ shall `.claude/agents/` と `repo-template/.claude/agents/` を byte 一致で同期する（`diff -r` が空）

### Requirement 2: 運用ドキュメントの整合

**Objective:** As a 既稼働 watcher のユーザー, I want 本変更で何が変わるかを README で知りたい, so that 意図せぬモデル変更がないことを確認し、新しく効くようになったレバーを使える

#### Acceptance Criteria

1. The README shall migration note として「本変更前はサブエージェントが常に frontmatter 固定モデルで動作し、`DEV_MODEL` / `REVIEWER_MODEL` はオーケストレーター層にのみ適用されていた。本変更後は両 env がサブエージェントまで届く（既定値は従来と同一の `claude-opus-4-7`）」旨を記載する
2. The README shall 全サブエージェントのモデルを一括 override できる `CLAUDE_CODE_SUBAGENT_MODEL` 環境変数の存在と優先順位を記載する

## Non-Functional Requirements

1. The リポジトリ shall 既定の有効モデルを変更しない（`DEV_MODEL` / `REVIEWER_MODEL` の既定値 `claude-opus-4-7` を継承するため、env 未設定環境では本変更前と同一モデルで動作する）
2. The リポジトリ shall agent 定義の frontmatter `model:` 以外（name / description / tools / 本文の役割規定）を変更しない
3. The リポジトリ shall watcher スクリプト・installer・workflow を変更しない（agent 定義と README のみ）

## Out of Scope

- `DEV_MODEL` / `REVIEWER_MODEL` / `TRIAGE_MODEL` の既定値変更（#328 で Stage C 用 `PJM_MODEL` を別途導入）
- CLAUDE.md の規約文言更新（#330 のスリム化と競合するため、そちらに委ねる）
- Stage B / C のフラット化（#329）
