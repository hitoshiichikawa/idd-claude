# Requirements Document

## Introduction

Phase A（Issue #14）で導入された Merge Queue Processor は、対象 PR 検索クエリで
`-label:"needs-rebase"` を指定して **`needs-rebase` 付き PR を恒常的に除外**している。
このため、人間が手動で conflict を解消したのにラベルを外し忘れたケースや、main の進行で
conflict が自然解消したケースでも、PR は永久に Phase A の対象外となり、人間が `gh pr edit
--remove-label` を手動実行しない限り再評価が走らない。本機能では、watcher サイクル冒頭で
`needs-rebase` 付きの approved PR のみを対象とした **再評価ループ**を別レーンで起動し、
`mergeable=MERGEABLE` に戻った PR のラベルを自動除去することで、運用上の手作業を削減する。
既存 Phase A の挙動・env / ラベル / exit code 契約は保ちつつ、新機能は独立した env で opt-in
制御する。

## Requirements

### Requirement 1: Re-check ループの起動条件と対象範囲

**Objective:** As a watcher operator, I want `needs-rebase` 付きの approved PR だけを再評価対象にし、Phase A 本体ループとは独立に有効化したい, so that 既稼働環境を壊さずに段階的に opt-in でき、Phase A 本体と同等の安全フィルタが効いた集合だけを対象にできる

#### Acceptance Criteria

1. While watcher サイクルが開始した直後、リポジトリ最新化が完了した状態で, the Issue Watcher shall Phase A 本体ループ（既存 Merge Queue Processor）が起動する **直前** に Re-check Processor を 1 回起動する
2. The Issue Watcher shall Re-check Processor の有効化／無効化を制御する環境変数 `MERGE_QUEUE_RECHECK_ENABLED` を読み取り、値が `true` でない場合は Re-check Processor を起動しない
3. The Issue Watcher shall `MERGE_QUEUE_RECHECK_ENABLED` のデフォルト値を `false`（opt-in）として扱う
4. The Re-check Processor shall 対象 repo の open PR のうち、少なくとも 1 件以上の approving review が付いており、かつ `needs-rebase` ラベルが付与されているものだけを処理対象に含める
5. If 処理対象 PR が draft 状態である, the Re-check Processor shall その PR を対象から除外する
6. If 処理対象 PR に `claude-failed` ラベル相当の終端状態ラベルが付いている, the Re-check Processor shall その PR を対象から除外する
7. If 処理対象 PR の head branch 名が Phase A と同じ head branch pattern（既存 `MERGE_QUEUE_HEAD_PATTERN`、デフォルト `^claude/`）に合致しない, the Re-check Processor shall その PR を対象から除外する
8. If 処理対象 PR の head repo owner が base repo owner と異なる（= fork からの PR）, the Re-check Processor shall その PR を対象から除外する
9. The Re-check Processor shall 対象 PR ごとに GitHub API から `mergeable` 相当の情報を取得する

### Requirement 2: mergeable 判定ごとの挙動

**Objective:** As a reviewer, I want 一時的だった conflict が解消した PR を自動で再評価対象に戻し、まだ conflict が残るものは手元の対応待ちのまま据え置いてほしい, so that ラベル除去の手作業を最小化しつつ、未解消 conflict にノイズ（重複コメント・再ラベル）が積み上がらない

#### Acceptance Criteria

1. When 対象 PR の mergeable 状態が `MERGEABLE` と判定された, the Re-check Processor shall 当該 PR から `needs-rebase` ラベルを除去する
2. When `needs-rebase` ラベルの除去が成功した, the Re-check Processor shall 「conflict resolved, re-evaluating next cycle」相当の 1 行 INFO ログを当該 PR 番号付きで出力する
3. When 対象 PR の mergeable 状態が `CONFLICTING` と判定された, the Re-check Processor shall 当該 PR の状態を変更しない（再ラベル付与を行わず、コメントも追記しない）
4. When 対象 PR の mergeable 状態が `UNKNOWN` または未確定（null）と判定された, the Re-check Processor shall 当該 PR の状態を変更せず、判定を次回サイクルに委ねる
5. The Re-check Processor shall ラベル除去後の即時 re-merge / 自動 rebase / 状況コメント投稿を行わない
6. If `needs-rebase` ラベル除去 API がエラーを返した, the Re-check Processor shall watcher ログに WARN レベル相当で原因を記録し、後続 PR の処理は継続する

