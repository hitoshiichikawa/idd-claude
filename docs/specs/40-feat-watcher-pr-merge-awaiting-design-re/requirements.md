# Requirements Document

## Introduction

設計 PR ゲート（#1 / #2）で導入された 2 PR フローでは、設計 PR を merge した後に
人間が Issue から `awaiting-design-review` ラベルを手動で除去する必要がある。この手動
ステップは PR merge 直後に忘れやすく、結果として watcher が当該 Issue を永久に pickup
できないまま放置される事故が #36 / #20 / #26 で実害として観測された。PR #39 で
ドキュメント側の文言修正は入ったが、忘却そのものを防ぐ手段にはなっていない。

本機能は watcher の cron tick 冒頭に **Design Review Release Processor** を新設し、
リンクされた設計 PR が merged 状態である `awaiting-design-review` 付き Issue を検出して
自動的にラベルを除去し、状況コメントを 1 件投稿する。既存運用への影響を避けるため
opt-in（既定無効）とし、Phase A merge queue / Phase A re-check / PR iteration と同じ
flock 内で直列実行する。既存 env / ラベル / cron 登録文字列の契約は維持する。

## Requirements

### Requirement 1: 起動条件と opt-in gate

**Objective:** As an existing watcher user, I want Design Review Release Processor を環境変数で無効化できるようにしたい, so that 安定運用中の cron / launchd 環境に破壊的変更を与えず段階的に opt-in できる

#### Acceptance Criteria

1. While `DESIGN_REVIEW_RELEASE_ENABLED` 環境変数が `true` に設定されていない, the Issue Watcher shall Design Review Release Processor を起動しない
2. The Issue Watcher shall `DESIGN_REVIEW_RELEASE_ENABLED` のデフォルト値を `false` として扱う
3. While watcher サイクルが開始した直後、リポジトリ最新化が完了した状態で, the Issue Watcher shall ピックアップ済み Issue の処理ループに入る前に Design Review Release Processor を 1 回起動する
4. Where Design Review Release Processor が無効化されている, the Issue Watcher shall 本機能導入前と完全に一致する Issue / PR 処理フローのみを実行する
5. The Issue Watcher shall Design Review Release Processor を既存の watcher 多重起動防止ロック（`LOCK_FILE`）と同じ排他境界内で起動し、Phase A Merge Queue Processor / Merge Queue Re-check Processor / PR Iteration Processor と直列実行する

### Requirement 2: 対象 Issue の検出範囲

**Objective:** As a watcher operator, I want `awaiting-design-review` 付きで、かつ idd-claude が作成した設計 PR が merge された Issue だけを対象にしたい, so that 人間が手動で運用している Issue や、設計 PR 以外を起点にした PR との誤マッチを防げる

#### Acceptance Criteria

1. The Design Review Release Processor shall 対象 repo の open Issue のうち `awaiting-design-review` ラベルが付いているものを処理候補として列挙する
2. The Design Review Release Processor shall 各候補 Issue について、当該 Issue にリンクされた PR を GitHub から取得する
3. The Design Review Release Processor shall 取得した PR のうち head branch 名が head branch pattern（`DESIGN_REVIEW_RELEASE_HEAD_PATTERN`、デフォルト `^claude/issue-[0-9]+-design-`）に合致するものだけを評価対象とする
4. The Design Review Release Processor shall 評価対象 PR のうち少なくとも 1 件が merged 状態である Issue を、ラベル除去対象として確定する
5. If 候補 Issue にリンクされた PR が 1 件も取得できない, the Design Review Release Processor shall 当該 Issue をラベル除去対象から除外する
6. If 評価対象 PR の中に merged 状態のものが 1 件もない, the Design Review Release Processor shall 当該 Issue のラベルを変更しない
7. If 候補 Issue に `claude-failed` または `needs-decisions` ラベルが併存している, the Design Review Release Processor shall 当該 Issue をラベル除去対象から除外する

