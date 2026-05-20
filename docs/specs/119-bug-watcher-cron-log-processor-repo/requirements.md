# Requirements Document

## Introduction

idd-claude の watcher は 1 リポジトリ 1 cron entry で起動され、全リポジトリのログを
共通の `$HOME/.issue-watcher/cron.log` に append する設計だが、`pr-iteration:` /
`merge-queue:` / `merge-queue-recheck:` / `design-review-release:` / `quota-aware:`
などの processor 系ログ行には repo 識別子（`owner/name`）が含まれていない。

このため複数リポを並行運用する環境では、ある repo が cycle 冒頭の `git checkout`
失敗で abort して processor ステージに到達していない状況と、別 repo の `対象候補
0 件` ログが混在し、運用者が grep で repo を絞り込めず沈黙の失敗を見抜けない。
実機事例として `keynest_for_mimamowellness` の dirty working tree 由来の checkout
失敗が約 3 時間検知されず、needs-iteration が放置された。

本要件は (1) 全 processor 系ログ行に `[<REPO>]` prefix を付けて grep 可能にし、
(2) cycle 冒頭の checkout 失敗を「無 prefix の git 純正 stderr」ではなく構造化
された 1 イベントとして cron.log に残し、(3) 運用者が複数リポ運用時に使う
grep 例を README / QUICK-HOWTO に追加することで、沈黙の失敗を観測可能にする。
auto-recover の中身そのものは別 Issue に委ね、本要件は **可視化** のみを対象とする。

## Requirements

### Requirement 1: processor 系ログ行への repo 識別子付与

**Objective:** As a watcher 運用者, I want processor 系ログ行から repo を grep で特定できる状態, so that 複数リポ運用下でも対象 repo のサイクルだけを正確に追える

#### Acceptance Criteria

1. When `pi_log` / `pi_warn` / `pi_error` のいずれかが出力されるとき, the Watcher shall ログ行の時刻 prefix の直後に `[<REPO>]` 形式の repo 識別子を 1 つ含める
2. When `mq_log` が出力されるとき, the Watcher shall ログ行の時刻 prefix の直後に `[<REPO>]` 形式の repo 識別子を 1 つ含める
3. When `mqr_log` が出力されるとき, the Watcher shall ログ行の時刻 prefix の直後に `[<REPO>]` 形式の repo 識別子を 1 つ含める
4. When `drr_log` が出力されるとき, the Watcher shall ログ行の時刻 prefix の直後に `[<REPO>]` 形式の repo 識別子を 1 つ含める
5. When quota-aware 系ロガー（既存 `pi_log` / `mq_log` と同形式のもの）が出力されるとき, the Watcher shall ログ行の時刻 prefix の直後に `[<REPO>]` 形式の repo 識別子を 1 つ含める
6. The Watcher shall `[<REPO>]` の `<REPO>` 部に環境変数 `REPO` の値（`owner/name` 形式）をそのまま埋め込む
7. The Watcher shall 同一ログ行に repo 識別子を 2 つ以上重ねて出力しない
8. While `REPO` が `owner/your-repo` 既定値のままであるとき, the Watcher shall その既定値をそのまま `[<REPO>]` として出力する

### Requirement 2: ログ行構造の後方互換性

**Objective:** As a 既存 grep スクリプトを書いている運用者, I want 時刻 prefix と processor prefix の構造が維持された状態, so that 既存の log 解析ワンライナーを大幅に書き直さずに済む

#### Acceptance Criteria

1. The Watcher shall ログ行の先頭を `[YYYY-MM-DD HH:MM:SS]` 形式の時刻 prefix で開始する
2. The Watcher shall 時刻 prefix と `[<REPO>]` の後ろに、既存の processor prefix（`pr-iteration:` / `merge-queue:` / `merge-queue-recheck:` / `design-review-release:` / `quota-aware:`）を従来の文字列のまま保持する
3. The Watcher shall 既存ログ行で使用していた processor prefix 文字列・サマリ行のキー名・カウンタ名を本要件導入前と同一に保つ
4. The Watcher shall `[<REPO>]` を追加すること以外でログ本文の表現（句読点・カウンタ名・サマリ書式）を変更しない

### Requirement 3: cycle 冒頭 checkout 失敗の構造化ログ化

**Objective:** As a watcher 運用者, I want 作業ツリーが dirty で BASE_BRANCH checkout に失敗したサイクルが構造化されたログとして cron.log に残ること, so that 沈黙の失敗を grep で検知できる

#### Acceptance Criteria

1. If cycle 冒頭の BASE_BRANCH checkout が dirty working tree により失敗したとき, the Watcher shall `watcher: [<REPO>] dirty working tree blocks BASE_BRANCH checkout` を 1 行目として cron.log に出力する
2. When Requirement 3.1 のイベントを出力するとき, the Watcher shall 続けて `current_branch=<value>` / `dirty_files=<count>` / `head=<short-sha>` / `action=<auto-recover|escalate>` の 4 値を構造化された形でログに含める
3. If cycle 冒頭の checkout 失敗を検出したとき, the Watcher shall 当該サイクルの processor ステージ（pr-iteration / merge-queue / merge-queue-recheck / design-review-release）を開始しない
4. If cycle 冒頭の checkout 失敗を検出したとき, the Watcher shall 当該サイクルの終了 exit code を 0 以外で返す
5. The Watcher shall checkout 失敗イベントのログ行に Requirement 1 と同じ `[<REPO>]` prefix を含めることで、processor 系ログと同じ grep キーで抽出可能にする

