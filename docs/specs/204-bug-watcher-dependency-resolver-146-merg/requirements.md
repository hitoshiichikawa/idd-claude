# Requirements Document

## Introduction

Dependency Resolver（#146 で実装）は `Depends on: #N` を宣言した Issue の依存先 Issue が merge 済みかを判定し、未解決なら `blocked` ラベルを付与して自動処理を中止する。しかし依存先が CLOSED の場合のマージ判定で、PR ノードの merge 状態を取得できない取得経路を使っているため、merge 済みでも常に「未 merge で閉じられた」と誤判定する。この結果、依存先がすべて merge 済みでも対象 Issue は永久に `blocked` が再付与され、自動処理が二度と再開しない false-block が発生している（実害: #187 が merge 済みの #177 / #180 / #181 に永久ブロックされた）。本修正は CLOSED 依存のマージ判定を正しい観測経路に是正し、後方互換契約（verdict 文字列・ラベル契約・ログ書式・env var）を不変に保つことを目的とする。あわせて、依存抽出が説明文・コード例の依存マーカーを誤検出して false-block を起こす同根の堅牢性問題も対象に含める。

## Requirements

### Requirement 1: CLOSED 依存のマージ状態判定の是正

**Objective:** As a watcher 運用者, I want CLOSED な依存 Issue が merge 済みで閉じられたかを正しく判定してほしい, so that merge 済み依存に対する永久 false-block が解消される

#### Acceptance Criteria

1. When 依存先 Issue が CLOSED でありかつ少なくとも 1 件の merge 済み PR で閉じられたとき, the Dependency Resolver shall その依存を `resolved` と判定する
2. When 依存先 Issue が CLOSED でありかつ閉じた PR がいずれも merge されていないとき, the Dependency Resolver shall その依存を `closed unmerged` と判定する
3. When 依存先 Issue が CLOSED でありかつ紐づく PR が 1 件も存在しないとき, the Dependency Resolver shall その依存を `closed unmerged` と判定する
4. When 依存先 Issue が OPEN のとき, the Dependency Resolver shall その依存を `open` と判定する
5. The Dependency Resolver shall 依存先の merge 状態を、PR ノードの merge 状態（merged / closed-unmerged の区別）を観測可能な経路から取得する

### Requirement 2: 判定失敗時の安全側挙動

**Objective:** As a watcher 運用者, I want 依存状態の取得に失敗したときも安全側に倒れてほしい, so that 取得失敗が merge 済み扱いの誤った自動処理続行につながらない

#### Acceptance Criteria

1. If 依存先 Issue の状態取得に失敗したとき, the Dependency Resolver shall その依存を `api error` と判定する
2. If 取得した応答が想定外の構造で merge 状態を解釈できないとき, the Dependency Resolver shall その依存を `api error` と判定する
3. When いずれかの依存が `open` / `closed unmerged` / `api error` のいずれかと判定されたとき, the Dependency Resolver shall 対象 Issue を block 確定として扱う
4. When すべての依存が `resolved` と判定されたとき, the Dependency Resolver shall 対象 Issue を block せず後続処理を続行させる

### Requirement 3: 後方互換契約の維持

**Objective:** As a 既存 consumer repo の運用者, I want 本修正が外部から観測可能な契約を一切変えないことを保証してほしい, so that 既稼働の cron / ラベル運用 / ログ解析を壊さずに修正を取り込める

#### Acceptance Criteria

1. The Dependency Resolver shall 依存判定の結果語彙を `resolved` / `open` / `closed unmerged` / `api error` の 4 種に限定し、新規語彙を追加しない
2. When 対象 Issue が block 確定したとき, the Dependency Resolver shall `blocked` ラベルを付与しかつ `claude-claimed` ラベルを除去する
3. While 対象 Issue に既に `blocked` ラベルが付与されているとき, the Dependency Resolver shall ラベル再付与・コメント再投稿を行わず冪等に skip する
4. The Dependency Resolver shall 構造化ログの書式（`dr_log` / `dr_warn` の出力形式と verdict キー）を本修正前と同一に保つ
5. The Dependency Resolver shall 既存の環境変数名を変更・削除せず、新規の必須環境変数を導入しない

### Requirement 4: 依存抽出の誤検出防止

**Objective:** As a Issue 起票者, I want 説明文・コード例・引用に含まれる依存マーカーが実依存として誤抽出されないでほしい, so that 例示目的で依存記法を書いた Issue が誤って false-block されない

#### Acceptance Criteria

1. When Issue 本文の実依存宣言行に依存記法が記述されているとき, the Dependency Resolver shall その行から依存 Issue 番号を抽出する
2. Where 依存記法が markdown コードフェンスで囲まれたブロック内に現れるとき, the Dependency Resolver shall その記法を実依存として抽出しない
3. Where 依存記法が引用ブロック（行頭が引用記号の行）に現れるとき, the Dependency Resolver shall その記法を実依存として抽出しない
4. The Dependency Resolver shall 抽出した依存 Issue 番号集合を重複排除しかつ決定的な順序で出力する
5. When 本文中に依存記法がいずれの抽出対象行にも存在しないとき, the Dependency Resolver shall 依存抽出結果を空とし副作用なしで後続処理を続行させる

