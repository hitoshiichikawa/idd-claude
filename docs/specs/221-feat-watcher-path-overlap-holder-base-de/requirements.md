# Requirements Document

## Introduction

Phase E Path Overlap Checker（#18）の dispatch-time gate は、in-flight holder（path claim を握る作業）を収集する際に判定ラベル集合を固定で持ち、その中に `staged-for-release`（#100、定義「develop merged / main 未着」）を含んでいる。holder の本質は「dispatch 先 base ブランチにまだ取り込まれていない作業」であるため、base=develop の dispatch から見ると `staged-for-release` の作業は既に develop へ統合済みであり holder から除外すべきところ、現状は過剰に保守的に holder へ計上している。その結果、完了済みなのに `staged-for-release` が付与されたまま open で残る Issue が、同一 top-level path を編集する新規 Issue を不要に awaiting-slot へ落とし、並列度を下げている。一方 promote-pipeline（develop→main）の文脈では `staged-for-release` は「まだ main に無い in-flight 集合」そのものなので holder として維持する必要がある。本要件は holder ラベル集合を呼び出しコンテキスト（dispatch base / promote target）に応じた base 相対の契約としてパラメータ化し、dispatch-time では `staged-for-release` を除外、promote-target=main の文脈では維持することを定義する。

## Requirements

### Requirement 1: holder ラベル集合の base 相対化（dispatch base=develop）

**Objective:** As a watcher 運用者, I want dispatch-time の path-overlap holder 集合から develop 統合済みの作業を除外したい, so that 完了済みで `staged-for-release` のまま残る Issue が新規 Issue の dispatch を不要に阻害しなくなる

#### Acceptance Criteria

1. When Path Overlap Checker が dispatch base=develop の文脈で in-flight holder を収集するとき, the Path Overlap Checker shall `staged-for-release` ラベルのみを持つ Issue を holder 集合から除外する。
2. While 完了し `staged-for-release` を付与した Issue が open のまま残っているとき, the Path Overlap Checker shall 当該 Issue が編集していた top-level path を holder claim として計上しない。
3. While 完了し `staged-for-release` を付与した Issue が open のまま残っているとき, the dispatcher shall 同一 top-level path を編集する新規 Issue を当該 Issue を理由に awaiting-slot へ落とさない。
4. When Issue が `staged-for-release` と他の in-flight ラベル（claude-claimed 等）を併せ持つとき, the Path Overlap Checker shall 当該 Issue を holder 集合に維持する。

### Requirement 2: holder ラベル集合の base 相対化（promote target=main）

**Objective:** As a watcher 運用者, I want promote-pipeline（develop→main）の overlap 判定で `staged-for-release` を引き続き holder として扱いたい, so that まだ main に無い in-flight 集合の保護が従来通り維持される

#### Acceptance Criteria

1. When path-overlap holder の収集が promote target=main の文脈で行われるとき, the Path Overlap Checker shall `staged-for-release` ラベルの Issue を in-flight holder 集合に維持する。
2. When promote-pipeline が develop→main の overlap を判定するとき, the Path Overlap Checker shall 本変更導入前と同一の holder 集合を計上する。

### Requirement 3: holder ラベル集合をコンテキスト依存の契約として共有

**Objective:** As a 開発者, I want holder ラベル集合を呼び出しコンテキストに応じて決定する単一の契約として表現したい, so that dispatch 用途と promote 用途で同じ仕組みを共有しても互いの判定を壊さない

#### Acceptance Criteria

1. The Path Overlap Checker shall holder ラベル集合を呼び出しコンテキスト（dispatch base / promote target）に応じて決定する。
2. When holder 集合の決定処理を dispatch 用途と promote 用途の双方が共有するとき, the Path Overlap Checker shall いずれの用途の判定結果も他方によって変化させない。
3. The Path Overlap Checker shall dispatch base=develop の文脈と promote target=main の文脈とで、`staged-for-release` の holder 計上有無を上記 Requirement 1 / 2 のとおり相互に独立して決定する。

### Requirement 4: コンテキスト解釈が曖昧な場合の安全側挙動

**Objective:** As a watcher 運用者, I want 呼び出しコンテキストやラベル状態が曖昧なときに安全側へ倒したい, so that 誤って holder から外すことで path 衝突を見逃すリスクを避けられる

#### Acceptance Criteria

1. If 呼び出しコンテキスト（dispatch base / promote target）が判定不能であるとき, the Path Overlap Checker shall 当該 Issue を holder 集合に維持する。
2. If Issue のラベル状態が holder 該当か否か判定不能であるとき, the Path Overlap Checker shall 当該 Issue を holder 集合に維持する。

## Non-Functional Requirements

### NFR 1: 後方互換性（single-branch 運用でのゼロ差分）

1. When `staged-for-release` を使わない single-branch 運用で dispatch が行われるとき, the Path Overlap Checker shall 本変更導入前と同一の holder 集合および awaiting-slot 判定結果を生成する。
2. The Path Overlap Checker shall `staged-for-release` 以外の in-flight ラベル（claude-claimed / claude-picked-up / awaiting-design-review / ready-for-review / needs-iteration / needs-rebase）の holder 計上挙動を本変更導入前と同一に保つ。

### NFR 2: API 呼び出し回数の不変性

1. The Path Overlap Checker shall in-flight Issue の列挙を本変更導入前と同じく 1 サイクルあたり 1 回に保ち、追加の Issue 列挙 API 呼び出しを発生させない。
2. The Path Overlap Checker shall 各 in-flight 候補 Issue あたりの edit_paths 読み出し API 呼び出し回数を本変更導入前と同じく 1 回に保つ。

### NFR 3: 可観測性

1. When dispatch 文脈で `staged-for-release` Issue を holder 集合から除外したとき, the Path Overlap Checker shall 当該除外がログから判別可能な形でログ出力する。

## Out of Scope

- ready-for-review → staged-for-release への自動遷移の実装（本 Issue は「`staged-for-release` が付いていれば develop dispatch で holder 扱いしない」までを対象とする）
- promote-pipeline の main 昇格ロジック本体の変更
- Tasks Count Gate（#216）や他ゲートの変更
- `staged-for-release` を誰がどのタイミングで付与するかの運用フローの新設（既存運用を前提とする）

## Open Questions

- ready-for-review の扱い: PR 未 merge の可能性があるため dispatch holder に残すのが安全と判断し、本要件では dispatch 除外対象を `staged-for-release` のみとした。除外対象を `staged-for-release` のみに限定する判断で問題ないか、人間レビューで確認したい。
- promote-pipeline 側が dispatch-time と同一の holder ラベルクエリを実際に共有しているかの確認: オーケストレータ調査では、固定ラベル集合（`staged-for-release` を含む）は dispatch-time の in-flight 収集にのみ存在し、promote-pipeline 側は実 merge 状態（`is:merged base:<branch>` の PR 列挙）で判定しており当該ラベルクエリを共有していない可能性が高い。本要件は base 相対パラメータ化という観測可能な契約として記述しており、promote-pipeline が実際に同一 holder ラベルクエリを使っているか否か（= Requirement 2 / 3.2 を共有関数で満たすか、別経路の挙動不変保証で満たすか）は design フェーズで確定する前提とする。
- `staged-for-release` への遷移を誰が付与するかを運用ガイドとして docs に併記すべきかは、本 Issue スコープ外だが docs 反映要否を確認したい。

## 関連

- Related: #18 #100 #15 #13