### Requirement 4: 複数リポ運用向け grep ガイドのドキュメント整備

**Objective:** As a 新規運用者, I want 複数リポ運用時の cron.log grep 例がドキュメントで提示された状態, so that 自力で正しい正規表現を組み立てなくても repo 単位の調査ができる

#### Acceptance Criteria

1. The Documentation shall README または QUICK-HOWTO のいずれかに「複数リポ運用時の cron.log grep 例」節を含める
2. The Documentation shall 特定 repo のサイクルだけを抽出する grep 例（例: `grep "\[owner/name\]" ~/.issue-watcher/cron.log`）を 1 件以上含める
3. The Documentation shall 全 repo を通じて pr-iteration の失敗・skip 系イベントを抽出する grep 例を 1 件以上含める
4. The Documentation shall checkout 失敗イベント（Requirement 3）を抽出する grep 例を 1 件以上含める

### Requirement 5: 既存サンプル・運用スクリプトの整合

**Objective:** As a ドキュメント参照者, I want リポジトリ内の既存サンプル grep / sed コマンドが新フォーマットで動く状態, so that ドキュメント記載のコマンドをコピペしてもログがヒットする

#### Acceptance Criteria

1. If README または QUICK-HOWTO 内に既存の `cron.log` grep / sed サンプルが存在するとき, the Documentation shall 当該サンプルを `[<REPO>]` prefix を含む新フォーマットでも動作する記述に更新する
2. The Documentation shall 同一 PR 内で挙動変更（Requirement 1〜3）と該当ドキュメント更新（Requirement 4・5）を揃えて反映する

### Requirement 6: テストによる prefix 付与の確認

**Objective:** As a watcher のメンテナ, I want repo prefix の付与をテストで検証できる状態, so that 将来のリファクタで prefix が抜け落ちる退行を検知できる

#### Acceptance Criteria

1. The Watcher Test Suite shall `pi_log` / `mq_log` / `mqr_log` / `drr_log` を経由するサイクルのログ出力に `[<REPO>]` prefix が含まれることを検証するテストを 1 件以上含める
2. The Watcher Test Suite shall Requirement 3 の checkout 失敗イベント 4 行が cron.log に残ることを検証するテストを 1 件以上含める
3. While 既存 cycle テスト（pr-iteration / merge-queue / design-review-release）が走るとき, the Watcher Test Suite shall 本要件導入前と同じ pass 状態を維持する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Watcher shall 既存の環境変数名（`REPO` / `REPO_DIR` / `REPO_SLUG` / `LOG_DIR` / `LOCK_FILE` / `BASE_BRANCH` 等）の意味と既定挙動を変更しない
2. The Watcher shall 既存の cron 登録文字列（`*/N * * * * REPO=... REPO_DIR=... $HOME/bin/issue-watcher.sh`）を変更せずに本要件の挙動が成立する状態を維持する
3. The Watcher shall 既存の ログ出力ファイルパス（`$HOME/.issue-watcher/cron.log`）と append 動作を維持する
4. The Watcher shall 既存ラベル名（`auto-dev` / `claude-claimed` / `needs-decisions` / `claude-failed` 等）と cycle の exit code の意味を変更しない

### NFR 2: 可観測性の運用基準

1. The Watcher shall Requirement 1・3 のログ行を 1 イベント 1 行で出力し改行を含めない
2. The Watcher shall Requirement 1 の `[<REPO>]` prefix を、運用者が `grep "\[owner/name\]"` の単一 grep で当該 repo のサイクル全行を抽出できる位置と形式で配置する
3. The Watcher shall Requirement 3 の checkout 失敗イベント 4 行を、grep で時刻範囲を絞り込んだ際に隣接行として観測できる順序で連続出力する

### NFR 3: 性能・互換性

1. The Watcher shall prefix 付与によるサイクル全体の追加遅延を 100ms 未満に抑える
2. The Watcher shall 既存 cron entry の起動間隔（最短 2 分）以内に本要件導入前と同等のサイクル完了時間を維持する

## Out of Scope

- `git checkout` 失敗時の auto-recover ロジックそのもの（dirty working tree からの自動 commit & push、人間 escalation 振り分け）。本要件は **可視化** のみを対象とし、recover の中身は別 Issue に切り出す
- cron.log を repo 別ファイルに分割する経路（例: `$HOME/.issue-watcher/cron-<repo-slug>.log`）。cron entry の書き換えが必要で破壊的、本要件は prefix 方式に限定する
- 既存ログ行の表現・言語の統一（日本語 / 英語混在の正規化、i18n）
- syslog / journald / 外部 log 集約サービスへのログ送出（本リポジトリは file-based ログ前提）
- prefix フォーマットを `[<REPO_SLUG>]` へ切り替える運用判断（本要件は `[<REPO>]`＝`owner/name` 形式に固定）
- 既存ログ形式と新フォーマットを移行期間中に並存させる二重 emit 経路（一括書き換え方針を採用する）
- 本要件以外の dispatcher・Triage 系ログ整形（既に repo 情報を含む行は対象外、未対応行があれば本要件の Requirement 1 で吸収する）

## Open Questions

- なし（Issue 本文「仮案・判断を委ねたい点」のうち、prefix フォーマットは `[<REPO>]`（`owner/name`）を採用し、既存ログ行は移行期間を設けず一括書き換える方針で確定。checkout 失敗の検出経路は `git status --porcelain` を用いた先読みでも `git checkout` の stderr 包み込みでも要件 3 を満たせばよく、選択は design 領分とする）
