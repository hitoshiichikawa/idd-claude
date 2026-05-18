# Requirements Document

## Introduction

idd-claude の `local-watcher/bin/issue-watcher.sh` には、過去の段階導入で opt-in（既定 OFF）として
配置された env var が複数存在する。導入から十分な dogfooding 期間を経て安定運用が確認された現時点、
これら opt-in env var を **明示的に有効化しなくてもデフォルトで動作する**よう、watcher 既定値を
反転させる。対象は Issue #112 で列挙された 9 種の env var（`MERGE_QUEUE_ENABLED` /
`MERGE_QUEUE_RECHECK_ENABLED` / `PR_ITERATION_ENABLED` / `PR_ITERATION_DESIGN_ENABLED` /
`DESIGN_REVIEW_RELEASE_ENABLED` / `STAGE_CHECKPOINT_ENABLED` / `QUOTA_AWARE_ENABLED` /
`IMPL_RESUME_PRESERVE_COMMITS` / `IMPL_RESUME_PROGRESS_TRACKING`）。

本変更は cron / launchd の登録文字列（env 渡し）を変更させない後方互換ポリシーを維持しつつ、
新規 install したユーザーが追加設定なしで idd-claude の標準機能をすべて享受できる状態を目指す。
既に `=true` を明示している既存環境では挙動が変わらず、`=false` を明示することで従来通りの
opt-out が可能でなければならない。

## Requirements

### Requirement 1: デフォルト有効化（標準機能化）の対象範囲

**Objective:** As an idd-claude operator, I want 安定運用が確認された opt-in env var を追加設定なしでデフォルト ON にしたい, so that 新規セットアップ時に cron / launchd で env を列挙しなくても idd-claude の標準機能が利用できる

#### Acceptance Criteria

1. When `MERGE_QUEUE_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall Merge Queue Processor の判定・処理パスを有効として動作させる
2. When `MERGE_QUEUE_RECHECK_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall `needs-rebase` 付き approved PR の Re-check Processor を有効として動作させる
3. When `PR_ITERATION_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall 実装 PR の PR Iteration Processor を有効として動作させる
4. When `PR_ITERATION_DESIGN_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall 設計 PR を対象とする Iteration 拡張を有効として動作させる
5. When `DESIGN_REVIEW_RELEASE_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall 設計 PR merge 後の `awaiting-design-review` ラベル自動除去 Processor を有効として動作させる
6. When `STAGE_CHECKPOINT_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall impl 系モードの Stage Checkpoint Resume を有効として動作させる
7. When `QUOTA_AWARE_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall Claude Max quota 検知と `needs-quota-wait` ラベル運用を有効として動作させる
8. When `IMPL_RESUME_PRESERVE_COMMITS` が未設定の状態で watcher が起動した場合, the Watcher shall impl-resume 経路で既存 origin branch の commit を保持したまま resume する保護機構を有効として動作させる
9. When `IMPL_RESUME_PROGRESS_TRACKING` が未設定の状態で watcher が起動した場合, the Watcher shall Developer のタスク完了時に `tasks.md` の `- [ ]` を `- [x]` に書き換え `docs(tasks): mark <id> as done` で commit する規約を有効として動作させる

### Requirement 2: 明示 opt-out（`=false`）の挙動保持

**Objective:** As an idd-claude operator, I want 個別機能を `=false` で明示的に無効化する手段を残したい, so that 自分のリポジトリに影響する機能だけを選択的に opt-out して段階導入できる

#### Acceptance Criteria

1. When `MERGE_QUEUE_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall Merge Queue Processor のコードパスを skip して本機能導入前と等価な挙動を行う
2. When `MERGE_QUEUE_RECHECK_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall Re-check Processor のコードパスを skip する
3. When `PR_ITERATION_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall PR Iteration Processor のコードパスを skip し、設計 PR 用 Iteration テンプレートの存在チェックも実行しない
4. When `PR_ITERATION_DESIGN_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall 設計 PR を Iteration 対象から除外する
5. When `DESIGN_REVIEW_RELEASE_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall `awaiting-design-review` ラベルを自動除去せず人間操作に委ねる
6. When `STAGE_CHECKPOINT_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall Stage Checkpoint Resume を行わず impl / impl-resume を最初の Stage から再実行する
7. When `QUOTA_AWARE_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall quota 検知ヘルパを副作用なし（gate 早期 return）で実行し、`needs-quota-wait` ラベルを付与しない
8. When `IMPL_RESUME_PRESERVE_COMMITS=false` が明示された状態で watcher が起動した場合, the Watcher shall impl-resume を `origin/$BASE_BRANCH` 起点で強制リセットして従来挙動と等価に動作する
9. When `IMPL_RESUME_PROGRESS_TRACKING=false` が明示された状態で watcher が起動した場合, the Watcher shall Developer prompt への `tasks.md` 進捗追跡指示の注入を行わない
10. If `=false` 以外の任意の値（空文字 / `0` / `False` / typo 等）が明示された場合, the Watcher shall 当該機能をデフォルト有効（=true）として扱う

