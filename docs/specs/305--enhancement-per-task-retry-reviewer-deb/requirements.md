# Requirements Document

## Introduction

`PER_TASK_LOOP_ENABLED=true` の per-task ループでは、Reviewer reject 後の Developer 再実行が
**初回と同じ prompt** で起動されており、直前 round の Reviewer Findings や Debugger Fix Plan が
prompt 本文に inline 注入されていません。現状の Developer は、`review-notes.md` /
`debugger-notes.md` が spec ディレクトリに「存在することに気付けば」読む構造に依拠している
ため、指摘の見落としや「同じ AC・同じ missing test を round=1 / round=2 / round=3 で繰り返し
reject される」事象が発生しています。Issue #305 では、per-task retry 経路において Developer
prompt に Reviewer Findings / Debugger Fix Plan を **inline で強く注入**し、Developer 側に
**Finding Closure Matrix の記録義務**を課し、運用者から見て「同じ指摘が無限に繰り返される」
状態を watcher 側でも検出できるようにします。本変更は per-task ループの prompt 構築と Developer
向け規約に閉じ、Reviewer の判定カテゴリ・Debugger の権限境界・ループ全体の構造（rounds 数 /
Debugger Gate 配置）は変更しません。

### 用語

- **per-task retry**: per-task ループにおいて、同一 `task_id` に対する 2 回目以降の Developer
  再実行（Reviewer round=1 reject 後の再実行 / round=2 reject + Debugger Gate 後の再実行）
- **Reviewer Findings**: `review-notes.md` の `## Findings` セクションに列挙された Finding
  項目（カテゴリ・対象 numeric requirement ID・指摘本文）
- **Debugger Fix Plan**: `debugger-notes.md` の `## Task <id>` セクション配下に Debugger が
  記録した根本原因・修正手順・検証手順・残存リスク
- **Finding Closure Matrix**: Developer が `impl-notes.md` に追記する、Reviewer Finding と
  fix commit / 追加テスト / 検証結果の対応表

## Requirements

### Requirement 1: per-task retry 時の Developer prompt への Reviewer Findings 注入

**Objective:** As an idd-claude 運用者, I want per-task Reviewer reject 後の Developer 再実行
prompt が直前 round の Reviewer Findings を inline で運ぶこと, so that Developer が指摘内容を
見落とさず修正に着手できる

#### Acceptance Criteria

1. When per-task Reviewer が round=1 で reject 判定を返した直後の Developer 再実行が起動される,
   the per-task Implementer Prompt Builder shall prompt 本文に直前 round の `review-notes.md` の
   `## Findings` セクションを inline で埋め込む
2. When per-task Reviewer が round=2 で reject 判定を返した直後の Developer 再実行（Debugger
   Gate 経由）が起動される, the per-task Implementer Prompt Builder shall prompt 本文に
   `review-notes.md` の `## Findings` セクションと `debugger-notes.md` の当該 task の
   `## Task <id>` セクションの双方を inline で埋め込む
3. When 注入する `review-notes.md` の `## Findings` セクションを prompt 本文に埋め込む,
   the per-task Implementer Prompt Builder shall 各 Finding の対象 numeric requirement ID と
   指摘カテゴリ（AC 未カバー / missing test / boundary 逸脱）を可読な形で保持する
4. If 当該 task の per-task Developer 起動が初回（直前に Reviewer reject 履歴がない）, the per-task
   Implementer Prompt Builder shall Reviewer Findings / Debugger Fix Plan の inline 注入ブロックを
   prompt に追加しない
5. If 注入対象の `review-notes.md` が存在しない / 当該 round の Findings 抽出に失敗する,
   the per-task Implementer Prompt Builder shall 注入を諦め、prompt 本文にその旨を明示した
   1 行を残して Developer 起動を継続する

### Requirement 2: Developer による Finding Closure Matrix の記録義務

**Objective:** As a Reviewer round=2 / round=3 担当者, I want Developer が直前 round の指摘を
どの commit でどう閉じたかを構造化された表で残してくれること, so that 再判定時に「閉じた指摘」と
「閉じ残し」を即座に区別できる

#### Acceptance Criteria

1. While per-task retry 経路で Developer が再実行される, the Developer shall `impl-notes.md` の
   当該 task セクション配下に **Finding Closure Matrix** を追記する
