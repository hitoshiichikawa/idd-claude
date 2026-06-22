# Requirements Document

## Introduction

idd-claude は完全自動化を志向しており、運用者が GitHub UI を常時監視しない前提で稼働する。
現状の観測手段は `run-summary` 構造化ログと watcher 自体のログファイル（`$HOME/.issue-watcher/logs/`）に
限定されており、自動 merge / failed-recovery 終端 / needs-decisions 自動続行 / promote といった
**結果系の重要イベント**を運用者が能動的に grep しなければ把握できない。本機能（D-18）は、
これらの重要イベントを **Slack Incoming Webhook 経由で push 通知**することで、
人間が介入すべきタイミング（特に異常終端・自動マージ完了・promote 完了）を能動的に検知できる
状態を提供する。

本機能は **低優先（D-18）**として位置付ける。通常の運用は引き続き `run-summary` + ログで
完結し、Slack 通知は補助的な可視化チャネルである。したがって、本機能の有効化は **env による
明示的 opt-in**（`SLACK_NOTIFY_ENABLED=true`）とし、未設定時は導入前と完全に同一の挙動を保つ。
通知失敗はパイプライン本体に伝播せず、警告ログのみを残す（fail-open）。webhook URL は secret 値
であり、env 経由で渡し、リポジトリへコミットしない。

## Requirements

### Requirement 1: Opt-in Gate と後方互換性

**Objective:** As an idd-claude operator, I want Slack 通知機能を env による明示的 opt-in で
のみ起動できる, so that 既存運用と他 processor の挙動を壊さず、Slack 連携を導入したくない
consumer は何も設定を変えずに済む

#### Acceptance Criteria

1. The watcher Config block shall declare `SLACK_NOTIFY_ENABLED` with a default value of `false`
2. While `SLACK_NOTIFY_ENABLED` is the exact string `true`, the watcher shall enable Slack 通知 emitter を起動可能状態にする
3. While `SLACK_NOTIFY_ENABLED` is unset / empty / any value other than `true`（`false` / `0` / `True` / typo 等を含む）, the watcher shall normalize the gate to OFF and not emit any Slack 通知
4. If `SLACK_NOTIFY_ENABLED=true` であっても `SLACK_WEBHOOK_URL` が未設定 / 空文字 のとき, the watcher shall Slack 通知を発行せず、no-op として扱い、エラー終了しない
5. The watcher shall 本機能導入前と完全に同一の cron tick 挙動（gh / git API 呼び出し回数・ラベル遷移・コミット・push）を保つ when `SLACK_NOTIFY_ENABLED` が無効化されているとき
6. The watcher shall 既存 env var 名 / ラベル名 / exit code 意味 / cron 登録文字列 / 既存ログ出力先に対して破壊的変更を加えない

### Requirement 2: 通知対象イベントの列挙

**Objective:** As an idd-claude operator, I want 重要イベント発生時に Slack 通知が 1 通発行
される, so that 人間が能動的に把握すべき自動処理の結果を push で受け取れる

#### Acceptance Criteria

1. When 自動 merge processor（auto-merge / auto-merge-design / merge-queue 経由を含む）が PR の merge を完了したとき, the watcher shall Slack 通知を 1 通発行する
2. When failed-recovery processor が Issue / PR を終端状態（成功復旧確定 / max-attempts 到達 / no-progress 終端 等の最終遷移）に遷移させたとき, the watcher shall Slack 通知を 1 通発行する
3. When needs-decisions 自動続行（`NEEDS_DECISIONS_MODE` が `classified` / `all-auto` で `safe` 分類の Issue が自動続行されたとき）が発火したとき, the watcher shall Slack 通知を 1 通発行する
4. When promote pipeline が `staged-for-release` PR を target branch（例: develop → main）に promote 完了したとき, the watcher shall Slack 通知を 1 通発行する
5. While 上記 2.1〜2.4 以外のイベント（routine な Triage / PM / Architect / Developer / Reviewer の段階遷移・log のみで完結する処理）が発生しているとき, the watcher shall Slack 通知を発行しない
6. When 同一イベントが同一 tick 内で複数回発火するとき, the watcher shall 各発火に対して 1 通ずつ Slack 通知を発行する（イベント単位の冪等化は本要件の責務外）

### Requirement 3: Slack Payload の最小情報

**Objective:** As an idd-claude operator, I want Slack 通知 payload から「どの repo の・どの
Issue / PR で・何が起きたか」を即座に判別したい, so that Slack 上で本文を開かずに概要把握と
深掘り判断ができる

#### Acceptance Criteria

1. The Slack 通知 payload shall 含む: イベント種別の識別子（`auto-merge` / `failed-recovery` / `needs-decisions-auto-continue` / `promote` のいずれか相当）
2. The Slack 通知 payload shall 含む: 対象 repo 識別子（`$REPO` 値、例: `hitoshiichikawa/idd-claude`）
3. The Slack 通知 payload shall 含む: 対象 Issue 番号または PR 番号
4. The Slack 通知 payload shall 含む: 該当 Issue / PR の GitHub URL（運用者が Slack からワンクリックで遷移できる）
5. Where 対象イベントが終端遷移を伴うとき（failed-recovery 終端・promote 完了 等）, the Slack 通知 payload shall 含む: 最終結果ステータス（success / failure / 終端理由 等のいずれか相当）
6. The Slack 通知 payload shall 機密情報（API key / OAuth token / webhook URL 自体 / Issue 本文中の secret 候補値）を含めない

