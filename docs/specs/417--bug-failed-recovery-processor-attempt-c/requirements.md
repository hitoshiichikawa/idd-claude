# Requirements Document

## Introduction

Failed Recovery Processor（#359）は `claude-failed` Issue / auto-merge 待ち PR を fresh Claude session で
復旧する仕組みで、通算 attempt 上限到達時（`max-attempts`）と同原因再発による無進捗時（`no-progress`）に
**終端理由コメントを 1 件だけ投稿して `claude-failed` ラベルを据え置く**契約になっている。しかし現状の実装は
終端状態を cross-cycle で永続化しておらず、終端到達後も毎 cron tick（既定 2 分間隔）で候補列挙に再ヒットし、
同一の「修正試行を停止します（終端理由: max-attempts）」「同（no-progress）」コメントを無制限に再投稿し続ける。
人間運用者のコメントで `max-attempts` 経路だけでなく `no-progress` 経路でも同じ spam を観測済みである旨が
補足されているため、**両経路に共通する cross-cycle のべき等性**を回復することが本要件の目的である。

関連: 同原因の上流に位置する quota 由来の誤 `claude-failed` 確定は #416 で扱う。本要件は terminate 経路の
べき等化に限定し、`FAILED_RECOVERY_MAX_ATTEMPTS` 既定値の見直し・既存重複コメントの遡及削除は扱わない。

## Requirements

### Requirement 1: 終端コメントの cross-cycle べき等性

**Objective:** As an idd-claude 運用者, I want 終端理由コメントが 1 Issue / PR の生涯で最大 1 回だけ投稿される, so that cron tick ごとに同一終端コメントが繰り返し再投稿される spam を受け取らずに済む

#### Acceptance Criteria

1. When 通算 attempt 上限到達による終端処理が同一 Issue / PR に対して 2 回目以降のサイクルで起動された場合, the Failed Recovery Processor shall 終端理由コメントを新たに投稿しない
2. When 同原因再発・無進捗（no-progress）による終端処理が同一 Issue / PR に対して 2 回目以降のサイクルで起動された場合, the Failed Recovery Processor shall 終端理由コメントを新たに投稿しない
3. The Failed Recovery Processor shall 同一 Issue / PR の `max-attempts` 終端理由コメントを生涯で最大 1 件しか投稿しない
4. The Failed Recovery Processor shall 同一 Issue / PR の `no-progress` 終端理由コメントを生涯で最大 1 件しか投稿しない
5. When `max-attempts` 終端処理が起動された場合, the Failed Recovery Processor shall 当該 Issue / PR が以後のサイクルでも終端済みと判定できる情報を永続化する
6. When `no-progress` 終端処理が起動された場合, the Failed Recovery Processor shall 当該 Issue / PR が以後のサイクルでも終端済みと判定できる情報を永続化する

### Requirement 2: 終端後サイクルの副作用ゼロ

**Objective:** As an idd-claude 運用者, I want 終端到達後のサイクルでは Failed Recovery Processor が一切の副作用を起こさない, so that 終端済み Issue / PR に対する claude session 起動・コメント・ラベル変更・通知の全種別が二重発火しない

#### Acceptance Criteria

1. While 同一 Issue / PR が `max-attempts` 終端済みである, the Failed Recovery Processor shall 当該 Issue / PR に対して recovery claude session を起動しない
2. While 同一 Issue / PR が `no-progress` 終端済みである, the Failed Recovery Processor shall 当該 Issue / PR に対して recovery claude session を起動しない
3. While 同一 Issue / PR が `max-attempts` または `no-progress` で終端済みである, the Failed Recovery Processor shall 着手コメント・結果コメントを新たに投稿しない
4. While 同一 Issue / PR が `max-attempts` または `no-progress` で終端済みである, the Failed Recovery Processor shall Slack 通知 emitter を新たに発火しない
5. While 同一 Issue / PR が `max-attempts` または `no-progress` で終端済みである, the Failed Recovery Processor shall 通算 attempt カウンタを加算しない
6. While 同一 Issue / PR が `max-attempts` または `no-progress` で終端済みである, the Failed Recovery Processor shall run-summary の最終結果確定を新たに行わない

### Requirement 3: 終端済み Issue / PR の識別

**Objective:** As an idd-claude 運用者, I want 終端済みの Issue / PR をサイクル間で確実に識別できる, so that 終端済み判定の取りこぼしや誤判定が起きずに Req 1・Req 2 が成立する

#### Acceptance Criteria

1. The Failed Recovery Processor shall 各 Issue / PR について「`max-attempts` 終端済み」「`no-progress` 終端済み」「未終端」のいずれかを cron tick 間で判定可能な情報源を 1 つ以上維持する
2. The Failed Recovery Processor shall 終端済み判定の情報源を、watcher プロセスの再起動・cron 実行ユーザーの再ログインを跨いでも保持する
3. When 終端済み判定の情報源が新たに `max-attempts` または `no-progress` の状態を記録する場合, the Failed Recovery Processor shall その記録を、対応する終端理由コメントの投稿と同一サイクル内で確定させる

### Requirement 4: ラベル運用と既存契約の維持

**Objective:** As an idd-claude 運用者, I want 終端済みでも `claude-failed` ラベルが据え置かれる既存運用を維持したい, so that 手動レビュー対象の検出フロー（`claude-failed` ラベルでの列挙）が壊れずに済む

#### Acceptance Criteria

