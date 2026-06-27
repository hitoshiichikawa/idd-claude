# Requirements Document

## Introduction

quota-aware モジュール（#66 / #104 / #169）は Claude Max の 5 時間ローリング quota 枯渇を
検出し、当該 Issue を `needs-quota-wait` 状態にして reset 時刻経過後に自動 resume するための
機構である。しかし現状の検出経路は claude CLI が出力する stream-json の 3 スキーマ
（`rate_limit_event_v2` / `rate_limit_event_v1` / `synthetic_429_result`）のみであり、
**セッション上限到達時に claude CLI が stream-json を一切出さず平文 1 行で early-exit する**
ケース（観測例: `You've hit your session limit · resets 7:40pm (Asia/Tokyo)`）を取りこぼす。
この結果、本来 quota 起因として deferral すべき一過性失敗が `claude-failed`（手動復旧 +
Failed Recovery 起動）に誤分類される。本要件は quota-aware が平文セッション上限メッセージを
quota 枯渇として検出し、既存 JSON 経路と同じ deferral 経路（`needs-quota-wait` 付与 + reset
時刻永続化 + 自動 resume）に合流させることを目的とする。既存の JSON 検出経路・opt-out 挙動・
ラベル契約・cron 登録は本修正で変更しない。

## Requirements

### Requirement 1: 平文セッション上限メッセージの quota 検出

**Objective:** As a 運用者, I want claude CLI が出力する平文「You've hit your session limit · resets <time>」メッセージを quota 枯渇として検出したい, so that セッション上限到達時に Issue が `claude-failed` ではなく `needs-quota-wait` に遷移し、自動 resume の対象になる

#### Acceptance Criteria

1. While `QUOTA_AWARE_ENABLED=true` が有効である間, the Quota-Aware Watcher shall claude CLI が Stage 実行中に出力した平文セッション上限メッセージ（`You've hit your session limit` を含む行）を quota 枯渇として検出する
2. When 平文セッション上限メッセージが Stage 実行中に検出されたとき, the Quota-Aware Watcher shall 既存 JSON 経路（`rate_limit_event_v2` / `rate_limit_event_v1` / `synthetic_429_result`）と同じ deferral 経路に合流させ、Stage Wrapper の exit 99 sentinel 経路で呼び出し側へ通知する
3. When 平文セッション上限メッセージが Stage 実行中に検出されたとき, the Quota-Aware Watcher shall 当該 Issue を `claude-failed` ではなく `needs-quota-wait` に遷移させる
4. When 同一 Stage 実行中に平文セッション上限メッセージと JSON 形式の quota 検出（`rate_limit_event_*` / `synthetic_429_result`）が同時に観測されたとき, the Quota-Aware Watcher shall いずれか 1 つを採用して 1 回の quota 検出として扱い、二重 escalation を発生させない
5. While 平文セッション上限メッセージが Stage 実行中に観測されない間, the Quota-Aware Watcher shall 当該 Stage を本要件の検出経路では quota 枯渇として分類しない

### Requirement 2: reset 時刻のパースと永続化

**Objective:** As a 運用者, I want 平文メッセージから抽出された reset 時刻を可能な限り epoch に解決して永続化したい, so that 既存 Quota Resume Processor が reset+grace 経過後に自動 resume できる

#### Acceptance Criteria

1. When 平文セッション上限メッセージから `resets <time>` 部分の時刻表記が抽出できたとき, the Quota-Aware Watcher shall 当該時刻を「現在時刻から見た直近の該当時刻」の UNIX epoch 秒に解決する
2. When reset 時刻の解決に成功したとき, the Quota-Aware Watcher shall 解決された epoch を当該 Issue 番号 keyed の永続化先（`QUOTA_RESET_STATE_FILE`）にアトミックに書き込み、Issue 単位の最新値 1 件のみが保持される状態を維持する
3. Where 平文の時刻表記にタイムゾーン指定（例: `(Asia/Tokyo)`）が含まれる, the Quota-Aware Watcher shall 当該タイムゾーンを尊重して epoch に解決する
4. Where 平文の時刻表記が 12 時間表記（`am` / `pm` サフィックス）または 24 時間表記である, the Quota-Aware Watcher shall いずれの表記揺れに対しても同一の epoch 解決結果を得る
5. If 平文セッション上限メッセージは検出されたが reset 時刻の抽出または epoch 解決に失敗したとき, the Quota-Aware Watcher shall 当該 Issue を `claude-failed` に落とさず、既存の「reset 欠落 fallback」と同等の安全側挙動（quota として認識し、warn ログを出力した上で claude 本体の rc を透過）に倒す
6. If 平文セッション上限メッセージが複数行に分割されて出力されたとき, the Quota-Aware Watcher shall 行をまたいで判定し、少なくとも `You've hit your session limit` を含む単一行を検出した時点で本要件を満たす

### Requirement 3: 既存 JSON 検出経路との後方互換

**Objective:** As a 既存運用者, I want 平文検出の追加によって既存 JSON 経路の挙動が変わらないこと, so that 本 Bug 修正の deploy が既存 quota-aware の動作を退行させない

#### Acceptance Criteria

