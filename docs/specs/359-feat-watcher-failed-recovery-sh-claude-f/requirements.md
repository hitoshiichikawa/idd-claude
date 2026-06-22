# Requirements Document

## Introduction

idd-claude の watcher は `claude-failed` ラベル付き Issue と auto-merge 待ち PR の CI 失敗を、
現状は人間が手動で復旧する運用となっている。本機能 Failed Recovery Processor は、これらの
失敗状態を自動で解析・修正し開発を再開させる一方で、quota 燃焼と多重ループを防ぐための
**Issue 単位通算 4 回の attempt budget** と **no-progress ガード** を強制する確実な終端設計
を持つ（D-19）。reviewer-reject 由来の `claude-failed`、および auto-merge 待ち PR の CI error
を解析対象に含め、対応内容は PR コメントに残す（D-07 追加要件 / D-10 / D-11 / D-19a）。
opt-in gate（`FAILED_RECOVERY_ENABLED`）と上位の `FULL_AUTO_ENABLED` を二重に必要とし、
既定 off では既存の手動復旧運用と等価挙動を保つ。

## Requirements

### Requirement 1: Failed Recovery Processor の起動制御

**Objective:** As a idd-claude 運用者, I want Failed Recovery Processor を明示的 opt-in でのみ起動させる, so that 既定運用では既存の手動 `claude-failed` 復旧手順に影響を与えない

#### Acceptance Criteria

1. Where `FAILED_RECOVERY_ENABLED=true` かつ `FULL_AUTO_ENABLED=true` が同時に成立する, the Failed Recovery Processor shall 通常の watcher サイクル内で起動する
2. If `FAILED_RECOVERY_ENABLED` が未設定または `true` 以外の値である, the Failed Recovery Processor shall 起動せず、対象 Issue / PR への副作用を行わない
3. If `FULL_AUTO_ENABLED` が未設定または `true` 以外の値である, the Failed Recovery Processor shall 起動せず、対象 Issue / PR への副作用を行わない
4. While `FAILED_RECOVERY_ENABLED` が無効である, the watcher shall 既存の `claude-failed` 手動復旧運用（ラベル除去手順に基づく次サイクル再 pickup）と等価な挙動を保つ
5. If `FAILED_RECOVERY_ENABLED` の値が `true` / `false` 以外の文字列（typo / 不正値）である, the Failed Recovery Processor shall 安全側（無効）として扱い起動しない

### Requirement 2: 復旧対象の選定

**Objective:** As a Failed Recovery Processor, I want 復旧対象となる Issue / PR を明確に定義する, so that 他 Processor の領分と衝突せず、対象範囲が誤って広がらない

#### Acceptance Criteria

1. When watcher サイクルが Failed Recovery Processor を起動した, the Failed Recovery Processor shall `claude-failed` ラベル付き Issue を復旧対象として走査する
2. When `claude-failed` ラベル付き Issue を走査するとき, the Failed Recovery Processor shall reviewer-reject 由来で付与された `claude-failed` も対象に含める
3. When watcher サイクルが Failed Recovery Processor を起動した, the Failed Recovery Processor shall auto-merge 待ち PR で CI error が発生しているものを復旧対象として走査する
4. If 対象 Issue / PR が `needs-quota-wait` / `needs-decisions` / `hold` 等の人間判断待ちラベルを持つ, the Failed Recovery Processor shall 当該対象を復旧候補から除外する
5. Where Issue に `auto-dev` ラベルが付与されていない, the Failed Recovery Processor shall 当該 Issue を復旧候補から除外する

### Requirement 3: 失敗解析と修正適用

**Objective:** As a Failed Recovery Processor, I want 失敗ログから原因 hint を抽出して修正を適用する, so that 人手介入なしで開発を再開できる

#### Acceptance Criteria

