# Requirements Document

## Introduction

idd-claude は現在 `main` を base ブランチとする運用を前提に、watcher スクリプト・workflow YAML・
agent prompt・template ドキュメントの各所に "main" リテラルがハードコードされている。
gitflow 運用（`develop` を integration branch、`main` を本番安定版とするフロー）に移行するには、
base branch を環境変数で差し替え可能にする必要がある。本機能は base branch を表す
`BASE_BRANCH` env var を導入し、watcher 経路と template 経路の双方が同一 env から base を
解決できるようにする。後方互換性を最優先とし、`BASE_BRANCH` 未設定時は従来挙動と完全に等価で
あることを保証する。idd-claude は self-hosting（dogfooding）リポジトリでもあるため、本変更が
merge 後すぐに idd-claude 自身を gitflow で運用しながら auto-dev を継続できることをゴールとする。

## Requirements

### Requirement 1: BASE_BRANCH env による base branch 抽象化（watcher）

**Objective:** As a watcher 運用者, I want `BASE_BRANCH` env var で base branch を切り替えたい, so that gitflow（`develop` 起点）など `main` 以外の base に対しても auto-dev フローを完走させられる

#### Acceptance Criteria

1. When watcher 起動時に `BASE_BRANCH=develop` が cron / launchd から渡された場合, the Watcher Script shall その値を base branch として解決し、以降のすべての git 操作・PR base 指定・prompt 文面の base 参照に使用する
2. When `BASE_BRANCH` が未設定で watcher が起動した場合, the Watcher Script shall base branch として `main` を採用する
3. When watcher が新規 branch を origin から派生させる場合, the Watcher Script shall `origin/$BASE_BRANCH` を起点とする
4. When watcher が per-slot worktree を最新化する場合, the Watcher Script shall 当該 worktree を `origin/$BASE_BRANCH` の最新 commit に強制リセットする
5. When watcher が Reviewer に投入する diff を生成する場合, the Watcher Script shall `$BASE_BRANCH..HEAD` の範囲で diff / log を取得する
6. When watcher が各処理後の安全網として作業ブランチを離れる場合, the Watcher Script shall `$BASE_BRANCH` に checkout し直す
7. The Watcher Script shall 起動時に解決した `BASE_BRANCH` の値を log に出力し、運用者が観測できるようにする

### Requirement 2: MERGE_QUEUE_BASE_BRANCH との連鎖 default

**Objective:** As a watcher 運用者, I want `BASE_BRANCH` だけ設定すれば merge queue も同じ base を使ってほしい, so that 設定箇所の重複を避け、merge queue だけ別 base にしたい超レアケースのみ別 env で上書きできる

#### Acceptance Criteria

1. When `BASE_BRANCH=develop` のみ設定され `MERGE_QUEUE_BASE_BRANCH` が未設定の場合, the Watcher Script shall merge queue の base branch として `develop` を採用する
2. When `BASE_BRANCH` と `MERGE_QUEUE_BASE_BRANCH` の両方が異なる値で設定されている場合, the Watcher Script shall `MERGE_QUEUE_BASE_BRANCH` の値を merge queue の base branch として優先する
3. When `BASE_BRANCH` も `MERGE_QUEUE_BASE_BRANCH` も未設定の場合, the Watcher Script shall merge queue の base branch として `main` を採用する
4. The Watcher Script shall `MERGE_QUEUE_BASE_BRANCH` の env var 名を変更しない

### Requirement 3: workflow YAML の base branch 抽象化

**Objective:** As a GitHub Actions ワークフロー運用者, I want workflow からも base branch を切替可能にしたい, so that local watcher 経路と Actions 経路の双方で同じ gitflow 運用が可能になる

#### Acceptance Criteria