### Requirement 3: ラベル除去とステータスコメント投稿

**Objective:** As a developer, I want 設計 PR merge 後数分以内に Issue が impl-resume モードで自動再開されることを確認したい, so that 手動でラベルを外す操作を忘れても次回 cron tick で開発が再開される

#### Acceptance Criteria

1. When ラベル除去対象として確定した Issue を処理する, the Design Review Release Processor shall 当該 Issue から `awaiting-design-review` ラベルを除去する
2. When `awaiting-design-review` ラベルの除去が成功した, the Design Review Release Processor shall 当該 Issue に対してステータスコメントを 1 件投稿する
3. The Design Review Release Processor shall ステータスコメントに、検出した merged 設計 PR の番号と、次回 cron tick で Developer が impl-resume モードで自動起動する旨を含める
4. If `awaiting-design-review` ラベル除去 API がエラーを返した, the Design Review Release Processor shall watcher ログに WARN レベル相当で原因を記録し、当該 Issue へのステータスコメント投稿は行わず、後続 Issue の処理を継続する
5. If ステータスコメント投稿 API がエラーを返した, the Design Review Release Processor shall watcher ログに WARN レベル相当で原因を記録し、後続 Issue の処理を継続する
6. The Design Review Release Processor shall ラベル除去とコメント投稿以外の副作用（再 pickup の即時起動、Developer の即時呼び出し、PR 側へのコメント / ラベル操作等）を行わない

### Requirement 4: 冪等性と人間運用との共存

**Objective:** As an operator, I want 自動除去機能と既存の人間による手動ラベル除去運用が同一 repo 上で同時に動作しても、二重コメント / 二重ラベル除去 / 既処理 Issue への誤動作が起きないことを保証したい, so that 段階的な opt-in や運用切り替え期に Issue 履歴がノイズで埋まらない

#### Acceptance Criteria

1. If 候補 Issue に `awaiting-design-review` ラベルが既に付いていない（人間が先に除去済み）, the Design Review Release Processor shall 当該 Issue に対してラベル除去 API を呼ばず、コメントも投稿しない
2. If 候補 Issue に Design Review Release Processor が以前のサイクルで投稿したステータスコメントが既に存在する, the Design Review Release Processor shall 同等内容のステータスコメントを再投稿しない
3. The Design Review Release Processor shall 既処理 Issue を判定する手段（コメント本文中のマーカー文字列、hidden HTML コメント、もしくは同等の観測可能な記録）を備える
4. When 同一 watcher サイクル内で同一 Issue が候補として 2 回以上挙がった場合, the Design Review Release Processor shall 当該 Issue に対するラベル除去とコメント投稿を 1 回までに制限する
5. The Design Review Release Processor shall 人間が `awaiting-design-review` を手動除去した Issue に対する追加操作（後追いコメント等）を一切行わない

### Requirement 5: 実行コスト・タイムバジェット

**Objective:** As a watcher operator, I want Design Review Release Processor が watcher の通常実行間隔に収まる範囲で完了することを保証したい, so that 後続の Phase A 本体ループ・Phase A re-check・PR Iteration・Issue 処理ループが遅延せず、cron / launchd の重複起動も発生しない

#### Acceptance Criteria

1. The Design Review Release Processor shall 1 サイクルあたりに処理する Issue 数の上限値を、環境変数 `DESIGN_REVIEW_RELEASE_MAX_ISSUES` で上書き可能とし、デフォルト値を `10` とする
2. If 上限を超える候補 Issue が存在する, the Design Review Release Processor shall 残りの Issue を次回サイクルに持ち越し、watcher ログにスキップ件数（overflow）を記録する
3. The Design Review Release Processor shall 1 Issue あたりの GitHub API 呼び出し回数を、リンク済 PR 取得・ラベル除去・コメント投稿（必要時のみ）の合計で 5 回以内に抑える
4. The Design Review Release Processor shall サイクル中の各 GitHub API 呼び出しに対して、無限待機を避けるためのタイムアウト制御を適用する
5. If いずれかの Issue 処理がタイムアウトに達した, the Design Review Release Processor shall 当該 Issue の操作を中断し、watcher ログに WARN を出して次の Issue の処理に進む

