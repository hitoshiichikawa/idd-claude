# Requirements Document

## Introduction

idd-claude を multi-branch（例: `BASE_BRANCH=develop`）運用するリポジトリでは、approved PR が
Phase A（#14 Merge Queue Processor）によって `BASE_BRANCH` に merge された後、
リリースブランチ（既定 `main`）に手動で release PR を作って merge するまでの間、System Test（ST）
の合否確認と revert 判断が運用者の手作業に残っていた。本フェーズ（Phase B）は、`BASE_BRANCH` に
merge された変更について、watcher サイクル内で ST check-run の結果をポーリングし、success なら
`BASE_BRANCH` → `PROMOTION_TARGET_BRANCH`（既定 `main`）への fast-forward 昇格、failure なら
`git revert -m 1` + Issue 再オープン + `st-failed` 通知を自動化する。

本 Issue は既存実装 #89（`BASE_BRANCH` 切替）・#100（`staged-for-release` ラベル定義）・
#14（Phase A Merge Queue）の上に積み上げる機能であり、それらの再定義は対象外である。
新規に追加する挙動は (1) ST 結果連動の `staged-for-release` 自動付与／除去、(2) ST 結果ポーリング
と revert-on-failure、(3) `BASE_BRANCH` → `PROMOTION_TARGET_BRANCH` への fast-forward promote、
(4) `PROMOTE_MODE`（`continuous` / `batched` / `on-demand`）による昇格タイミング制御の 4 点に
限定する。Phase B 全体は環境変数 `PROMOTE_PIPELINE_ENABLED=true` を opt-in gate として持ち、
未設定または `false` のリポジトリでは導入前と完全に同一の挙動を維持する。

なお、single-branch（`BASE_BRANCH` 未設定 = `main` のみ）運用では `BASE_BRANCH` と
`PROMOTION_TARGET_BRANCH` が同一となるため、本機能は no-op として振る舞う。
`STAGING_BRANCH` を独立に導入する 3-branch model は本フェーズの対象外とする
（後続フェーズで検討）。

## Requirements

### 1. Opt-in gate と適用条件

**Objective:** As an existing watcher operator, I want Phase B 機能を環境変数で明示的に有効化したい, so that 既存運用に影響を与えずに段階導入できる。

#### 1.1 環境変数による有効化

1. While `PROMOTE_PIPELINE_ENABLED` が未設定または `false` である, the Issue Watcher shall Phase B 導入前と同一の処理フローのみを実行する
2. When `PROMOTE_PIPELINE_ENABLED=true` であり、かつ `BASE_BRANCH` と `PROMOTION_TARGET_BRANCH` が異なる値に設定されている, the Issue Watcher shall watcher サイクル内で Promote Pipeline Processor を起動する
3. While `BASE_BRANCH` が未設定または `PROMOTION_TARGET_BRANCH` と等しい, the Promote Pipeline Processor shall 起動せず no-op として終了する
4. The Promote Pipeline Processor shall 既存環境変数（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `BASE_BRANCH`, `TRIAGE_MODEL`, `DEV_MODEL` 等）のデフォルト値と意味を変更しない

#### 1.2 `PROMOTION_TARGET_BRANCH` の解釈

1. The Promote Pipeline Processor shall `PROMOTION_TARGET_BRANCH` が未設定の場合に既定値 `main` を採用する
2. If `PROMOTION_TARGET_BRANCH` がリモートに存在しない, the Promote Pipeline Processor shall 当該サイクルでの promote 操作を中止し、watcher ログに ERROR を記録する

### 2. ST 連携と `staged-for-release` 自動付与

**Objective:** As a release manager, I want `BASE_BRANCH` に merge された変更を ST 結果に応じて自動的に Issue ラベル状態に反映したい, so that release 待ち集合と ST failure 集合を Issue 一覧画面のラベルフィルタだけで把握できる。

