# Requirements Document

## Introduction

idd-claude の PR Iteration Processor (#26 / #35) は、`needs-iteration` ラベル付き PR を fresh
context の Claude で反復対応する仕組みである。現行仕様では、PR 本体の Conversation タブに
投稿される一般コメント（general comment）のうち **`@claude` mention を含むコメントだけ**を
Claude へ渡す prompt（`{{GENERAL_COMMENTS_JSON}}`）に積んでいる。この制約により、PR #53
のレビュー反復で人間レビュワーが mention なしで残した 2 件の指摘が prompt に含まれず、
Claude が「コメントなし」として何もせずに `ready-for-review` へ遷移してしまう事故が発生した。

本機能は、impl 用 / design 用の双方の iteration prompt template と watcher の
`pi_build_iteration_prompt` から `@claude` mention 必須の制約を撤廃し、**当該 PR の一般コメントを
原則すべて Claude に渡す**。誤発火を防ぐため、watcher 自身の自動投稿コメントと「過去 round で
すでに対応済みのコメント」は除外する。`PR_ITERATION_ENABLED` / `PR_ITERATION_DESIGN_ENABLED` の
opt-in 構造、ラベル遷移契約、hidden round marker、`PR_ITERATION_HEAD_PATTERN` 等の既存環境変数
は変更しない（後方互換性）。

## Glossary

- **line comment**: PR の特定ファイル・特定行に紐づくレビューコメント
  （`/repos/.../pulls/<n>/reviews/<id>/comments`）。本要件では既存挙動を変更しない
- **general comment**: PR の Conversation タブに投稿される、行に紐づかない一般コメント
  （`/repos/.../issues/<n>/comments`）。本要件のスコープ
- **round**: 1 PR に対する自動 iteration の試行回数。PR body の hidden marker
  `<!-- idd-claude:pr-iteration round=N last-run=ISO8601 -->` で記録される
- **iteration**: 1 round 内で fresh context の Claude を 1 回起動し、line / general コメントに
  応答する一連の処理（`pi_run_iteration` で表現される単位）
- **watcher 自身の自動投稿コメント**: PR Iteration Processor が round 開始時に投稿する
  着手表明コメント（hidden marker `<!-- idd-claude:pr-iteration-processing round=N -->` を含む）、
  およびエスカレーション時に Processor 名義で投稿するコメントの総称
- **PR Iteration Processor**: watcher (`local-watcher/bin/issue-watcher.sh`) の
  `process_pr_iteration` / `pi_*` 関数群および iteration prompt template から構成される
  サブシステム。本要件における主要 subject

## Requirements

### Requirement 1: 一般コメントの既定対象範囲

**Objective:** As a 人間レビュワー, I want PR の Conversation タブに投稿した一般コメントが
mention の有無に関わらず Claude の iteration prompt に届くこと, so that レビュー指摘が
silent に取りこぼされて自動 iteration が空回りする事故を再発させない。

#### Acceptance Criteria

1. When PR Iteration Processor が `needs-iteration` ラベル付き PR の一般コメントを収集する場合, the PR Iteration Processor shall 当該 PR の一般コメントを mention の有無で篩い分けせず原則すべて prompt の `{{GENERAL_COMMENTS_JSON}}` に積む
2. The PR Iteration Processor shall `@claude` mention の有無に応じて一般コメントを採用 / 不採用に切り替える特別扱いを一切行わない
3. The impl 用 iteration prompt template shall 一般コメント節の見出し・説明文から「`@claude` mention 付き」という限定文言を排除する
4. The design 用 iteration prompt template shall 一般コメント節の見出し・説明文から「`@claude` mention 付き」という限定文言を排除する
5. When 当該 PR に一般コメントが 1 件も存在しない場合, the PR Iteration Processor shall 空配列 `[]` を `{{GENERAL_COMMENTS_JSON}}` に展開する
6. When `{{GENERAL_COMMENTS_JSON}}` に 1 件以上の一般コメントが含まれる場合, the iteration prompt template shall 各コメントについて「精読し、対応すべきと判断したものに対して修正 commit または返信を行う」ことを Claude へ責務として明示する

### Requirement 2: 誤発火を防ぐ除外要件

**Objective:** As a 運用者, I want watcher 自身の自動投稿や前 round で既に処理されたコメントが
Claude へ再度渡されないこと, so that 自己ループ（自分自身に返信する）や同一指摘への二重対応で
混乱や `claude-failed` 誤遷移を引き起こさない。

#### Acceptance Criteria

1. When 一般コメントを収集する場合, the PR Iteration Processor shall watcher 自身の自動投稿コメント（着手表明コメント・エスカレーションコメント等の Processor 名義の投稿）を `{{GENERAL_COMMENTS_JSON}}` から除外する
2. When 同一 PR に対して 2 回目以降の round が起動された場合, the PR Iteration Processor shall 直前の round 時点で既に存在し対応済みと判定できる一般コメントを `{{GENERAL_COMMENTS_JSON}}` から除外する
3. The 「対応済みと判定できる」境界 shall PR body の hidden round marker（`idd-claude:pr-iteration round=N last-run=<ISO8601>`）の `last-run` タイムスタンプより前に作成された一般コメントを「過去 round で既に Claude に提示済み」とみなす形で定義される
4. When PR が初回 round（既存 hidden marker なし）の状態で iteration を開始する場合, the PR Iteration Processor shall 「過去 round で対応済み」を理由とした除外を一切行わず、すべての一般コメントを候補に残す（除外は Requirement 2.1 のみ適用）
5. When 同一 round 内で fresh context の Claude が起動される場合, the PR Iteration Processor shall 当該 round 開始時点までに収集された一般コメントを 1 度だけ prompt に渡し、同一 round 内での再評価は行わない
6. If GitHub API がシステム由来の自動コメント（PR を close / reopen した等の event-style コメント）を返した場合, the PR Iteration Processor shall それらを一般コメントとしては扱わず `{{GENERAL_COMMENTS_JSON}}` から除外する
7. The 除外判定 shall コメント本文中の `@claude` 文字列の有無に依存せず、Requirement 2.1 / 2.2 / 2.6 の条件のみで決定される

### Requirement 3: 大量コメント時のコンテキスト保護

**Objective:** As a 運用者, I want 50 件を超えるような大量の一般コメントが付いた PR でも
iteration prompt がコンテキストを圧迫してターン上限超過や Claude の沈黙を引き起こさないこと,
so that レアケースでも自動 iteration が機械的に失敗せず、観測できる形で縮退する。

#### Acceptance Criteria

1. While 当該 PR の対象一般コメント件数が大量で prompt のコンテキストを圧迫する恐れがある場合, the PR Iteration Processor shall コメント全文をそのまま全件積むのではなく、コンテキスト圧迫を防ぐための削減手段（件数上限・新しい順への絞り込み・本文 truncate のいずれか、または組み合わせ）を適用する
2. When Requirement 3.1 の削減手段が発動した場合, the PR Iteration Processor shall 削減が発生した事実（何件中何件を採用したか、および truncate の有無）を watcher の WARN ログに 1 行で出力する
3. When Requirement 3.1 の削減手段が発動した場合, the iteration prompt shall 「対象コメントの一部のみが提示されている」旨と「未提示のコメントへの対応は次 round 以降または人間レビュワーに委ねられる」旨を Claude が読み取れる形で含める
4. The PR Iteration Processor shall 削減手段が発動しない通常ケース（コメント件数が上限以下）において、すべての対象一般コメントを欠落・truncate なしに prompt に渡す

### Requirement 4: 既存ラベル遷移と round カウンタの維持

**Objective:** As a 運用者, I want コメントフィルタを緩和した後も既存の round カウンタ仕様 / ラベル
遷移契約 / opt-in 環境変数が変わらないこと, so that 既稼働の cron / launchd / consumer repo を
壊さずに本変更を取り込める。

#### Acceptance Criteria

1. The PR Iteration Processor shall PR body の hidden round marker（`idd-claude:pr-iteration round=N last-run=ISO8601`）形式・更新タイミング・読み取りキー名を従来どおり維持する
2. The PR Iteration Processor shall `needs-iteration` → `ready-for-review`（impl PR 成功時）／`needs-iteration` → `awaiting-design-review`（design PR 成功時）／`needs-iteration` → `claude-failed`（round 上限到達時）のラベル遷移契約を従来どおり維持する
3. The PR Iteration Processor shall `PR_ITERATION_ENABLED=false`（既定）の状態では本機能のコードパスを完全に skip し、Issue 処理フローを導入前と同一に保つ
4. The PR Iteration Processor shall `@claude` mention 必須を opt-out で復活させるための新規環境変数を追加しない
5. The PR Iteration Processor shall 着手表明コメントに含める hidden marker `idd-claude:pr-iteration-processing round=N` の文字列形式を従来どおり維持する
6. The PR Iteration Processor shall `PR_ITERATION_HEAD_PATTERN` / `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_DESIGN_HEAD_PATTERN` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_MAX_TURNS` / `PR_ITERATION_MAX_PRS` / `PR_ITERATION_GIT_TIMEOUT` / `ITERATION_TEMPLATE` / `ITERATION_TEMPLATE_DESIGN` の名前・既定値・意味を変更しない

### Requirement 5: ドキュメント更新義務

**Objective:** As a 運用者 / consumer repo の maintainer, I want 「対象コメントの範囲が変わった」
ことが README と PjM agent / repo-template の両方に明示されていること, so that レビュワーが
mention なしで指摘してよいか迷わずに済み、template 配布先 repo の運用も整合する。

#### Acceptance Criteria

1. The README shall PR Iteration Processor 節（および設計 PR 拡張節）から「`@claude` mention 付き general コメント」を対象とする旨の記述を削除し、「PR Conversation タブの一般コメントを原則すべて対象とする」旨に書き換える
2. The README shall watcher 自身の自動投稿が除外される旨と、過去 round で対応済みのコメントが除外される旨を「対象コメント」節として記述する
3. The repo-template の Project Manager agent ドキュメント（`repo-template/.claude/agents/project-manager.md`）shall 設計 PR ガイダンス内の「`@claude` mention 付き general コメント」文言を、Requirement 1 / 2 と整合する説明に書き換える
4. The README shall 本変更で破壊的影響が無い旨（既存 env var / ラベル / cron 登録文字列を壊さない旨）を、後方互換性ポリシー節と整合する形で言及する
5. When ドキュメント更新と watcher / template 実装が同一 PR に含まれない場合, the Project Manager shall 当該 PR を merge 候補としない（README / PjM agent / template と watcher 挙動の二重管理を許容しない）

### Requirement 6: impl PR / design PR 双方での一貫性

**Objective:** As a Claude 実行エージェント, I want impl 用と design 用の iteration prompt が
一般コメントの取り扱いについて同じ規約で書かれていること, so that branch kind による分岐で
レビュワー体験や採用ロジックが食い違わず、混乱しない。

#### Acceptance Criteria

1. The impl 用 iteration prompt template と design 用 iteration prompt template shall 一般コメント節について同一の対象範囲（Requirement 1）と同一の除外規約（Requirement 2）を提示する
2. The PR Iteration Processor shall impl PR / design PR のどちらに対する iteration でも `{{GENERAL_COMMENTS_JSON}}` の生成ロジックを共通化し、kind による条件分岐で対象範囲を変えない
3. When design PR に対する iteration が実行される場合, the design 用 iteration prompt shall 一般コメントへの返信先（同一 PR の一般コメントとして投稿する旨）と編集許容スコープ（`{{SPEC_DIR}}` 配下のみ）の既存規約を引き続き保持する
4. When impl PR に対する iteration が実行される場合, the impl 用 iteration prompt shall 一般コメントへの返信先（同一 PR の一般コメントとして投稿する旨）と既存の commit / push / 返信規約を引き続き保持する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Iteration Processor shall 本変更後も既存環境変数（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `PR_ITERATION_*`, `ITERATION_TEMPLATE*`, `LABEL_*`）の名前・既定値・意味を変更せずに動作する
2. The PR Iteration Processor shall 既存の exit code 規約（0=成功 / 1=失敗 / 2=エスカレ / 3=skip）と watcher ログの 1 行サマリ形式（`pr-iteration: サマリ: success=N, fail=N, skip=N, escalated=N, overflow=N (design=N, impl=N)`）を維持する
3. The PR Iteration Processor shall 既稼働の cron / launchd 登録文字列（`PR_ITERATION_ENABLED=true` 等の env を渡す形）を変更しない
4. The repo-template 配下のラベルセット（`needs-iteration` / `ready-for-review` / `awaiting-design-review` / `claude-failed` 等）shall 名前・色・意味を変更しない

### NFR 2: 観測性

1. When 一般コメントの除外が発生した場合, the PR Iteration Processor shall 除外件数および除外理由カテゴリ（自己投稿除外 / 過去 round 対応済み除外 / システムコメント除外 / 大量コメント削減）が運用者にとって追跡可能な形で watcher ログに記録される
2. The PR Iteration Processor shall 1 round の実行ログから「対象一般コメント件数」「除外件数」「prompt に積んだ最終件数」を後追いで把握できる粒度で出力する

### NFR 3: 静的解析・スモークテスト

1. The watcher 実装変更 shall `shellcheck local-watcher/bin/*.sh` を警告ゼロでクリアする
2. The iteration prompt template 変更 shall watcher の placeholder 展開（`{{GENERAL_COMMENTS_JSON}}` 等）を従来どおり機能させ、dry run（`REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh`）が「処理対象の Issue なし」で正常終了する
3. The 受入確認 shall PR #53 の事故ケース（mention なし general コメント 2 件 + `needs-iteration` 付与）と等価な dogfood テストを再現し、本変更後に当該コメントが Claude へ渡されることを確認する

## Out of Scope

- line comment（行コメント）の取り扱い変更（既存 `{{LINE_COMMENTS_JSON}}` の収集ロジックは対象外）
- review submission 本体の summary text の取り込み
- mention によらない PR Iteration の有効化条件（`PR_ITERATION_ENABLED` opt-in 構造）の変更
- `@claude` mention 必須挙動を opt-out で復活させるための新規環境変数の追加
- 大量コメント時の削減アルゴリズムの具体仕様（件数上限の数値・truncate 方式・優先度ロジック等）— 本要件では「圧迫しない手段を取ること」のみ規定し、選択は `design.md` の領分
- watcher 自己投稿の検出方法（marker ベース vs author ベース）— 本要件は除外という観測可能な
  挙動のみ規定し、判定アルゴリズムは `design.md` の領分
- 「過去 round 対応済み」の判定ロジック（`last-run` TS 比較 vs reaction ベース vs reply 有無）—
  本要件は観測可能な除外義務のみ規定し、判定アルゴリズムは `design.md` の領分
- 設計 PR の Reviewer エージェント連携（impl 系限定の現状仕様を踏襲、本要件で変更しない）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`、`IDD_CLAUDE_USE_ACTIONS=true` opt-in 経路）への反映 — 本要件は local watcher 経路に閉じる

## Open Questions

- なし（Issue 本文で「Architect が着手時に決定する 4 論点」として整理された項目は、本要件では
  observable な義務として記述し、判定アルゴリズム自体は意図的に design に委ねている。
  Issue 本文と既存コメント（watcher 自身の自動コメント 1 件のみで人間追記なし）から、
  人間判断を要する未解決事項は無いと判断）