### Requirement 6: ロギングと可観測性

**Objective:** As a watcher operator, I want Design Review Release Processor の判断とラベル除去結果をログから追えるようにしたい, so that 自動除去の挙動を検証し、想定外の Issue が誤って自動再開されていないか監査できる

#### Acceptance Criteria

1. The Design Review Release Processor shall サイクル開始時に「対象候補 Issue 件数」「実際に処理する件数」「上限超過件数（overflow）」をログに出力する
2. The Design Review Release Processor shall 各 Issue ごとに「Issue 番号」「検出した merged 設計 PR 番号（もしくは未検出の旨）」「実施したアクション（label removed + commented / kept / skip）」を 1 行以上のログに出力する
3. The Design Review Release Processor shall サイクル終了時に「ラベル除去成功数」「対象外（merged PR 未検出）数」「skip 数（既処理含む）」「失敗数」のサマリをログに出力する
4. The Design Review Release Processor shall 自身が出力するすべての判定・サマリログ行に `design-review-release:` プレフィックスを付与し、operator が grep で集計できるようにする
5. The Design Review Release Processor shall ログのタイムスタンプ書式を Issue Watcher と統一する（`[YYYY-MM-DD HH:MM:SS]` 相当）
6. The Design Review Release Processor shall ログの出力先を既存 watcher の `LOG_DIR` 配下に統一し、新規の出力ディレクトリを作らない
7. The Design Review Release Processor shall 標準エラー出力には人間向けの WARN/ERROR のみを出し、標準出力は機械可読な集計用に予約する

### Requirement 7: 後方互換性

**Objective:** As an existing watcher user, I want 本機能の導入によって既稼働の cron / launchd / GitHub ラベル運用が壊れないことを保証したい, so that 既存環境を停止せずに段階的に opt-in できる

#### Acceptance Criteria

1. The Issue Watcher shall 既存の環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `MERGE_QUEUE_ENABLED`, `MERGE_QUEUE_RECHECK_ENABLED`, `MERGE_QUEUE_MAX_PRS`, `MERGE_QUEUE_GIT_TIMEOUT`, `MERGE_QUEUE_BASE_BRANCH`, `MERGE_QUEUE_HEAD_PATTERN`, `PR_ITERATION_ENABLED` 等）の意味とデフォルト挙動を変更しない
2. The Issue Watcher shall 既存ラベル（`auto-dev`, `claude-picked-up`, `awaiting-design-review`, `ready-for-review`, `claude-failed`, `needs-decisions`, `skip-triage`, `needs-rebase`, `needs-iteration`）の名前・意味・付与契約を変更しない
3. The Issue Watcher shall 既存の lock ファイルパス・ログ出力先・watcher の exit code の意味を変更しない
4. The Issue Watcher shall 既存の cron / launchd 登録文字列（`$HOME/bin/issue-watcher.sh` の起動行）が本機能導入後も書き換え不要のまま動作するようにする
5. Where `DESIGN_REVIEW_RELEASE_ENABLED=false`, the Issue Watcher shall 本機能のコードパスを完全にスキップし、本機能導入前と一致する挙動で動作する
6. The Design Review Release Processor shall ラベル除去主体として動作し、`awaiting-design-review` ラベルの付与（PjM の責務）を行わない

### Requirement 8: ドキュメント更新（DoD）

**Objective:** As a new operator, I want 本機能の挙動・有効化方法・既存手動運用との関係を README から読み取れるようにしたい, so that 既存ユーザが本機能の opt-in 可否を即判断でき、PjM テンプレートの案内文と挙動が一致する

