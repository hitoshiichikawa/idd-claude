# Requirements Document

## Introduction

gitflow など `BASE_BRANCH=develop` を用いる multi-branch 運用では、依存先 Issue が
develop に統合済みで main 到達待ちの状態（`staged-for-release` ラベル付与 + OPEN 維持）に
留まる期間がある。現状の依存ゲート（Issue 本文の明示依存宣言行 `Depends on:` 等を判定する
`dr_*` 系統、#146 由来）は依存先 Issue の close 状態のみで解決判定を行うため、
`staged-for-release` の OPEN 依存先を「未解決」と誤判定し、依存元 Issue に `blocked` を
付与して auto-dev を不要に停止させてしまう。同様の base 相対化は path-overlap holder
集合では #221 で実装済みだが、依存ゲート側には未適用である。本要件は、依存ゲートに
base 相対化を導入して develop dispatch での誤ブロックを解消しつつ、`BASE_BRANCH=main`
の従来挙動を一切変えないことを目的とする。

## Requirements

### Requirement 1: 依存ゲートの base 相対化（staged-for-release 依存の解決判定）

**Objective:** As an auto-dev 運用者, I want 依存ゲートが develop dispatch で
`staged-for-release` の OPEN 依存先を解決済みとして扱うこと, so that develop 統合済み
依存に阻まれて後続 Issue の自動実装が不要に停止しないようにする

#### Acceptance Criteria

1. When `BASE_BRANCH` が `main` 以外の値で依存ゲートが起動し依存先 Issue が `OPEN` かつ `staged-for-release` ラベルを持つ場合, the Dependency Gate shall 当該依存を解決済み (`resolved`) として分類する
2. When `BASE_BRANCH` が `main` で依存ゲートが起動し依存先 Issue が `OPEN` かつ `staged-for-release` ラベルを持つ場合, the Dependency Gate shall 当該依存を未解決として分類し従来挙動を維持する
3. When 依存先 Issue が `OPEN` で `staged-for-release` ラベルを持たない場合, the Dependency Gate shall `BASE_BRANCH` の値にかかわらず当該依存を未解決として分類する
4. When 依存先 Issue が `CLOSED` で関連 PR に `MERGED` 状態のものが存在する場合, the Dependency Gate shall 当該依存を解決済み (`resolved`) として分類し従来挙動を維持する
5. When 依存先 Issue が `CLOSED` で関連 PR に `MERGED` 状態のものが存在しない場合, the Dependency Gate shall 当該依存を `closed unmerged` として分類し従来挙動を維持する

### Requirement 2: 解決判定のラベル取得と失敗時フォールバック

**Objective:** As an auto-dev 運用者, I want 依存ゲートが依存先 Issue のラベルを取得できない場合でも安全側に倒れること, so that 不確実な状態で誤って依存をスキップしてブロックすべき Issue を実装に進めないようにする

#### Acceptance Criteria

1. The Dependency Gate shall 依存先 Issue の state とラベル一覧を同一の問い合わせで取得する
2. If 依存先 Issue の state またはラベル一覧の取得・解析に失敗した場合, the Dependency Gate shall 当該依存を従来同様の安全側 (`api error` = 未解決) として分類する
3. If 依存先 Issue のラベル一覧の取得・解析に失敗した場合, the Dependency Gate shall `BASE_BRANCH` の値にかかわらず `staged-for-release` ラベル付与を仮定して解決済みとして扱う処理を行わない

### Requirement 3: テスト網羅性（回帰防止）

**Objective:** As an auto-dev 運用者, I want 依存ゲートの主要シナリオが回帰テストで網羅されること, so that 将来の watcher 改修で同種の誤判定が再発しないようにする

#### Acceptance Criteria

1. The Dependency Gate Test Suite shall develop dispatch (`BASE_BRANCH != main`) かつ依存先 OPEN かつ `staged-for-release` 付与のシナリオで解決済み判定となることを検証するケースを含む
2. The Dependency Gate Test Suite shall develop dispatch かつ依存先 OPEN かつ `staged-for-release` 未付与のシナリオで未解決判定となることを検証するケースを含む
3. The Dependency Gate Test Suite shall main dispatch (`BASE_BRANCH == main`) かつ依存先 OPEN かつ `staged-for-release` 付与のシナリオで未解決判定となることを検証するケースを含む
4. The Dependency Gate Test Suite shall 依存先 CLOSED + merged PR ありのシナリオで解決済み判定となる従来挙動の回帰テストを含む
5. The Dependency Gate Test Suite shall 依存先 CLOSED + merged PR なしのシナリオで `closed unmerged` 判定となる従来挙動の回帰テストを含む

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `BASE_BRANCH` の値が `main` の状態で動作している場合, the Dependency Gate shall 本変更導入前と完全に同一の解決判定結果を返す
2. The Dependency Gate shall 既存環境変数 (`BASE_BRANCH`, `DRR_GH_TIMEOUT`) のみで本機能を制御し新規 env var を導入しない
3. The Dependency Gate shall #221 で実装済みの path-overlap holder 側の base 相対化判定を変更しない

### NFR 2: 外部 API 呼び出し効率

1. The Dependency Gate shall 1 依存先 Issue あたりの GitHub API 問い合わせ回数を本変更導入前と同数（state 取得 + 関連 PR 取得の従来回数）に保つ

### NFR 3: 観測可能性

1. While 依存先 Issue を `staged-for-release` により解決済みとして分類した場合, the Dependency Gate shall 解決理由が `staged-for-release` であることを運用者が watcher ログから判別できる形で出力する

## Out of Scope

- path-overlap holder 側（#221）の base 相対化ロジックの再変更
- dispatch 候補フィルタ（`issue-watcher.sh:9822` 付近）の挙動変更
- `staged-for-release` ラベルを Issue / PR に自動付与する側の挙動変更
- 依存記法（`Depends on:` / `Blocked by:` 等）の本文抽出ロジック（`dr_extract_deps`）の変更
- `BASE_BRANCH` の値判定そのものの仕様変更（develop 以外の任意 branch 名でも `main` 以外なら multi-branch 扱いとなる従来規約を踏襲）

## Open Questions

- なし（Issue 本文と #221 の base 相対化規約から判定方針は確定。残課題は design 段階での GraphQL クエリ変更点と log 出力フォーマットの詳細）

## 関連

- Depends on: #221
- Related: #146
