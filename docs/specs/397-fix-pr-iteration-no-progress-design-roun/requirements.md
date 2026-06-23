# Requirements Document

## Introduction

PR Iteration Processor の design round が新規 commit を生まなかった場合（no-progress round）、
no-progress 連続カウンタが上限に達していなくても `needs-iteration` を外して
`awaiting-design-review` に遷移させ、結果として `action=success` 扱いになっている。
`pr-iteration` の候補抽出は `needs-iteration` ラベル付与 PR を起点に行うため、
`awaiting-design-review` へ移行した PR は次 round の対象から外れ、no-progress 連続カウンタが
加算されない。結果として escalation（`claude-failed` 付与）が発火せず、必須 status check が
FAILED のまま auto-merge も再レビューも進まない silent deadlock が発生している。本要件は
#122 で導入された no-progress 安全機構を design 遷移経路でも有効化し、no-progress を観測した
ときに deadlock せず最終的に escalation または retry に収束させることを目的とする。

## Requirements

### Requirement 1: no-progress な design round のラベル据え置き

**Objective:** As an idd-claude 運用者, I want no-progress な design round で
`needs-iteration` ラベルが据え置かれることを保証してほしい, so that PR が候補プールから外れずに
次 round で再試行され、no-progress 連続カウンタが加算され続けて最終的に escalation に到達する。

#### Acceptance Criteria

1. When design 種別の PR Iteration round が終了し、当該 round の開始時点から終了時点までに
   head branch に新規 commit が push されなかった場合、the PR Iteration Processor shall
   `needs-iteration` ラベルを据え置き、`awaiting-design-review` ラベルを付与しない。
2. When design 種別の PR Iteration round が終了し、当該 round で新規 commit が push されな
   かった場合、the PR Iteration Processor shall 当該 round の終了結果を `action=success` として
   記録しない。
3. When design 種別の PR Iteration round が終了し、当該 round で新規 commit が push されな
   かった場合、the PR Iteration Processor shall 当該 PR が次サイクルでも `needs-iteration`
   ラベルを起点とする候補抽出に再び含まれる状態を維持する。

### Requirement 2: no-progress 連続カウンタの加算と escalation 到達性

**Objective:** As an idd-claude 運用者, I want no-progress な round が観測されたら
no-progress 連続カウンタが確実に加算され、上限に達した時点で escalation が発火することを
保証してほしい, so that PR が必須 status check FAILED のまま無期限に停滞することがなくなる。

#### Acceptance Criteria

1. When design 種別の PR Iteration round が新規 commit 無しで終了した場合、
   the PR Iteration Processor shall 当該 PR の no-progress 連続カウンタを 1 加算した状態で
   次サイクルから観測可能にする。
2. While 当該 PR の no-progress 連続カウンタが `PR_ITERATION_NO_PROGRESS_LIMIT` 未満である
   間、the PR Iteration Processor shall 当該 PR を `needs-iteration` 候補のまま次 round に
   進められる状態として残す。
3. When 当該 PR の no-progress 連続カウンタが `PR_ITERATION_NO_PROGRESS_LIMIT` 以上に達した
   round の終了時点で、the PR Iteration Processor shall escalation を発火させ、当該 PR に
   `claude-failed` ラベルを付与する。
4. When escalation が発火した場合、the PR Iteration Processor shall reason=`no-progress` と
   加算後の連続カウンタ値および limit 値を含む 1 行ログを出力する。

### Requirement 3: 新規 commit がある round の success 遷移は維持

**Objective:** As an idd-claude 運用者, I want 当該 round で実際に新規 commit が push された
ケースでは従来通り success 遷移する挙動を維持してほしい, so that 本 fix が正常な iteration
パスを壊さず、design 反復の通常運用が継続できる。

#### Acceptance Criteria

1. When design 種別の PR Iteration round が終了し、当該 round で head branch に新規 commit が
   push された場合、the PR Iteration Processor shall `needs-iteration` を外して
   `awaiting-design-review` を付与するラベル遷移を実行する。
2. When design 種別の PR Iteration round が終了し、当該 round で head branch に新規 commit が
   push された場合、the PR Iteration Processor shall 当該 PR の no-progress 連続カウンタを 0 に
   リセットする。
3. When design 種別の PR Iteration round で新規 commit が push されラベル遷移に成功した場合、
   the PR Iteration Processor shall 当該 round の終了結果を `action=success` として 1 行
   ログに記録する。

### Requirement 4: impl 種別 round における同型経路の扱い

