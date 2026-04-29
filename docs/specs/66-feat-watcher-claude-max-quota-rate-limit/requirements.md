# Requirements Document

## Introduction

watcher の各 Stage は内部で `claude` CLI を呼び出すが、Claude Max サブスクリプションには 5 時間ローリングウィンドウの quota がある。実装中に quota 超過すると現在は CLI が非ゼロ終了するだけで、watcher は他の失敗（parse-failed / coverage 不足 / 実装エラー）と区別できず一律 `claude-failed` として人間に escalate してしまう。さらに quota window が reset された後も自動再開する仕組みがないため、夜間に quota 切れた Issue は人間が翌日手動で復旧するまで停止し続ける。本機能は claude CLI が出力する `rate_limit_event` JSON を watcher が解釈し、quota 起因の失敗を専用ラベル `needs-quota-wait` として `claude-failed` から分離した上で、reset 時刻経過後に自動で通常 pickup ループへ復帰させる仕組みを opt-in で導入する。既存の cron 登録・env var 名・終端ラベル契約・既 install 済み consumer repo への影響を保ちながら、本リポジトリ自身（dogfooding）でも quota 超過 → 自動 resume が end-to-end で成立することを保証する。

## Requirements

### Requirement 1: Opt-in 切り替えと既定挙動

**Objective:** As a 既存運用者, I want quota-aware 機能を明示的に有効化するまで現在の挙動が一切変わらないこと, so that 本機能の deploy が既存 cron / launchd 運用にダウンタイムを起こさない

#### Acceptance Criteria

1. While `QUOTA_AWARE_ENABLED` 環境変数が未設定または `false` である間, the Issue Watcher shall claude CLI 出力の `rate_limit_event` 解析・`needs-quota-wait` 付与・自動 resume 処理のいずれも実行しない
2. While `QUOTA_AWARE_ENABLED=true` が設定されている間, the Issue Watcher shall 本ドキュメントの Requirement 2〜5 で規定する rate_limit 検知・ラベル付与・reset 永続化・自動 resume の各挙動を有効化する
3. The Issue Watcher shall `QUOTA_AWARE_ENABLED` 既定値を `false` に固定する
4. The Issue Watcher shall 既存環境変数（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）の名前・受理形式・意味を本機能の追加によって変更しない
5. The Issue Watcher shall 既存 cron / launchd 登録文字列を変更しなくても本機能が無効化された状態で従来通り動作する状態を維持する
6. The Issue Watcher shall 既存ラベル `auto-dev` / `claude-claimed` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `needs-iteration` / `needs-rebase` / `skip-triage` の名前・意味・遷移条件を本機能の追加によって変更しない

### Requirement 2: rate_limit_event の検知と quota 超過判定

**Objective:** As a 運用者, I want claude CLI が出力する rate_limit_event を watcher が解析して quota 超過を判定できる, so that quota 起因の Stage 失敗が他の失敗原因と区別できる

#### Acceptance Criteria

1. Where `QUOTA_AWARE_ENABLED=true` が有効である, the Issue Watcher shall Stage 実行中の claude CLI 出力から `rate_limit_event` 種別の JSON イベントを抽出する
2. When `rate_limit_event` の `status` が `exceeded` であるイベントを検出したとき, the Issue Watcher shall 当該 Stage を quota 超過として分類する
3. When quota 超過と分類されたイベントを検出したとき, the Issue Watcher shall 当該イベントから reset 予定時刻（UNIX エポック秒）を取り出して保持する
4. If 同一 Stage 実行中に複数の `rate_limit_event` (status=exceeded) を検出したとき, the Issue Watcher shall 最新（最後に観測した）イベントの reset 時刻を採用する
5. If `rate_limit_event` JSON の解析に失敗したとき, the Issue Watcher shall 当該 Stage を quota 超過として分類せず、既存の Stage 失敗フローに委ねる
6. While `rate_limit_event` の `status` が `allowed` のみで `exceeded` を含まない間, the Issue Watcher shall 当該 Stage を quota 超過として分類しない