#### Acceptance Criteria

1. The README.md shall Design Review Release Processor の概要（目的・対象・タイミング・既存手動運用との並存）を記述するセクションを含む
2. The README.md shall 本機能の有効化／無効化を制御する環境変数 `DESIGN_REVIEW_RELEASE_ENABLED` / `DESIGN_REVIEW_RELEASE_MAX_ISSUES` / `DESIGN_REVIEW_RELEASE_HEAD_PATTERN` の名称・デフォルト値・推奨値を明記する
3. The README.md shall 本機能導入による後方互換性方針（既存 env / ラベル / lock / exit code / cron 登録文字列が不変であること、`DESIGN_REVIEW_RELEASE_ENABLED=false` で完全に従来挙動になること）を migration note として明記する
4. The PjM agent template（`repo-template/.claude/agents/project-manager.md`）shall 設計 PR merge 後の案内文に、本機能が有効化されている場合は手動ラベル除去が不要である旨の注記を追加する
5. The README.md shall 設計 PR ゲート節に、本機能導入後の状態遷移（merge → 自動ラベル除去 → 次回 cron tick で impl-resume 起動）を反映する

## Non-Functional Requirements

### NFR 1: パフォーマンス

1. The Design Review Release Processor shall 通常ケース（候補 Issue 0〜3 件）の処理を、watcher の最短実行間隔（README 既定 2 分）の 1/4（30 秒）以内に完了する
2. The Design Review Release Processor shall 上限値 `DESIGN_REVIEW_RELEASE_MAX_ISSUES` 件をフルに処理した場合でも、watcher の最短実行間隔の半分（60 秒）以内に完了することを目指す

### NFR 2: 安全性

1. The Design Review Release Processor shall リモートに対する破壊的操作（PR 側のラベル変更、PR への commit / push、Issue / PR の close）を行わず、対象 Issue に対する `awaiting-design-review` ラベルの除去とステータスコメント投稿のみを副作用として持つ
2. If 対象 Issue にリンクされた PR の merge 状態判定が確定しない（取得失敗、不明値）, the Design Review Release Processor shall ラベル除去を行わず、当該 Issue を次回サイクルに持ち越す
3. The Design Review Release Processor shall `main` ブランチや任意の repo branch に対する push / 書き込みを一切行わない

### NFR 3: 観測可能性

1. The Design Review Release Processor shall 各 Issue への操作結果（label removed + commented / kept / skip / fail）を operator がログを grep するだけで集計できる識別語（`design-review-release:` プレフィックス）でマークする
2. The Design Review Release Processor shall サイクル開始ログ・各 Issue 判定ログ・サマリログのいずれにおいても、Phase A 本体（`merge-queue:`）・Phase A re-check（`merge-queue-recheck:`）・PR Iteration の各プロセッサとは異なる識別子を使用する

## Out of Scope

- 設計 PR が close（merge せずに却下）された場合の Issue 側ラベル処理
- 設計 PR 以外の PR と Issue ラベルの自動連動
- 設計 PR 内の review comment を起点とした iteration（#26 PR Iteration の領分）
- リンクされた PR が複数ある場合の優先度ロジック（1 件以上 merged で除去対象とする）
- ラベル除去後の Developer 即時起動（次回 cron tick の通常 pickup フローに委ねる）
- Issue へリンクされた PR を検出するための GraphQL / REST API 選択（実装詳細として design に委ねる）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への本機能の組み込み
- `DESIGN_REVIEW_RELEASE_MAX_ISSUES` 上限超過時の優先度付け（古い Issue / 古いラベル付与順 等）
- Reviewer サブエージェント（#20）が出した review コメントへの自動対応

## Open Questions

- なし（Issue #40 本文の DoD・動作仕様・環境変数定義に従って閉じた要件として記述。検出方式 (a)/(b)/(c) の選択は設計詳細として Architect に委ねる）
