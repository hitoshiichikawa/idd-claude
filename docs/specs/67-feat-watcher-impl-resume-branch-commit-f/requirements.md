# Requirements Document

## Introduction

`impl-resume` モードはフェイルセーフ設計として毎回 worktree を `origin/main` 起点に強制初期化するため、(A) Reviewer の `claude-failed` 後に人間が手動で PR を作成して再 pickup された場合、(B) Claude Max quota 切れにより途中まで commit 済みで一時停止していた場合、(C) impl-resume の途中で人間が補完 commit を push した直後に再起動された場合の 3 シナリオで、人間 / 既存 Developer が積んだ commit が破棄されたり force-push で orphan 化したりする事故が発生している（PR #62 / #64 が事例）。本機能ではこれらの破壊的挙動を opt-in で抑制し、既存 origin branch を尊重した resume・`tasks.md` 進捗追跡・force-push 抑止と非 fast-forward 検出時の安全停止を導入する。既定値 OFF により既存 install 済みリポジトリ・既存 cron 起動契約・既存 Issue は無改変で従来挙動のまま動作する。

## Requirements

### Requirement 1: opt-in による既存挙動の保全

**Objective:** As a 既存 install 済みリポジトリの運用者, I want 本機能を opt-in でのみ有効化したい, so that 既定では既存 cron / Issue / PR 挙動が一切変化せず移行コストを発生させない

#### Acceptance Criteria

1. While `IMPL_RESUME_PRESERVE_COMMITS` 環境変数が未設定または `false` である間, the Issue Watcher shall `impl-resume` モードの worktree 初期化を本機能導入前と同一の手順（`origin/main` 起点での強制リセット + force-push 系の push）で実行する
2. While `IMPL_RESUME_PRESERVE_COMMITS=true` である間, the Issue Watcher shall 本要件群（Requirement 2 / 3 / 4）で定義する保護的 resume 挙動を有効化する
3. The Issue Watcher shall `IMPL_RESUME_PRESERVE_COMMITS` の受理値を `true` / `false` の 2 値とし、それ以外の値（空文字 / `1` / `True` / 不正値）は `false` と等価に扱う
4. The Issue Watcher shall 既存環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）の意味と受理形式を本変更で改変しない
5. The Issue Watcher shall 既存 cron / launchd 登録文字列を変更しなくても本機能（既定 OFF 状態）が動作する状態を維持する

### Requirement 2: 既存 origin branch を尊重した resume

**Objective:** As a 開発者, I want `impl-resume` モードで対象ブランチが origin に存在するときその commit 履歴を保持したまま resume したい, so that 過去の Developer commit と人間が補完した commit が破棄されない

#### Acceptance Criteria

1. While `IMPL_RESUME_PRESERVE_COMMITS=true` であり、対象 Issue の作業ブランチが origin に既存するとき, the Issue Watcher shall worktree を当該 origin ブランチの先端から resume させ、そこに積まれた既存 commit を保持する
2. While `IMPL_RESUME_PRESERVE_COMMITS=true` であり、対象 Issue の作業ブランチが origin に存在しないとき, the Issue Watcher shall worktree を `origin/main` 起点で初期化して新規 branch として作業を開始する
3. When 既存 origin ブランチからの resume を行うとき, the Issue Watcher shall 「既存 branch から resume 中である」旨を運用者が事後に判別可能な粒度でログに記録する
4. When `impl-resume` モードで Developer サブエージェントを起動するとき, the Issue Watcher shall Developer に対し「既存 commit / 既存 `tasks.md` 進捗を尊重し、未完了タスクから続きを実装する」ことを指示するプロンプトを与える
5. The Issue Watcher shall 既存 origin ブランチからの resume において worktree の untracked / 一時ファイル（commit 未確定の作業状態）を保護対象に含めない

### Requirement 3: tasks.md 進捗追跡