2. When Developer が Finding Closure Matrix を追記する, the Developer shall 直前 round の
   各 Reviewer Finding について「対象 numeric requirement ID」「fix commit の subject または
   短縮 SHA」「追加 / 更新したテストファイルパス」「検証結果（どう確認したか）」の 4 項目を
   1 行に対応付ける
3. If 直前 round の Finding に対して fix commit が存在しない, the Developer shall Finding
   Closure Matrix の該当行で「未対応」「対応不可（理由）」「次 round へ持ち越し」のいずれかを
   明示する
4. The Developer shall 先行 task の learnings セクションおよび先行 round の Finding Closure
   Matrix 既存行を改変・削除・並び替えしない
5. When Debugger Fix Plan を prompt に inline 注入された round で Developer が再実行される,
   the Developer shall Finding Closure Matrix の各行に対応する Fix Plan ステップ（根本原因 /
   修正手順）への参照を併記する

### Requirement 3: 反復同一 reject の fail-fast 検出

**Objective:** As an idd-claude 運用者, I want 同じ task で同じカテゴリ・同じ対象の Finding が
連続 round で reject されつつテストファイルに有意な差分が積まれない状態を watcher が機械的に
検出して停止すること, so that 同じ指摘で無限に turn を消費する事故を未然に止められる

#### Acceptance Criteria

1. When per-task Reviewer が同一 `task_id` の 2 回連続 round で reject を返す, the per-task Retry
   Inspector shall 各 round の `review-notes.md` から Findings のカテゴリと対象 numeric
   requirement ID を抽出する
2. If 連続 2 round の Findings が「同一カテゴリ かつ 同一対象 numeric requirement ID」を 1 件
   以上共有する かつ 直近 round の Developer 再実行で関連するテストファイル（テストとして
   扱われるパス配下のファイル）に差分が積まれていない, the per-task Retry Inspector shall
   watcher の log に fail-fast 検出理由を出力する
3. If 上記 fail-fast 条件が成立する, the per-task Retry Inspector shall 当該 Issue を
   `claude-failed` ラベル相当の停止状態へ遷移させ、Issue コメントとして検出条件・対象
   `task_id`・連続 reject 対象の Finding 概要・運用者向けの判断材料（review-notes.md /
   debugger-notes.md / impl-notes.md へのパス）を残す
4. If 連続 2 round の Findings がカテゴリまたは対象 numeric requirement ID で 1 件も重ならない,
   the per-task Retry Inspector shall fail-fast 検出を発火させずに既存の per-task ループ規約
   （round 上限・Debugger Gate 配置）に従って処理を継続する
5. The per-task Retry Inspector shall テストファイルに該当するパス判定の基準（拡張子 / ディレ
   クトリ / 命名規則のいずれを採用するか）を `design.md` で明示するものとする

### Requirement 4: 規約反映と既存仕様との整合

**Objective:** As a 将来 Developer / Reviewer エージェント, I want per-task retry の新規挙動が
Developer / Reviewer agent 規約と既存 spec 群に整合する形で文書化されていること, so that 別
spec / 別エージェントが本機能を前提に行動できる

#### Acceptance Criteria

1. The Developer agent 規約は per-task retry 経路で Finding Closure Matrix を `impl-notes.md`
   に追記する責務を明示するものとする
2. The Reviewer agent 規約は per-task Reviewer の Findings 出力フォーマット（対象 numeric
   requirement ID とカテゴリの明示）を変更しないものとする
3. Where 本機能の prompt 注入が有効化される, the per-task Implementer Prompt Builder shall
   既存の per-task Implementer prompt が満たしてきた制約（PR 作成禁止 / spec 書き換え禁止 /
   対象 task 以外への着手禁止 / 進捗マーカー更新規約 / `## Implementation Notes` 配下
   `### Task <id>` 追記規約）を温存する
4. The 本機能の規約変更は `.claude/agents/developer.md` および
   `repo-template/.claude/agents/developer.md` の双方に byte 一致で反映されるものとする

### Requirement 5: テストおよび回帰検証

**Objective:** As a Reviewer of the 本 spec, I want 本機能のプロンプト注入経路・Finding Closure
Matrix・fail-fast 検出に対する自動検証が用意されていること, so that 既存挙動（per-task ループ
disabled / round=1 approve 経路 / Debugger Gate 非起動経路）を意図せず壊していないことを
保証できる

