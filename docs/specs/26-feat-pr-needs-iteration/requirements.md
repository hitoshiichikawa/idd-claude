# Requirements Document

## Introduction

idd-claude の watcher は Issue → PR 作成までを自動化するが、**PR が `ready-for-review`
に到達した後の人間レビューに基づく修正サイクル**は手動で Claude Code を立ち上げ直す運用
になっている。人間は PR のレビューコメントを残し `needs-iteration` ラベルを付けるだけで済み、
watcher が次サイクルでそれを検知して Claude「PR iteration モード」を fresh context で起動し、
レビューコメントを読み込み → 修正 commit を PR branch に push → 各レビュースレッドに返信
→ ラベルを `ready-for-review` に戻す、という反復開発ループを閉じることを狙いとする。
本フェーズは opt-in（デフォルト無効）で導入し、既存 watcher ユーザの挙動を一切変えないこと
を最優先とする。Phase A (#14) の merge queue 処理との競合制御、および `PR_ITERATION_MAX_ROUNDS`
超過時の無限ループ防止もスコープに含む。

## Requirements

### Requirement 1: 反復対象 PR の検知範囲

**Objective:** As a watcher operator, I want `needs-iteration` ラベルが付いた PR のうち idd-claude 管理下のものだけを反復対象にしたい, so that 人間が手書きした PR や fork PR、終端状態の PR に意図しない自動 commit / push が走らない

#### Acceptance Criteria

1. While PR Iteration Processor が有効化されている, the Issue Watcher shall watcher サイクル内で `needs-iteration` ラベル付きの open PR を検索する
2. If 対象 PR の head branch 名が PR Iteration Processor の head branch pattern（デフォルト `^claude/`）に合致しない, the PR Iteration Processor shall その PR を対象から除外する
3. If 対象 PR の head repo owner が base repo owner と異なる（= fork からの PR）, the PR Iteration Processor shall その PR を対象から除外する
4. If 対象 PR が draft 状態である, the PR Iteration Processor shall その PR を対象から除外する
5. If 対象 PR に `claude-failed` ラベルが付いている, the PR Iteration Processor shall その PR を対象から除外する
6. The PR Iteration Processor shall 1 サイクルあたりに処理する PR 数の上限値（環境変数で上書き可能、デフォルト 3 件）を持ち、上限を超える分は次回サイクルに持ち越す

### Requirement 2: 機能の opt-in gate と環境変数

**Objective:** As an existing watcher user, I want PR iteration 機能を環境変数で無効化できるようにしたい, so that 安定運用中の cron / launchd 環境に破壊的変更を与えず段階的に opt-in できる

#### Acceptance Criteria

1. While PR Iteration Processor の有効化フラグ（環境変数 `PR_ITERATION_ENABLED`）が `true` に設定されていない, the Issue Watcher shall PR Iteration Processor を起動しない
2. Where PR Iteration Processor が無効化されている, the Issue Watcher shall 本機能導入前と同じ Issue 処理フロー（および Phase A merge queue 処理）のみを実行する
3. The Issue Watcher shall 既存の環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `MERGE_QUEUE_ENABLED` 等）の意味とデフォルト挙動を変更しない
4. The Issue Watcher shall PR iteration 用の以下の環境変数を読み取り、未設定時は所定のデフォルト値を用いる: 有効化フラグ（デフォルト `false`）、iteration 用モデル ID（デフォルト `claude-opus-4-7`）、1 iteration あたりの最大 turn 数（デフォルト 60）、1 サイクルあたりの処理上限（デフォルト 3）、1 PR あたりの iteration 上限（デフォルト 3）
5. The Issue Watcher shall 既存ラベル（`auto-dev`, `claude-picked-up`, `awaiting-design-review`, `ready-for-review`, `claude-failed`, `needs-decisions`, `skip-triage`, `needs-rebase`）の名前・意味・付与契約を変更しない
6. The Issue Watcher shall 既存の lock ファイルパス・ログ出力先・exit code の意味を変更しない

### Requirement 3: レビューコメントの取得範囲と文脈構築

**Objective:** As a reviewer, I want 自分が付けた line コメントと @claude mention general コメントだけが Claude に渡ることを保証したい, so that 古いコメントや無関係な会話が文脈に混入せず、指摘が意図通り反映される

#### Acceptance Criteria

1. When PR Iteration Processor が対象 PR を処理する, the PR Iteration Processor shall その PR の最新 review の line コメント全件を Claude への入力文脈に含める
2. When PR Iteration Processor が対象 PR を処理する, the PR Iteration Processor shall その PR に付いた general コメント（PR 全体コメント）のうち `@claude` メンションを含むもの全件を Claude への入力文脈に含める
3. The PR Iteration Processor shall 各レビューコメントについて、コメント ID、コメント本文、対象ファイルパス、対象行番号（line コメントの場合）を Claude が識別可能な形式で入力文脈に含める
4. The PR Iteration Processor shall 対象 PR の現在の diff（base branch との差分）を Claude への入力文脈に含める
5. The PR Iteration Processor shall 対象 PR に紐づく Issue 番号から `docs/specs/<番号>-<slug>/requirements.md` を解決できる場合、その内容を Claude への入力文脈に含める
6. The PR Iteration Processor shall 各 iteration を fresh context（前回 iteration の会話履歴を引き継がない独立 Claude 起動）で実行する

### Requirement 4: 修正 commit の作成と push 方法

**Objective:** As a reviewer, I want 反復の修正履歴が commit 単位で残り、force push で既存 commit が上書きされないことを保証したい, so that レビュー済み commit の SHA が失効せず、review thread の line 参照が壊れない

#### Acceptance Criteria

1. When Claude が修正を確定した, the PR Iteration Processor shall 対象 PR の head branch に新しい commit として push する
2. The PR Iteration Processor shall 反復サイクル中に `--force` および `--force-with-lease` を用いた force push を実施しない
3. If 対象 PR の head branch への通常 push が失敗した（リモート先行等の理由）, the PR Iteration Processor shall 当該 PR への操作を中断し、watcher ログに WARN レベル相当で原因を記録した上で後続 PR の処理を継続する
4. The PR Iteration Processor shall push 前にローカルの head branch を origin の最新状態に追従させる（リモート先行が無いことを保証する）
5. If Claude が修正なしで完了した（レビューコメントへの返信のみで対応可能と判断した）, the PR Iteration Processor shall commit / push を行わず、返信コメントの投稿のみを実施する

### Requirement 5: レビュースレッドへの返信

**Objective:** As a reviewer, I want 自分が付けた各指摘がどう扱われたか（修正したのか、不要と判断したのか）を該当スレッドで確認したい, so that PR 画面を離れず指摘の取り込み状況を追跡できる

#### Acceptance Criteria

1. When Claude が 1 件のレビューコメントへの対応を確定した, the PR Iteration Processor shall 当該レビュースレッドに対して「何をどう修正したか、もしくは修正しない理由」を含む返信コメントを投稿する
2. The PR Iteration Processor shall line コメントに対する返信を、元コメントと同じスレッド（review thread）として投稿する
3. The PR Iteration Processor shall `@claude` メンションを含む general コメントに対する返信を、同一 PR の一般コメントとして投稿する
4. The PR Iteration Processor shall レビュースレッドの resolve / unresolve 状態を変更しない（人間が閉じる運用を保つ）
5. If 返信コメント投稿の API がエラーを返した, the PR Iteration Processor shall watcher ログに WARN レベル相当で原因を記録し、当該 PR の残りの処理を続行する

### Requirement 6: ラベル遷移

**Objective:** As a reviewer, I want 反復処理の開始・成功・失敗が PR ラベルで可視化されることを保証したい, so that 次に自分が何をすべきか（再レビューか、エスカレーション対応か）を一覧で判断できる

#### Acceptance Criteria

1. When PR Iteration Processor が対象 PR の処理を開始した, the PR Iteration Processor shall 対象 PR から `needs-iteration` ラベルを除去する前に処理中であることを示す手段（コメントまたは処理中ラベル）で着手を表明する
2. When 対象 PR の iteration が成功した（commit push もしくは返信のみで正常完了した）, the PR Iteration Processor shall 対象 PR から `needs-iteration` ラベルを除去し、`ready-for-review` ラベルを付与する
3. If 対象 PR の 1 iteration サイクルで Claude の実行が失敗した（プロセス非 0 終了、turn 数上限到達、push 失敗等）, the PR Iteration Processor shall `needs-iteration` ラベルを除去せず、watcher ログに失敗を記録した上で後続 PR の処理を継続する
4. The PR Iteration Processor shall `ready-for-review` ラベル付与の前に、以前のサイクルで付いていた `needs-iteration` ラベルが残存しないよう除去済みであることを確認する
5. The idd-claude ラベル作成スクリプト（`.github/scripts/idd-claude-labels.sh` 相当）shall 本機能で追加されるラベル（`needs-iteration` 等、必要なもの）を冪等に作成できるよう更新される

### Requirement 7: 無限ループ防止（iteration 上限）

**Objective:** As a watcher operator, I want 同一 PR に対する自動反復が指定回数を超えないよう上限を設けたい, so that Claude の判断ミスや不安定な指摘で永久に commit/push が続く事故を防げる

#### Acceptance Criteria

1. The PR Iteration Processor shall 対象 PR ごとに、これまで自動で実施された iteration 回数を観測可能な形式（PR 上のコメント、ラベル、もしくは付帯情報のいずれか）で記録する
2. If 対象 PR の累計 iteration 回数が上限値（環境変数で上書き可能、デフォルト 3）に到達している, the PR Iteration Processor shall 当該 PR に対する新規 iteration を実施せず、`claude-failed` ラベルを付与する
3. When 累計 iteration 回数が上限に達して `claude-failed` に昇格させた, the PR Iteration Processor shall 人間にエスカレーションする旨のコメント（上限値、これまでの iteration 概要、次に人間が取るべきアクション）を対象 PR に投稿する
4. If 人間が対象 PR の iteration カウンタをリセットする意図で `claude-failed` ラベルを除去し、`needs-iteration` を再付与した, the PR Iteration Processor shall 当該 PR を再び対象として扱う（カウンタ初期化の具体方法は design に委ねる）

### Requirement 8: Phase A merge queue 処理との共存

**Objective:** As a watcher operator, I want PR iteration と Phase A merge queue の自動 rebase が同一 PR・同一ローカルワーキングコピー上で競合しないことを保証したい, so that 同時実行による git ref の不整合や force-with-lease 失敗を防げる

#### Acceptance Criteria

1. While PR Iteration Processor が対象 PR の head branch にローカル checkout している間, the Issue Watcher shall 同一 watcher プロセス内で同一 PR への Phase A 自動 rebase を並行起動しない
2. While PR Iteration Processor が動作している, the Issue Watcher shall 既存の watcher 多重起動防止ロック（`LOCK_FILE`）と同じ排他境界内で動作し、別 watcher プロセスが同一 repo を処理することを防ぐ
3. When PR Iteration Processor が対象 PR の処理を終えた, the PR Iteration Processor shall ローカル作業ツリーを main ブランチに戻してから次の PR / Issue 処理に進む
4. If 対象 PR に `needs-rebase` ラベルが付いている, the PR Iteration Processor shall 当該 PR を対象から除外する（Phase A の責務に委ねる）
5. If PR Iteration Processor 実行中に想定外のローカル変更（dirty working tree）を検知した, the PR Iteration Processor shall 当該 PR の操作を中止し、ログに ERROR を記録する

### Requirement 9: ロギングと可観測性

**Objective:** As a watcher operator, I want PR iteration の判断と結果を既存 watcher ログから追えるようにしたい, so that 自動反復の挙動を検証し、問題発生時に原因を特定できる

#### Acceptance Criteria

1. The PR Iteration Processor shall サイクル開始時に「対象候補 PR 件数」「実際に処理する件数」をログに出力する
2. The PR Iteration Processor shall 各 PR ごとに「PR 番号」「iteration 回数」「実施したアクション（commit+push / 返信のみ / スキップ / 失敗）」を 1 行以上のログに出力する
3. The PR Iteration Processor shall サイクル終了時に「成功数」「失敗数」「スキップ数」「上限超過で `claude-failed` 昇格した数」のサマリをログに出力する
4. The PR Iteration Processor shall ログの出力先を既存 watcher の `LOG_DIR` 配下に統一し、新規の出力ディレクトリを作らない
5. The PR Iteration Processor shall Issue Watcher と同じタイムスタンプ書式でログ行を出力し、grep で集計可能な識別語（プレフィックス）で自己の出力をマークする

### Requirement 10: ドキュメント更新（DoD）

**Objective:** As a new operator, I want PR iteration の挙動・有効化方法・新ラベルの意味を README から読み取れるようにしたい, so that 既存ユーザが追加機能の opt-in 可否を即判断できる

#### Acceptance Criteria

1. The README.md shall 本機能の概要（目的・対象・起動タイミング）を記述するセクションを含む
2. The README.md shall 本機能の有効化／無効化を制御する環境変数の名称・デフォルト値・推奨値を明記する
3. The README.md shall 新ラベル `needs-iteration` の意味・付与主体・解除タイミングをラベル一覧と状態遷移セクションに追記する
4. The README.md shall 本機能導入による後方互換性方針（既存 env / ラベル / lock / exit code が不変であること、`PR_ITERATION_ENABLED=false` で完全無影響であること）を migration note として明記する
5. The README.md shall Phase A（`needs-rebase`）と本機能（`needs-iteration`）の住み分け、両者のラベルが同一 PR に併存した場合の取り扱いを記述する

## Non-Functional Requirements

### NFR 1: パフォーマンス・実行コスト

1. The PR Iteration Processor shall 1 iteration あたりの Claude 実行に turn 数上限（環境変数 default 60）を適用し、上限到達時は当該 PR の処理を失敗として打ち切る
2. The PR Iteration Processor shall 1 サイクルあたりの対象 PR 数を環境変数で制限し（default 3）、残りは次回サイクルに持ち越す
3. The PR Iteration Processor shall watcher サイクル全体（Phase A merge queue + Issue 処理 + 本機能）が既定の watcher 実行間隔（README 既定 2 分）に収まるよう、1 PR あたりの処理をタイムアウトで打ち切る手段を持つ

### NFR 2: 安全性

1. The PR Iteration Processor shall PR branch への push 手段として通常 push のみを用い、`--force` / `--force-with-lease` を用いた force push を一切行わない
2. The PR Iteration Processor shall `main` ブランチへの直接 push を一切行わない
3. If 対象 PR の処理中に想定外のローカル変更（dirty working tree）が検知された, the PR Iteration Processor shall そのサイクルでの当該 PR の操作を中止し、ログに ERROR を記録する

### NFR 3: 観測可能性

1. The PR Iteration Processor shall Issue Watcher と同じタイムスタンプ書式（`[YYYY-MM-DD HH:MM:SS]`）でログ行を出力する
2. The PR Iteration Processor shall 各 PR への操作結果（成功 / 失敗 / 上限超過エスカレーション / スキップ）を operator がログを grep するだけで集計できる識別語でマークする

## Out of Scope

- レビュースレッドの自動 resolve / unresolve（人間が閉じる運用を保つ）
- fork PR（head repo owner ≠ base repo owner）への反復対応
- PR に付いたレビュー指摘の妥当性評価・選別（Claude に全件渡し判断を委ねる）
- 汎用 Reviewer サブエージェント（#20 Phase 1 Reviewer の範囲）
- タスク単位の反復開発ループ（#21 per-task loop の範囲）
- `tasks.md` の自動更新（#21 完成後に別 Issue で扱う）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への本機能の組み込み
- 反復中に `requirements.md` / `design.md` を書き換える機能
- PR 説明文（body）の自動更新
- iteration カウンタの永続化ストア（DB 等）の導入
- Phase A `needs-rebase` と本機能の `needs-iteration` が同一 PR に併存した場合の自動調停ロジック（ドキュメント上の住み分け明記のみで対応）

## Open Questions

- 着手中表明の具体手段（AC 6.1）: 「処理中コメント投稿」か「専用の処理中ラベル新設」か。Phase A は前者を選んでいないため、本機能で処理中ラベル（例: `iterating`）を新設するかは design フェーズで決める
- iteration カウンタの観測可能な記録方法（AC 7.1 / 7.4）: PR 上の特定マーカーコメント（hidden HTML コメント等）か、PR 本文メタブロックか、`docs/specs/<番号>-*/impl-notes.md` 付記か。人間がリセット可能な方式を design で決める
- レビュースレッドの line 返信粒度（AC 5.1）: 「全コメントに 1:1 で返信」か「Claude が関連コメント群をまとめて返信」を許すか。Issue 本文では「各レビュースレッドに返信」と記載されているが、まとめ返信を許すかは曖昧（design で明示化推奨）
- Phase A 実行中の排他制御の実装層（AC 8.1 / 8.2）: 既存 `LOCK_FILE` 内の直列実行で十分か、それとも `needs-rebase` / `needs-iteration` のラベル上の相互排他で防ぐかは design の領分だが、要件として「同一 PR に両ラベルが同時付与されたら本機能は skip する」方針を AC 8.4 に含めているため、それ以上の排他は design に委ねる
