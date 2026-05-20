# Requirements Document

## Introduction

`pr-iteration` Processor で 1 round 分の Claude セッションを実行している最中に Claude Max の
5 時間ローリング quota の警告閾値（`rate_limit_event` の `status == "allowed_warning"` かつ
`surpassedThreshold >= 0.9`）に到達すると、Claude セッションがファイル編集の途中で打ち切られ、
commit / push に到達せずに終了する事例が観測されている。watcher は Claude CLI の exit code が 0
で返ることから「成功」と判定して `needs-iteration` ラベルを外し（あるいは finalize 失敗で残置し）
ながら、作業ツリーには未コミット変更（dirty）を残す。次サイクルでは `process_pr_iteration` 冒頭の
dirty 検知で Processor 全体がスキップされるか、`git checkout` が衝突して以後の cycle が沈黙失敗する。

本要件は、`pr-iteration` round の中で quota 警告を検知して「soft-fail」として扱い、未コミット変更を
自動 commit / push して以降の cycle が継続できる clean state に戻すこと、および dirty が残った
状態で次サイクルが始まった場合の最小限の自動回復ガードを定義する。`needs-quota-wait` 経由の
Resume Processor 統合などの大規模な再設計は本要件のスコープ外で、観測実例で session 中断していた
事象に対する**最小ガード（auto-commit + `needs-iteration` 据え置き）**に範囲を絞る。

## Requirements

### Requirement 1: Round 実行中の quota 警告検知と soft-fail 化

**Objective:** As a idd-claude 運用者, I want `pr-iteration` round 中に Claude Max quota の
警告閾値到達を検知して soft-fail として扱い未コミット変更を退避してほしい, so that quota 起因で
途中終了した round の差分が失われたり次サイクルを沈黙失敗させたりしない。

#### Acceptance Criteria

1. When PR Iteration Round の Claude セッション出力に `type == "rate_limit_event"` かつ `status == "allowed_warning"` かつ `surpassedThreshold >= 0.9` を満たすイベントが現れたとき, the PR Iteration Processor shall その round を `quota-soft-fail` として記録する
2. When `quota-soft-fail` を検出した round が終了したとき, the PR Iteration Processor shall 未コミットの差分があれば head branch に対して自動で commit と push を行う
3. When `quota-soft-fail` の round で auto-commit を実施するとき, the PR Iteration Processor shall commit message を `docs(specs): partial round-<N> output before quota cutoff (auto-recovered)` 形式とし、`Co-Authored-By: Claude <noreply@anthropic.com>` 行を含める
4. When `quota-soft-fail` を検出した round が終了したとき, the PR Iteration Processor shall 対象 PR の `needs-iteration` ラベルをそのまま残置し、`ready-for-review` / `awaiting-design-review` への昇格は行わない
5. If `quota-soft-fail` round の auto-commit や push に失敗したとき, the PR Iteration Processor shall その失敗を WARN ログに記録した上で `needs-iteration` を残置して当該 PR の処理を終了する
6. The PR Iteration Processor shall `quota-soft-fail` 検知時に対象 PR に `needs-quota-wait` ラベルを付与しない（dispatcher の Resume Processor との連携は本要件スコープ外）

### Requirement 2: Round 終了後の未コミット差分の自動回復

**Objective:** As a idd-claude 運用者, I want quota 警告の有無にかかわらず round 終了時点で
作業ツリーに未コミット差分が残っていれば自動で退避してほしい, so that 次サイクルが dirty 検知で
スキップされたり `git checkout` 衝突で停止したりしない。

#### Acceptance Criteria

1. When PR Iteration Round の Claude セッションが終了したとき, the PR Iteration Processor shall 作業ツリーが clean かどうかを判定する
2. When Round 終了時に未コミット差分が残存しているとき, the PR Iteration Processor shall head branch に対して自動で commit と push を行い作業ツリーを clean state に戻す
3. When Requirement 2.2 に該当して auto-commit を実施するとき, the PR Iteration Processor shall commit message を `docs(specs): recover uncommitted round-<N> output (auto)` 形式とし、`Co-Authored-By: Claude <noreply@anthropic.com>` 行を含める
4. If Round 終了後の auto-commit / push に失敗したとき, the PR Iteration Processor shall その失敗を WARN ログに記録した上で当該 PR の処理を終了する
5. When Round 終了時の dirty 状態が Requirement 1（quota-soft-fail）と Requirement 2（quota 非起因の dirty）の両方の条件を満たすとき, the PR Iteration Processor shall Requirement 1 の commit message と挙動を優先して適用する

### Requirement 3: サイクル開始時の dirty 状態の最小ガード

**Objective:** As a idd-claude 運用者, I want 前 cycle で dirty を残したまま新 cycle が開始した場合に
作業ツリーを安全に復旧してほしい, so that 過去 round の中間生成物に起因して Processor が
無期限にスキップされ続けない。

#### Acceptance Criteria

1. When PR Iteration Processor が cycle 冒頭で作業ツリーの dirty を検出したとき, the PR Iteration Processor shall 現在チェックアウトされている branch 名と dirty なパス一覧をログに記録する
2. When dirty 検出時の current branch が `claude/issue-<番号>-<slug>` 命名規約に一致するとき, the PR Iteration Processor shall 当該 branch に対して未コミット差分を自動 commit / push して作業ツリーを clean state に戻し、Processor の本処理を継続する
3. When Requirement 3.2 に該当して auto-commit を実施するとき, the PR Iteration Processor shall commit message を `docs(specs): recover pre-cycle dirty state on <branch> (auto)` 形式とし、`Co-Authored-By: Claude <noreply@anthropic.com>` 行を含める
4. If dirty 検出時の current branch が `claude/issue-<番号>-<slug>` 命名規約に一致しないとき, the PR Iteration Processor shall ERROR ログを残した上で当該 cycle の PR Iteration Processor をスキップして終了する
5. If 自動回復の commit / push に失敗したとき, the PR Iteration Processor shall ERROR ログを残した上で当該 cycle の PR Iteration Processor をスキップして終了する