1. When `claude-failed` Issue を復旧対象として選定した, the Failed Recovery Processor shall Issue コメントおよび関連ログから失敗原因の hint を抽出し、修正試行を伴う再開を実行する
2. When auto-merge 待ち PR の CI error を復旧対象として選定した, the Failed Recovery Processor shall 当該 PR の CI ログを解析し、修正コミットを push したうえで checks を再実行する
3. When 修正試行を実行する, the Failed Recovery Processor shall 対応内容（解析した失敗原因の概要・適用した修正の概要・attempt 回数）を当該 PR または Issue にコメントとして 1 件残す
4. When 修正試行の結果 checks が green に復帰した, the Failed Recovery Processor shall `claude-failed` ラベルを除去し、当該 Issue / PR を通常の処理フローに復帰させる
5. If 修正試行中に未信頼入力（Issue 本文 / PR 本文 / branch 名 / コメント等）を外部コマンドへ渡す必要が生じる, the Failed Recovery Processor shall 当該入力を quote / `--` 区切り / ID 形式検証で sanitize したうえで使用する

### Requirement 4: 通算 attempt budget による終端保証

**Objective:** As a idd-claude 運用者, I want 復旧試行回数を Issue 単位の通算カウンタ 1 つで上限管理する, so that quota 燃焼と多重ループを必ず終端させられる

#### Acceptance Criteria

1. The Failed Recovery Processor shall Issue 単位の attempt カウンタを `FAILED_RECOVERY_MAX_ATTEMPTS`（既定値 4）を上限として通算で管理する
2. When Failed Recovery Processor が修正試行を 1 回開始した, the Failed Recovery Processor shall 当該 Issue の通算 attempt カウンタを 1 だけ増加させる
3. The Failed Recovery Processor shall 通算 attempt カウンタを Reviewer 内部の 2/2 試行や pr-iteration 3R 試行と掛け算せず、唯一のカウンタとして扱う（D-19b）
4. While 当該 Issue の通算 attempt カウンタが `FAILED_RECOVERY_MAX_ATTEMPTS` 未満である, the Failed Recovery Processor shall 次の修正試行を実行できる
5. If 当該 Issue の通算 attempt カウンタが `FAILED_RECOVERY_MAX_ATTEMPTS` に到達した, the Failed Recovery Processor shall それ以降の修正試行を実行せず `claude-failed` ラベルを据え置きで停止する
6. When `FAILED_RECOVERY_MAX_ATTEMPTS` 到達により停止する, the Failed Recovery Processor shall run-summary に通算試行回数と終端理由を含む通知を 1 件出力する
7. The Failed Recovery Processor shall 通算 attempt カウンタを `$HOME/.issue-watcher/` 配下に永続化し、watcher プロセスの再起動や cron サイクル跨ぎでもカウンタを保持する
8. Where `FAILED_RECOVERY_MAX_ATTEMPTS` が未設定 / 非整数 / 0 以下の値である, the Failed Recovery Processor shall 既定値 4 を採用する

### Requirement 5: no-progress ガード

**Objective:** As a Failed Recovery Processor, I want 同一原因の反復を検出して即終端する, so that 無進捗の修正試行で budget と quota を消費しない

#### Acceptance Criteria

1. While 修正試行を実行しようとしている, the Failed Recovery Processor shall 直前試行と今回の失敗原因 / 修正差分を比較する
2. If 直前試行と同一の失敗理由が再発しかつ修正差分が無進捗である, the Failed Recovery Processor shall 当該 Issue を no-progress と判定し以降の修正試行を実行しない
3. When no-progress 判定により終端する, the Failed Recovery Processor shall `claude-failed` ラベルを据え置きにし、終端理由（no-progress）を含むコメントを当該 Issue / PR に 1 件残す
4. When no-progress 判定により終端する, the Failed Recovery Processor shall run-summary に no-progress 終端を含む通知を 1 件出力する
5. The Failed Recovery Processor shall no-progress 判定に用いる前回試行情報を `$HOME/.issue-watcher/` 配下に永続化する

### Requirement 6: 復旧成功時の状態遷移

**Objective:** As a idd-claude 運用者, I want 復旧成功時に attempt カウンタと no-progress 履歴を適切に扱う, so that 同一 Issue が再度失敗した際の挙動が予測可能になる

#### Acceptance Criteria

