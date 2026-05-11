# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` の `build_reviewer_prompt` 関数は、Reviewer サブエージェント起動用プロンプトに `git diff ${BASE_BRANCH}..HEAD` の **全文** を heredoc で埋め込み、生成した文字列を `claude --print "$prompt"` の単一引数として渡している。差分が大きい Issue（例: 91 ファイル変更で約 327,886 B）では Linux の `MAX_ARG_STRLEN = 131,072 B` を超え、`execve()` が `E2BIG` を返して Reviewer ステージが起動できず、Issue は `claude-failed` ラベルで人間にエスカレーションされてしまう（2026-05-11 に KeyNest repo Issue #1 で実発生）。

本機能では、Reviewer 用プロンプトから inline diff を撤廃し、Reviewer サブエージェント自身が `Bash` ツールで差分を取得する手順をプロンプトに明示することで、差分サイズに依存せず Reviewer ステージが起動できるようにする。プロンプトの出力契約（`RESULT: approve|reject`）、round 制御、後方互換性（env var / ラベル / cron 文字列 / exit code）は維持する。idd-claude は self-hosting であり、修正後の watcher は本リポジトリ自身の差分が大きくなった Issue でも同様に動作する必要がある。

## Requirements

### Requirement 1: Reviewer プロンプトの inline diff 撤廃

**Objective:** As a watcher 運用者, I want Reviewer プロンプトに `git diff` 全文を埋め込まない方式に切り替えたい, so that 大きな差分でも Reviewer ステージが `Argument list too long` で失敗せずに起動できる

#### Acceptance Criteria

1. When `build_reviewer_prompt` がプロンプトを生成するとき, the Reviewer Prompt Builder shall `git diff ${BASE_BRANCH}..HEAD` の全文を出力に含めない
2. When `build_reviewer_prompt 1 "(none)"` を本リポジトリ（slot-1 worktree）で実行したとき, the Reviewer Prompt Builder shall 出力バイト数を 131,072 B 未満に収める
3. When 差分取得が失敗または空であっても, the Reviewer Prompt Builder shall プロンプト生成自体を成功させる（プロンプト本文に差分埋め込みの fallback テキストを残さない）
4. The Reviewer Prompt Builder shall 出力に `BASE_BRANCH` の値、`HEAD` commit SHA、作業ブランチ名（`BRANCH`）の各 identifier を引き続き含める

### Requirement 2: Reviewer による差分自己取得手順の提示

**Objective:** As a Reviewer サブエージェント, I want プロンプトから差分取得手順を明示的に受け取りたい, so that Bash ツールで自力で差分を取得してレビュー判定できる

#### Acceptance Criteria

1. The Reviewer Prompt Builder shall プロンプト本文に `git diff --stat ${BASE_BRANCH}..HEAD` を実行して差分概要を取得する旨を明示する
2. The Reviewer Prompt Builder shall プロンプト本文にファイル単位の詳細差分が必要な場合は `git diff ${BASE_BRANCH}..HEAD -- <path>` を実行する旨を明示する
3. The Reviewer Prompt Builder shall 差分取得手順の説明に `BASE_BRANCH` の実値を埋め込んだ形で記載する（reviewer サブエージェントがそのままコピペで実行できる粒度）

### Requirement 3: 既存のレビュー契約・round 制御の維持

**Objective:** As a watcher 運用者, I want Reviewer ステージの出力契約と round 制御を変えずに保ちたい, so that 既稼働のパイプライン（パーサ・差し戻しループ・PjM 起動条件）に影響を与えない

#### Acceptance Criteria

