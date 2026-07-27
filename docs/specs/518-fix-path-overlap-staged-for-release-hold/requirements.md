# Requirements Document

## Introduction

Phase E Path Overlap Checker（#18）の dispatch-time gate では、#221 で「dispatch × multi-branch（`BASE_BRANCH != PROMOTION_TARGET_BRANCH`）では develop 統合済みを示す `staged-for-release` を holder 集合から除外する」契約を導入した。しかし実装は holder ラベル集合の**クエリ側減算のみ**（`staged-for-release` を抜いた 6 ラベルの `label:X OR ...` クエリを発行）で、列挙結果から staged 済み Issue を落とす後段フィルタが無い。そのため `staged-for-release` と他の holder ラベル（例: `ready-for-review`）を**併存**する Issue は、併存ラベル経由でクエリにマッチし、依然 holder として列挙・計上される。

さらに gitflow かつ promote pipeline 無効の構成では、`ready-for-review` を除去する処理が promote-pipeline 側にしか存在しないため、impl PR が develop へ merge された後も `ready-for-review` が Issue に残置し続ける。運用者が手で `staged-for-release` を付与しても、上記の併存問題により当該 Issue が holder 集合から外れない。実害として、gitflow（`BASE_BRANCH=develop` / `PATH_OVERLAP_CHECK=true` / promote 無効）構成で develop merge 済みの複数 Issue（`ready-for-review` + `staged-for-release` 併存）が、同一 top-level path を編集する新規 Issue を毎 tick `awaiting-slot` へ落とし、次リリースまで数日〜恒久的に dispatch をブロックする事象が発生した。

本要件は、dispatch × multi-branch 文脈において「`staged-for-release` を**付与されている** Issue は、他 holder ラベルの併存有無に関わらず holder 集合から**除外**する」ことを定義する。これは #221 Requirement 1.4（「Issue が `staged-for-release` と他 in-flight ラベルを併せ持つとき holder 集合に**維持**する」）を**意図的に上書き**する変更である。上書きの根拠は、gitflow + promote 無効では `ready-for-review` 残置が構造的に発生するため併存を holder 維持条件にすると本問題が解消せず、かつ `staged-for-release` の存在こそが develop 統合済みの信頼できるシグナルであることによる。single-branch 構成および promote target=main の文脈では従来どおり `staged-for-release` を holder に維持し、ゼロ差分を保つ。

## Requirements

### Requirement 1: staged-for-release 併存 Issue の holder 除外（dispatch × multi-branch）

**Objective:** As a watcher 運用者, I want dispatch × multi-branch で `staged-for-release` を付与された Issue を他ラベル併存の有無に関わらず holder 集合から除外したい, so that develop 統合済みの Issue が新規 Issue の dispatch を恒久的に阻害しなくなる

補足: 本 Requirement は #221 Requirement 1.4（併存時は holder 維持）を意図的に上書きする。#221 Req 1.4 の挙動を検証する既存テスト fixture は本 Issue により更新される想定であり、それ以外の path-overlap fixture は不変（NFR 1 参照）。

#### Acceptance Criteria

1. When Path Overlap Checker が dispatch base ブランチと promote target ブランチが異なる（multi-branch）文脈で in-flight holder を収集するとき, the Path Overlap Checker shall `staged-for-release` を付与された Issue を、他の holder ラベルの併存有無に関わらず holder 集合から除外する。
2. When Issue が `staged-for-release` と `ready-for-review` を併存し open のまま multi-branch dispatch 文脈で評価されるとき, the Path Overlap Checker shall 当該 Issue を holder 集合に計上しない。
3. While `staged-for-release` を付与された Issue が open のまま残っているとき, the dispatcher shall 同一 top-level path を編集する新規 Issue を当該 Issue を理由に awaiting-slot へ落とさない。

### Requirement 2: single-branch / promote 文脈での holder 維持（後方互換）

**Objective:** As a watcher 運用者, I want single-branch 運用と promote target=main の文脈では `staged-for-release` を従来どおり holder に維持したい, so that 本変更が既存の single-branch 運用と promote 判定に差分を与えない

#### Acceptance Criteria

1. When single-branch 構成（dispatch base ブランチと promote target ブランチが同一、main only / 未設定）で dispatch が行われるとき, the Path Overlap Checker shall `staged-for-release` を付与された Issue を holder 集合に維持する。
2. When path-overlap holder の収集が promote target=main の文脈で行われるとき, the Path Overlap Checker shall `staged-for-release` を付与された Issue を holder 集合に維持する。
3. When single-branch 構成で dispatch が行われるとき, the Path Overlap Checker shall 本変更導入前と同一の holder 集合および awaiting-slot 判定結果を生成する。

