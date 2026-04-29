# Requirements Document

## Introduction

PR #51（Phase C 並列化）で Dispatcher が atomic claim のために `claude-picked-up` ラベルを Triage 開始前に付与する設計に変更した結果、`claude-picked-up` が「claim 完了」「Triage 実行中」「実装中」の 3 状態を兼任するようになった。これによりラベル単位での状態判別が不可能となり、Phase E（実装中 Issue の触りそうなパス集計）、Dashboard / SLA 計測、運用者のメンタルモデル形成に支障が出ている。本機能では新ラベル `claude-claimed` を追加して claim/Triage フェーズと実装フェーズを分離し、1 状態 1 ラベルの semantic を回復する。既存の進行中 Issue・cron 起動契約・既存 install 済みリポジトリへの後方互換性を保ちながら、本リポジトリ自身（dogfooding）でも遷移が成立することを保証する。

## Requirements

### Requirement 1: Claim/Triage フェーズの新ラベル付与

**Objective:** As a 運用者, I want claim と Triage 中の Issue を `claude-picked-up` とは異なるラベルで識別したい, so that 実装中 Issue とそれ以前の Issue をラベルだけで区別できる

#### Acceptance Criteria

1. When Dispatcher が auto-dev 付き Issue を slot に予約したとき, the Issue Watcher shall 当該 Issue に `claude-claimed` ラベルを付与する
2. When Dispatcher が claim を行うとき, the Issue Watcher shall 当該 Issue に `claude-picked-up` ラベルを付与しない
3. While `claude-claimed` ラベルが Issue に付与されている間, the Issue Watcher shall 当該 Issue が claim 完了済みまたは Triage 実行中であることを表す状態として扱う
4. If Dispatcher が `claude-claimed` ラベルの付与に失敗したとき, the Issue Watcher shall 当該 slot を解放し次の Issue へ進む

### Requirement 2: Triage 完了後の実装フェーズへの遷移

**Objective:** As a 運用者, I want Triage 完了後に実装が始まる Issue を `claude-picked-up` で示したい, so that ラベル名から「実際にコードを編集中」を一意に判定できる

#### Acceptance Criteria

1. When Triage が完了し Developer フェーズへ進むと判定されたとき, the Issue Watcher shall 当該 Issue から `claude-claimed` を除去し `claude-picked-up` を付与する
2. While 実装フェーズが進行中である間, the Issue Watcher shall 当該 Issue に `claude-picked-up` ラベルのみを保持し `claude-claimed` を保持しない
3. The Issue Watcher shall 1 つの Issue に `claude-claimed` と `claude-picked-up` の両方を同時に付与した状態を継続させない

### Requirement 3: 終端ラベル遷移時の `claude-claimed` クリーンアップ

**Objective:** As a 運用者, I want Triage の結果として終端状態（needs-decisions / awaiting-design-review）に遷移した Issue から claim 系ラベルが残らないようにしたい, so that 終端ラベルだけを見れば Issue 状態が正しく判断できる

#### Acceptance Criteria

1. When Triage 結果が `needs-decisions` となったとき, the Issue Watcher shall 当該 Issue から `claude-claimed` を除去し `needs-decisions` を付与する
2. When Triage 結果が `awaiting-design-review` 経路（Architect 起動）となったとき, the Issue Watcher shall 当該 Issue から `claude-claimed` を除去し `awaiting-design-review` を付与する（design-review ルートも `claude-claimed` を経由する前提）
3. If Triage 自体の実行が失敗したとき, the Issue Watcher shall 当該 Issue から `claude-claimed` を除去し `claude-failed` を付与する
4. The Issue Watcher shall `claude-claimed` を Triage 終了時のいかなる遷移経路でも残置しない

### Requirement 4: Issue ピックアップの排他制御

**Objective:** As a 運用者, I want 別 slot や次サイクルで `claude-claimed` 付き Issue が二重に拾われないようにしたい, so that 同一 Issue が複数の処理対象として並走することを防げる

#### Acceptance Criteria

1. While Issue に `claude-claimed` ラベルが付与されている間, the Issue Watcher shall 当該 Issue を新規ピックアップ対象から除外する
2. The Issue Watcher shall ピックアップ対象検索の除外条件として `claude-claimed` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `needs-iteration` をすべて含める
3. When 同一サイクル内で複数 slot が空いているとき, the Issue Watcher shall 同一 Issue 番号を 2 つ以上の slot に同時 claim させない

### Requirement 5: 後方互換性と既存進行中 Issue の継続性

**Objective:** As a 既存 install 済みリポジトリの運用者, I want 本変更が deploy された時点で進行中の Issue や既存 cron 設定が壊れないこと, so that ダウンタイムや手動修復なしで移行できる

#### Acceptance Criteria

