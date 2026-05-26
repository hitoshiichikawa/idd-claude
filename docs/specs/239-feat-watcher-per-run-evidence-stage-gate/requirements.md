# Requirements Document

## Introduction

idd-claude の watcher は impl / impl-resume / design の各サイクルを実行するが、
現状は成果物（impl-notes.md / review-notes.md / PR 等）の有無からしか「実際に何が走ったか」を
事後判定できない。このため「独立 Reviewer ゲートが本当に別 context で起動したのか」
「stage-a-verify が走ったか」「scaffolding（`.claude/agents` / `.claude/rules`）が揃っていたか」
といった degraded 実行（#238 背景）を外形的に検出できない。本機能は 1 サイクルごとに
「どの stage / gate が実際に走り、どう判定されたか」を機械可読な run サマリとして既存ログに
追記し、実行時の実態を grep で外形検証可能にする observability を提供する。

## Requirements

### Requirement 1: per-run サマリの出力

**Objective:** As a watcher の運用者, I want 各サイクル終了時に実行実態の機械可読サマリが 1 件出力されること, so that 成果物の有無に頼らず「何が実際に走ったか」を外形検証できる

#### Acceptance Criteria

1. When impl / impl-resume / design のサイクルが終了したとき, the run-summary emitter shall そのサイクルの実行実態を表す機械可読な run サマリを 1 件出力する
2. The run-summary emitter shall run サマリに mode（impl / impl-resume / design のいずれか）を含める
3. The run-summary emitter shall run サマリに対象 Issue 番号を含める
4. The run-summary emitter shall 1 サイクルにつき run サマリを 1 行のみ出力する（低ノイズ）
5. While サイクルが正常終了・失敗終了・保留のいずれであっても, the run-summary emitter shall run サマリを出力する

### Requirement 2: 実行 stage の記録

**Objective:** As a watcher の運用者, I want どの stage が実際に走ったかが run サマリに残ること, so that stage checkpoint resume 等で一部 stage がスキップされた実行を識別できる

#### Acceptance Criteria

1. When サイクルが終了したとき, the run-summary emitter shall そのサイクルで実際に実行された stage（A / A' / B / B' / C のうち該当するもの）を run サマリに列挙する
2. If 当該サイクルでいずれの stage も実行されなかったとき, the run-summary emitter shall stage が実行されなかった旨を run サマリに明示する
3. When 複数 stage が実行されたとき, the run-summary emitter shall 実行された全 stage を判別可能な形で列挙する

### Requirement 3: Reviewer ゲートの記録

**Objective:** As a watcher の運用者, I want Reviewer ゲートが独立 context で起動したか・round・verdict が run サマリに残ること, so that 独立 Reviewer ゲートが degraded して効いていなかった実行を検出できる

#### Acceptance Criteria

1. When Reviewer ゲートが走るサイクルが終了したとき, the run-summary emitter shall Reviewer が独立 context（別 Claude プロセス）で起動したか否かを run サマリに記録する
2. When Reviewer が独立 context で起動したとき, the run-summary emitter shall その verdict（approve / reject）を run サマリに記録する
3. When Reviewer が独立 context で起動したとき, the run-summary emitter shall その round 番号を run サマリに記録する
4. While Reviewer が独立 context で起動できなかった場合, the run-summary emitter shall その事実を degraded として run サマリに明示する
5. Where 当該サイクルが Reviewer ゲートを持たないモード（design 等）であるとき, the run-summary emitter shall Reviewer ゲートが非該当である旨を run サマリに記録する

### Requirement 4: stage-a-verify ゲートの記録

**Objective:** As a watcher の運用者, I want stage-a-verify が走ったか・結果・解決経路が run サマリに残ること, so that build 不通を見逃した実行や gate が SKIP された実行を識別できる

#### Acceptance Criteria

1. When stage-a-verify ゲートが実行されたサイクルが終了したとき, the run-summary emitter shall その結果（success / 差し戻し / 失敗のいずれか）を run サマリに記録する
2. If stage-a-verify ゲートが SKIP または DISABLED であったとき, the run-summary emitter shall その状態（SKIP / DISABLED）を run サマリに明示する
3. When stage-a-verify ゲートが round=1 で差し戻し・または round=2 へ進んだとき, the run-summary emitter shall その round 情報を run サマリに記録する

### Requirement 5: scaffolding 有無の記録