**Objective:** As a 開発者, I want 各タスク完了時点で `tasks.md` の進捗が永続化されること, so that quota 切れ・人間介入・再 pickup 後にどこから再開すべきかが Issue 単位で機械的に判断できる

#### Acceptance Criteria

1. While `IMPL_RESUME_PROGRESS_TRACKING` 環境変数が未設定または `true` である間, the Issue Watcher shall Developer がタスクを完了した時点で `tasks.md` の対応する未完了マーカーを完了マーカーへ更新し、当該変更を作業ブランチに commit する挙動を有効化する
2. While `IMPL_RESUME_PROGRESS_TRACKING=false` である間, the Issue Watcher shall `tasks.md` 進捗マーカーの自動更新を行わない
3. When `impl-resume` モードで再起動された Issue の `tasks.md` に未完了マーカーが残っているとき, the Developer Subagent shall 当該未完了マーカーの先頭タスクから実装を再開する
4. When `impl-resume` モードで再起動された Issue の `tasks.md` に未完了マーカーが残っていないとき, the Developer Subagent shall 全タスク完了済みとして扱い追加の実装を行わない
5. The Issue Watcher shall `tasks.md` 進捗追跡で書き換えるのは進捗マーカー部分のみとし、`_Requirements:_` / `_Boundary:_` / `_Depends:_` などの既存アノテーション・タスク本文・タスク順序を改変しない
6. The Issue Watcher shall `IMPL_RESUME_PROGRESS_TRACKING` の受理値を `true` / `false` の 2 値とし、それ以外の値は `true` と等価に扱う

### Requirement 4: force-push 抑制と非 fast-forward 検出時の安全停止

**Objective:** As a 開発者, I want 既存 commit を含むブランチへの push で force-push を行わず、conflict 検出時は人間判断に委ねたい, so that 人間が手動で積んだ commit を watcher が無告知で上書きすることを防げる

#### Acceptance Criteria

1. While `IMPL_RESUME_PRESERVE_COMMITS=true` であり、`impl-resume` が既存 origin ブランチから resume したとき, the Issue Watcher shall 当該ブランチへの push を fast-forward 制約付きの通常 push として実行し force / `--force-with-lease` 系の上書き push を行わない
2. If `impl-resume` の通常 push が非 fast-forward を理由に拒否されたとき, the Issue Watcher shall 当該 push をリトライせず、当該 Issue を `claude-failed` ラベル付与により人間判断対象として停止する
3. When 非 fast-forward による push 拒否で `claude-failed` 遷移を行うとき, the Issue Watcher shall 当該 Issue にコメントで「自動 force-push を抑制したため停止した」旨と「人間が手動で衝突解消後に `claude-failed` ラベルを除去すること」を投稿する
4. While `IMPL_RESUME_PRESERVE_COMMITS=false` である間, the Issue Watcher shall force-push 抑制の対象外として従来の push 挙動を維持する
5. The Issue Watcher shall 非 fast-forward 検出時の安全停止において、既存 origin ブランチ上の commit と人間が積んだ commit を改変・削除・rebase しない

### Requirement 5: ドキュメント整合と運用者向け説明

**Objective:** As a 既存 install 済みリポジトリの運用者, I want README で本機能の opt-in 手順・新挙動・既存 Issue への影響を確認したい, so that 適用判断と移行手順を README 単独で完結できる

#### Acceptance Criteria

1. The Documentation shall README の Phase C / `impl-resume` 節に `IMPL_RESUME_PRESERVE_COMMITS` / `IMPL_RESUME_PROGRESS_TRACKING` の用途・既定値・有効化方法を追記する
2. The Documentation shall README に opt-in 時の新挙動（既存 origin branch からの resume / `tasks.md` 進捗マーカー更新 / force-push 抑制と `claude-failed` 遷移）を運用者視点で記述する
3. The Documentation shall README に Migration Note として「既定では従来挙動が維持される」「opt-in 後も新規 branch（origin にブランチが無い Issue）は従来通りに初期化される」「進行中 Issue は本変更で中断・再 claim されない」旨を明記する