1. While 既存の Issue が `claude-picked-up` のみを付与された状態で実装フェーズを進行中である間, the Issue Watcher shall 当該 Issue の処理を中断・再 claim せずそのまま完了させる
2. The Issue Watcher shall 既存環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）の意味と受理形式を本変更で改変しない
3. The Issue Watcher shall 既存 cron / launchd 登録文字列を変更しなくても本機能が動作する状態を維持する
4. The Issue Watcher shall 既存ラベル `auto-dev` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` の名前と意味を変更しない
5. If `claude-claimed` ラベルが対象リポジトリに未存在の状態で本機能が起動したとき, the Issue Watcher shall ラベル付与失敗を slot 解放として扱い、後続 Issue 処理を継続する

### Requirement 6: ラベル定義スクリプトの冪等更新

**Objective:** As a 既存 install 済みリポジトリの運用者, I want `idd-claude-labels.sh` を再実行するだけで `claude-claimed` ラベルが追加されること, so that 追加の手作業なくラベル基盤を更新できる

#### Acceptance Criteria

1. When 運用者が `bash .github/scripts/idd-claude-labels.sh` を実行したとき, the Label Setup Script shall `claude-claimed` ラベルを当該リポジトリに追加する
2. While `claude-claimed` ラベルが既に存在するとき, the Label Setup Script shall 当該ラベルを再作成せず冪等にスキップする
3. When 運用者が `bash .github/scripts/idd-claude-labels.sh --force` を実行したとき, the Label Setup Script shall 既存の `claude-claimed` ラベル定義を上書き更新する
4. The Label Setup Script shall 既存ラベル群（`auto-dev` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration`）の name / color / description を本機能の追加によって変更しない
5. The Label Setup Script shall `claude-claimed` ラベルの description に【Issue 用】prefix（既存規約 Issue #54 準拠）を含める

### Requirement 7: ドキュメントとエージェント定義の整合

**Objective:** As a 新規 contributor, I want 状態遷移図・ラベル一覧・PjM の遷移指示が新ラベルを反映していること, so that 仕様書とコードの挙動の食い違いに惑わされない

#### Acceptance Criteria

1. When 運用者が README の状態遷移セクションを参照したとき, the Documentation shall `auto-dev → claude-claimed → claude-picked-up → ready-for-review/claude-failed` および `auto-dev → claude-claimed → needs-decisions/awaiting-design-review` の両ルートを図示する
2. The Documentation shall README のラベル一覧に `claude-claimed` を追加し、その目的・付与タイミング（Dispatcher claim 時）・除去タイミング（Triage 完了時）を記載する
3. The Documentation shall README に既存運用者向け Migration Note（在進行中 Issue は旧ラベルのまま完走する旨・`idd-claude-labels.sh` 再実行手順）を含める
4. When PjM サブエージェントが impl 系モードでラベル遷移指示を実行するとき, the Project Manager Agent Template shall 実装完了時の付け替え対象として `claude-picked-up` のみを指定し `claude-claimed` を指定しない

### Requirement 8: Dogfooding による状態遷移検証

**Objective:** As a 開発者, I want 本リポジトリ自身に対して新ラベル遷移が end-to-end で成立することを確認できる, so that 他リポジトリに展開する前に挙動破綻を検出できる

#### Acceptance Criteria

1. When 本リポジトリの Issue に `auto-dev` ラベルを付与したとき, the Issue Watcher shall 当該 Issue を `auto-dev → claude-claimed → claude-picked-up → ready-for-review` の順で遷移させる
2. When 本リポジトリの Issue で Triage 結果が `needs-decisions` となったとき, the Issue Watcher shall 当該 Issue を `auto-dev → claude-claimed → needs-decisions` の順で遷移させ、`claude-picked-up` を経由しない
3. When 本リポジトリの Issue で Triage 結果が Architect 起動（`awaiting-design-review`）となったとき, the Issue Watcher shall 当該 Issue を `auto-dev → claude-claimed → awaiting-design-review` の順で遷移させ、`claude-picked-up` を経由しない

## Non-Functional Requirements

### NFR 1: 観測可能性

1. The Issue Watcher shall `claude-claimed` ラベル付与・除去のイベントを既存ログ出力先（`LOG_DIR` 配下）に追記し、運用者が事後に遷移経路を再構成できる粒度で記録する
2. The Issue Watcher shall 1 つの Issue に対して `claude-claimed` と `claude-picked-up` を同時に付与した状態が一時的にも 5 秒以上継続することを発生させない

### NFR 2: 移行容易性

1. The Label Setup Script shall 既存 install 済みリポジトリで本スクリプトを再実行する以外の追加手作業を新ラベル導入に必要としない
2. The Issue Watcher shall 旧バージョン watcher が付与した `claude-picked-up` のみを持つ進行中 Issue に対して、本バージョン watcher が起動したサイクルで誤遷移・誤完了・誤 fail を発生させない

### NFR 3: 静的解析クリーン

1. The Issue Watcher script shall `shellcheck` 実行において新規警告を 0 件に保つ
2. The Workflow YAML（変更が及ぶ場合）shall `actionlint` 実行において新規警告を 0 件に保つ

## Out of Scope

- `claude-claimed` ラベルの色・description 文言の最終決定（Architect の設計判断および運用合意の領分）
- PR #51 並列化機構（Dispatcher / slot manager / worktree manager）の構造変更
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）に対する `claude-claimed` 導入（local watcher が claim 主体である現設計に対し、Actions 版での同等遷移を導入するかは別 Issue で議論）
- ダッシュボード / SLA 計測ツール側のラベル集計ロジック更新
- 既存ラベル名の rename・廃止
- `claude-claimed` を起点とした追加の自動化（例: claim 後一定時間経過で自動解除など）
- Reviewer Gate 内部のステージ遷移（Stage A / Stage A' / Reviewer round 系）でのラベル細分化

## Open Questions

- なし（Issue 本文の「未解決設計論点」4 項目はいずれも Architect 判断事項であり、要件レベルでは「design-review ルートも `claude-claimed` を経由する」という Issue 提示の現案を Requirement 3.2 / 8.3 で固定済み。色・description 文言は Out of Scope として Architect に委譲）
