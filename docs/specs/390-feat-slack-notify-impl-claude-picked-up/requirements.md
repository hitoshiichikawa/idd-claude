# Requirements Document

## Introduction

idd-claude の Slack 通知 emitter（`modules/slack-notify.sh`、関数 prefix `sn_`）には現在 5 種類のイベント（`auto-merge` / `auto-merge-design` / `failed-recovery` / `needs-decisions-auto-continue` / `promote`）が定義されているが、Issue が実装フェーズに着手したタイミング（`claude-claimed` → `claude-picked-up` へのラベル遷移）を Slack で追跡する手段がない。dogfooding 運用者から「impl 着手の可視化」要望が上がっており、本要件は 6 番目のイベント種別 `claude-pickup` を Slack notify に追加することを目的とする。既存 5 イベントの挙動・enum 受理性・payload 構造は不変、`SLACK_NOTIFY_ENABLED` gate も既存のものを流用し、新しい env var / 新しい prefix は導入しない。

## Requirements

### Requirement 1: claude-pickup イベントの発火

**Objective:** As an idd-claude 運用者, I want impl 着手（`claude-picked-up` 遷移）時に Slack 通知を 1 通受け取りたい, so that 実装フェーズ開始のタイミングを Slack 上で追跡できる

#### Acceptance Criteria

1. When Issue のラベルが `claude-claimed` から `claude-picked-up` へ付け替え成功した直後、the Slack Notify Module shall `claude-pickup` イベントタイプで通知を 1 通送信する
2. When `MODE` が `impl` または `impl-resume` のいずれかである状態で claude-picked-up 遷移が発生したとき、the Slack Notify Module shall 当該遷移に対応する 1 通の通知を発火する
3. While ラベル付け替え自体が失敗した状態, the Slack Notify Module shall claude-pickup 通知を送信しない
4. When 同一 Issue が再度 pickup（`impl-resume` による再遷移）されたとき, the Slack Notify Module shall その遷移ごとに 1 通の通知を発火する

### Requirement 2: payload 仕様

**Objective:** As a Slack 通知の受信者, I want 通知 payload から Issue 特定と mode 判別ができること, so that 通知だけで該当 Issue と着手モードを把握できる

#### Acceptance Criteria

1. When `claude-pickup` イベントが送信されるとき、the notification payload shall Issue 番号を含む
2. When `claude-pickup` イベントが送信されるとき、the notification payload shall Issue URL を含む
3. When `claude-pickup` イベントが送信されるとき、the notification payload shall 着手モード（`impl` または `impl-resume`）を識別できる文字列を含む
4. The notification payload shall 既存 5 イベントが従う `sn_notify <event_type> "<number>" "<url>" <result> "<detail>"` の callsite 規約に整合する形式で構成される

### Requirement 3: event_type enum の拡張

**Objective:** As Slack Notify Module の保守担当, I want `sn_build_payload` の event_type enum に `claude-pickup` を正規に追加すること, so that 新イベントが「不正 event」として弾かれず、既存テストの validate 経路で受理される

#### Acceptance Criteria

1. The `sn_build_payload` function shall `claude-pickup` を有効な event_type として受理する
2. When event_type が `claude-pickup` で `sn_build_payload` が呼ばれたとき、the Slack Notify Module shall エラー終了せず正常な payload を生成する
3. The Slack Notify Module shall 既存 5 イベント（`auto-merge` / `auto-merge-design` / `failed-recovery` / `needs-decisions-auto-continue` / `promote`）の受理性・payload 構造・既存テスト合格状態を維持する

### Requirement 4: gate 制御と fail-open 挙動

**Objective:** As idd-claude 運用者, I want 既存 Slack 通知の gate・失敗時挙動と一貫した制御を期待する, so that 新イベント追加によって既存運用前提が崩れない

#### Acceptance Criteria