### Requirement 3: quota 超過時の専用ラベル付与と escalation

**Objective:** As a 運用者, I want quota 起因の停止と他要因（parse-failed / coverage 不足等）の停止をラベルだけで区別したい, so that ログを読まずに原因切り分けができ、quota wait 中の Issue は誤って手動介入対象に混ざらない

#### Acceptance Criteria

1. When 当該 Stage が Requirement 2 により quota 超過として分類されたとき, the Issue Watcher shall 当該 Issue に `needs-quota-wait` ラベルを付与する
2. When `needs-quota-wait` ラベルを付与するとき, the Issue Watcher shall 当該 Issue に `claude-failed` ラベルを付与しない
3. When `needs-quota-wait` ラベルを付与するとき, the Issue Watcher shall 進行中ラベル（`claude-claimed` / `claude-picked-up` のうち付与されているもの）を当該 Issue から除去する
4. When `needs-quota-wait` ラベルを付与するとき, the Issue Watcher shall 当該 Issue に escalation コメントを投稿し、検知した Stage 種別（Triage / Developer / Reviewer / PjM のいずれか）と reset 予定時刻を ISO 8601 形式（タイムゾーン付き）で明記する
5. While Issue に `needs-quota-wait` ラベルが付与されている間, the Issue Watcher shall 当該 Issue を新規 pickup 対象から除外する
6. The Issue Watcher shall pickup 対象検索の除外条件に `needs-quota-wait` を追加し、既存の除外条件（`claude-claimed` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `needs-iteration`）の意味を保持する
7. The Issue Watcher shall 1 つの Issue に対して `needs-quota-wait` と `claude-failed` を同時に付与した状態を継続させない

### Requirement 4: reset 時刻の永続化

**Objective:** As a 運用者, I want quota 超過時の reset 予定時刻が watcher プロセス終了後も読み出せる形で保存されること, so that 次回 cron tick で別プロセスとなった watcher が reset 経過を正しく判定できる

#### Acceptance Criteria

1. When `needs-quota-wait` ラベルを付与するとき, the Issue Watcher shall 当該 Issue の reset 予定時刻（UNIX エポック秒）を当該 Issue 自身に紐づく形で永続化する
2. When 後続の cron tick で同一 Issue を再評価するとき, the Issue Watcher shall 永続化された reset 予定時刻を読み出して比較に使用する
3. The Issue Watcher shall reset 時刻の永続化を 1 Issue につき最新値 1 件のみ保持する形で行い、複数値が並存して曖昧になる状態を発生させない
4. If 永続化された reset 時刻が読み出せないか不正な値であるとき, the Issue Watcher shall 当該 Issue の `needs-quota-wait` を自動除去せず、後続の cron tick での再判定または人間判断に委ねる

### Requirement 5: reset 経過後の自動 resume

**Objective:** As a 運用者, I want quota window が reset した後に watcher が自動で `needs-quota-wait` を外して通常 pickup に戻すこと, so that 夜間 quota 切れの Issue が翌朝以降の人間操作なしに完了まで進む

#### Acceptance Criteria

1. Where `QUOTA_AWARE_ENABLED=true` が有効である, the Issue Watcher shall 各 cron tick の冒頭で `needs-quota-wait` ラベル付き open Issue を走査する Quota Resume Processor を実行する
2. When Quota Resume Processor が `needs-quota-wait` 付き Issue を発見し、現在時刻が当該 Issue の reset 予定時刻 + `QUOTA_RESUME_GRACE_SEC` 秒を超えているとき, the Issue Watcher shall 当該 Issue から `needs-quota-wait` ラベルを除去する
3. While 現在時刻が reset 予定時刻 + `QUOTA_RESUME_GRACE_SEC` 秒に達していない間, the Issue Watcher shall 当該 Issue から `needs-quota-wait` ラベルを除去しない
4. When `needs-quota-wait` ラベルが Quota Resume Processor によって除去されたとき, the Issue Watcher shall 当該 Issue を以後の通常 pickup ループの対象として扱い、本機能内で claim や Stage 実行を直接トリガーしない
5. The Issue Watcher shall `QUOTA_RESUME_GRACE_SEC` 既定値を `60` 秒に固定し、env var で上書き可能にする
6. If Quota Resume Processor 実行中に GitHub API 呼び出しが失敗したとき, the Issue Watcher shall 当該サイクルでの後続処理（Merge Queue / PR Iteration / Design Review Release / Issue Pickup 等）を中断せず継続する