1. When 修正試行により当該 Issue / PR が `claude-failed` を脱して通常フローに復帰した, the Failed Recovery Processor shall 当該 Issue / PR に対し以降の本サイクル内で追加の修正試行を実行しない
2. The Failed Recovery Processor shall 復旧成功後の通算 attempt カウンタ取り扱いを永続化ファイル上で識別可能にし、後続サイクルで同一 Issue が再度 `claude-failed` 化した際に通算上限判定へ反映できる状態を保つ

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Failed Recovery Processor shall 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `FULL_AUTO_ENABLED` 等）の名前・意味を変更しない
2. The Failed Recovery Processor shall 既存ラベル名（`claude-failed` / `auto-dev` / `needs-quota-wait` / `needs-decisions` 等）の名前・付与契約を変更しない
3. While `FAILED_RECOVERY_ENABLED=false` または未設定である, the watcher shall 本機能導入前と完全に同一の外部挙動（Issue / PR への副作用がない状態）を保つ

### NFR 2: 冪等性と再起動耐性

1. The Failed Recovery Processor shall 同一 Issue / PR に対する同一サイクル内の重複起動を内部状態または外部ロックで防止する
2. While watcher プロセスが終了またはサイクル跨ぎで再起動した, the Failed Recovery Processor shall 永続化済みの attempt カウンタおよび no-progress 履歴を継承する
3. The Failed Recovery Processor shall `$HOME/.issue-watcher/` 配下の永続化ファイルを TOCTOU 安全な方法で読み書きする

### NFR 3: セキュリティ

1. The Failed Recovery Processor shall Issue / PR / コメント / branch 名・branch 上ファイルといった未信頼入力を `gh` / `git` / `jq` / `bash` 等へ渡すとき、quote / `--arg` `--argjson` / `--` 区切り / 数値 ID `^[0-9]+$` / SHA `^[0-9a-f]{40}$` 検証を適用する
2. The Failed Recovery Processor shall secrets を含む環境変数を Issue / PR コメントおよび run-summary 通知に出力しない

### NFR 4: 可観測性

1. When Failed Recovery Processor が修正試行・終端・no-progress 判定を行った, the Failed Recovery Processor shall 該当イベントの種別と Issue / PR 番号を `$LOG_DIR` 配下のログへ記録する
2. When `FAILED_RECOVERY_MAX_ATTEMPTS` 到達または no-progress による終端が発生した, the Failed Recovery Processor shall run-summary 通知 1 件を発行する

### NFR 5: 静的解析と近接テスト

1. The `modules/failed-recovery.sh` shall `shellcheck` を警告ゼロでクリアする
2. The Failed Recovery Processor shall 通算 attempt カウンタ加算 / 上限到達による終端 / no-progress 判定の 3 経路に対する近接テスト（`local-watcher/test/` 配下に stub ベースで配置）を備える

### NFR 6: テンプレート同期

1. The Failed Recovery Processor 配布物（`modules/failed-recovery.sh` / 関連 env var の README 記載 / ラベルセット）shall root `.claude/`・root `modules/`・`local-watcher/` と `repo-template/` 配下の対応物で byte 一致または機能等価で同期される

## Out of Scope

- `needs-decisions` 状態の Issue を自動継続させる挙動（Issue 06 の責務）
- semantic conflict（意味論的衝突）の解析と解消（Issue 07 の責務）
- Reviewer 内部 2/2 試行や pr-iteration 3R の上限値そのものの変更（本機能は通算カウンタの単独 source として扱うのみ）
- `modules/failed-recovery.sh` 内部の関数構成 / 公開 IF シグネチャ / 永続化ファイルのファイル名・スキーマ詳細（Architect の責務）
- `auto-dev` 未付与の Issue や手動運用 Issue への自動復旧適用
- Triage / Architect / Developer / Reviewer 各エージェント自体の起動制御変更

## Open Questions

- なし（Issue 本文・関連決定 D-07 / D-10 / D-11 / D-19 / D-19a / D-19b・依存 Issue 01・merge 済み #348 / #356 の情報で要件確定可能）

## 関連

- Depends on: #348
- Related: #356