**Objective:** As a watcher の運用者, I want worktree に `.claude/agents` / `.claude/rules` が存在したかが run サマリに残ること, so that scaffolding 欠落による degraded 実行（#238）を検出できる

#### Acceptance Criteria

1. When サイクルが終了したとき, the run-summary emitter shall worktree に `.claude/agents` および `.claude/rules` が存在したか否かを run サマリに記録する
2. If `.claude/agents` または `.claude/rules` のいずれかが欠落していたとき, the run-summary emitter shall scaffolding が不完全である旨を run サマリに明示する
3. The run-summary emitter shall scaffolding 有無の判定に既存の scaffolding 検査結果（core_utils.sh の検査）を流用する

### Requirement 6: 検出エラーの記録

**Objective:** As a watcher の運用者, I want 実行中に検出された degraded 兆候のエラー有無が run サマリに残ること, so that subagent 未定義 / ファイル欠落等の異常を外形検出できる

#### Acceptance Criteria

1. When サイクルが終了したとき, the run-summary emitter shall 実行中に検出された degraded 兆候のエラーの有無を run サマリに記録する
2. If 実行中に degraded 兆候（subagent 未定義 / 必要ファイルの No such file 等）が検出されたとき, the run-summary emitter shall エラーが検出された旨を run サマリに明示する
3. If degraded 兆候が一切検出されなかったとき, the run-summary emitter shall エラーが無い旨を run サマリに記録する

### Requirement 7: 最終遷移の記録

**Objective:** As a watcher の運用者, I want サイクルの最終遷移結果が run サマリに残ること, so that run サマリ 1 行で実行の最終状態まで把握できる

#### Acceptance Criteria

1. When サイクルが終了したとき, the run-summary emitter shall そのサイクルの最終遷移（ready-for-review / needs-iteration / claude-failed / 保留 のいずれか）を run サマリに記録する
2. While サイクルが claude-failed で終了した場合, the run-summary emitter shall 最終遷移を claude-failed として run サマリに記録する

### Requirement 8: 機械可読性と grep 互換

**Objective:** As a watcher の運用者, I want run サマリが固定 prefix を持ち grep で抽出できること, so that ログ集計や監視で run サマリ行だけを安定して取り出せる

#### Acceptance Criteria

1. The run-summary emitter shall すべての run サマリ行に grep 可能な固定 prefix を付与する
2. The run-summary emitter shall 各記録項目を key=value 形式で機械可読に表現する
3. The run-summary emitter shall 1 件の run サマリを 1 行に収める

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The run-summary emitter shall 既存ログ行を変更・削除せず、run サマリ行の追記のみを行う
2. The watcher shall 本機能の導入によって既存の env var 名・ラベル遷移契約・exit code の意味を変更しない
3. While 本機能が無効化された場合, the watcher shall 本機能導入前と user-observable / operator-observable に同一の挙動を維持する

### NFR 2: 低ノイズ・冪等性

1. The run-summary emitter shall 1 サイクルにつき run サマリを 1 行に抑える
2. While 同一サイクルが再実行（resume 等）された場合, the run-summary emitter shall 既存ログを破壊せず追記のみで一貫した run サマリを出力する

### NFR 3: 外部依存の不在

1. The run-summary emitter shall ローカルログ出力のみを行い、新規の外部サービス呼び出しを追加しない

### NFR 4: フェイルセーフ

1. If run サマリの生成・出力に失敗したとき, the watcher shall 当該サイクルの本処理（stage 実行・ラベル遷移）を倒さずに継続する

## Out of Scope

- run サマリのフォーマット実装詳細（一時ファイルか変数か、awk / 関数構成、prefix 文字列の確定値）
  → `design.md`（Architect の領分）
- run サマリを Issue コメント / slot ログへ併記する任意機能の必須化（任意機能としての扱いは Architect が判断）
- run サマリの集計・可視化・ダッシュボード・アラート連携
- 過去サイクルの run サマリの遡及生成（retrofit）
- scaffolding 欠落・degraded を検出した際の自動修復や自動再実行（本機能は記録のみ。修復は別 Issue）
- 外部 observability SaaS / ログ転送基盤との連携

## Open Questions

- なし（現時点で人間の追加決定が必要な不明点なし。run サマリの最終フォーマット・prefix 文字列・
  Issue コメント併記の任意機能化は実装レベルの決定として Architect / design に委ねる）

## 関連

- Related: #238 #228 #237