### Requirement 4: 通知失敗時のフェイルセーフ（異常系）

**Objective:** As an idd-claude operator, I want Slack 通知の失敗がパイプライン本体に伝播しない, so that Slack 側の障害・rate limit・webhook 失効が watcher の自動処理を停止させない

#### Acceptance Criteria

1. If Slack Incoming Webhook への POST が HTTP error status（>= 400）を返したとき, the watcher shall パイプライン本体を継続し、警告ログを 1 行残す
2. If Slack Incoming Webhook への POST がネットワーク障害（接続失敗・タイムアウト 等）で失敗したとき, the watcher shall パイプライン本体を継続し、警告ログを 1 行残す
3. If Slack 通知 emitter 自体が内部エラー（payload 整形失敗 等）で失敗したとき, the watcher shall パイプライン本体を継続し、警告ログを 1 行残す
4. The watcher shall Slack 通知の発行可否・成否を理由に既存 processor の exit code・ラベル遷移・gh API 呼び出しを変更しない
5. The watcher shall Slack 通知のための HTTP POST に対し、タイムアウト上限を有限値（具体値は Architect 確定）として設定し、無限待機しない

### Requirement 5: 観測可能性（監査ログ）

**Objective:** As an idd-claude operator, I want Slack 通知の発行・skip・失敗を構造化ログから
追跡したい, so that Slack 受信側との突き合わせや原因調査ができる

#### Acceptance Criteria

1. When Slack 通知が成功裏に発行されたとき, the watcher shall 構造化ログ 1 行を出力し、イベント種別・対象 Issue/PR 番号・送信成否を含める
2. When Slack 通知が `SLACK_NOTIFY_ENABLED=false` で skip されたとき, the watcher shall 通常の cron tick で追加ログを出力しない（既存ログとの増分はゼロ）
3. When Slack 通知が `SLACK_WEBHOOK_URL` 未設定 で skip されたとき, the watcher shall 警告ログを 1 行出力し、skip 理由を含める（`SLACK_NOTIFY_ENABLED=true` だが URL 未設定のミス設定を運用者が検知できるようにするため）
4. If Slack 通知が失敗したとき, the watcher shall 警告ログを 1 行出力し、HTTP status / network error / payload error のいずれであるかを含める
5. The watcher shall webhook URL 全体をログ出力に含めない（URL に含まれる secret 部分の漏洩を防ぐ）

### Requirement 6: 配布範囲とドキュメント

**Objective:** As a メンテナ, I want 本機能の変更範囲を local-watcher 単体に限定しつつ、
README へ挙動・env var を反映したい, so that consumer repo（template 配布対象）への影響を
最小化し、運用者が機能を把握できる

#### Acceptance Criteria

1. The watcher 実装変更 shall `local-watcher/bin/issue-watcher.sh` および同階層 `modules/` 配下に限定する
2. When 本機能が PR として提出されるとき, the maintainer shall README のオプション機能一覧節を同一 PR で更新し、`SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` と既定値・既定挙動・通知対象イベントを記載する
3. The maintainer shall webhook URL の実値を `.env` ファイル・コード・README・テストフィクスチャ・PR description に含めない（secret 非コミット）
4. The repository shall keep `local-watcher/` ↔ `repo-template/` byte-equivalent for files under shared dual-management scope (`.claude/agents/` / `.claude/rules/` / workflows / labels script) after the change

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `SLACK_NOTIFY_ENABLED` is unset or set to any value other than `true`, the watcher shall produce byte-equivalent external side effects (gh / git API 呼び出し / ラベル遷移 / コミット / push / 既存ログ出力行) to the pre-introduction state
2. The watcher shall not rename, repurpose, or remove existing env var names (`FULL_AUTO_ENABLED` / `AUTO_MERGE_ENABLED` / `FAILED_RECOVERY_ENABLED` / `NEEDS_DECISIONS_MODE` / `PROMOTE_PIPELINE_ENABLED` 等), label names, exit code semantics, or cron registration strings as part of this change
3. The watcher shall not change the existing `run-summary` 1 行出力の形式・出力先・出力タイミング（本機能は run-summary と independent な観測チャネルとして追加する）

### NFR 2: 性能・運用

1. While `SLACK_NOTIFY_ENABLED=false` のとき, the watcher shall Slack 通知 emitter の処理（HTTP 接続準備・payload 構築・外部コマンド呼び出し）を一切実行しない
2. When 通知対象イベントが発火したとき, the watcher shall Slack POST の所要時間が cron tick 全体の主処理（Triage / PM / Architect / Developer / Reviewer / PjM / merge / promote）を顕著に遅延させないよう、有限タイムアウト（具体値は Architect 確定）で打ち切る
3. The watcher shall Slack 通知のために新規外部 CLI 依存（既存 `gh` / `jq` / `git` / `flock` / `claude` 以外）を追加せず、HTTP POST は既存環境に存在する手段（例: `curl`）で実装する