1. While 本要件群の修正後の quota-aware が稼働している間, the Quota-Aware Watcher shall 既存 JSON 検出経路（`rate_limit_event_v2` / `rate_limit_event_v1` / `synthetic_429_result`）の検出ロジック・優先順位・出力契約を変更しない
2. While `QUOTA_AWARE_ENABLED` が未設定または `false` である間, the Quota-Aware Watcher shall 平文セッション上限メッセージの検出・解析・ラベル付与・永続化のいずれも実行しない
3. The Quota-Aware Watcher shall 既存の Stage Wrapper exit code 契約（`0` = 正常、`99` = quota 検出、それ以外 = claude 本体の非ゼロ exit）を本要件追加によって変更しない
4. The Quota-Aware Watcher shall 既存環境変数（`QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC` / `QUOTA_RESET_STATE_FILE` / `LOG_DIR` 等）の名前・受理形式・既定値を本要件追加によって変更しない
5. The Quota-Aware Watcher shall 既存ラベル（`needs-quota-wait` / `claude-failed` / `claude-claimed` / `claude-picked-up`）の名前・付与契約・遷移条件を本要件追加によって変更しない

### Requirement 4: 検出結果の観測性

**Objective:** As a 運用者, I want 平文検出経路で quota が検出されたことをログから事後検索したい, so that 既存 JSON 経路と平文経路のどちらで検出されたかを切り分けて運用判断できる

#### Acceptance Criteria

1. When 平文セッション上限メッセージが quota 枯渇として検出されたとき, the Quota-Aware Watcher shall 検出経路を識別できる文字列（既存 `detection_path` 表記体系と整合する識別子）と検出 Stage ラベルと reset epoch（解決できた場合）を `$LOG_DIR` 配下のログに 1 行で記録する
2. If 平文セッション上限メッセージは検出されたが reset 時刻の epoch 解決に失敗したとき, the Quota-Aware Watcher shall reset 欠落である旨と Stage ラベルを warn レベルでログに記録する
3. The Quota-Aware Watcher shall 平文検出経路で投稿される escalation コメントの構造（h2 タイトル / 検知情報 / 自動復帰の条件 / 手動介入したい場合）を既存 JSON 経路と同一テンプレートに揃え、検出経路の差異が運用者に追加学習コストを強いない形にする

## Non-Functional Requirements

### NFR 1: 性能・処理コスト

1. The Quota-Aware Watcher shall 平文検出経路の追加によって、既存 JSON 経路のみで処理した場合と比較して単一 Stage 実行の wall-clock レイテンシが体感できる水準（数秒以上）で増加しない状態を維持する
2. The Quota-Aware Watcher shall 平文検出経路の追加にあたって、Stage 実行の正常終了を遅延させるためのブロッキング待機（sleep / 追加同期処理）を新規に導入しない

### NFR 2: 後方互換性

1. The Quota-Aware Watcher shall `QUOTA_AWARE_ENABLED=false`（明示 opt-out）または未設定環境において、本要件追加前と 100% 同一の挙動（素通し実行・検出なし・永続化なし）を維持する
2. The Quota-Aware Watcher shall 既 install 済み consumer リポジトリの再 install を必須としない形で本修正を提供する（`install.sh` 再実行のみで反映され、追加の手作業を要求しない）

### NFR 3: 回帰防止テスト

1. The Quota-Aware Watcher shall 平文セッション上限メッセージ単独入力ケースの単体テストを `local-watcher/test/qa_detect_rate_limit_test.sh` または同等のテストファイルに追加する
2. The Quota-Aware Watcher shall stream-json と平文が同一 Stage 実行内で混在するケースの単体テストを追加する
3. The Quota-Aware Watcher shall 平文メッセージが複数行に分割されて出力されるケースの単体テストを追加する
4. The Quota-Aware Watcher shall reset 時刻のタイムゾーン表記揺れ（少なくとも `(Asia/Tokyo)` を含むケース）と 12 時間表記（`am` / `pm`）のケースを単体テストでカバーする
5. The Quota-Aware Watcher shall 既存 JSON 検出経路の単体テスト（既存 `qa_detect_rate_limit_test.sh` / `qa_run_claude_stage_test.sh`）を本修正後も合格させる

## Out of Scope

- 外部 Feature Flag SaaS との連携
- Failed Recovery Processor の terminal コメント spam（別 Issue で扱う。本 Issue は「quota を `claude-failed` に落とさない」検出修正に限定）
- claude CLI 側の出力フォーマット指定変更（stream-json 強制化）による上流根治。本要件は watcher 側の検出網拡張のみを扱う（Issue 本文「仮案 B」は対象外）
- セッション上限以外の平文エラーメッセージ全般の quota 分類（例: API 接続失敗 / モデル切替時の通知等）。本要件は「セッション上限」文言に限定する
- 既存 `rate_limit_event_v2` / `rate_limit_event_v1` / `synthetic_429_result` JSON 検出ロジック自体の修正・拡張
- `needs-quota-wait` の新規ラベル定義変更や `idd-claude-labels.sh` の変更（#66 で導入済みのラベルをそのまま流用する）

## Open Questions

- 平文メッセージ文言の厳密マッチ範囲: Claude Code のバージョンによって `You've hit your session limit · resets <time>` の正確な文言・記号（中黒 `·` / TZ 括弧表記 等）が変わり得る。**緩いと誤検出、厳しいとバージョン差で取りこぼし**となるトレードオフがあるため、最終的なマッチパターンの粒度（substring `You've hit your session limit` のみで判定するか、`resets` 部分まで含めて判定するか）は design.md で確定する
- reset 時刻に日付が含まれない場合（例: `7:40pm (Asia/Tokyo)` のみ）の「直近の該当時刻」決定ロジック: 現在時刻が `7:40pm` を過ぎていれば翌日同時刻を採用するか、24 時間以内の最近未来時刻を採用するか。design.md で確定する
- 平文検出経路の `detection_path` 識別子の命名（例: `session_limit_plain_v1` 等）。既存 JSON 経路の命名体系と整合させる形で design.md で確定する

## 関連

- Depends on: #66
- Related: #104 #169 #118