### Requirement 6: Dogfooding による End-to-End 検証

**Objective:** As a 開発者, I want 本リポジトリ自身で 2 つの代表シナリオが成立することを確認したい, so that 他リポジトリへの展開前に保護機能の挙動破綻を検出できる

#### Acceptance Criteria

1. When 本リポジトリで作業ブランチに途中 commit が積まれた状態（quota 切れ相当）から `IMPL_RESUME_PRESERVE_COMMITS=true` で `impl-resume` が再実行されたとき, the Issue Watcher shall 当該既存 commit を保持したまま未完了タスクから実装を継続する
2. When 本リポジトリで作業ブランチに人間による直接 commit が積まれた状態から `IMPL_RESUME_PRESERVE_COMMITS=true` で `impl-resume` が再実行されたとき, the Issue Watcher shall 非 fast-forward push 拒否を検出し当該 Issue を `claude-failed` 付与で安全停止させる
3. When 上記 dogfooding シナリオを `IMPL_RESUME_PRESERVE_COMMITS=false`（既定）で再実行したとき, the Issue Watcher shall 本機能導入前と同一の挙動（`origin/main` 起点での強制リセット + force-push 系 push）で動作する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall 既定値（`IMPL_RESUME_PRESERVE_COMMITS=false`）下で、本機能導入前にピックアップ済みの Issue・既存 PR・既存 cron 設定が中断・誤遷移・誤完了・誤 fail を起こさない状態を維持する
2. The Issue Watcher shall 既存ラベル `auto-dev` / `claude-claimed` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` の名前・意味・遷移契約を本機能で変更しない
3. The Issue Watcher shall 既存 exit code の意味と既存ログ出力先（`LOG_DIR` 配下）のフォーマット契約を本機能で変更しない

### NFR 2: 観測可能性

1. The Issue Watcher shall `IMPL_RESUME_PRESERVE_COMMITS=true` 下での「既存 origin branch から resume」「新規 branch 初期化」「force-push 抑制による non-ff 検出」の 3 イベントを `LOG_DIR` 配下のログに事後判別可能な粒度で記録する
2. The Issue Watcher shall 非 fast-forward 検出による `claude-failed` 遷移を、運用者がログ単独で原因（force-push 抑制）と対象 Issue 番号を特定できる粒度で記録する

### NFR 3: 静的解析クリーン

1. The Issue Watcher script shall `shellcheck` 実行において新規警告を 0 件に保つ
2. The Workflow YAML（変更が及ぶ場合）shall `actionlint` 実行において新規警告を 0 件に保つ

## Out of Scope

- 人間 commit が混入したブランチに対する自動 merge / 自動 rebase（force-push 抑制と `claude-failed` 遷移で人間判断に委ねる）
- Reviewer 判定段階の resume（review-notes.md の存在チェック以上の retry は #63 範疇）
- Claude Max quota / rate_limit の自動検知と auto-resume 判定（#66 範疇）
- 作業ブランチ上の untracked / commit 未確定ファイルの保護
- 既存ラベル名の rename・廃止
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への本機能の同等導入（local watcher が claim 主体である現設計に対する Actions 版での扱いは別 Issue）
- `IMPL_RESUME_PRESERVE_COMMITS=true` 既定化への移行スケジュールおよび deprecation 期間設計

## Open Questions

- なし（Issue 本文の「未解決の設計論点」3 項目（既存 branch detection の信頼性判定方法 / `tasks.md` 進捗マーカーの format / 強制 fresh フラグの要否）はいずれも Architect 判断事項として委譲する。要件レベルでは「観測可能な挙動契約」のみを Requirement 2〜4 で固定し、検出方式・マーカー記法・追加フラグの有無は design.md で確定する）