1. When 運用者が GitHub Actions 側で base branch を `develop` に切り替えた場合, the Issue-to-PR Workflow shall checkout / 新規ブランチ作成 / PR base 指定のすべてを `develop` で実行する
2. When 運用者が GitHub Actions 側で base branch を未設定にした場合, the Issue-to-PR Workflow shall 従来どおり `main` を base branch として使用する
3. The Issue-to-PR Workflow shall workflow YAML 内の prompt 文面に登場する base branch 表記を、解決された base branch 値で表示するか、または特定 branch 名に依存しない一般語で表現する
4. The Issue-to-PR Workflow shall 既存の `IDD_CLAUDE_USE_ACTIONS` opt-in gate を変更せず、未 opt-in の repo に新規外部呼び出しを発生させない

### Requirement 4: agent prompt / template の base branch 動的化

**Objective:** As a developer / reviewer / project-manager エージェント, I want prompt 内の base branch 参照が動的に解決されてほしい, so that watcher / Actions のいずれの経路でも、エージェントが正しい base に対する diff・log・PR base を扱える

#### Acceptance Criteria

1. When watcher が developer / reviewer / project-manager の prompt を組み立てる場合, the Prompt Assembly Process shall prompt 内の base branch 参照箇所が解決後の `BASE_BRANCH` 値を反映するよう生成する
2. When エージェントが PR を作成する場合, the Project Manager Agent shall 解決された base branch を PR の base に指定する
3. When エージェントが既存 commit との差分を確認する場合, the Developer / Reviewer Agent shall `$BASE_BRANCH..HEAD` 相当の範囲で diff / log を取得する
4. The Agent Templates shall 任意の base branch（`main` / `develop` / その他）でも、prompt の指示が文意として整合する形式で記述される

### Requirement 5: impl-resume モードの base 追従

**Objective:** As a watcher 運用者, I want impl-resume モードも `BASE_BRANCH` に追従してほしい, so that 設計 PR が `develop` に merge 済みの状態から実装フェーズが正しく resume できる

#### Acceptance Criteria

1. When impl-resume モードが「設計 PR の成果物が base に存在するか」を判定する場合, the Watcher Script shall `$BASE_BRANCH` 上の `docs/specs/<N>-*/` の存在で判定する
2. When impl-resume モードで対象 branch が origin に存在せず新規作成する場合, the Watcher Script shall `origin/$BASE_BRANCH` を起点として branch を作成する
3. The Watcher Script shall `IMPL_RESUME_PRESERVE_COMMITS` の env var 名を変更しない
4. The Watcher Script shall impl-resume 関連の log メッセージにおいて、特定 branch 名 `main` をハードコードせず、解決された `BASE_BRANCH` 値または base branch を指す一般語を使用する

### Requirement 6: ドキュメント整備（migration note）

**Objective:** As a idd-claude / consumer repo の運用者, I want gitflow 運用への切替手順を README から辿りたい, so that `BASE_BRANCH` の有効化方法と、本変更で発生する運用上の注意点を理解できる

#### Acceptance Criteria

1. The README shall `BASE_BRANCH` env var の役割・既定値（`main`）・設定方法（cron / launchd への注入）を記載する
2. The README shall gitflow 運用に切替えるための手順（`develop` ブランチ作成、`BASE_BRANCH=develop` 設定、watcher 再起動）を migration note として記載する
3. The README shall `BASE_BRANCH` と `MERGE_QUEUE_BASE_BRANCH` の関係（後者が前者の default を継ぐ、明示時は merge queue のみ別 base）を表または記述で明示する
4. The Root CLAUDE.md and Repo-Template CLAUDE.md shall 「main への直接 push 禁止」等の特定 branch 名に依存した文言を、base branch を指す一般化した文言に置き換える
5. The README shall self-hosting で `BASE_BRANCH=develop` 運用を開始した後の dogfood 確認手順（test issue が `develop` 起点で PR まで到達することの観測方法）を記載する

### Requirement 7: 既 installed consumer repo の保護

**Objective:** As a 既 installed consumer repo の運用者, I want 本変更が自動的に挙動を変えないでほしい, so that 既存の `main` 起点運用が、何もせずに継続できる

#### Acceptance Criteria

