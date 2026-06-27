<!-- Issue: #421 -->
<!-- URL: https://github.com/hitoshiichikawa/idd-claude/issues/421 -->

# Requirements Document

## Introduction

`PER_TASK_LOOP_ENABLED=true` の per-task ループにおいて、per-task Reviewer の diff range 解決
（`local-watcher/bin/issue-watcher.sh` の `pt_resolve_diff_range`、L3695-3775 付近）は
`docs(tasks): mark <id> as done` の **subject 完全一致**（単記 marker パス）と **末尾アンカ
付き正規表現** `^docs\(tasks\): mark (.+) as done$`（連記 marker fallback パス）で marker
commit を識別している。このため Developer が Conventional Commits / GitHub 慣習に従って
trailing issue-ref suffix（例: `docs(tasks): mark 6 as done (#118)`）を付けた marker を
作成すると、subject が完全一致せず、かつ末尾アンカも満たさないため当該 task の marker
commit が解決できず `diff-range-resolve-failed (no-marker-commit-found)` で `claude-failed`
に落ちる事象が altpocket-server #118 で観測された。

本 spec は (1) 単記 / 連記いずれのパスでも trailing issue-ref suffix `(#<number>)` 付き
marker を解決可能にする許容範囲拡大、(2) canonical（suffix 無し）marker の挙動温存、
(3) 連記 marker fallback の既存挙動温存、(4) `as done` 後ろの suffix 文字列パターンの
許容 / 拒否境界の明確化、を要件として定義する。実装手段（regex 拡張 / subject 正規化等）は
`design.md` に委ねる。

関連: 本 spec は #164（連記 marker fallback 導入）の許容範囲をさらに広げる継続改善であり、
#164 で確立された「1 commit = 1 task ID」の canonical 規約自体は本 spec で変更しない。

## Requirements

### Requirement 1: trailing issue-ref suffix 付き単記 marker の解決

**Objective:** As the Per-Task Diff Range Resolver, I want subject 末尾に issue-ref suffix `(#<number>)` を伴う単記 marker commit からも当該 task ID を解決できる, so that Developer が Conventional Commits 慣習に従って付与した issue-ref suffix を理由に diff range 解決が失敗しないようにする

#### Acceptance Criteria

1. When `${BASE_BRANCH}..HEAD` 範囲に subject が `docs(tasks): mark <id> as done (#<number>)` 形式の単記 marker commit のみ存在する場合, the Per-Task Diff Range Resolver shall 当該 task ID の marker commit SHA を解決する
2. When 同一 task ID に対して suffix 無し marker と suffix 付き marker の双方が時系列上に存在する場合, the Per-Task Diff Range Resolver shall いずれか 1 つを一意に決定し、選択基準を観測ログで識別可能にする
3. The Per-Task Diff Range Resolver shall trailing issue-ref suffix の `<number>` 部を `^[0-9]+$` を満たす整数とみなして照合する
4. The Per-Task Diff Range Resolver shall suffix 形式として canonical に許容する表記を `docs(tasks): mark <id> as done (#<number>)`（`as done` と `(` の間に半角空白 1 つ、`#` の直後に数字、閉じ括弧 `)` で終端）と定義する
5. Where suffix 付き marker から解決した場合, the Per-Task Diff Range Resolver shall 観測可能な識別子（例: `via=single-id-marker-with-suffix` 相当のタグ）を stdout または stderr のログ行に残し、運用者が grep で件数を把握できるようにする

### Requirement 2: trailing issue-ref suffix 付き連記 marker の解決

**Objective:** As the Per-Task Diff Range Resolver, I want subject 末尾に issue-ref suffix を伴う連記 marker commit からも当該 task ID を解決できる, so that #164 で導入した連記 fallback と suffix 許容が両立し、連記かつ suffix 付きという複合パターンでも解決失敗を回避する

#### Acceptance Criteria