1. While `SLACK_NOTIFY_ENABLED` が `true` 以外（未設定 / `false` / 不正値）, the Slack Notify Module shall `claude-pickup` 通知を送信しない
2. Where `SLACK_NOTIFY_ENABLED=true` が設定されている, the Slack Notify Module shall Requirement 1 の条件に従って `claude-pickup` 通知を送信する
3. If `claude-pickup` 通知の送信が失敗した（HTTP 4xx/5xx・curl 非ゼロ終了・payload 整形失敗のいずれか）, the Issue Watcher shall pickup 後の後続処理（ブランチ作成・実装開始）をブロックしない
4. If `claude-pickup` 通知が失敗した, the Slack Notify Module shall 既存 5 イベントと同じ fail-open（`|| true` 相当）挙動で本処理を継続させる

### Requirement 5: 後方互換性

**Objective:** As idd-claude を install 済みの consumer repo 運用者, I want 既存運用・既存設定・既存ログ出力に副作用が出ないこと, so that 本 issue の取り込みに追加運用作業（env 変更・ラベル変更）が発生しない

#### Acceptance Criteria

1. The Slack Notify Module shall 新規 env var を追加せず、`SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` / `SLACK_NOTIFY_TIMEOUT` を流用する
2. The Slack Notify Module shall 新規関数 prefix を導入せず、既存 `sn_` namespace 内で実装する
3. The Issue Watcher shall 既存ラベル名（`claude-claimed` / `claude-picked-up`）・既存ラベル遷移契約・既存 exit code 意味を変更しない
4. The Slack Notify Module shall 既存 5 イベントの callsite（`auto-merge.sh` / `auto-merge-design.sh` / `needs-decisions-auto.sh` / `promote-pipeline.sh` / `failed-recovery.sh`）を改変しない

## Non-Functional Requirements

### NFR 1: 静的解析・テスト健全性

1. The Slack Notify Module shall `shellcheck` で警告ゼロを維持する（既存 `.shellcheckrc` の accepted baseline を超える新規警告を出さない）
2. The Issue Watcher workflow shall `actionlint` クリーンを維持する
3. The Slack Notify Module shall 既存テスト `local-watcher/test/sn_build_payload_test.sh`（特に Section 3 の event_type enum validation）が `claude-pickup` を有効 enum として受理する状態で合格する
4. The Slack Notify Module shall 既存 5 イベントを対象とするテストケースを破壊しない

### NFR 2: ドキュメント整合性

1. The README shall 「通知対象イベント」の件数記述（line 1500 周辺の「5 イベント」表記）を `claude-pickup` 追加後の件数に同一 PR で更新した状態で公開される
2. The Slack Notify Module shall 関数冒頭コメント・event_type enum 列挙箇所が新イベント `claude-pickup` を含む形で更新される

### NFR 3: 通知の即時性と単発性

1. When ラベル付け替えが成功してから `claude-pickup` 通知 1 通が送信されるまで、the Slack Notify Module shall 既存 5 イベントと同等のタイムアウト境界（`SLACK_NOTIFY_TIMEOUT` の既定値）内で完了を試行する
2. The Slack Notify Module shall 1 回の `claude-picked-up` 遷移につき 1 通の通知のみを発火する（同一遷移を重複発火しない）

## Out of Scope

- `merged`（実マージ完了）イベントの追加 — #388 に委譲
- 細粒度のステージ通知（Triage / Stage A / Reviewer / per-task など）の追加
- per-event の有効/無効トグル（例: `SLACK_NOTIFY_EVENTS=...` 形式の選択的 enable）導入
- 同一 Issue の再 pickup（impl-resume）に対する追加の dedup 状態管理（遷移ごとに 1 通発火を維持）
- 既存 5 イベントの payload 構造・callsite シグネチャ変更
- Slack 以外の通知先（Discord / Teams / Email 等）への拡張
- 既存 `.shellcheckrc` baseline の更新

## Open Questions

- なし（Issue 本文と既存実装パターンで全 AC が決定可能）

## 関連

- Parent: #370
- Sibling: #388