### Requirement 3: Phase A 本体との独立性・後方互換性

**Objective:** As an existing watcher user, I want Re-check 機能を Phase A 本体（自動 rebase + 状況コメント）の有効／無効とは独立に制御したい, so that 「再評価だけ有効化したい」「Phase A 本体だけ有効化したい」のいずれの運用にも適合し、既稼働環境を壊さない

#### Acceptance Criteria

1. The Issue Watcher shall `MERGE_QUEUE_RECHECK_ENABLED` を `MERGE_QUEUE_ENABLED` とは独立した環境変数として扱い、互いの値が他方の挙動に影響しないようにする
2. Where `MERGE_QUEUE_RECHECK_ENABLED=true` かつ `MERGE_QUEUE_ENABLED=false`, the Issue Watcher shall Re-check Processor のみを実行し、Phase A 本体の自動 rebase / 状況コメント投稿は行わない
3. Where `MERGE_QUEUE_RECHECK_ENABLED=false`, the Issue Watcher shall Re-check Processor のコードパスを完全にスキップし、本機能導入前と一致する挙動（既存 Phase A 本体ループのみが `MERGE_QUEUE_ENABLED` に従って動作する状態）で動作する
4. The Issue Watcher shall 既存の環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `MERGE_QUEUE_ENABLED`, `MERGE_QUEUE_MAX_PRS`, `MERGE_QUEUE_GIT_TIMEOUT`, `MERGE_QUEUE_BASE_BRANCH`, `MERGE_QUEUE_HEAD_PATTERN` 等）の意味とデフォルト挙動を変更しない
5. The Issue Watcher shall 既存ラベル（`auto-dev`, `claude-picked-up`, `awaiting-design-review`, `ready-for-review`, `claude-failed`, `needs-decisions`, `skip-triage`, `needs-rebase`, `needs-iteration`）の名前・意味・付与契約を変更しない
6. The Issue Watcher shall 既存の lock ファイルパス・ログ出力先・watcher の exit code の意味を変更しない
7. The Re-check Processor shall `needs-rebase` ラベルの除去主体として動作し、ラベル付与（Phase A 本体の責務）は行わない

### Requirement 4: 実行コスト・タイムバジェット

**Objective:** As a watcher operator, I want Re-check Processor が watcher の通常実行間隔に収まる範囲で完了することを保証したい, so that 後続の Phase A 本体ループおよび Issue 処理ループが遅延せず、cron / launchd の重複起動も発生しない

#### Acceptance Criteria

1. The Re-check Processor shall 1 サイクルあたりに処理する PR 数の上限値を、環境変数 `MERGE_QUEUE_RECHECK_MAX_PRS` で上書き可能とし、デフォルト値を `20` とする
2. If 上限を超える対象 PR が存在する, the Re-check Processor shall 残りの PR を次回サイクルに持ち越し、watcher ログにスキップ件数（overflow）を記録する
3. The Re-check Processor shall 1 PR あたりの GitHub API 呼び出し回数を、対象 PR 取得・mergeable 判定・ラベル除去の合計で 3 回以内に抑える
4. The Re-check Processor shall 各 GitHub API 呼び出しに対し、Phase A と同等のタイムアウト制御（既存 `MERGE_QUEUE_GIT_TIMEOUT` 相当）を適用する
5. If いずれかの PR 処理がタイムアウトに達した, the Re-check Processor shall 当該 PR の操作を中断し、ログに WARN を出して次の PR の処理に進む

### Requirement 5: ロギング・可観測性

**Objective:** As a watcher operator, I want Re-check Processor の判断とラベル除去結果をログから追えるようにしたい, so that 自動再評価の挙動を検証し、想定外のラベル除去が起きていないか監査できる

#### Acceptance Criteria