1. The Reviewer Prompt Builder shall プロンプト本文に「最終行は `RESULT: approve` または `RESULT: reject` で終わること」の指示を引き続き含める
2. The Reviewer Prompt Builder shall プロンプト本文に判定カテゴリを「AC 未カバー / missing test / boundary 逸脱」の 3 つに限定する指示を引き続き含める
3. The Reviewer Prompt Builder shall プロンプト先頭で round 番号（`round=1` / `round=2`）と最大 2 round の上限を引き続き提示する
4. The Reviewer Prompt Builder shall round=2 のとき直前ラウンドの結果（`PREV_RESULT`）をプロンプトに引き続き含める
5. The Reviewer Prompt Builder shall プロンプト本文に「requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えない」「`git add` / `git commit` / `git push` / `gh` を実行しない」「style / lint / フォーマット観点では reject しない」の各制約を引き続き含める

### Requirement 4: 後方互換性の維持

**Objective:** As a 既稼働 watcher のユーザー, I want 既存環境がそのまま動き続けてほしい, so that 本変更の取り込みで手元の cron / launchd / consumer repo 設定を直さなくて済む

#### Acceptance Criteria

1. The Reviewer Prompt Builder shall `BASE_BRANCH` / `REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` を含む既存の環境変数名・既定値・参照方法を変更しない
2. The watcher shall Reviewer ステージで使用するラベル（`claude-reviewing` / `claude-failed` 等）の名前・付与/剥がしのタイミングを変更しない
3. The watcher shall exit code の意味（正常 / 処理対象なし / エラー）を変更しない
4. The watcher shall Reviewer 差し戻しループの上限（Reviewer 最大 2 回 / Developer 最大 2 回）を変更しない
5. The watcher shall `~/bin/issue-watcher.sh` を起動する cron 登録文字列を変更しない（インストール側の文言を変えない）

## Non-Functional Requirements

### NFR 1: プロンプトサイズ上限

1. The Reviewer Prompt Builder shall 1 回のプロンプト生成で `claude --print` に渡される引数バイト数を 131,072 B（Linux `MAX_ARG_STRLEN`）未満に抑える
2. The Reviewer Prompt Builder shall 差分ファイル数や差分行数に依存せず、出力バイト数が概ね一定（差分内容を含まないため数 KB 程度）に収まる

### NFR 2: 静的解析

1. When `shellcheck local-watcher/bin/issue-watcher.sh` を実行したとき, the build pipeline shall 本変更によって新規に発生する警告を 0 件にする

### NFR 3: 観測性・互換性確認

1. When `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を対象なし状態で実行したとき, the watcher shall 「処理対象の Issue なし」で正常終了する（既存スモークテストの結果を変えない）
2. When 差分が空の Issue（実体としては発生しない想定だが防御的）に対して Reviewer ステージを起動したとき, the watcher shall Reviewer サブエージェントを起動でき、差分なし状態でも reviewer サブエージェントの自己取得手順により判定可能な状態に到達する

### NFR 4: self-hosting 安全性

1. When 本変更後の `local-watcher/bin/issue-watcher.sh` を idd-claude 自身に対して稼働させたとき, the watcher shall 自身の repo の Issue に対しても Reviewer ステージを起動できる（dogfooding 適合）

## Out of Scope

- prompt を stdin で渡す方式（例: `claude --print < tmpfile`）への移行
- Reviewer 以外のステージ（Triage / Developer / PjM）のプロンプト構造変更
- Reviewer 出力のパーサ（`RESULT:` 行抽出ロジック）変更
- reviewer サブエージェント定義（`.claude/agents/reviewer.md` / `repo-template/.claude/agents/reviewer.md`）の構造変更（差分取得手順との整合を取るための 1 行追記程度の補足は許容するが、判定ルール・出力契約は変えない）
- LaunchDarkly 等の外部 Feature Flag 連携、差分サイズに応じたモデル切替などの新規機能
- diff の要約・トリミング・分割送信などの代替アルゴリズム導入
- `claude` CLI 側の制限緩和や upstream 修正

## Open Questions

- なし（Issue 本文と現行コード（`local-watcher/bin/issue-watcher.sh:2741-2801`）で本要件を確定できる。reviewer サブエージェント定義側の追記要否は design.md にて判断する）