### Requirement 3: dispatch 通常経路と flock-skip 可視化経路の一貫性

**Objective:** As a watcher 運用者, I want dispatch 通常経路と flock-skip 可視化経路とで holder 除外結果を一致させたい, so that どちらの経路でも同じ Issue が同じく holder から除外され awaiting-slot 判定が矛盾しない

#### Acceptance Criteria

1. When flock-skip 可視化経路が multi-branch 文脈で候補を評価するとき, the Path Overlap Checker shall 通常 dispatch 経路と同一の `staged-for-release` 併存 Issue 除外規則を適用する。
2. The Path Overlap Checker shall 通常 dispatch 経路と flock-skip 可視化経路とで、`staged-for-release` を付与された Issue の holder 計上有無を同一に決定する。

### Requirement 4: コンテキスト / ラベル判定不能時の安全側挙動

**Objective:** As a watcher 運用者, I want ラベル取得やコンテキスト判定が不能なときに holder を維持する安全側へ倒したい, so that 誤って holder から外すことで path 衝突を見逃すリスクを避けられる

#### Acceptance Criteria

1. If Issue の holder 該当ラベル（`staged-for-release` の有無を含む）を取得できず判定不能であるとき, the Path Overlap Checker shall 当該 Issue を holder 集合に維持する。
2. If 呼び出しコンテキスト（dispatch base / promote target）が判定不能であるとき, the Path Overlap Checker shall `staged-for-release` を付与された Issue を holder 集合に維持する。

## Non-Functional Requirements

### NFR 1: 後方互換性（ゼロ差分）

1. When `PATH_OVERLAP_CHECK` が off / 未設定 / 不正値であるとき, the Path Overlap Checker shall 本変更導入前と同一の挙動（early return / no-op）を保つ。
2. The Path Overlap Checker shall `staged-for-release` を付与されていない Issue の holder 計上挙動（`claude-claimed` / `claude-picked-up` / `awaiting-design-review` / `ready-for-review` / `needs-iteration` / `needs-rebase` 単独および併存を含む）を本変更導入前と同一に保つ。

### NFR 2: API 呼び出し回数の不変性

1. The Path Overlap Checker shall in-flight Issue の列挙を 1 サイクルあたり 1 回に保ち、追加の Issue 列挙 API 呼び出しを発生させない。
2. The Path Overlap Checker shall 各候補 Issue あたりの edit_paths 読み出し API 呼び出し回数を 1 回に保つ。
3. The Path Overlap Checker shall holder 除外判定に必要なラベル情報を既存の in-flight 列挙 API 呼び出しの結果から取得し、ラベル取得のための追加 API 呼び出しを発生させない。

### NFR 3: 可観測性

1. When multi-branch 文脈で `staged-for-release` を付与された Issue を holder 集合から除外したとき, the Path Overlap Checker shall 当該除外がログから判別可能な形でログ出力する。

## Out of Scope

- promote pipeline 本体の挙動変更
- gitflow での `ready-for-review` → `staged-for-release` 自動遷移の新設（別 Issue 候補）
- impl PR merge 検出時に `ready-for-review` → `staged-for-release` へ遷移させる軽量プロセッサの新設（本 Issue の holder 除外だけで実害は解消するため。Open Questions 参照）
- 新しい env var / フラグの追加（既存の `BASE_BRANCH` / `PROMOTION_TARGET_BRANCH` の 2 変数のみで multi-branch を判定する #221 の設計を踏襲する）
- `staged-for-release` を誰がどのタイミングで付与するかの運用フローの新設（既存運用を前提とする）
- #221 Requirement 1.4 の挙動を検証する既存テスト fixture 以外の path-overlap テスト fixture の破壊的変更

## Open Questions

- promote pipeline 無効の gitflow 構成向けに「impl PR merge 検出時に `ready-for-review` → `staged-for-release` へ遷移させる軽量プロセッサ」を提供するか。本 Issue のデフォルト方針は「holder 除外だけで実害（新規 Issue の awaiting-slot 恒久滞留）は解消するため、遷移プロセッサは本 Issue スコープ外（必要なら別 Issue）」とする。ただしラベルのライフサイクルとして、develop merge 後も `ready-for-review` が意味を失ったまま残置する問題は本 Issue 完了後も残る旨を記録する。

## 関連

- Depends on: #221
- Related: #316 #100 #18 #15