1. When 既 installed consumer repo の運用者が `install.sh` を再実行した場合, the Installer shall consumer repo に配置される template デフォルトとして `main` 相当の従来挙動が選択される構成を保つ
2. When consumer repo が `BASE_BRANCH` を設定していない状態で watcher を実行した場合, the Watcher Script shall 従来と完全に同一の git 操作・PR base 指定・prompt 文面・log メッセージを生成する
3. The Installer shall consumer repo に対して、本変更の有効化（`BASE_BRANCH` 設定）を必須化しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. When `BASE_BRANCH` env var が未設定の状態で watcher を起動した場合, the Watcher Script shall 本変更導入前と git 操作・PR base 指定・prompt 文面・log メッセージのすべてにおいて完全に同一の出力を生成する
2. The Watcher Script shall 既存の env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `MERGE_QUEUE_BASE_BRANCH`, `IMPL_RESUME_PRESERVE_COMMITS` 等）を変更しない
3. The Watcher Script shall 既存の cron / launchd 登録文字列（`~/bin/issue-watcher.sh` 起動方式・引数規約）を変更しない
4. The Watcher Script shall 既存の exit code 意味・ラベル名・ラベル遷移契約を変更しない

### NFR 2: 冪等性とセットアップ安全性

1. When 運用者が `install.sh` または `setup.sh` を再実行した場合, the Installer shall 既存の watcher / template 配置に対して破壊的変更を行わない
2. The Installer shall sudo を要求しないユーザースコープの操作のみで完了する

### NFR 3: dogfood 安全性（段階的移行）

1. When 本変更を含む PR が idd-claude 自身に merge された直後, the Self-Hosted Watcher shall `BASE_BRANCH` 未設定（=`main`）のままで停止せず動作を継続する
2. When idd-claude 自身に `develop` ブランチが未作成の状態で `BASE_BRANCH=develop` を誤って設定した場合, the Watcher Script shall 異常を log で観測可能にし、サイレントに不正な branch 操作を行わない

### NFR 4: 観測可能性

1. The Watcher Script shall 起動時に解決した base branch 値を log に出力する
2. The Watcher Script shall base branch 関連の git 操作（worktree reset / branch 派生 / diff 生成）失敗時に、失敗した操作と base branch 値が運用者に判別できる log を出力する

## Out of Scope

- gitflow の release branch（`release/x.y.z`）の自動作成・運用
- `develop` → `main` の自動 merge / tag リリース / 本番デプロイ通知 / Slack 連携
- PR base に応じた自動ラベル付与（例: `base:develop` の付与）
- consumer repo 側で `BASE_BRANCH` を切替するための支援ツールや `install.sh` への env 設定支援機能の追加
- `MERGE_QUEUE_BASE_BRANCH` のリネーム・廃止（後方互換のため温存）
- `BASE_BRANCH` を base branch 以外の用途（例: PR の head branch prefix 制御）に転用すること
- 複数 base branch を同時並行で扱う運用（1 watcher プロセスは 1 base branch を前提とする）

## Open Questions

以下は requirements 段階では確定しない、design.md / Architect が決定すべき項目:

- workflow YAML 側の base branch 注入方法（repository variable `${{ vars.IDD_CLAUDE_BASE_BRANCH }}` / workflow_dispatch input / その他）の選定
- agent prompt 文面の base branch 解決方式（watcher 側の文字列置換 / `{{BASE_BRANCH}}` placeholder 展開 / 一般語化のいずれを採用するか、または併用するか）
- README の migration note の置き場所（既存「セットアップ」節への追記 vs 新規「ブランチ運用」節の新設）
- self-hosting 用 `develop` ブランチの作成タイミング（README 手順書記載のみ vs `setup.sh` への自動化）。後者を採るかは別 Issue 化が妥当かを含めて判断
- prompt 文面で「base ブランチ」と一般語化する場合、ユーザー（PM / Architect / Developer / Reviewer agent）にとって誤読を生まない訳語の選定