### Requirement 6: ラベル定義スクリプトの冪等更新

**Objective:** As a 既存 install 済みリポジトリの運用者, I want `idd-claude-labels.sh` を再実行するだけで `needs-quota-wait` ラベルが追加されること, so that 追加の手作業なくラベル基盤を更新できる

#### Acceptance Criteria

1. When 運用者が `bash .github/scripts/idd-claude-labels.sh` を実行したとき, the Label Setup Script shall `needs-quota-wait` ラベルを当該リポジトリに追加する
2. While `needs-quota-wait` ラベルが既に存在するとき, the Label Setup Script shall 当該ラベルを再作成せず冪等にスキップする
3. When 運用者が `bash .github/scripts/idd-claude-labels.sh --force` を実行したとき, the Label Setup Script shall 既存の `needs-quota-wait` ラベル定義を上書き更新する
4. The Label Setup Script shall 既存ラベル群（`auto-dev` / `claude-claimed` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration`）の name / color / description を本機能の追加によって変更しない
5. The Label Setup Script shall `needs-quota-wait` ラベルの description に【Issue 用】prefix（既存規約 Issue #54 準拠）を含める

### Requirement 7: ドキュメント整合

**Objective:** As a 新規 contributor, I want quota-aware 機能の挙動・env・opt-in 手順が README に記載されていること, so that 仕様書とコードの挙動の食い違いに惑わされない

#### Acceptance Criteria

1. The Documentation shall README に `## Quota-Aware Watcher` 節を追加し、本機能の opt-in 手順・有効化時の挙動・新ラベル `needs-quota-wait` の意味と除去契約を記載する
2. The Documentation shall README のラベル一覧に `needs-quota-wait` を追加し、付与タイミング（quota 超過検知時）・除去タイミング（reset 経過時に Quota Resume Processor が自動除去）を記載する
3. The Documentation shall README に env var 一覧（`QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC`）と既定値を記載する
4. The Documentation shall README の状態遷移セクションに、進行中ラベル（`claude-claimed` / `claude-picked-up`）から `needs-quota-wait` への遷移、および `needs-quota-wait` から通常 pickup ループへの自動復帰を反映する
5. The Documentation shall `QUOTA_AWARE_ENABLED=false`（既定）では本機能が無効である旨を README で明示する

### Requirement 8: Dogfooding による動作検証

**Objective:** As a 開発者, I want 本リポジトリ自身に対して quota 超過検知 → 自動 resume が end-to-end で成立することを確認できる, so that 他リポジトリに展開する前に挙動破綻を検出できる

#### Acceptance Criteria

1. When quota exceeded を再現する fixture（claude CLI 出力に `rate_limit_event` `status=exceeded` を含む応答）に対して watcher を実行したとき, the Issue Watcher shall 対象 Issue に `needs-quota-wait` ラベルを付与する
2. When fixture で付与された reset 時刻 + `QUOTA_RESUME_GRACE_SEC` を経過した状態で watcher の cron tick を再実行したとき, the Issue Watcher shall 当該 Issue から `needs-quota-wait` ラベルを自動除去する
3. When `needs-quota-wait` が除去された後の cron tick で当該 Issue が pickup 候補となるとき, the Issue Watcher shall 当該 Issue を通常 pickup ループの対象として再選定する
4. The Test Plan shall 上記 dogfood シナリオを PR 本文の Test plan セクションに記載し、観測ログ・ラベル遷移の証跡を含める

## Non-Functional Requirements

### NFR 1: 観測可能性