1. When subject が `docs(tasks): mark <ids> as done (#<number>)` 形式の連記 marker commit のみ存在し、`<ids>` に当該 task ID と完全一致するトークンが含まれる場合, the Per-Task Diff Range Resolver shall 当該 commit を当該 task ID の marker commit として解決する
2. The Per-Task Diff Range Resolver shall 連記 ID の token 化（`/` / `,` / 空白を区切りとする word 単位完全一致）を、suffix 有無に関わらず同一の規則で適用する
3. The Per-Task Diff Range Resolver shall 連記 suffix 付き marker から解決した場合の観測ログを、Requirement 1.5 と区別可能な形（例: `via=multi-id-marker-with-suffix` 相当のタグ）で出力する

### Requirement 3: canonical（suffix 無し）marker の挙動温存

**Objective:** As the Per-Task Diff Range Resolver, I want 既存の suffix 無し marker のみで構成される履歴で解決結果を本変更前と完全一致させる, so that 既存リポジトリ・既存 PR・既存ログ列が本変更の影響を受けないことを保証する（CLAUDE.md「後方互換性」規約）

#### Acceptance Criteria

1. When `${BASE_BRANCH}..HEAD` 範囲が既存形式の suffix 無し単記 marker（`docs(tasks): mark <id> as done`）のみで構成されている場合, the Per-Task Diff Range Resolver shall 本変更前と同一の解決結果（同一 range_start / range_end SHA pair）を返す
2. When `${BASE_BRANCH}..HEAD` 範囲が #164 で導入された suffix 無し連記 marker（`mark 1 / 1.1 as done` / `mark 1, 1.1 as done`）を含む場合, the Per-Task Diff Range Resolver shall 本変更前と同一の解決結果を返す
3. The Per-Task Diff Range Resolver shall suffix 許容に伴って単記経由 / 連記経由いずれの既存観測ログ（`via=multi-id-marker` 等の既存タグ）の文字列形式と発火条件を変更しない

### Requirement 4: suffix の許容 / 拒否境界の明確化

**Objective:** As the Per-Task Diff Range Resolver, I want `as done` 後に続く文字列の許容パターンを明示的に定義する, so that 「どこまでが marker として認識され、どこからが marker として無視されるか」が運用者にとって曖昧にならない

#### Acceptance Criteria

1. When subject が `docs(tasks): mark <id> as done (#<number>)`（`as done` と `(` の間に半角空白 1 つ、閉じ括弧で終端）である場合, the Per-Task Diff Range Resolver shall 当該 commit を marker として **解決する**
2. If subject が `docs(tasks): mark <id> as done(#<number>)`（空白なし）である場合, the Per-Task Diff Range Resolver shall 当該 commit を marker として **解決しない**
3. If subject が `docs(tasks): mark <id> as done #<number>`（括弧なし）である場合, the Per-Task Diff Range Resolver shall 当該 commit を marker として **解決しない**
4. If subject が `docs(tasks): mark <id> as done (#<number>) <任意の追加文字列>`（閉じ括弧の後に追加文字列）である場合, the Per-Task Diff Range Resolver shall 当該 commit を marker として **解決しない**
5. If subject が `docs(tasks): mark <id> as done (#<非数字>)` のように `<number>` 部が `^[0-9]+$` を満たさない場合, the Per-Task Diff Range Resolver shall 当該 commit を marker として **解決しない**
6. The Per-Task Diff Range Resolver shall 上記許容 / 拒否境界を単記パスと連記パス双方に同一規則で適用する

### Requirement 5: 解決失敗時の挙動温存（既存契約）

**Objective:** As the Per-Task Diff Range Resolver, I want suffix 許容の範囲外と判定された marker しか存在しない場合でも、`diff-range-resolve-failed` で停止する既存契約を維持する, so that 誤検出による silent な range 解決を回避しつつ、運用者向けの既存復旧導線（#164 Requirement 4）を温存する

#### Acceptance Criteria