#### 2.1 `staged-for-release` 自動付与

1. When approved PR が Phase A の Merge Queue Processor によって `BASE_BRANCH` に merge された, the Promote Pipeline Processor shall 当該 PR に `Closes #N` 等でリンクされた Issue に `staged-for-release` ラベルを自動付与する
2. The Promote Pipeline Processor shall 既存の人間付与による `staged-for-release` ラベル（#100 で定義された運用）と自動付与による `staged-for-release` ラベルを名前・色・description において区別せず、同一ラベルを使用する
3. If 対象 Issue にすでに `staged-for-release` ラベルが付いている, the Promote Pipeline Processor shall ラベル付与 API を再送せず、重複付与によるイベント発火を抑止する

#### 2.2 ST check-run 結果のポーリング

1. While Issue に `staged-for-release` ラベルが付与されている, the Promote Pipeline Processor shall 当該 Issue にリンクされた直近の `BASE_BRANCH` commit に対する ST check-run の状態を取得する
2. The Promote Pipeline Processor shall ポーリング対象の ST check-run 名を環境変数 `ST_CHECK_RUN_NAME` の値（単一文字列）で特定する
3. If `ST_CHECK_RUN_NAME` が未設定である, the Promote Pipeline Processor shall ST 結果連動を停止し、watcher ログに WARN を記録した上で当該サイクルでの promote を行わない
4. While ST check-run が `pending` / `in_progress` 相当の未完了状態である, the Promote Pipeline Processor shall 当該 Issue に対するラベル変更・promote を行わず次回サイクルに持ち越す
5. While Issue が `staged-for-release` でラベル付けされているが対応する ST check-run が存在しない, the Promote Pipeline Processor shall 当該 Issue に対する状態判断を見送り、watcher ログに WARN を記録する

#### 2.3 ST success 時の挙動

1. When ST check-run が success と判定された, the Promote Pipeline Processor shall 当該 Issue から `staged-for-release` ラベルを除去する
2. When ST success に伴ってラベルを除去した直後, the Promote Pipeline Processor shall 当該変更を `PROMOTION_TARGET_BRANCH` への promote 対象集合に含める

#### 2.4 ST failure 時の挙動（revert-and-continue）

1. When ST check-run が failure と判定された, the Promote Pipeline Processor shall 当該 Issue に `st-failed` ラベルを付与する
2. When ST failure を検知した, the Promote Pipeline Processor shall `BASE_BRANCH` 上で対応する merge commit に対して `git revert -m 1` 相当の revert commit を作成し、`--force-with-lease` 相当の安全 push でリモートに反映する
3. When ST failure に伴う revert を行った, the Promote Pipeline Processor shall 対応する Issue を reopen し、ST log の URL を含む 1 件のステータスコメントを Issue に投稿する
4. When ST failure に伴って revert・Issue 再オープン・コメント投稿を行った, the Promote Pipeline Processor shall 当該 Issue から `staged-for-release` ラベルを除去する
5. If 1 件の Issue で ST failure を検知した, the Promote Pipeline Processor shall 他の `staged-for-release` 付き Issue の処理を継続する（fail-continue を維持する）
6. If revert commit の push が失敗した（リモート先行等の理由）, the Promote Pipeline Processor shall 当該 Issue の `st-failed` 付与を保留し、watcher ログに WARN を記録して次の Issue の処理に進む

### 3. `BASE_BRANCH` → `PROMOTION_TARGET_BRANCH` の昇格

**Objective:** As a release manager, I want ST success 済みの変更をリリースブランチへ自動 fast-forward したい, so that 手動 release PR を毎回作成する手間を排除できる。

#### 3.1 昇格手段（fast-forward）

