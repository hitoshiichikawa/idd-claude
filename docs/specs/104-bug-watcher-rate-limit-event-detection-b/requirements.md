# Requirements Document

## Introduction

Claude Max の 5 時間 quota が watcher 実行中に枯渇した際、本来は `needs-quota-wait` ラベルで
休止し reset 後に resume すべきところを、watcher が「Stage C 完了 / PR 作成済み」と虚偽の成功
報告を返してしまう不具合が観測されている（再現例: `hitoshiichikawa/KeyNest` Issue #29、Claude
CLI v2.1.139 環境で local worktree に 12 個の orphan commit が滞留）。

原因は 3 つの bug の連鎖である:

1. `qa_detect_rate_limit` の jq filter が現行 Claude CLI の `rate_limit_event` スキーマ
   （`rate_limit_info.status == "rejected"`）に追従しておらず、旧スキーマ（top-level
   `.status == "exceeded"`）しか検出できない。
2. Claude CLI が quota 枯渇時に `subtype:"success"` / `is_error:true` /
   `api_error_status:429` を含む synthetic な `result` 行を返したうえで exit code 0 で終了する
   ケースがあり、return code のみを見る既存判定をすり抜ける。
3. Stage C 完了報告時に PR の実在を `gh pr view` で verify しておらず、PjM サブエージェントが
   1 turn で空転終了しても成功と宣言される。

本要件定義は、上記 3 bug を修正しつつ、旧スキーマとの後方互換性および既存テスト群の
グリーンを維持することをスコープとする。

## Requirements

### Requirement 1: 現行スキーマでの quota 検出

**Objective:** As a watcher 運用者, I want Claude CLI の現行スキーマで送られてくる
`rate_limit_event` を確実に quota 枯渇として検出したい, so that quota 超過時に虚偽成功を
出さずに `needs-quota-wait` で正しく休止できる

#### Acceptance Criteria

1. When Claude CLI が `rate_limit_info.status == "rejected"` を含む `rate_limit_event` 行を
   stream に出力したとき, the Quota-Aware Watcher Module shall それを quota 枯渇として
   検出し、当該 stage の終了コードを 99 として呼び出し側に返す
2. When `rate_limit_event` 行から quota 検出がトリガーされたとき, the Quota-Aware Watcher
   Module shall 当該 event の reset 時刻情報を epoch 秒の整数として `reset_file` に書き出す
3. While reset 時刻情報が現行スキーマでネスト位置（`rate_limit_info` 配下相当）にある場合,
   the Quota-Aware Watcher Module shall そのネスト位置から reset 時刻を取得する
4. If `rate_limit_event` 行は出力されたが reset 時刻情報が欠落または非数値の場合, the
   Quota-Aware Watcher Module shall 既存フローへの委譲（quota 検出なし扱い）に fallback し、
   その旨を warn ログへ記録する

### Requirement 2: 旧スキーマとの後方互換性

**Objective:** As a watcher 運用者, I want 旧 Claude CLI スキーマ（top-level `.status ==
"exceeded"`）も引き続き検出できる状態を保ちたい, so that CLI のバージョン差や将来の rollback
時にも quota 検出が機能する

#### Acceptance Criteria

1. When Claude CLI が旧スキーマ形式（top-level `.status == "exceeded"`）の `rate_limit_event`
   行を出力したとき, the Quota-Aware Watcher Module shall 現行スキーマと同様に quota 枯渇と
   して検出し、終了コード 99 を返す
2. When 旧スキーマと現行スキーマの両方で reset 時刻フィールド名が異なる場合, the
   Quota-Aware Watcher Module shall 既存実装が受理してきたフィールド名群（`resetsAt` /
   `reset_at` / `resets_at` 等）を引き続き受理する

### Requirement 3: synthetic 429 result 行の検出

**Objective:** As a watcher 運用者, I want Claude CLI が exit code 0 で返しても output 内に
synthetic な 429 エラーが含まれる場合は quota 枯渇として扱いたい, so that CLI の return code
ベース判定では拾えない quota 超過パターンも `needs-quota-wait` に正しく遷移できる

#### Acceptance Criteria

1. When Claude CLI が `type:"result"` かつ `is_error:true` かつ `api_error_status:429` を持つ
   行を stream に出力したとき, the Quota-Aware Watcher Module shall 当該 stage を quota 枯渇
   として扱い、終了コード 99 を呼び出し側に返す
2. When synthetic 429 result 行が検出されたが reset 時刻情報が同一 stream 内に得られない場合,
   the Quota-Aware Watcher Module shall 既存の reset 時刻欠落時フォールバック（warn ログ +
   既存フロー委譲）と同等の挙動を取る
3. When synthetic 429 result 行が検出されたとき, the Quota-Aware Watcher Module shall 「CLI
   の return code は 0 だが synthetic 429 を検出したため quota 枯渇扱いに格上げした」旨を
   warn または info レベルでログへ記録する
4. While Claude CLI が `type:"result"` かつ `is_error:false`（通常成功）の行を返している場合,
   the Quota-Aware Watcher Module shall それを quota 枯渇として扱わず、従来どおり成功として
   呼び出し側に返す