1. While `QUOTA_AWARE_ENABLED=true` が有効である間, the Issue Watcher shall `rate_limit_event (status=exceeded)` 検知・`needs-quota-wait` 付与・reset 経過判定・`needs-quota-wait` 除去の各イベントを既存ログ出力先（`LOG_DIR` 配下）に追記し、運用者が事後に遷移経路を再構成できる粒度で記録する
2. The Issue Watcher shall 各ログ行に Issue 番号・Stage 種別・reset 予定時刻（UNIX エポック秒および ISO 8601）を含め、grep による事後検索を可能にする

### NFR 2: 後方互換性

1. The Issue Watcher shall `QUOTA_AWARE_ENABLED=false` の状態で、本機能導入前と同一の Stage 失敗時挙動（`claude-failed` 付与 + escalation コメント）を保持する
2. The Issue Watcher shall 既存の `claude-failed` 関連 Issue / PR の処理経路を本機能の追加によって変更しない
3. The Label Setup Script shall 既存 install 済みリポジトリで本スクリプトを再実行する以外の追加手作業を新ラベル導入に必要としない

### NFR 3: 性能・運用制約

1. The Issue Watcher shall Quota Resume Processor 1 回の実行を、対象 Issue 数が 0 件の場合に GitHub API 呼び出し 1 回（`needs-quota-wait` 付き Issue 一覧取得）以内に収める
2. The Issue Watcher shall Quota Resume Processor の実行を既存 watcher 全体タイムバジェット（cron 起動間隔の半分以内）に収め、後続 Processor の起動を阻害しない
3. The Issue Watcher shall 同一 Issue に対する `needs-quota-wait` 付与・除去の往復を 1 cron tick 内で発生させない（reset 直後の再失敗 → 即時付け直しを `QUOTA_RESUME_GRACE_SEC` で抑止する）

### NFR 4: 静的解析クリーン

1. The Issue Watcher script shall `shellcheck` 実行において新規警告を 0 件に保つ
2. The Label Setup Script shall `shellcheck` 実行において新規警告を 0 件に保つ

## Out of Scope

- partial work（Stage 途中までの進捗 commit）の保護・復元（別 Issue で扱う）
- Stage 単位の自動 retry（quota とは独立の失敗種別。別 Issue で扱う）
- quota 以外の rate-limit（API rate-limit / token rate-limit / 1 分単位 burst limit 等）の検知と扱い
- overage（`overageStatus` の `org_level_disabled` 解除等）への自動切り替え・課金プラン変更通知
- 多 repo 運用で同一 Anthropic アカウント token を共有する場合の grace period 競合の動的調整（`QUOTA_RESUME_GRACE_SEC` 固定値での対処に留める）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への quota-aware 機能の同等導入
- Reviewer Gate / PR Iteration Processor / Merge Queue Processor 等、Issue 以外を主対象とする Processor における quota 超過検知の対応（本 Issue では Issue Stage 系のみを対象とする）
- `needs-quota-wait` 状態が長期化した場合の自動エスカレーション（例: reset から N 時間経過しても resume されない場合の `claude-failed` 昇格）
- Triage / Developer / Reviewer / PjM 各 Stage 内部での部分 retry（Stage 全体の再実行は通常 pickup ループ経由で行う）

## Open Questions

以下は Architect が design.md で決定する設計論点であり、要件レベルでは挙動契約（永続化されること・cron tick で読み出せること・grace period で抑止されること）のみを AC 化している。Architect への申し送り事項として残す:

- reset 時刻の永続化媒体（Issue body の hidden marker / 専用 comment / label description / ローカルファイル等）の選定（Requirement 4）
- claude CLI 出力の解析方式（全 stdout buffer / tail stream / 行単位 jq fold）の選定（Requirement 2）
- 多 repo 運用で同一 Anthropic アカウント token を共有する場合の `QUOTA_RESUME_GRACE_SEC` 既定値の妥当性検証（NFR 3.3）
- escalation コメントのフォーマット詳細（Stage 種別の表記揺れ防止・既存 escalation コメントとの視覚的一貫性）