1. When promote 対象が確定した, the Promote Pipeline Processor shall `BASE_BRANCH` の HEAD を `PROMOTION_TARGET_BRANCH` に対して fast-forward push で反映する
2. The Promote Pipeline Processor shall fast-forward 可能でない状態（`PROMOTION_TARGET_BRANCH` 側が `BASE_BRANCH` の祖先でない）を検知した場合、promote 操作を中止する
3. If 上記 3.1.2 によって promote 操作を中止した, the Promote Pipeline Processor shall watcher ログに `promote-failed` 相当の識別語を含む WARN を出し、Issue 側のラベル状態を変更しない
4. The Promote Pipeline Processor shall promote 操作中もローカルワーキングコピーが dirty にならないよう、操作終了時に元の checkout 状態へ復帰する

#### 3.2 `PROMOTE_MODE` による昇格タイミング制御

1. The Promote Pipeline Processor shall 環境変数 `PROMOTE_MODE` から `continuous` / `batched` / `on-demand` のいずれかの値を受け取る
2. While `PROMOTE_MODE` が未設定または不正値である, the Promote Pipeline Processor shall 既定値 `on-demand` で動作する
3. Where `PROMOTE_MODE=continuous` が設定されている, the Promote Pipeline Processor shall ST success 検知サイクルと同一サイクルで promote を実行する
4. Where `PROMOTE_MODE=batched` が設定されている, the Promote Pipeline Processor shall 環境変数 `PROMOTE_CRON` で指定された標準 cron 式に合致する時刻ウィンドウでのみ promote を実行する
5. Where `PROMOTE_MODE=on-demand` が設定されている, the Promote Pipeline Processor shall ST success 検知後も `staged-for-release` ラベルを除去せず、人間トリガー（明示的な promote コマンド／別 Issue 起票）を待つ
6. While `PROMOTE_MODE=batched` かつ `PROMOTE_CRON` が未設定または不正な cron 式である, the Promote Pipeline Processor shall 当該サイクルでの promote を行わず、watcher ログに WARN を記録する

#### 3.3 昇格失敗時の通知

1. If promote 操作が失敗した, the Promote Pipeline Processor shall watcher ログに失敗理由を含む WARN/ERROR を必ず記録する
2. Where 環境変数 `PROMOTE_FAIL_NOTIFY_ISSUE` に有効な Issue 番号が設定されている, the Promote Pipeline Processor shall 当該 Issue に promote 失敗の旨と原因を含む 1 件のコメントを投稿する
3. While `PROMOTE_FAIL_NOTIFY_ISSUE` が未設定または不正である, the Promote Pipeline Processor shall log 出力のみに留め、Issue へのコメント投稿を行わない

### 4. ラベル定義と既存ラベル契約

**Objective:** As an operator, I want Phase B で増えるラベルが既存の一括ラベル作成スクリプトで配布されるようにしたい, so that 各リポジトリで個別に `gh label create` を打たずに済む。

#### 4.1 `st-failed` ラベルの追加

1. When 運用者が idd-claude の一括ラベル作成スクリプトを実行する, the Labels Setup Script shall `st-failed` ラベルを作成する
2. The Labels Setup Script shall `st-failed` を「Issue に適用するラベル」として扱い、既存 idd-claude 標準ラベルの description における 適用先 prefix 規約に整合させる
3. The Labels Setup Script shall idd-claude 自身用（self-hosting）と consumer 配布用テンプレートの両系統で、同一の名前・色・description で `st-failed` を提供する
4. The Labels Setup Script shall 再実行に対して冪等であり、`st-failed` 追加によって複数回実行時のラベル状態が不整合にならない

#### 4.2 既存ラベル契約の保持