### Requirement 4: Stage C 完了の PR 実在検証

**Objective:** As a watcher 運用者, I want Stage C 完了を宣言する前に対象ブランチに impl PR
が実在することを verify したい, so that PjM サブエージェントが空転終了しても虚偽成功で
終わらず `claude-failed` として人間に正しくエスカレーションできる

#### Acceptance Criteria

1. When Stage C の Claude 実行が return code 0 かつ quota 枯渇検出なしで終了したとき, the
   Stage C Pipeline shall 完了宣言の前に当該 Issue 用ブランチに対応する impl PR の存在を
   GitHub 側で確認する
2. If Stage C 終了時に対応 PR が存在しないと判定された場合, the Stage C Pipeline shall 当該
   Issue を `claude-failed` として `mark_issue_failed "stageC" ...` 経路で扱い、虚偽の成功
   メッセージを出力しない
3. When Stage C 終了時に対応 PR の存在が確認できた場合, the Stage C Pipeline shall 従来どおり
   「Stage C 完了 / PR 作成済み」を成功ログに出力し、終了コード 0 で返す
4. If Stage C 終了時の PR 存在確認自体が GitHub API 障害など一時的な原因で失敗した場合, the
   Stage C Pipeline shall PR 不在と同等の安全側判定（虚偽成功を出さない）に倒し、原因を
   ログへ記録する

### Requirement 5: テストフィクスチャとリグレッションテスト

**Objective:** As a watcher 開発者, I want 現行 / 旧スキーマおよび synthetic 429 のサンプル
出力をフィクスチャとして保持し検証したい, so that 将来の Claude CLI スキーマ変更で同種
リグレッションが再発した際に CI/手動テストで早期検知できる

#### Acceptance Criteria

1. The Test Suite shall 現行スキーマ（`rate_limit_info.status == "rejected"`）の
   `rate_limit_event` 行サンプルを `local-watcher/test/fixtures/` 配下のフィクスチャとして
   保持する
2. The Test Suite shall 旧スキーマ（top-level `.status == "exceeded"`）の `rate_limit_event`
   行サンプルを `local-watcher/test/fixtures/` 配下のフィクスチャとして保持する
3. The Test Suite shall synthetic 429 result 行（`subtype:"success"` / `is_error:true` /
   `api_error_status:429`）のサンプルを `local-watcher/test/fixtures/` 配下のフィクスチャと
   して保持する
4. When 上記 3 種フィクスチャに対する quota 検出テストを実行したとき, the Test Suite shall
   いずれのケースでも検出成功（exit 99 相当の判定）を観測できる
5. The Test Suite shall 既存の `local-watcher/test/` 配下テスト群（`parse_review_result_test.sh`
   ほか）が本変更後も pass し続ける

## Non-Functional Requirements

### NFR 1: 後方互換性とフラグ既定値

1. The Quota-Aware Watcher Module shall `QUOTA_AWARE_ENABLED != "true"` での opt-out 既定挙動
   （tee も解析も走らず素通し実行）を本変更後も維持する
2. The Quota-Aware Watcher Module shall 既存の環境変数名（`QUOTA_AWARE_ENABLED` 等）と既存の
   stage 終了コード意味（0 = 成功 / 99 = quota 検出 / それ以外 = 既存失敗）を変更しない

### NFR 2: 観測性

1. When quota 枯渇検出（現行スキーマ / 旧スキーマ / synthetic 429 のいずれか）が発火した
   とき, the Quota-Aware Watcher Module shall どの検出経路で発火したかを `$LOG` から事後に
   識別可能な粒度（経路名 + stage label を含むログ行）で記録する
2. If Stage C で PR 不在による `claude-failed` 化が発生した場合, the Stage C Pipeline shall
   人間が原因を特定できる粒度（Issue 番号、対象ブランチ、PR 不在の判定根拠）でログを残す

### NFR 3: 検証コスト

1. The Test Suite shall フィクスチャベースの quota 検出テストを外部ネットワーク呼び出し
   （Claude API / GitHub API への live 呼び出し）なしで実行できる

## Out of Scope

- Claude CLI のスキーマ自体を upstream で修正する作業（CLI ベンダー側の責務）
- `needs-quota-wait` 検出後の reset 時刻計算ロジックや resume タイミング制御の見直し
  （Issue #66 の既存設計を踏襲）
- Stage A / Stage B の return code 0 + 空成果物パターンに対する同種の verify 強化
  （本 Issue は Stage C の PR 実在 verify に閉じる。Stage A / B 側の検証強化が必要であれば
  別 Issue として切り出す）
- `qa_persist_reset_time` 等 reset 時刻永続化系の挙動変更
- Quota-Aware Watcher の opt-in / opt-out 既定値の変更
- Reviewer / PjM サブエージェントのプロンプト本文の改修
- 自動 CI ジョブの新設（テストフィクスチャ追加と既存スモークテスト経路の維持に閉じる）

## Open Questions

- なし