### Requirement 5: 回帰の固定

**Objective:** As a 保守担当, I want 本バグの再発を検知する回帰テストが固定されていてほしい, so that 将来の変更で同種の false-block が再混入したときに検知できる

#### Acceptance Criteria

1. The 検証スイート shall 「CLOSED + merge 済み PR で閉じた依存」が `resolved` と判定されることを確認するケースを含む
2. The 検証スイート shall 「CLOSED + 未 merge（手動 close）依存」が `closed unmerged` と判定されることを確認するケースを含む
3. The 検証スイート shall 「OPEN 依存」が `open` と判定されることを確認するケースを含む
4. The 検証スイート shall 本修正前のコードでケース 1 が誤判定（`closed unmerged`）となり修正後に正される Red→Green 遷移を確認できる構成を含む

## Non-Functional Requirements

### NFR 1: 後方互換性（既存挙動の保全）

1. When 依存記法が Issue 本文に 1 件も存在しないとき, the Dependency Resolver shall gh API 呼び出し・ラベル変更・コメント投稿を 0 回とし本修正前と同一の pickup 挙動を維持する
2. The Dependency Resolver shall `blocked` ラベル付与時に `needs-decisions` ラベルの状態を変更しない

### NFR 2: 可観測性

1. The Dependency Resolver shall 各 Issue の依存チェック結果について、抽出した依存・解決済み依存・未解決依存・最終 verdict を含む構造化ログを 1 行以上出力する
2. If 依存状態取得が失敗したとき, the Dependency Resolver shall 対象 Issue 番号と失敗事由を含む警告ログを標準エラー出力に出力する

### NFR 3: 性能・運用負荷

1. The Dependency Resolver shall 1 つの依存先 Issue のマージ状態判定に要する外部 API 呼び出しを、依存件数に対し線形（依存 1 件あたり定数回）に保つ

## Out of Scope

- 既存 Issue 本文の依存記法を canonical 表記へ書き換える retrofit（`.claude/rules/issue-dependency.md` の「既存 Issue の retrofit は不要」方針に従う）
- `blocked` 解除後の自動再開フロー自体の変更（依存解消後に `blocked` を手動除去して次 tick で再合流する既存運用は不変）
- GitHub Actions 版ワークフロー（`issue-to-pr.yml`）側の依存判定（本 Issue はローカル watcher の Dependency Resolver が対象）
- 逆ブロッキング（`Blocks: #N`）の検出。canonical では被ブロッキング側 `Depends on:` のみを対象とする既存方針を踏襲
- `Parent:` / `Sibling:` / `Related:` / `Split from:` など非ブロッキング関係種別の判定（従来通り block 対象外）
- watcher 全体のラベル状態遷移・slot 直列化（#187 / #198 / #200 の path 管理）の再設計

## Open Questions

確認事項:

- 副次スコープ（Requirement 4: `dr_extract_deps` の誤検出防止）の扱いについて: Issue 本文の推奨に従い本修正に **含める** 判断とした。理由は (a) merge 判定バグ（Req 1〜3）と誤検出（Req 4）はいずれも「依存解決の堅牢性不足による false-block」という同根の症状であり、本 Issue 自身が説明文中の依存マーカーを誤抽出されて block された実害がある、(b) #146 実装の `dr_extract_deps` は元々 NFR 1.4 でコードフェンス/引用内の誤検出を「スコープ外（運用者が手動でラベル除去して復旧）」と明記していたため、本修正で堅牢性を引き上げることが既存 NFR の正当な更新になる、(c) 両者は同一関数群（`dr_*`）の小規模修正であり 1 PR で完結できる粒度である。ただし Req 4 のコードフェンス/引用判定は新規の本文パース挙動を伴うため、もし Architect が実装複雑度を高すぎると判断した場合は Req 4 のみを別 Issue（`Depends on: #204`）に分離する選択肢を許容する。分離可否は Architect の設計判断に委ねる。
- Requirement 1.5 のマージ状態取得経路について: Issue は GraphQL 直叩き（`closedByPullRequestsReferences ... { nodes { number state } }` の `state == "MERGED"` 判定、同ファイル L4979-4991 に確立済みパターンあり）を推奨経路として提示している。具体的な取得手段の選定は design.md（Architect）の領分とし、本要件では「PR の merge 状態を観測可能な経路から取得する」観点のみを固定した。代替の `gh pr view` 個別問い合わせ方式（API 呼び出し増）を採るかは設計判断に委ねる。
- それ以外の不明点はなし。
