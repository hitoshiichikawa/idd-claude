# Requirements Document

## Introduction

pr-reviewer モジュールの `pr_already_processed` は、(sha, kind) ペアの marker が既存コメントに
存在するかを判定して重複投稿を防ぐ関数だが、現在 PR コメントを GitHub REST API のデフォルト件数
（per_page=30 / 1 ページのみ）で取得しているため、コメント総数が 30 件を超え該当 marker が 1
ページ目の外（page 2 以降）に存在する PR では「未投稿」と誤判定する。結果として、`exec-fail-escalated`
advisory が cron tick 毎（約 2 分間隔）に同一 head sha のまま重複投稿されてしまい、運用者の
ノイズと PR コメントスレッドの汚染を招く。本要件は、(sha, kind) 単位の重複判定セマンティクスと
marker 形式を変えずに、PR のコメント総数に依らない正確な重複判定を実現し、同一の盲点を共有する
他の呼び出し経路（`pr_post_error_comment` / レビュー結果コメント）にも漏れなく適用することを
目的とする。

## Requirements

### Requirement 1: コメント総数に依らない marker 重複判定

**Objective:** As an idd-claude 運用者, I want `pr_already_processed` が PR のコメント総数に依らず全コメントを走査して marker の有無を判定できる, so that コメント 30 件を超える PR でも `exec-fail-escalated` などの advisory が二重投稿されない

#### Acceptance Criteria

1. When `pr_already_processed` が呼び出された場合, the PR Reviewer Module shall 当該 PR の全 issue コメントを対象に (sha, kind) marker の有無を判定する
2. While 当該 PR の issue コメント総数が 30 件以下である間, the PR Reviewer Module shall 従来と同一の判定結果（既存=rc 0 / 未存在=rc 1）を返す
3. When 当該 PR の issue コメント総数が 30 件を超え該当 marker が 31 件目以降のコメントに存在する場合, the PR Reviewer Module shall 当該 marker を「既存」と判定して rc 0 を返す
4. When 当該 PR の issue コメント総数が 31 件以上で該当 marker が 1 件も存在しない場合, the PR Reviewer Module shall 当該 marker を「未存在」と判定して rc 1 を返す
5. The PR Reviewer Module shall (sha, kind) ペア単位の判定セマンティクスを維持し、tool 属性の値を判定条件に含めない
6. The PR Reviewer Module shall 既存の marker 文字列形式（`<!-- idd-claude:pr-reviewer sha=<sha> kind=<kind> tool=<tool> -->`）を変更しない

### Requirement 2: 同一盲点を共有する呼び出し経路への適用

**Objective:** As an idd-claude 運用者, I want `pr_already_processed` を共有する全ての投稿経路で同じ重複判定を効かせたい, so that exec-fail-escalated advisory と同様の重複投稿が他の kind（exec-failed / no-tool / review 等）でも発生しない

#### Acceptance Criteria

1. When `pr_post_exec_fail_escalation_comment` が同一 (sha, kind=exec-fail-escalated) marker の既存判定を行う場合, the PR Reviewer Module shall Requirement 1 と同一の判定経路を経由する
2. When `pr_post_error_comment` が同一 (sha, kind) marker の既存判定を行う場合, the PR Reviewer Module shall Requirement 1 と同一の判定経路を経由する
3. When レビュー結果コメント投稿経路が同一 (sha, kind=review) marker の既存判定を行う場合, the PR Reviewer Module shall Requirement 1 と同一の判定経路を経由する
4. The PR Reviewer Module shall 上記いずれの経路でも、コメント 30 件超 PR で marker が 1 ページ目外にあるケースを「未存在」と誤判定しない

### Requirement 3: コメント取得失敗時の安全側フォールバック

**Objective:** As an idd-claude 運用者, I want コメント取得が失敗した場合でも重複投稿を発生させない安全側フォールバックを維持したい, so that 一時的な GitHub API エラーが advisory の連続再投稿を引き起こさない

#### Acceptance Criteria

1. If 当該 PR のコメント取得が失敗（API エラー / timeout / 認証失敗 / レート制限など）した場合, the PR Reviewer Module shall 該当 marker を「既存扱い」として rc 0 を返し、呼び出し元の再投稿を抑止する
2. If 全コメント走査の途中ページ取得が失敗した場合, the PR Reviewer Module shall それまでに取得済みのページに marker が含まれていない場合でも「既存扱い」として rc 0 を返す
3. If コメント取得が失敗した場合, the PR Reviewer Module shall 警告ログ（`pr_warn` prefix）を一次運用ログに出力し、運用者が事後に状況を追跡できるようにする
4. The PR Reviewer Module shall コメント取得失敗時のフォールバック挙動を Requirement 1 / Requirement 2 のいずれの呼び出し経路でも一貫して適用する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Reviewer Module shall `pr_already_processed` の入出力契約（引数順 = pr_number / sha / kind、戻り値 0=既存 / 1=未存在）を変更しない
2. The PR Reviewer Module shall 既存の marker 文字列形式・hidden HTML コメントとしての可視性・GitHub UI 上での非表示性を変更しない
3. The PR Reviewer Module shall 既存の (sha, kind) 単位重複判定セマンティクス（tool 属性を判定に含めない方針）を変更しない
4. The PR Reviewer Module shall 既存の環境変数名と既定値（`PR_REVIEWER_GIT_TIMEOUT` を含む timeout 設定）の意味を変更しない
5. The PR Reviewer Module shall 既存に投稿済みの marker 付きコメントを遡及的に削除・修正しない

### NFR 2: 性能

1. The PR Reviewer Module shall コメント 30 件以下の PR では Requirement 1 適用前と比較して GitHub API 呼び出し回数を増やさない
2. The PR Reviewer Module shall コメント走査のページ取得を `PR_REVIEWER_GIT_TIMEOUT` の範囲内で完了させ、超過時はコメント取得失敗として Requirement 3 のフォールバックに合流する

### NFR 3: 可観測性

1. The PR Reviewer Module shall marker 重複判定の結果（既存 / 未存在 / 取得失敗）を識別できる粒度のログ出力を維持する
2. The PR Reviewer Module shall コメント取得失敗を `pr_warn` レベルで一次運用ログに記録する

## Out of Scope

- 外部レビューツール（codex / antigravity）側の rate-limit / quota 制御や HTTP 429 ハンドリングそのものは本要件の対象外
- `pr_post_exec_fail_escalation_comment` の advisory 本文・連続失敗回数閾値（`PR_REVIEWER_EXEC_FAIL_LIMIT`）・ラベル付与方針の見直しは本要件の対象外
- failed-recovery processor の no-progress 終端 spam（#417）は別 Issue で追跡し本要件では扱わない
- 既に投稿済みの重複 `exec-fail-escalated` advisory コメントの遡及削除 / 整理は本要件の対象外（運用者の手動対応に委ねる）
- pr-iteration / pr-design-reviewer / adjudicator / security-review 等の他モジュール側の独立した重複判定パスのページネーション点検は本要件の対象外（`pr_already_processed` を直接呼び出す経路のみを対象とする）
- marker 形式そのものを変える設計（PR body marker への移行 / idempotency flag 追加等）は本要件の対象外（後方互換性 NFR 1.2 と整合）

## Open Questions

- なし（具体的な実装方式は仮案 A/B/C の選択を含めて Architect / Developer の責務）

## 関連

- Depends on: なし
- Parent: なし
- Related: #417
