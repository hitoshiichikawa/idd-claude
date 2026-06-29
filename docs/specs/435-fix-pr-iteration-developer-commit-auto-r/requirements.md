# Requirements Document

## Introduction

PR Iteration の Developer は、1 round 内で実装変更を行っても自分で commit せず、watcher の
中途異常終了向け保険である `pi_auto_commit_and_push`（`docs(specs): recover uncommitted
round-N output (auto)`）に commit を肩代わりさせて運用するケースが観測されている
（altpocket-server PR #139 / 2026-06-26）。これにより 2 つの問題が起きる:
(1) commit メッセージが作業意図を反映しない `recover uncommitted ... (auto)` ばかりになり
commit 履歴が無意味化する、(2) no-progress ループ検知（#122）が auto-recovery round を
進捗なしと誤判定して premature な `claude-failed` 昇格を招く懸念がある。

本要件は、PR Iteration の Developer に「1 round 内で実装変更を行ったら自分で意味のある
Conventional Commits メッセージで commit + push する」commit 規律を `.claude/agents/developer.md`
に明文化することを主軸とする。あわせて、実コード差分が push された round（auto-recovery 経由を
含む）を no-progress と誤カウントして premature な `claude-failed` に倒さない不変条件を、現行
コードでの充足状況を切り分けた上で固定する。本要件は idd-claude self-hosting の後方互換性
（env var 名 / ラベル / exit code / cron 文字列 / ログ出力先 / hidden marker 契約を壊さない）を
前提とする。

## Requirements

### Requirement 1: Developer の round 内 self-commit 規律の明文化

**Objective:** As a idd-claude 運用者, I want PR Iteration の Developer が 1 round 内の実装変更を
自分で意味のある commit メッセージで commit + push するよう規律づけたい, so that auto-recovery
への常用依存をやめ commit 履歴が作業意図を反映する状態を保てる。

#### Acceptance Criteria

1. The `.claude/agents/developer.md` shall PR Iteration 内で Developer が 1 round 内に実装変更を行った場合は、その round 内で当該変更を自分で commit + push する責務を負うことを明記する
2. The `.claude/agents/developer.md` shall round 内 self-commit のメッセージを Conventional Commits 規約（`feat` / `fix` / `test` / `docs` / `refactor` / `chore`）に従って作業意図が読み取れる形にすることを明記する
3. The `.claude/agents/developer.md` shall watcher の auto-recovery commit（`recover uncommitted ... (auto)` 系）が中途異常終了時の保険であり、Developer の通常 commit 経路の代替として常用しないことを明記する
4. Where Developer の commit 規律が PR Iteration / impl-resume の文脈に該当するとき, the `.claude/agents/developer.md` shall 本規律を当該文脈（PR Iteration / impl-resume 節）の中で読み取れる位置に記載する
5. The `.claude/agents/developer.md` shall 既存の impl-resume / tasks.md 進捗追跡規約（既存 commit の温存・`git reset` / `git rebase` 禁止）と矛盾しない形で本規律を記述する

### Requirement 2: 進捗 commit が push された round の no-progress 誤判定防止

**Objective:** As a idd-claude 運用者, I want 実コード差分が push された round（auto-recovery
commit 経由を含む）を no-progress と誤カウントさせたくない, so that healthy なブランチ作業が
premature に `claude-failed` へ昇格されない。

#### Acceptance Criteria

1. While round 終了時に head branch の HEAD が round 開始時の HEAD と異なるとき, the PR Iteration Processor shall 当該 round を進捗ありとして扱い no-progress 連続カウンタを `0` にリセットする
2. While round 終了時に head branch の HEAD が round 開始時の HEAD から変化していないとき, the PR Iteration Processor shall 当該 round を no-progress として扱い no-progress 連続カウンタを `1` 加算する
3. Where round 内の commit が auto-recovery commit（`recover uncommitted ... (auto)` 系）として push されたとき, the PR Iteration Processor shall その round を進捗ありとして扱い、Developer 自身の commit と同等に no-progress 連続カウンタをリセットする
4. When 本要件に着手するとき, the Developer shall 現行コード（`pi_run_iteration` の `before_sha`／`after_sha` 比較と `pi_classify_round_outcome`）で auto-recovery commit が発生した round が既に進捗ありとして算入されているかを切り分け、その結果を impl-notes に記録する
5. Where 切り分けの結果 AC 2.1〜2.3 の不変条件が現行コードで既に満たされていると確認されたケースであるとき, the PR Iteration Processor shall コード挙動を変更せず、当該不変条件が回帰テストによって固定された状態を満たす
6. If 切り分けの結果 AC 2.1〜2.3 の不変条件が現行コードで満たされていないと確認されたとき, the PR Iteration Processor shall 該当箇所を修正し、AC 2.1〜2.3 が回帰テストによって保証された状態を満たす

