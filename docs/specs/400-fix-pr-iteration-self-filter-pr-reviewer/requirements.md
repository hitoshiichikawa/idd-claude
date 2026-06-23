# Requirements Document

## Introduction

PR Iteration Processor（#26 で導入、#55 で一般コメントの mention 篩い撤廃を実施）の
self-comment フィルタが、`idd-claude:` 文字列を含む **全コメントを一律除外** する実装に
なっている。このため、PR Reviewer（#399 で導入された review 自動投稿系、
`<!-- idd-claude:pr-reviewer sha=<sha> kind=review tool=<tool> -->` 形式の hidden marker
を本文に持つ）が投稿した review 指摘も "self" として扱われ、iteration agent の入力
（一般コメント）から取り除かれる。実稼働ログでは `fetched=8, filtered_self=7, final=0`
のような全除外が発生し、codex 由来の review 指摘を渡せないまま iteration agent が起動
するため、推測ベースの no-op に陥り PR が `needs-iteration` のまま no-progress 連続で
ループ → 最終的に codex review ゲートで stuck する。本要件は self-filter の対象を
「PR Iteration Processor 自身が投稿した marker のみ」に正しく限定し、PR Reviewer 由来の
review 指摘を iteration agent へ確実に届けることを目的とする。重複処理防止（last-run 境界）
と self 除外（無限ループ防止）の既存規約は維持する。

## Requirements

### Requirement 1: PR Reviewer 投稿の review 指摘を iteration agent 入力に含める

**Objective:** As a auto-dev 運用者, I want PR Reviewer が投稿した review 指摘（`idd-claude:pr-reviewer ... kind=review` marker 付き）が PR Iteration Processor の入力に渡るようにしたい, so that codex / claude の具体的な指摘内容に基づいて iteration agent が修正できる（推測に頼らない）

#### Acceptance Criteria

1. When PR Iteration Processor が一般コメントを収集する, the PR Iteration Processor shall `<!-- idd-claude:pr-reviewer sha=<sha> kind=review tool=<tool> -->` marker を本文に含むコメントを self-filter で除外せず iteration agent の入力に含める
2. When PR Reviewer 由来の `kind=review` コメントが last-run TS より後に新規投稿されている, the PR Iteration Processor shall 当該コメントを iteration agent へ渡す一般コメント集合に含める
3. The PR Iteration Processor shall PR Reviewer の `kind` 属性値（`review` / `reply` / その他）に依存せず、Requirement 2 が定める self-filter 限定範囲に該当しない限りすべての PR Reviewer 投稿コメントを iteration agent 入力に含める
4. If PR Reviewer 由来の review 指摘が 1 件以上存在し他のフィルタ（last-run / event-style / truncate）で除外されない, the PR Iteration Processor shall iteration agent への最終入力件数（`final` カウンタ）を 0 ではない値で確定させた状態で agent を起動する

### Requirement 2: self-filter の対象を PR Iteration Processor 自身の marker に限定する

**Objective:** As a watcher 運用者, I want self-filter が PR Iteration Processor 自身の自動投稿のみを除外するようにしたい, so that 無限ループ（iteration agent が自己投稿を再処理する事故）を防ぎつつ他系統（PR Reviewer / Security Review / Quota-Aware 等）の自動投稿を誤除外しない

#### Acceptance Criteria

1. When 一般コメント本文に `idd-claude:pr-iteration` で始まる hidden marker が含まれる, the PR Iteration Processor shall 当該コメントを self として除外する
2. When 一般コメント本文に `idd-claude:pr-iteration-processing` marker が含まれる（着手表明コメント）, the PR Iteration Processor shall 当該コメントを self として除外する
3. When 一般コメント本文に `idd-claude:pr-iteration-529-warning` marker が含まれる（quota soft-fail 警告コメント）, the PR Iteration Processor shall 当該コメントを self として除外する
4. The PR Iteration Processor shall `idd-claude:pr-reviewer` / `idd-claude:security-review` / `idd-claude:security-notes` / `idd-claude:quota-reset` / `idd-claude:partial-status` / `idd-claude:edit-paths` / `idd-claude:awaiting-slot` / `idd-claude:busy-wait` / `idd-claude:auto-rebase` / `idd-claude:auto-rebase-semantic` / `idd-claude:dep-cycle-detected` / `idd-claude:design-review-release` / `idd-claude:review` 等、`idd-claude:pr-iteration` 以外の prefix を持つ hidden marker を self として除外しない
5. Where 将来 PR Iteration Processor 系の新しい marker サブ種別が `idd-claude:pr-iteration<suffix>` 形式（例: `idd-claude:pr-iteration-foo`）で追加される, the PR Iteration Processor shall 当該 marker を self として除外する（前方互換性のため prefix 単位の判定）

### Requirement 3: 重複処理防止（last-run 境界）の維持

**Objective:** As a auto-dev 運用者, I want 過去 round で既に処理済みの review 指摘を再処理しないようにしたい, so that 同じ指摘で iteration が空回りする / コストが暴走することを防ぐ

#### Acceptance Criteria

1. When PR Reviewer の review コメントが last-run TS 以前（同時刻を含む）に投稿されている, the PR Iteration Processor shall 当該コメントを過去 round 既処理として最終入力から除外する
2. When PR Reviewer の review コメントが last-run TS より後に投稿されている, the PR Iteration Processor shall 当該コメントを iteration agent への最終入力に含める
3. When PR body 内に PR Iteration Processor の hidden marker が存在しない（初回 round）, the PR Iteration Processor shall 取得した全 PR Reviewer 由来コメントを過去 round 段では除外しない（last-run 不在時の no-op 既存挙動を踏襲）
4. The PR Iteration Processor shall last-run 比較の境界判定（`==` を除外側に倒す既存挙動）を変更しない