1. When `max-attempts` 終端処理が完了した場合, the Failed Recovery Processor shall 当該 Issue / PR の `claude-failed` ラベルを除去しない
2. When `no-progress` 終端処理が完了した場合, the Failed Recovery Processor shall 当該 Issue / PR の `claude-failed` ラベルを除去しない
3. While 同一 Issue / PR が `max-attempts` または `no-progress` で終端済みである, the Failed Recovery Processor shall 当該 Issue / PR の `claude-failed` ラベルを変更しない
4. When 終端済みの Issue / PR に対して人間運用者が `claude-failed` ラベルを手動で除去した場合, the Failed Recovery Processor shall 通常の候補列挙経路から外れた結果として副作用を起こさない

### Requirement 5: 異常系（state 不整合）の fail-open

**Objective:** As an idd-claude 運用者, I want 終端済み判定の情報源が破損・欠落していた場合に従来挙動に fail-open する, so that 本変更が新たな停止リスクを生まずに既存の fail-continue 方針と整合する

#### Acceptance Criteria

1. If 終端済み判定の情報源（state ファイル等）が parse 失敗・読み出し不能となった場合, the Failed Recovery Processor shall 警告ログを残した上で当該 Issue / PR を「未終端」として扱い、本変更導入前と同等の候補選定フローに退行する
2. If 終端済み判定の情報源がサイクル開始時点で欠落していた場合, the Failed Recovery Processor shall 警告ログを残した上で当該 Issue / PR を「未終端」として扱い、本変更導入前と同等の候補選定フローに退行する
3. The Failed Recovery Processor shall fail-open 退行時も watcher 本体の後続 Issue 処理を停止させない（fail-continue を維持する）

### Requirement 6: gate OFF 時の副作用ゼロ

**Objective:** As an idd-claude 運用者, I want `FAILED_RECOVERY_ENABLED=false` または `FULL_AUTO_ENABLED=false` の環境では本変更による副作用がゼロである, so that 機能 opt-out 中の repo に対して本修正が新たな状態書き込みやコメント投稿を発生させない

#### Acceptance Criteria

1. While `FAILED_RECOVERY_ENABLED` が `true` 以外（未設定・空・`false`・typo を含む）である, the Failed Recovery Processor shall 終端済み判定の情報源への書き込みを行わない
2. While `FULL_AUTO_ENABLED` が `true` 以外である, the Failed Recovery Processor shall 終端済み判定の情報源への書き込みを行わない
3. While 二重 opt-in gate のいずれかが OFF である, the Failed Recovery Processor shall 終端理由コメントの投稿・ラベル変更・Slack 通知 emitter の発火を行わない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Failed Recovery Processor shall 既存の state JSON スキーマの必須フィールド（`issue` / `total_attempts` / `last_status` / `last_failure_signature` / `last_head_sha` / `last_attempt_at` / `immediate_failure_streak` / `history`）の名称と型を変更しない
2. The Failed Recovery Processor shall 既存の終端理由識別子文字列（`max-attempts` / `no-progress` / `immediate-failure-streak`）を変更しない
3. The Failed Recovery Processor shall 本変更導入以前に書かれた state ファイル（終端状態が永続化されていない既存ファイル）を読み込んだ際、当該 Issue / PR を「未終端」として扱い、現行サイクルから新仕様に従って終端済みを永続化する経路に進ませる
4. The Failed Recovery Processor shall 既存の環境変数名（`FAILED_RECOVERY_ENABLED` / `FULL_AUTO_ENABLED` / `FAILED_RECOVERY_MAX_ATTEMPTS` / `FAILED_RECOVERY_STATE_DIR` 等）の意味と既定値を変更しない
5. The Failed Recovery Processor shall 既存の終端コメント本文に含まれる「通算回数」「上限値」「終端理由識別子」「`claude-failed` ラベルは据え置く」旨の文言を引き続き含める

### NFR 2: 可観測性

1. When 同一 Issue / PR が終端済みと判定されて副作用が抑止された場合, the Failed Recovery Processor shall 当該抑止の事実を一次運用ログ（`failed-recovery:` prefix 付きの行）に Issue / PR 番号と終端理由識別子と共に 1 行記録する
2. The Failed Recovery Processor shall 終端済み判定の抑止ログを、運用者が `grep` で重複コメント spam の収束を確認可能な粒度（理由識別子の文字列を含む）で出力する

### NFR 3: セキュリティ

1. The Failed Recovery Processor shall 終端済み判定の情報源を、既存 state ファイルと同じディレクトリ（`$FAILED_RECOVERY_STATE_DIR` 配下、既定で `$HOME/.issue-watcher/` 配下）に配置し、予測可能名の `/tmp` 配下を採用しない
2. The Failed Recovery Processor shall 終端済み判定に関わるログ・コメント・通知 detail に GH_TOKEN 等の secrets・failure signature の全文を含めない
3. The Failed Recovery Processor shall 終端済み判定の情報源を読み書きする際、未信頼入力（Issue / PR 番号等）の使用前検証（`^[0-9]+$`）を維持する

## Out of Scope

- 既に投稿済みの重複終端コメントの遡及削除・clean-up（GitHub 上の履歴は据え置く）
- quota 由来の誤 `claude-failed` 確定の修正（#416 の上流原因対応で扱う）
- `FAILED_RECOVERY_MAX_ATTEMPTS` 既定値（4）の見直し
- 既存の `no-progress` 判定ロジック自体の変更（signature 比較・head SHA 比較の閾値・アルゴリズム）
- `claude-failed` ラベル運用の方針変更（自動除去・別ラベルへの差し替え等）
- `immediate-failure-streak` 終端経路（#411）への同様のべき等性適用（本要件は max-attempts と no-progress に限定）
- 候補列挙段階での server-side filter（GitHub Search API）による終端済み除外（実装手段は design.md の領分）

## Open Questions

- なし