1. The Re-check Processor shall サイクル開始時に「対象候補 PR 件数」「実際に処理する件数」「上限超過件数（overflow）」をログに出力する
2. The Re-check Processor shall 各 PR ごとに「PR 番号」「mergeable 判定結果」「実施したアクション（label removed / kept / skip）」を 1 行以上のログに出力する
3. When `needs-rebase` ラベルを除去した, the Re-check Processor shall 「conflict resolved, re-evaluating next cycle」相当の文言を含む 1 行 INFO ログを出力する
4. The Re-check Processor shall サイクル終了時に「ラベル除去成功数」「conflict 維持数」「skip 数（UNKNOWN 含む）」「失敗数」のサマリをログに出力する
5. The Re-check Processor shall 自身が出力するすべての判定・サマリログ行に `merge-queue-recheck:` プレフィックスを付与し、operator が grep で集計できるようにする
6. The Re-check Processor shall ログのタイムスタンプ書式を Issue Watcher と統一する（`[YYYY-MM-DD HH:MM:SS]` 相当）
7. The Re-check Processor shall ログの出力先を既存 watcher の `LOG_DIR` 配下に統一し、新規の出力ディレクトリを作らない
8. The Re-check Processor shall 標準エラー出力には人間向けの WARN/ERROR のみを出し、標準出力は機械可読な集計用に予約する

### Requirement 6: ドキュメント更新（DoD）

**Objective:** As a new operator, I want Re-check 機能の有効化方法と Phase A 本体との関係を README から読み取れるようにしたい, so that 既存ユーザが本機能の opt-in 可否を即判断できる

#### Acceptance Criteria

1. The README.md shall Re-check Processor の概要（目的・対象・タイミング・Phase A 本体との独立性）を記述するセクションを含む
2. The README.md shall Re-check Processor の有効化／無効化を制御する環境変数 `MERGE_QUEUE_RECHECK_ENABLED` および `MERGE_QUEUE_RECHECK_MAX_PRS` の名称・デフォルト値・推奨値を明記する
3. The README.md shall 既存の Phase A 節「既知の制限: `needs-rebase` ラベルの自動解除は Phase A のスコープ外」を「解消済み（`MERGE_QUEUE_RECHECK_ENABLED=true` で opt-in 自動化）」と読める内容に更新する
4. The README.md shall 本機能導入による後方互換性方針（既存 env / ラベル / lock / exit code が不変であること、`MERGE_QUEUE_RECHECK_ENABLED=false` で本機能導入前と完全に一致する挙動になること）を migration note として明記する

## Non-Functional Requirements

### NFR 1: パフォーマンス

1. The Re-check Processor shall 通常ケース（対象 PR 0〜5 件）の処理を、watcher の最短実行間隔（README 既定 2 分）の 1/4（30 秒）以内に完了する
2. The Re-check Processor shall 上限値 `MERGE_QUEUE_RECHECK_MAX_PRS` 件をフルに処理した場合でも、watcher の最短実行間隔の半分（60 秒）以内に完了することを目指す

### NFR 2: 安全性

1. The Re-check Processor shall リモートに対する破壊的操作（ラベル付与・コメント投稿・force push 等）を行わず、`needs-rebase` ラベルの除去操作のみを副作用として持つ
2. If 対象 PR の mergeable が `MERGEABLE` 以外の値（`CONFLICTING` / `UNKNOWN` / null / 未知の値）と判定された, the Re-check Processor shall ラベル除去を行わない

### NFR 3: 観測可能性

1. The Re-check Processor shall 各 PR への操作結果（label removed / kept / skip / fail）を operator がログを grep するだけで集計できる識別語（`merge-queue-recheck:` プレフィックス）でマークする
2. The Re-check Processor shall サイクル開始ログ・各 PR 判定ログ・サマリログのいずれにおいても、Phase A 本体の `merge-queue:` プレフィックスとは異なる識別子を使用する

## Out of Scope

- ラベル除去後の即時 re-merge（merge ボタン相当の API 呼び出し）
- ラベル除去後の自動 rebase（Phase A 本体ループに委ねる）
- `needs-rebase` 付与時のコメントへの reply / 状況コメント追記
- GitHub mergeability 計算の強制 trigger（`UNKNOWN` 連発時の再計算指示）
- Re-check 専用のラベル付与（本機能は除去のみを担う）
- `needs-rebase` 付き PR の長期放置検知 / 起点 Issue への reminder 通知
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への本機能の組み込み
- `MERGE_QUEUE_RECHECK_MAX_PRS` 上限超過時の優先度付け（古い PR / 古いラベル付与順 等）

## Open Questions

- なし（Issue 本文・親 spec（#14）・既存実装の `MERGE_QUEUE_HEAD_PATTERN` / fork PR 除外契約に従って閉じた要件として記述）