### Requirement 4: フィルタ件数ログの後方互換

**Objective:** As a watcher 運用者, I want 一般コメント収集のサマリログ形式を変えずに監視・障害解析に使えるようにしたい, so that 既存の grep / log 集計ツールや過去ログとの比較が機能する

#### Acceptance Criteria

1. The PR Iteration Processor shall 一般コメント収集のサマリログを `PR #<n> general comments: fetched=<a>, filtered_self=<b>, filtered_resolved=<c>, filtered_event=<d>, truncated=<e> (limit=<L>)?, final=<f>` 形式で出力し、フィールド名（`fetched` / `filtered_self` / `filtered_resolved` / `filtered_event` / `truncated` / `final`）の意味を本要件導入前と一致させる
2. The PR Iteration Processor shall `filtered_self` のカウントを「Requirement 2 が定める self-filter で除外された件数」として計算する（PR Reviewer 由来コメントは self として数えない）
3. When 一般コメントが 0 件取得された、または取得失敗で degraded path に倒れた, the PR Iteration Processor shall サマリログのフィールド数を保ったまま該当カウンタを 0 で出力する（既存挙動と一致）
4. The PR Iteration Processor shall サマリログの出力先を stderr のままとし、JSON 配列の出力先（stdout）と分離する既存契約を変更しない

### Requirement 5: line-comment 経路の挙動整合

**Objective:** As a auto-dev 運用者, I want line-comment（review 行コメント）経路でも reviewer 由来コメントが iteration agent 入力に渡る挙動を維持したい, so that 一般コメント経路と line-comment 経路の両方で「reviewer 指摘を取り込む」という方針が一貫する

#### Acceptance Criteria

1. The PR Iteration Processor shall line-comment 経路（review 行コメント集合）に対して、本 Issue 修正で `idd-claude:` を含む文字列を一律除外する self-filter を新規導入しない
2. When line-comment 本文に `idd-claude:pr-iteration` で始まる marker が含まれる, the PR Iteration Processor shall 当該 line-comment を iteration agent への最終入力から除外する（一般コメント経路と同じ self-filter 規約を line-comment にも適用、Requirement 2 と整合）
3. When line-comment 本文に `idd-claude:pr-iteration` 以外の `idd-claude:` prefix を持つ marker が含まれる、または marker を含まない通常の line-comment である, the PR Iteration Processor shall 当該 line-comment を iteration agent への最終入力に含める

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Iteration Processor shall 既存の env var 名 / exit code 意味 / hidden marker prefix `<!-- idd-claude:pr-iteration ` / PR body 内 marker のキー名（`round=` / `last-run=` / `no-progress-streak=`）を変更しない
2. The local-watcher repo shall 既存テスト（PR Iteration Processor の marker regex / round カウンタ依存テスト）を退行させない
3. The local-watcher repo shall 本変更を root と repo-template（`repo-template/local-watcher/...` 配下）で byte 一致同期した状態で配布する

### NFR 2: 観測性

1. When self-filter で除外された件数が増減した, the PR Iteration Processor shall `filtered_self=<N>` のカウンタ値で外部観測可能にする（Requirement 4 と整合）
2. While iteration agent を起動する直前, the PR Iteration Processor shall サマリログを stderr に出力し、`fetched > 0` かつ `final=0` になった場合でも内訳（`filtered_self` / `filtered_resolved` / `filtered_event` / `truncated`）が運用者から判別可能な形にする

### NFR 3: テスト整備

1. The local-watcher repo shall 本要件を検証する近接テストを `local-watcher/test/` 配下に追加し、以下のケースを観測可能な形で最低限含める:
   - PR Reviewer の `kind=review` コメントが self-filter で除外されないこと
   - PR Iteration Processor 自身の `idd-claude:pr-iteration-processing` / `idd-claude:pr-iteration-529-warning` コメントが self-filter で除外されること
   - last-run TS より後の PR Reviewer コメントが最終入力に含まれること
   - last-run TS 以前（同時刻を含む）の PR Reviewer コメントが除外されること

## Out of Scope

- PR Reviewer 側の review 投稿フォーマット / marker 構造の変更（#399 で確立済み）
- line-comment 経路で新規 self-filter を実装することそのもの（Requirement 5.1 で除外。仮に line-comment にも `idd-claude:pr-iteration` marker を含むコメントが存在する場合の挙動規約のみ Requirement 5.2 に明記）
- last-run 境界判定そのもののロジック変更（`==` を除外側に倒す既存挙動を維持、Requirement 3.4）
- 一般 / line 以外の入力経路（PR body / 差分 / requirements.md）の取り扱い変更
- `PR_ITERATION_DESIGN_ENABLED` 等の opt-in gate 設計変更
- iteration agent の prompt template 本文の書き換え（reviewer 指摘を「具体指摘として活用せよ」という指示の追加は #399 で対応済み）
- PR Iteration Processor 以外の processor（Security Review / Auto-Rebase 等）の self-filter 挙動

## Open Questions

- なし（Issue #400 本文に修正方針・受入基準・DoD が明示されており、要件レベルで追加の人間判断は不要。実装段階で marker prefix 判定の具体的な照合方式（正規表現 / 文字列前方一致など）が必要になるが、それは design.md / impl の領分）

## 関連

- Depends on: #399
- Related: #26 #55 #397
