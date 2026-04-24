# Requirements Document

## Introduction

idd-claude の watcher は Issue から PR 作成までを自動化するが、approve 済みの PR が
human レビュー待ちの間に main が進み、merge 直前で conflict や stale base が発覚するケースが
頻発する。merge queue 化（親 Issue #13）の前段として、watcher サイクル冒頭で approve 済み PR の
mergeability を能動的に検知し、機械的に解決可能な stale base はその場で rebase + force-with-lease push
し、conflict が起きるものには `needs-rebase` ラベルと状況コメントを付けて人間判断に回す。
本フェーズ（Phase A）はあくまで「出口 conflict の早期検知」と「単純 rebase の自動化」のみを
担い、semantic conflict の自動解決（Phase D / #17）や staging branch（Phase B / #15）、
並列 rebase worker は対象外とする。

## Requirements

### Requirement 1: Approved PR の検知範囲

**Objective:** As a watcher operator, I want approved な open PR だけを mergeability チェックの対象にしたい, so that 終端状態の PR や未承認の PR に無駄な API call と git 操作を行わずに済む

#### Acceptance Criteria

1. While watcher サイクルが開始した直後, the Issue Watcher shall ピックアップ済み Issue の処理ループに入る前に Merge Queue Processor を 1 回起動する
2. The Merge Queue Processor shall 対象 repo の open PR のうち、少なくとも 1 件以上の approving review が付いているものだけを処理対象に含める
3. If 処理対象 PR に `claude-failed` ラベル相当の終端状態ラベル（既存の Issue 側終端ラベルに準ずる）が付いている, the Merge Queue Processor shall その PR を対象から除外する
4. If 処理対象 PR が draft 状態である, the Merge Queue Processor shall その PR を対象から除外する
5. The Merge Queue Processor shall 対象 PR ごとに GitHub API から `mergeable` / `mergeStateStatus` 相当の情報を取得する

### Requirement 2: CONFLICTING 検知時の挙動

**Objective:** As a reviewer, I want 自動 rebase で解消できない conflict を即座にラベルとコメントで通知してほしい, so that 自分が次に何をすればよいか（手動 rebase か Claude 介入依頼か）を即判断できる

#### Acceptance Criteria

1. When 対象 PR の mergeable 状態が CONFLICTING と判定された, the Merge Queue Processor shall その PR に `needs-rebase` ラベルを付与する
2. If 対象 PR にすでに `needs-rebase` ラベルが付いている, the Merge Queue Processor shall ラベル付与 API を再送せず、コメントも重複投稿しない
3. When 新たに `needs-rebase` ラベルを付与した, the Merge Queue Processor shall 対象 PR に conflict を検知した旨と推奨アクション（手動 rebase / Phase D 待ちなど）を含む 1 件のステータスコメントを投稿する
4. The Merge Queue Processor shall 投稿するステータスコメントに、どのファイルが conflict したかが利用者に伝わる粒度の情報を含める
5. If conflict 検知後の状態通知に失敗した（ラベル付与もしくはコメント投稿の API がエラーを返した）, the Merge Queue Processor shall watcher ログに WARN レベル相当で原因を記録し、後続 PR の処理は継続する

### Requirement 3: MERGEABLE かつ base が古い PR の自動 rebase

**Objective:** As a reviewer, I want 機械的に解消できる stale base はレビュー前に自動で最新化してほしい, so that approve 後に「base が古いだけ」で待たされない

#### Acceptance Criteria

1. When 対象 PR の mergeable 状態が MERGEABLE であり、かつ PR の base branch HEAD よりも main HEAD が進んでいる, the Merge Queue Processor shall ローカルワーキングコピー上で対象 PR ブランチを最新の main に rebase する
2. When 自動 rebase がコンフリクトなく完了した, the Merge Queue Processor shall 対象 PR ブランチを `--force-with-lease` 相当の安全な force push 方式でリモートに push する
3. If 自動 rebase 中にコンフリクトが発生した, the Merge Queue Processor shall ローカル rebase 操作を中断・abort し、対象 PR に `needs-rebase` ラベルと Requirement 2 と同等のステータスコメントを投稿する
4. If 自動 rebase 後の force push が失敗した（リモートが先行している等の理由）, the Merge Queue Processor shall 当該 PR への操作をスキップし、watcher ログに WARN レベル相当で原因を記録する
5. When 対象 PR の base がすでに main HEAD と同じか祖先関係を満たしている, the Merge Queue Processor shall 当該 PR に対する rebase 操作をスキップする
6. The Merge Queue Processor shall 自動 rebase 実施後に作業ツリーを元の状態（main checkout）に戻してから次の処理に進む

### Requirement 4: 実行コスト・タイムバジェット

**Objective:** As a watcher operator, I want Merge Queue Processor が watcher の通常実行間隔に収まる範囲で完了することを保証したい, so that 後続の Issue 処理が遅延せず、cron / launchd の重複起動も発生しない

#### Acceptance Criteria

1. The Merge Queue Processor shall 1 回の watcher サイクル内で対象 PR を処理する総時間が、watcher の最短実行間隔（README に記載のデフォルトでは 2 分）以内に収まることを目指す
2. The Merge Queue Processor shall 1 サイクルあたりに処理する PR 数の上限値（デフォルトおよび環境変数で上書き可能）を持つ
3. If 上限を超える対象 PR が存在する, the Merge Queue Processor shall 残りの PR を次回サイクルに持ち越し、watcher ログにスキップ件数を記録する
4. The Merge Queue Processor shall 1 PR の処理（API 取得 → rebase → push まで）でハングしないよう、rebase / push のサブプロセスにタイムアウトを設ける
5. If いずれかの PR 処理がタイムアウトに達した, the Merge Queue Processor shall 当該 PR の操作を中断し、ログに WARN を出して次の PR の処理に進む