1. If 当該 task ID に対する単記 / 連記いずれの marker（suffix 有無を問わず）も Requirement 1〜4 のもとで解決できなかった場合, the Per-Task Diff Range Resolver shall `diff-range-resolve-failed (no-marker-commit-found)` 相当の既存失敗終端を発火させる
2. The Per-Task Diff Range Resolver shall 失敗終端時の失敗カテゴリ識別子・Issue コメント書式・`claude-failed` ラベル遷移を本変更前と同一に保つ

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Per-Task Diff Range Resolver shall 既存 env var 名・既存ラベル名・既存失敗カテゴリ識別子（`diff-range-resolve-failed`）・既存観測ログタグ（`via=single-id-marker` / `via=multi-id-marker`）の文字列を変更せず、本変更後も完全一致で grep / 一致検査ができる
2. The Per-Task Diff Range Resolver shall `PER_TASK_LOOP_ENABLED` が未設定または `=true` 以外の起動経路では本変更経路に到達しないことで、本機能導入前と完全に同一の外形挙動を維持する

### NFR 2: 可観測性

1. When suffix 付き marker（単記 / 連記いずれか）経由で解決した場合, the Per-Task Diff Range Resolver shall 解決経路を識別可能なタグをログ行に残し、運用者が `via=*-with-suffix` 相当の grep で件数把握できるようにする
2. When 解決失敗時, the Per-Task Diff Range Resolver shall ログに当該 task ID と「単記 / 連記 / suffix 有 / suffix 無 のいずれの候補も見つからなかった」旨を明示する

### NFR 3: セキュリティ

1. The Per-Task Diff Range Resolver shall subject から抽出する `<number>` 部を使用直前に `^[0-9]+$` で検証し、未検証の文字列を path / git revision / 外部コマンド引数に渡さない（CLAUDE.md「未信頼 GitHub 入力の取り扱い」規約準拠）
2. The Per-Task Diff Range Resolver shall subject 抽出に用いる正規表現が `<id>` / `<number>` 部のメタ文字によって ReDoS 級の処理時間爆発を起こさないよう、量指定子を有界化する

### NFR 4: テスト追随性

1. The Per-Task Loop Implementation shall 本要件追加に対応する近接テスト（`local-watcher/test/` 配下、既存 `extract_function` イディオム）を追加し、Requirement 4 で定義する許容 / 拒否境界 5 パターンを fixture として網羅する
2. The Per-Task Loop Implementation shall 既存テスト（#164 / #270 / #304 配下の per-task Reviewer 関連テスト）を改変せずパスさせる

## Out of Scope

- #417 / #420 で扱われる別系統の per-task Reviewer 不具合（本 spec の責務外）
- marker commit 自体が存在しないケースの挙動変更（既存の `diff-range-resolve-failed` 終端を温存し、本 spec では拡張しない）
- Developer 側 prompt の suffix 付与禁止化 / 強制 canonical 化（Option C 系の規約変更は本 spec の対象外。canonical 規約は #164 で既定済みで、本 spec は watcher 側の許容拡大のみを扱う）
- `(#<number>)` 以外の trailing suffix 形式（例: 末尾 `[#<number>]` / `Closes #<n>` / 任意 free-form 文字列）の許容拡大
- 既に main にマージ済みの過去 commit / 過去 PR 履歴の遡及書き換え（retrofit）
- per-task ループ以外の Reviewer Gate（Stage B 既存経路 / Failed Recovery / PR Reviewer 等）への波及変更
- 連記 marker を canonical 表記として推奨する方向への規約変更（canonical は引き続き「1 commit = 1 task ID」、連記 / suffix 付きは「許容するが推奨しない」位置付け）

## Open Questions

なし（Issue 本文「受入基準」節に許容 / 拒否の境界 4 パターンが明示されており、本 spec は
Requirement 4 で 5 パターン（Issue 本文の 4 パターン + `<number>` 部の非数字ケース）として
網羅した。Issue にコメントは投稿されておらず、Developer 側の suffix 付与可否や代替仕様の
人間決定事項は未提示）

## 関連

- Depends on: なし
- Parent: なし
- Related: #164 #304 #305 #417 #420