### NFR 3: セキュリティ（未信頼入力・secret 取り扱い）

1. The watcher shall `SLACK_WEBHOOK_URL` を env からのみ取得し、コードベース・README・log・コメント・テストフィクスチャに実値を含めない
2. The watcher shall Slack payload に含める Issue / PR 本文・タイトル・ラベル等の未信頼入力を CLAUDE.md §5 に準拠して安全に展開する（変数クォート / jq `--arg` / `curl` 引数のオプション終端 / 数値 ID 検証）
3. The watcher shall Issue 本文中に検出可能な secret 候補値（GitHub token / API key パターン）を Slack payload にエコーしない（具体的な検出ロジックは実装裁量だが、本文全体を生で payload に貼ることはしない）
4. The watcher shall Slack 通知失敗時の警告ログに webhook URL 全体を出力しない

### NFR 4: 静的解析・テスト

1. The watcher script shall pass `shellcheck` and `bash -n` after the change is applied
2. The repository shall include 近接テスト（`local-watcher/test/`）で以下を最低限カバーする: `SLACK_NOTIFY_ENABLED=false` で no-op / `SLACK_NOTIFY_ENABLED=true` かつ `SLACK_WEBHOOK_URL` 未設定で no-op + 警告ログ / 通知対象イベント発火で 1 通 POST / POST 失敗時にパイプライン継続
3. The repository shall include 近接テストで env 正規化（不正値・typo・大文字小文字バリエーション）が安全側（OFF）に倒れることを検証する
4. The repository shall stub `curl`（または相当の HTTP クライアント）して call count / payload を観測することで、外部ネットワークへ依存しないテストを実装する

### NFR 5: 監査性

1. The watcher shall Slack 通知の発行・skip（URL 未設定起因）・失敗をすべて構造化ログ 1 行で記録し、grep で通知履歴を再構成できる

## Out of Scope

- 双方向 Slack 操作（承認ボタン / Slack コマンド経由の Issue 操作 / interactive message 等。Issue 本文「非スコープ」明記）
- Slack 以外の通知先（Discord / Microsoft Teams / メール / PagerDuty 等）への横展開
- 通知対象イベントの追加（Triage 完了 / PM 完了 / Architect 完了 / Developer 完了 / Reviewer 完了 / Stage A 完了 等の routine な段階遷移通知）
- 通知の rate limit / throttling / batching（同一 tick 内のイベント単位で 1 通発行する素直な実装に倒す）
- 通知文面のテンプレートカスタマイズ機能（payload 形式は固定。i18n / 多言語化なし）
- 複数 channel への振り分け（イベント種別ごとに別 webhook URL を使い分ける機能。当面は単一 webhook URL）
- Slack 受信側 app / bot の設定（Incoming Webhook 設定は運用者責務）
- 通知失敗時の自動再試行（fail-open でログのみ）
- 通知履歴の永続化（Slack 側に履歴が残るため、watcher 側で別途保存しない）
- 過去イベントの retrofit 通知（本機能有効化後に発火したイベントのみ通知対象。導入前の過去イベントは通知しない）

## 関連

- Depends on: #352 #354 #359 #362
- Related: #348

## Open Questions

- Slack payload の **詳細スキーマ**（Block Kit / 単純な `text` フィールドのみ / attachments 形式のいずれか）は Architect / Developer 実装裁量。本要件は Req 3 の「最小情報」を満たすことのみを要求する
- Slack POST の **タイムアウト具体値**（秒単位）は Architect / Developer 実装裁量。Req 4.5 / NFR 2.2 で「有限値」「主処理を顕著に遅延させない」とのみ規定
- `failed-recovery` の「終端遷移」の正確な範囲（成功復旧確定のみ通知するか / max-attempts と no-progress も含めるか）→ 本要件では「最終遷移」として包括するが、何を最終遷移と呼ぶかの正確な enumerate は design.md で確定する想定
- `auto-merge` の通知トリガーは「watcher が merge を発火した瞬間」か「merge 成功確定後」か → 本要件では「merge 完了」（Req 2.1）と記載し、PR が closed/merged 状態に遷移したことを観測した時点とする解釈を推奨。実装上の正確な hook point は design.md の領分
- secret 検出ロジック（NFR 3.3）の具体的なパターンセット（GitHub token prefix / OAuth token prefix / 一般的な API key パターン）は Developer 実装裁量。本要件は「Issue 本文全体を生で payload に貼らない」ことのみを要求する
- 単一 webhook URL でイベント種別を Slack 側で振り分けたいニーズ（例: channel route by event type）が将来発生した場合の拡張余地。本要件ではスコープ外とするが、payload にイベント種別識別子を含める（Req 3.1）ことで将来拡張の前提を残す