### Requirement 4: ログとオブザーバビリティ

**Objective:** As a idd-claude 運用者, I want quota soft-fail と自動回復の発生をログから識別可能に
してほしい, so that cron 出力の grep で発生件数や対象 PR を機械的に集計できる。

#### Acceptance Criteria

1. When `quota-soft-fail` を検知したとき, the PR Iteration Processor shall `pi_log` プレフィクス付きで PR 番号 / round / utilization / action（`auto-commit+keep-label` など）を 1 行にまとめてログ出力する
2. When Requirement 2 または Requirement 3 の自動回復を実行したとき, the PR Iteration Processor shall `pi_log` プレフィクス付きで PR 番号 / branch / 種別（`post-round-recover` / `pre-cycle-recover`）/ 結果（success/fail）をログ出力する
3. The PR Iteration Processor shall 自動回復に伴う commit / push の失敗を WARN または ERROR レベルで `>&2` に出力する

### Requirement 5: 既存 quota-aware 機構との独立性

**Objective:** As a idd-claude 運用者, I want 本要件の検知 / 回復ガードが既存の
`QUOTA_AWARE_ENABLED` opt-out 設定とは独立に動作してほしい, so that dispatcher の Resume Processor
を採用していない運用環境でも round 途中終了からの自動回復が機能する。

#### Acceptance Criteria

1. While `QUOTA_AWARE_ENABLED` が `false` に設定されているとき, the PR Iteration Processor shall Requirement 1 の `rate_limit_event` 検知と soft-fail 化を有効のまま動作させる
2. While `QUOTA_AWARE_ENABLED` が `false` に設定されているとき, the PR Iteration Processor shall Requirement 2 および Requirement 3 の自動回復ガードを有効のまま動作させる
3. The PR Iteration Processor shall 本要件で追加する検知・回復処理の中で `needs-quota-wait` ラベルの付与や `qa_handle_quota_exceeded` 相当の dispatcher 連携を行わない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Iteration Processor shall 本要件導入前から存在する PR 番号 / round / kind ベースのラベル遷移挙動（quota 警告が発生しない round における `needs-iteration` → `ready-for-review` / `awaiting-design-review`）を変更しない
2. The PR Iteration Processor shall 既存の `pi_log` / `pi_warn` / `pi_error` ログ出力形式と既存のログ行プレフィクスを変更しない
3. The PR Iteration Processor shall 既存の環境変数（`PR_ITERATION_ENABLED` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_GIT_TIMEOUT` / `QUOTA_AWARE_ENABLED` ほか）の意味と既定値を変更しない

### NFR 2: テスト可能性

1. The PR Iteration Processor shall Requirement 1 〜 3 の各分岐（quota 警告検知 / round 後 dirty / cycle 開始 dirty + branch 一致 / cycle 開始 dirty + branch 不一致）をそれぞれ独立に検証できる fixture を提供する
2. The PR Iteration Processor shall 既存テストスイートが本要件導入後も成功する状態を維持する

### NFR 3: 観測性とアラート

1. The PR Iteration Processor shall `quota-soft-fail` 行・自動回復行を含むログ出力を、`pi_log` の既存タイムスタンプ形式（`[YYYY-MM-DD HH:MM:SS] pi: ...`）で記録する
2. The PR Iteration Processor shall 1 回の cycle 中に発生した `quota-soft-fail` の件数を、その cycle のサマリログから集計可能にする（PR 番号付きで 1 行 1 件として出力する）

## Out of Scope

- dispatcher 側 Resume Processor（`process_quota_resume` / `qa_handle_quota_exceeded`）の改修や、`needs-quota-wait` ラベル経由での自動再 trigger 連携
- Stage A / B / C / Reviewer / Triage など `pr-iteration` 以外のステージにおける同種の round 途中終了対策（本要件は `pr-iteration` round に限定する）
- Claude Max quota 枯渇の予測抑制（utilization が閾値未満であっても予防的に round を遅延・分割する仕組み）
- Claude CLI 側で `allowed_warning` 受信後にツール実行を継続する挙動の修正・回避（upstream 課題）
- 既存 `needs-quota-wait` ラベル / `quota-reset` hidden marker の意味変更
- auto-commit 対象とする branch 命名規約の拡張（`claude/issue-<番号>-<slug>` 以外の branch を回復対象とすること）

## Open Questions

- なし（Issue 本文の「仮案・判断を委ねたい点」は、本要件で以下の通り採用した:
  - `needs-quota-wait` ラベル付与は今回スコープ外とし、最小ガード（auto-commit + `needs-iteration` 据え置き）に留める → Requirement 1.6 / 5.3 / Out of Scope に明記
  - `allowed_warning` 単独で soft-fail とする conservative な扱いを採用 → Requirement 1.1 で `surpassedThreshold >= 0.9` を併用条件として明文化
  - auto-commit message は `Co-Authored-By: Claude <noreply@anthropic.com>` を含む既存慣習に従う → Requirement 1.3 / 2.3 / 3.3 に明記）