**Objective:** As an idd-claude 運用者, I want impl 種別の PR Iteration round で発生し得る
同型の no-progress→success 経路についても本修正の対象範囲を明確化してほしい, so that
将来 impl 側で同じ silent deadlock が観測された際の扱いが Issue / PR 内で曖昧にならない。

#### Acceptance Criteria

1. When impl 種別の PR Iteration round が新規 commit 無しで終了した場合、
   the PR Iteration Processor shall design 種別と同等の制御フロー（`needs-iteration` 据え置き
   + no-progress 連続カウンタ加算 + 上限到達時 escalation）を適用する。
2. When impl 種別の PR Iteration round が新規 commit 無しで終了した場合、
   the PR Iteration Processor shall `needs-iteration` を外して `ready-for-review` を付与する
   ラベル遷移を実行しない。
3. When impl 種別の PR Iteration round で実際に新規 commit が push された場合、
   the PR Iteration Processor shall 従来通り `needs-iteration` を外して `ready-for-review` を
   付与するラベル遷移を実行する。

### Requirement 5: 観測可能性（ログ）

**Objective:** As an idd-claude 運用者, I want no-progress round と escalation の遷移点を
ログから機械可読に追跡できるようにしてほしい, so that 本修正が意図通り動作しているか
（または再回帰していないか）を運用ログから検証できる。

#### Acceptance Criteria

1. When design 種別 round が新規 commit 無しで終了した場合、the PR Iteration Processor shall
   PR 番号・kind・round 番号・加算後の no-progress 連続カウンタ値・limit 値を含む 1 行を
   既存のログ出力先に記録する。
2. When design 種別 round が新規 commit 無しで終了し、かつ連続カウンタが上限未満であった
   場合、the PR Iteration Processor shall 当該 round の終了結果を `action=success` を含まない
   ログ表現で記録する。
3. When escalation が発火した場合、the PR Iteration Processor shall PR 番号・kind・round
   番号・reason=`no-progress`・連続カウンタ値・limit 値を 1 行ログに記録する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Iteration Processor shall 既存の env var 名（`PR_ITERATION_NO_PROGRESS_LIMIT` /
   `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_MAX_ROUNDS*` 等）の名称と既定値の意味を
   変更しない。
2. The PR Iteration Processor shall 既存ラベル（`needs-iteration` / `awaiting-design-review` /
   `ready-for-review` / `claude-failed`）の名称・付与責務・取り外し責務の契約を変更しない
   （本要件はラベル遷移の発火条件のみを変更する）。
3. The PR Iteration Processor shall round の正常進行（新規 commit が push された round）に
   対する観測可能な挙動（ラベル遷移・no-progress 連続カウンタのリセット・ログ出力）を
   変更しない。

### NFR 2: 安全側のデフォルト挙動

1. If 当該 round で新規 commit が push されたか否かを判定するために必要な情報が取得不能だった
   場合、the PR Iteration Processor shall 当該 round を success 遷移として扱わず、
   `needs-iteration` 据え置きで終了させる。
2. If no-progress 連続カウンタの永続化に失敗した場合、the PR Iteration Processor shall
   `needs-iteration` を据え置いたまま終了し、ERROR レベルのログを出力する（現行の
   Issue #122 Req 5.4 の据え置き契約を維持する）。

## Out of Scope

- 「なぜ Architect / Developer / claude CLI が当該 round で commit を作らなかったか」という
  個別要因（フィードバック未到達 / 誤指示コメント / stale コメントの解釈等）の調査・修正は
  本要件の対象外。本要件は no-progress round を `action=success` として候補から外し deadlock
  させる制御フローの修正に限定する。
- reopen された PR に残る obsolete な人間コメントを現行指示として解釈する挙動の見直しは
  別 Issue 検討事項として扱い、本要件の対象外とする。
- `PR_ITERATION_NO_PROGRESS_LIMIT` の既定値変更や、kind 別に上限を分離する設計変更は
  本要件の対象外（既定値・分離なしの現行設計を前提に挙動を是正する）。
- design / impl 以外の新しい PR Iteration 種別の導入は本要件の対象外。
- pr-reviewer / auto-merge-design / design-review-release / promote-pipeline 等、本要件が
  解消しようとしている下流 processor 側の挙動変更は対象外（本要件の修正が完了すれば
  これら下流側の処理は既存契約のまま自然に進行する想定）。

## Open Questions

- なし（Issue 本文「受入基準」「スコープ外」が十分に明確で、本要件のスコープと完了条件は
  Issue 記述のみで一意に定まる）。

## 関連

- Depends on: なし
- Parent: なし
- Related: #122 #389 #383