### Requirement 3: 後方互換性（既存環境の無影響）

**Objective:** As an idd-claude operator running existing cron / launchd entries, I want 本変更後も既存登録文字列を書き換えずに同じ挙動が得られたい, so that idd-claude 更新によって運用中の自動化が壊れない

#### Acceptance Criteria

1. When 既存 cron / launchd で対象 env var を `=true` で明示している環境が本変更後に watcher を起動した場合, the Watcher shall 本変更前と完全に同一の機能を有効として動作させる
2. When 既存 cron / launchd で対象 env var を `=false` で明示している環境が本変更後に watcher を起動した場合, the Watcher shall 本変更前と完全に同一の opt-out 挙動で動作させる
3. The Watcher shall 本変更で対象 env var の **名前・スペル・参照 path・exit code の意味**を変更しない
4. The Watcher shall 本変更前から存在するラベル名（`needs-quota-wait` / `awaiting-design-review` / `needs-rebase` 等）の意味を変更しない
5. While watcher 起動直後に解決済み env 値を log に出力する処理が存在する間, the Watcher shall 既存の log prefix 文字列（`base-branch=` 等）を変更しない

### Requirement 4: ドキュメント整合（README / CLAUDE.md / 設定コメント）

**Objective:** As an idd-claude operator, I want README とコード内コメントを「デフォルト有効、`=false` で無効化可」前提に統一したい, so that デフォルト挙動の認識ズレが運用事故につながらない

#### Acceptance Criteria

1. The README.md shall 「オプション機能（opt-in / 常時有効）一覧」節において、対象 9 env var の既定値表記を「`true`」または「デフォルト有効」に統一する
2. The README.md shall 各機能セクションの「環境変数」表で、対象 env var のデフォルト列を「`true`」に更新し、推奨欄を「無効化する場合のみ `false`」に統一する
3. The README.md shall 本変更による既定値反転を運用者が認識できる migration note を持つ
4. The `local-watcher/bin/issue-watcher.sh` shall 対象 env var の宣言行直上のコメントから「初回導入は opt-in（デフォルト false）」相当の文言を削除または「デフォルト有効」表現に書き換える
5. Where `CLAUDE.md` の禁止事項節で「opt-in gate なしで新しい外部サービス呼び出しを有効化」を扱う場合, the CLAUDE.md shall 本変更が「新規外部サービスの追加ではなく既存機能のデフォルト変更」である旨を運用者が判別できるよう migration note を参照可能とする

### Requirement 5: 開発者プロンプト注入経路の整合性

**Objective:** As an idd-claude operator using impl-resume protection, I want `IMPL_RESUME_PRESERVE_COMMITS` と `IMPL_RESUME_PROGRESS_TRACKING` の組み合わせ挙動が直感に反しないようにしたい, so that impl-resume の進捗追跡が想定外に欠落しない

#### Acceptance Criteria