### Requirement 3: ドキュメント整合と root ↔ repo-template の二重管理

**Objective:** As a idd-claude 運用者, I want 本 commit 規律を Developer エージェント定義の
両系統（root と repo-template）に矛盾なく反映したい, so that 既 installed の consumer repo に
配布される Developer 定義も同じ規律で動作する。

#### Acceptance Criteria

1. When `.claude/agents/developer.md` を更新するとき, the Developer shall 同一内容を `repo-template/.claude/agents/developer.md` にも反映し両系統を byte 一致に保つ
2. The PR Iteration Processor shall 本要件導入後に `diff -r .claude/agents repo-template/.claude/agents` が空（差分なし）であることを満たす状態でドキュメントを確定する
3. The `.claude/agents/developer.md` shall 本規律の追記によって既存の節（実装ルール / impl-resume / per-task ループ / 出力契約等）の既存記述を意味的に変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Iteration Processor shall 既存 env 変数（`PR_ITERATION_NO_PROGRESS_LIMIT` / `PR_ITERATION_MAX_ROUNDS_IMPL` / `PR_ITERATION_MAX_ROUNDS_DESIGN` / `PR_ITERATION_ENABLED` 等）の名称・既定値・意味を変更しない
2. The PR Iteration Processor shall 既存の hidden marker コメントプレフィクス（`<!-- idd-claude:pr-iteration `）および `round` / `last-run` / `no-progress-streak` キー名と意味を変更しない
3. The PR Iteration Processor shall 既存の auto-recovery commit メッセージ文字列（`docs(specs): recover uncommitted round-N output (auto)` / soft-fail 系）を変更しない（commit メッセージは下流の挙動判定に使われないが、観測上の互換性のため温存する）
4. The PR Iteration Processor shall 既存の exit code 意味（`pi_run_iteration` の 0=success / 1=failure / 2=escalated / 3=skip）と `pi_log` / `pi_warn` / `pi_error` のログ書式・出力先を変更しない

### NFR 2: テスト可能性

1. The PR Iteration Processor shall Requirement 2 の no-progress 判定（HEAD 変化ありでのリセット / 変化なしでの加算 / auto-recovery commit 経由のリセット）をそれぞれ独立に検証できる回帰テストを `local-watcher/test/` 配下の既存イディオム（`extract_function` 隔離抽出）で提供する
2. The PR Iteration Processor shall 本要件導入後も既存テストスイートが成功する状態を維持する

### NFR 3: 観測性

1. The PR Iteration Processor shall no-progress 連続カウンタの加算 / escalate を、PR 番号・kind・カウンタ値・上限値を grep で機械抽出できる既存ログ形式で出力する挙動を維持する

## Out of Scope

- watcher 側で「Developer が round 内 self-commit を怠ったこと」を機械的に検出・矯正する新規 processor / gate / safety net の追加（本要件は Developer エージェント定義の規律明文化と no-progress 判定の不変条件固定までに留め、enforcement 機構は導入しない）
- auto-recovery commit メッセージ（`recover uncommitted ... (auto)` 等）の文言変更・リネーム・廃止
- `pi_auto_commit_and_push` の `git add -A` / plain `git push`（force 系を使わない）という既存回復方式そのものの変更
- no-progress 連続カウンタの上限値（`PR_ITERATION_NO_PROGRESS_LIMIT` 既定 `3`）や kind 別 round 上限の既定値変更
- PR Iteration 以外のステージ（Stage A / B / C / Reviewer / Triage）の commit 規律や no-progress 判定
- altpocket-server PR #139 で観測された具体事象の再現環境構築・事後デバッグ（旧バージョン由来か別タイミング問題かの歴史的特定は本要件の対象外。現行コードでの不変条件の切り分けと固定のみを行う）

## Open Questions

- なし（Issue 本文の「確認事項」が指摘する「auto-recovery commit が no-progress 判定の進捗に算入されているか（タイミング / 比較対象 sha）を先に切り分ける」点は、推測で断定せず Requirement 2.4〜2.6 の条件付き AC として落とし込み、Developer に切り分けを先行させる構造とした。Issue にコメントによる人間の追加回答は存在せず、本文ドラフト AC のみを根拠とした）