1. The Labels Setup Script shall 既存ラベル（`auto-dev` / `needs-decisions` / `awaiting-design-review` / `claude-claimed` / `claude-picked-up` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` / `needs-quota-wait` / `staged-for-release`）の名前・色・description を Phase B 追加に伴って変更しない
2. The Promote Pipeline Processor shall `staged-for-release` ラベル名・色・description（#100 で定義されたもの）を変更せず、付与・除去契約のみを拡張する
3. The Promote Pipeline Processor shall 既存ラベルの付与契約（Phase A の `needs-rebase` 付与契約等）の意味と挙動を変更しない

### 5. ロギング・可観測性

**Objective:** As an operator, I want Phase B の判断と操作結果をログから追えるようにしたい, so that ST 失敗時の revert や promote 失敗時の原因を grep だけで特定できる。

#### 5.1 ログ出力契約

1. The Promote Pipeline Processor shall Issue Watcher と同一のタイムスタンプ書式（`[YYYY-MM-DD HH:MM:SS]`）でログを出力する
2. The Promote Pipeline Processor shall 各 Issue ごとに「Issue 番号」「ST 状態（pending/success/failure/missing）」「実施したアクション（label-add / label-remove / promote / revert / skip）」を 1 行以上のログに出力する
3. The Promote Pipeline Processor shall サイクル終了時に「ST success → promote 成功数」「ST failure → revert 数」「pending によるスキップ数」「失敗数」のサマリをログに出力する
4. The Promote Pipeline Processor shall ログ出力先を既存 watcher の `LOG_DIR` 配下に統一し、新規の出力ディレクトリを作らない
5. The Promote Pipeline Processor shall 各ログ行に対象リポジトリを示す `[$REPO]` プレフィックスと、grep 集計用の識別語（例: `promote-pipeline:` / `promote-failed` 等の機械可読プレフィックス）を含める

### 6. ドキュメント更新（DoD）

**Objective:** As a new operator, I want Phase B の挙動・有効化方法・新ラベルの意味と状態遷移を README から読み取れるようにしたい, so that 既存ユーザが追加機能の opt-in 可否を即判断できる。

#### 6.1 README 記載項目

1. The README.md shall Phase B Promote Pipeline の概要（目的・対象・タイミング）を記述するセクションを含む
2. The README.md shall Phase B の opt-in 環境変数（`PROMOTE_PIPELINE_ENABLED`, `PROMOTION_TARGET_BRANCH`, `ST_CHECK_RUN_NAME`, `PROMOTE_MODE`, `PROMOTE_CRON`, `PROMOTE_FAIL_NOTIFY_ISSUE`）の名称・デフォルト値・推奨値を明記する
3. The README.md ラベル一覧 shall `st-failed` の「適用先」「付与主」「意味」を記載する
4. The README.md ラベル状態遷移節 shall Phase B 導入後の `staged-for-release` 状態遷移（自動付与・ST 結果による除去・revert）を補助フローとして記述する
5. The README.md shall #100 で定義された人間付与の `staged-for-release` 運用と、Phase B による自動付与の `staged-for-release` 運用が同一ラベルを共有する旨を明記する
6. The README.md shall Phase B 導入による後方互換性方針（`PROMOTE_PIPELINE_ENABLED` 未設定時に既存挙動が完全保持されること、既存 env / ラベル / lock / exit code が不変であること）を migration note として明記する

#### 6.2 関連ドキュメントとの整合

1. When 運用者が `QUICK-HOWTO.md` の「作成されるラベル」一覧を参照する, the QUICK-HOWTO.md shall `st-failed` を含むラベル一覧を提示する
2. The Documentation Set shall ラベル名 `st-failed` を全ドキュメントで完全一致（lowercase, ハイフン区切り）で記載する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `PROMOTE_PIPELINE_ENABLED` が未設定または `false` である, the Issue Watcher shall Phase B 導入前と完全に同一の挙動（既存 env var の意味・既存ラベル契約・既存 lock ファイルパス・既存ログ出力先・既存 exit code）を保持する
2. The Promote Pipeline Processor shall 既存環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `BASE_BRANCH`, `MERGE_QUEUE_ENABLED` 等）の意味とデフォルト挙動を変更しない
3. The Promote Pipeline Processor shall 既存ラベル契約を破壊しない（Phase A `needs-rebase` 契約・#100 `staged-for-release` 契約を含む）

### NFR 2: 安全性

1. The Promote Pipeline Processor shall リモートに対する破壊的操作として `--force-with-lease` 相当の安全 push のみを使用し、無条件 force push（`--force`）を使わない
2. The Promote Pipeline Processor shall `PROMOTION_TARGET_BRANCH` への昇格を fast-forward に限定し、merge commit や rebase による non-fast-forward 昇格を行わない
3. If 想定外のローカル変更（dirty working tree）が検知された, the Promote Pipeline Processor shall 当該サイクルでの promote / revert 操作を中止し、watcher ログに ERROR を記録する
4. The Promote Pipeline Processor shall fork PR（head repo owner が base repo owner と異なる PR）を起点とした自動 promote・自動 revert 対象から除外する

### NFR 3: 障害分離

1. If 1 件の Issue 処理（ST 判定 / label 操作 / revert / promote のいずれか）が失敗した, the Promote Pipeline Processor shall 他の Issue / PR の処理を中断せず継続する（fail-continue を保持する）
2. The Promote Pipeline Processor shall 1 件の処理に対してサブプロセス（`gh api` / `git revert` / `git push` 等）のタイムアウトを設け、ハングを防止する

### NFR 4: 観測可能性

1. The Promote Pipeline Processor shall 各操作結果（label-add / label-remove / promote-success / promote-failed / revert / skip）を operator がログ grep するだけで集計できる識別語でマークする
2. The Promote Pipeline Processor shall watcher 既存の出力契約（標準エラー出力は人間向け WARN/ERROR、標準出力は機械可読集計用）に揃える

### NFR 5: パフォーマンス

1. The Promote Pipeline Processor shall 1 サイクル内での ST ポーリング・promote・revert 操作合計時間が、watcher 最短実行間隔（README 既定 2 分）以内に収まることを目指す
2. The Promote Pipeline Processor shall 1 Issue あたりの GitHub API 呼び出し回数を、ST 状態取得・ラベル操作・コメント投稿・Issue 状態変更の合計で 10 回以内に抑える

## Out of Scope

- `BASE_BRANCH` 環境変数自体の導入（#89 で完了済み）
- `staged-for-release` ラベル定義の追加（#100 で完了済み）
- approved PR を `BASE_BRANCH` へ自動 merge する仕組み（#14 Phase A Merge Queue Processor の範囲）
- semantic conflict の Claude による自動解決（#17 Phase D の範囲）
- 並列 promote worker（複数 PROMOTE_MODE を同時に動かす仕組み）
- 独立した `STAGING_BRANCH` を介した 3-branch model（`BASE_BRANCH` + `STAGING_BRANCH` + `PROMOTION_TARGET_BRANCH`）
- ST check-run 名を正規表現／複数候補で解決する仕組み（`ST_CHECK_RUN_NAME` は単一文字列のみ）
- 人間付与の `staged-for-release` と自動付与の `staged-for-release` を区別するラベル名／属性の追加
- revert された commit に対する自動的な再修正（再 implement / cherry-pick リトライ等）
- fork からの PR を起点とした自動 promote / 自動 revert
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への Phase B 機能の組み込み
- `PROMOTE_MODE=batched` における高度なジョブスケジューラ統合（標準 cron 式以外の DSL 対応）

## 確認事項

- なし（Issue 本文の Open Questions Q1〜Q5 はいずれも Issue コメントで人間が提示した推奨値
  〈2-branch model 採用 / `PROMOTE_MODE` 既定値 `on-demand` / `ST_CHECK_RUN_NAME` は単一 env /
  `staged-for-release` source 区別なし / promote 失敗通知は log + `PROMOTE_FAIL_NOTIFY_ISSUE` 指定時の
  Issue コメント〉に従って本要件に確定済み）