#### Acceptance Criteria

1. When 本 spec の実装後に回帰検証スクリプトが実行される, the 回帰検証スクリプト shall
   per-task retry prompt 注入が round=1 reject → round=2 経路で発火することを検証する
2. When 本 spec の実装後に回帰検証スクリプトが実行される, the 回帰検証スクリプト shall
   Debugger Gate 経由 round=3 経路で `review-notes.md` と `debugger-notes.md` の双方が inline
   注入されることを検証する
3. When 本 spec の実装後に回帰検証スクリプトが実行される, the 回帰検証スクリプト shall
   fail-fast 検出条件（連続 2 round 同一 Finding + テスト差分なし）の成立 / 不成立の双方を
   fixture で検証する
4. While `PER_TASK_LOOP_ENABLED=false` または当該 Issue が per-task ループの対象外, the per-task
   Implementer Prompt Builder shall 本機能の prompt 注入ブロックを構造的に skip する
5. The 回帰検証スクリプトは round=1 で approve された経路（reject 履歴なし）で本機能の
   prompt 注入ブロックが prompt 本文に追加されないことを検証するものとする

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `PER_TASK_LOOP_ENABLED=false`, the per-task ループ周辺の prompt builder shall 本機能
   導入前と同一の prompt を生成し、既存ラベル遷移 / env var 名 / exit code 意味を変更しない
2. While Reviewer round=1 で approve が返された経路, the per-task ループ shall 本機能導入前と
   同一の Implementer 起動回数（task あたり 1 回）で完了する
3. The 本機能の prompt 注入経路 shall 既存の `claude-failed` 分類カテゴリ
   （`per-task-implementer-failed` / `per-task-implementer-redo-failed` /
   `per-task-implementer-pp-failed` 等）の意味を変更しない

### NFR 2: 二重管理規約遵守

1. The 本機能で更新される `.claude/agents/*.md` ファイル群 shall root と `repo-template/`
   配下の双方に byte 一致で反映され、`diff -r .claude/agents repo-template/.claude/agents` の
   出力が空であることを満たす

### NFR 3: 運用観測性

1. When per-task retry prompt 注入が発火する, the per-task Implementer Prompt Builder shall
   注入実施の事実（round 番号・注入対象ファイル名・注入の有無）を watcher ログに 1 行で
   出力する
2. When fail-fast 検出が発火する, the per-task Retry Inspector shall 検出理由・連続 reject
   対象の Finding 概要・参照すべきファイルパスを運用者が 5 分以内に状況把握できる粒度で
   Issue コメントに残す

### NFR 4: prompt サイズの妥当性

1. While 本機能の prompt 注入が発火する, the per-task Implementer Prompt Builder shall 直近
   1 round 分の `review-notes.md` の `## Findings` セクションのみを注入し、過去の round や
   無関係な task の Findings を inline 注入しない
2. While Debugger Fix Plan を inline 注入する, the per-task Implementer Prompt Builder shall
   当該 task の `## Task <id>` セクションのみを注入し、他 task の Fix Plan を inline 注入しない

## Out of Scope

- Reviewer reject カテゴリ（AC 未カバー / missing test / boundary 逸脱）の追加・変更・削除
- Debugger にコード修正権限を付与する変更
- per-task ループの round 数上限変更（round=1 / round=2 / Debugger Gate + round=3 の構造を維持）
- per-task ループ自体の廃止 / 単一 Implementer 経路への巻き戻し
- 使用モデル（`DEV_MODEL` / `REVIEWER_MODEL` / `DEBUGGER_MODEL`）や quota policy の変更
- 設計 PR ゲートや Stage A Verify Gate / Stage B Reviewer 等、per-task ループの外側の stage
  に対する変更
- 既に main にマージ済みの spec の `impl-notes.md` への Finding Closure Matrix 遡及追記
- Reviewer / Debugger の出力先ファイル（`review-notes.md` / `debugger-notes.md`）の格納場所や
  ファイル名・必須セクション名の変更
- 別 Issue で扱われる Reviewer / Debugger の prompt 改善（本 spec は Developer 側 prompt と
  Developer 側成果物の規約強化に限定）

## Open Questions

- なし（不足情報が判明した場合は `## 関連` の関連 Issue にて補足する）

## 関連

- Related: hitoshiichikawa/idd-codex#37