1. When `IMPL_RESUME_PRESERVE_COMMITS=true` かつ `IMPL_RESUME_PROGRESS_TRACKING=true`（いずれも未設定時のデフォルト含む）の状態で impl-resume が走った場合, the Developer prompt shall `tasks.md` 進捗追跡指示を含む
2. When `IMPL_RESUME_PRESERVE_COMMITS=true` かつ `IMPL_RESUME_PROGRESS_TRACKING=false` が明示された場合, the Developer prompt shall `tasks.md` 進捗追跡指示を含まない
3. If `IMPL_RESUME_PRESERVE_COMMITS=false` が明示された場合, the Watcher shall 進捗追跡指示注入経路を通過させず、結果として Developer prompt に `tasks.md` 進捗追跡指示を含めない（`IMPL_RESUME_PROGRESS_TRACKING` の値に関わらず）
4. The Watcher shall `IMPL_RESUME_PRESERVE_COMMITS=false` を「impl-resume 保護全体の opt-out」として扱う構造を本変更で破壊しない

## Non-Functional Requirements

### NFR 1: 既存運用との後方互換

1. The Watcher shall 本変更前に `=true` を明示していた cron / launchd エントリで、追加変更なしに本変更後も同一の機能セットが有効に保たれる
2. The Watcher shall 本変更前に `=false` を明示していた cron / launchd エントリで、追加変更なしに本変更後も同一の opt-out 状態が保たれる
3. The Watcher shall 本変更で env var 名・ラベル名・exit code の意味・log prefix を変更しない（運用者が grep / アラート設定を書き換える必要が生じない）

### NFR 2: 静的解析・自己検証

1. The `local-watcher/bin/issue-watcher.sh` shall `shellcheck` を警告ゼロで通過する
2. The Watcher shall cron-like 最小 PATH（`env -i HOME=$HOME PATH=/usr/bin:/bin`）でも対象 env var の未設定時にデフォルト ON で起動できる

### NFR 3: dogfooding 影響の最小化

1. While idd-claude 自身が自リポジトリ上で watcher 経路を運用している間, the Watcher shall 本変更により dogfooding 中の現行 PR / Issue 処理パイプラインを壊さない（既存 cron 登録の `=true` 明示が無効化される副作用を生まない）

## Out of Scope

- 既存 env var の名称変更・廃止（後方互換ポリシーにより本 PR では行わない）
- 新規 opt-in 機能の追加（本 PR は既存 9 env var のデフォルト反転のみを扱う）
- GitHub Actions ワークフロー側（`IDD_CLAUDE_USE_ACTIONS`）のデフォルト反転（Actions 経路は本変更のスコープ外）
- Feature Flag Protocol（`CLAUDE.md` の `## Feature Flag Protocol` 節）の採否デフォルト変更
- Reviewer Gate / Parallel Slot 等、本変更対象外の機能のデフォルト見直し
- 対象 env var の値解釈ロジック（true / false 以外の値の扱い）の刷新（既存「`=false` 以外はすべて有効」相当の解釈方針を継承する）

## 確認事項（PM 推奨）

- **README migration note の見せ方**: PM 推奨は「changelog 節新設ではなくインライン追記」。具体的には
  README の「オプション機能（opt-in / 常時有効）一覧」節の表上部に **note ブロック**を 1 つ追加し、
  各機能セクションの環境変数表内で既定値を `true` に更新する。理由は (1) idd-claude は OSS ツール
  リポジトリで明示的な changelog 慣習がない、(2) インライン追記の方が「該当機能の既定がどう変わったか」
  を該当箇所で読める、(3) 将来同種のデフォルト反転を行う際に追加できる粒度が揃う。許容できない場合は
  Issue コメントでエスカレーション。
- **`IMPL_RESUME_PRESERVE_COMMITS=false` 時の `IMPL_RESUME_PROGRESS_TRACKING` 強制 off ロジック**:
  PM 推奨は「現行の強制 off 構造（NFR 1.1 を構造的に保証する仕組み）を維持する」。本変更で
  `IMPL_RESUME_PRESERVE_COMMITS` がデフォルト `true` に反転するため、未指定時は両機能とも有効になり
  従来 opt-in 時の挙動と等価になる。`IMPL_RESUME_PRESERVE_COMMITS=false` を明示した場合は、
  「impl-resume 保護機構全体の opt-out」という意味論を維持する観点から、進捗追跡指示注入経路も
  off のままにすることが運用者の期待に整合する（Requirement 5.3 / 5.4）。本方針に異論があれば
  Issue コメントでエスカレーション。
