# Requirements Document

## Introduction

watcher の `verify_pushed_or_retry`（#106 導入）は Stage A / A' / B 完了直後に「ローカル commit が
origin に到達しているか」を verify し、`ahead>0`（未 push）を検出すると自動 push を 1 回リトライする。
ところが現状は **push リトライが成功した場合にも毎回 Issue へ ⚠️ コメントを投稿**している。idd-claude
の設計上 Developer は commit のみで push は行わず（push は watcher が集約する）、`ahead>0` は
ほぼ全ての impl Issue で発生する正常状態である。このため成功時コメントは「サブエージェントの push
漏れ」という誤った原因示唆を伴う誤検知ノイズとなり、Issue タイムラインを汚している（#219 / #238 /
#239 / #243 / #246 で実害が観測されている）。本要件は、push 成功パスの Issue コメント投稿を抑止し
cron ログへの info 記録のみに変更しつつ、push 失敗時の escalation 挙動を完全に温存することを定める。

## Requirements

### Requirement 1: push 成功時のコメント抑止と info ログ化

**Objective:** As a idd-claude の運用者, I want push リトライ成功時に Issue コメントが投稿されない, so that Issue タイムラインが誤検知ノイズで汚れず本当に対応が必要な失敗だけが可視化される

#### Acceptance Criteria

1. When Stage 完了直後に `ahead>0` を検出し自動 push リトライが成功したとき, the watcher shall 当該 Issue へのコメント投稿を行わない
2. When Stage 完了直後に `ahead>0` を検出し自動 push リトライが成功したとき, the watcher shall `$LOG`（cron ログ）に成功を示す info 行を 1 件記録する
3. When 自動 push リトライが成功したとき, the watcher shall return code 0 を呼び出し側へ返す
4. When 自動 push リトライが成功したとき, the watcher shall claude-failed への escalate を行わない

### Requirement 2: 成功時 info ログの監査トレーサビリティ

**Objective:** As a 運用者, I want 成功時 info ログに追跡に必要な識別情報が含まれる, so that Issue コメントを失っても cron ログから「いつ・どの Issue・どの stage で未 push が復旧したか」を後追いできる

#### Acceptance Criteria

1. When push リトライ成功時の info 行を記録するとき, the watcher shall 当該 Issue 番号を info 行に含める
2. When push リトライ成功時の info 行を記録するとき, the watcher shall stage 識別子を info 行に含める
3. When push リトライ成功時の info 行を記録するとき, the watcher shall 対象 branch を info 行に含める
4. When push リトライ成功時の info 行を記録するとき, the watcher shall 復旧した commit 数（ahead 数）を info 行に含める

### Requirement 3: push 失敗時の escalation 挙動の維持

**Objective:** As a 運用者, I want push リトライ失敗時の Issue コメント投稿と claude-failed escalation が従来どおり維持される, so that 本当に対応が必要な未 push 失敗は引き続き Issue 上で気付ける

#### Acceptance Criteria

1. If 自動 push リトライが失敗したとき, the watcher shall 当該 Issue へ失敗通知コメントを投稿する
2. If 自動 push リトライが失敗したとき, the watcher shall claude-failed への escalate を行う
3. If 自動 push リトライが失敗したとき, the watcher shall return code 1 を呼び出し側へ返す
4. If 自動 push リトライが失敗したとき, the watcher shall 失敗通知に stage 識別子 / 対象 branch / 未 push commit 数を含める
5. While 自動 push リトライが 1 回に固定されている状態, when push が失敗したとき, the watcher shall リトライ回数を本変更前と同一（1 回）に保つ

### Requirement 4: ahead==0（正常 push 済み）の無音挙動の維持

**Objective:** As a 運用者, I want 既に origin へ push 済み（ahead==0）の場合に副作用が一切発生しない, so that 通常成功ケースの外形挙動が本変更前と完全に一致する

#### Acceptance Criteria

1. When Stage 完了直後に `ahead==0` を検出したとき, the watcher shall Issue コメント投稿・ログ追記・push リトライのいずれも行わない
2. When Stage 完了直後に `ahead==0` を検出したとき, the watcher shall return code 0 を呼び出し側へ返す

### Requirement 5: ahead が判定不能（unknown）の場合の安全側挙動の維持

**Objective:** As a 運用者, I want ahead 数の取得に失敗した場合も本変更前と同じ安全側ロジックで動く, so that 未 push の可能性を取りこぼさず後方互換を保てる

#### Acceptance Criteria

1. If ahead 数の取得が失敗または timeout したとき, the watcher shall 未 push と同等扱いで自動 push リトライ経路へ進む
2. When ahead が unknown の状態で自動 push リトライが成功したとき, the watcher shall Requirement 1 と同一の成功時挙動（コメント抑止 + info ログのみ）を適用する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher shall push 失敗時の exit code・claude-failed escalation・リトライ回数（1 回）を本変更前と同一に保つ
2. The watcher shall 既存 env var 名（`REPO` / `REPO_DIR` / `LOG` / `NUMBER` 等）・ラベル遷移契約を変更しない
3. The watcher shall 既存の失敗通知コメント書式および失敗時ログ行書式を変更しない
4. Where stage 識別子 `stageA-push-missing` / `stageA-prime-push-missing` / `stageB-push-missing` が呼び出し側から渡される構成, the watcher shall 当該識別子の伝搬契約を本変更前と同一に保つ

### NFR 2: 冪等性・無害性

1. The watcher shall 同一の未 push 状態に対して関数を再実行しても、push 成功時に Issue コメントを新規投稿しない
2. While 通常成功ケース（ahead==0）を処理している状態, the watcher shall 副作用（コメント・ログ追記・push）を一切発生させない

### NFR 3: 観測可能性

1. The watcher shall push 成功時の info 行を機械的に grep 可能な単一行形式で `$LOG` に記録する（複数行に分割しない）

## Out of Scope

- Stage C 完了直後の PR 実在 verify ヘルパー（#108 / #110 の別関数）の挙動変更
- Developer / Reviewer プロンプトへの「branch を push せよ」という指示追加（commit-only 設計は維持し、push 集約は watcher 側に残す）
- `verify_pushed_or_retry` のリトライ回数を 1 回から増やす変更
- 失敗時通知コメントの文言・構造の変更（成功時のみが対象）
- 過去に投稿済みの成功時 ⚠️ コメントの遡及削除・クリーンアップ
- ahead 数測定の timeout 値（30 秒）やロジックの変更

## Open Questions

- なし（Issue 本文の受入観点・後方互換要件が明確であり、人間コメントによる追加決定事項も存在しないため、推測による未確定事項はない）