### Requirement 5: 既存運用との後方互換性 / opt-out

**Objective:** As an existing watcher user, I want Phase A の機能を環境変数で無効化できるようにしたい, so that 直列運用で安定稼働している環境を壊さずに段階的に opt-in できる

#### Acceptance Criteria

1. The Issue Watcher shall Merge Queue Processor の有効化／無効化を制御する環境変数（例: `MERGE_QUEUE_ENABLED`）を読み取り、無効化されている場合は Merge Queue Processor を起動しない
2. Where Merge Queue Processor が無効化されている, the Issue Watcher shall Phase A 導入前と同じ Issue 処理フローのみを実行する
3. The Issue Watcher shall 既存の環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）の意味とデフォルト挙動を変更しない
4. The Issue Watcher shall 既存ラベル（`auto-dev`, `claude-picked-up`, `awaiting-design-review`, `ready-for-review`, `claude-failed`, `needs-decisions`, `skip-triage`）の名前・意味・付与契約を変更しない
5. The Issue Watcher shall 既存の lock ファイルパス・ログ出力先・exit code の意味を変更しない
6. The ラベル作成スクリプト（`idd-claude-labels.sh` 相当）shall Phase A で追加されるラベル（`needs-rebase` 等）を冪等に作成できるよう更新される

### Requirement 6: ロギング・可観測性

**Objective:** As a watcher operator, I want Merge Queue Processor の判断と操作結果をログから追えるようにしたい, so that 自動 rebase の挙動を検証し、問題発生時に原因を特定できる

#### Acceptance Criteria

1. The Merge Queue Processor shall サイクル開始時に「対象候補 PR 件数」「実際に処理する件数」をログに出力する
2. The Merge Queue Processor shall 各 PR ごとに「PR 番号」「mergeable 判定結果」「実施したアクション（skip / rebase+push / label+comment）」を 1 行以上のログに出力する
3. The Merge Queue Processor shall サイクル終了時に「rebase+push 成功数」「conflict 検知数」「skip 数」「失敗数」のサマリをログに出力する
4. The Merge Queue Processor shall ログの出力先を既存 watcher の `LOG_DIR` 配下に統一し、新規の出力ディレクトリを作らない
5. The Merge Queue Processor shall 標準エラー出力には人間向けの WARN/ERROR のみを出し、標準出力は機械可読な集計用に予約する（既存 `issue-watcher.sh` の出力契約に揃える）

### Requirement 7: ドキュメント更新（DoD）

**Objective:** As a new operator, I want Phase A の挙動・有効化方法・新ラベルの意味を README から読み取れるようにしたい, so that 既存ユーザが追加機能の opt-in 可否を即判断できる

#### Acceptance Criteria

1. The README.md shall Phase A で追加された Merge Queue Processor の概要（目的・対象・タイミング）を記述するセクションを含む
2. The README.md shall Phase A の有効化／無効化を制御する環境変数の名称・デフォルト値・推奨値を明記する
3. The README.md shall 新ラベル `needs-rebase` の意味・付与主体・解除タイミングをラベル一覧と状態遷移セクションに追記する
4. The README.md shall Phase A 導入による後方互換性方針（既存 env / ラベル / lock / exit code が不変であること）を migration note として明記する
5. The README.md shall ラベル作成スクリプト（`.github/scripts/idd-claude-labels.sh` 相当）が Phase A で追加されるラベルを冪等に作成できる旨を記述する

## Non-Functional Requirements

### NFR 1: パフォーマンス

1. The Merge Queue Processor shall watcher の最短実行間隔（README 既定 2 分）の半分（60 秒）以内に通常ケース（対象 PR 0〜3 件）の処理を完了する
2. The Merge Queue Processor shall 1 PR あたりの GitHub API 呼び出し回数を、mergeability 取得・ラベル操作・コメント投稿の合計で 5 回以内に抑える

### NFR 2: 安全性

1. The Merge Queue Processor shall リモートに対する破壊的操作として `--force-with-lease` 相当の安全 push のみを使用し、無条件 force push（`--force`）を使わない
2. The Merge Queue Processor shall 自動 rebase 操作中はローカルワーキングコピーの未コミット変更を作らず、操作終了時に main ブランチに戻すことを保証する
3. If 想定外のローカル変更（dirty working tree）が検知された, the Merge Queue Processor shall そのサイクルでの rebase 操作を中止し、ログに ERROR を記録する

### NFR 3: 観測可能性

1. The Merge Queue Processor shall Issue Watcher と同じタイムスタンプ書式（`[YYYY-MM-DD HH:MM:SS]`）でログ行を出力する
2. The Merge Queue Processor shall 各 PR への操作結果（rebase+push 成功 / conflict / skip / 失敗）を operator がログを grep するだけで集計できる識別語（例: `merge-queue:` プレフィックス）でマークする

## Out of Scope

- Claude Code を起動した semantic conflict 解決（Phase D / #17 の範囲）
- Staging branch を介した PR の事前 merge 検証（Phase B / #15 の範囲）
- 並列 rebase worker（複数 PR を同時に rebase する仕組み）
- approving review 数のしきい値設定や、特定 reviewer による approve のみを認める設定
- merge queue 順序付けロジック（優先度・依存関係解決）
- conflict 発生時に Issue 本体（PR 起点 Issue）へラベルを伝搬させる仕組み
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への Phase A 機能の組み込み

## Open Questions

- なし（Issue 本文と親 Issue #13 のスコープに従って閉じた要件として記述）
