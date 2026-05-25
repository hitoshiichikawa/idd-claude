# Requirements Document

## Introduction

Tasks Count Gate (#147) は、local watcher の design モード完了直後・Developer pickup 前に
`tasks.md` のタスク件数を機械的に再カウントし、件数レンジに応じて normal / warn / escalate を
適用する harness 側の安全網である。現状の harness 計数 (`tc_count_tasks`) は全 checkbox 行
（子タスク `1.1`・完了 `[x]`・deferrable `*` を含む）を計上するのに対し、Architect の正準計数
（`design-review-gate.md` Budget overflow check）は最上位 numeric ID の未完了タスクのみを数える。
この乖離により、Architect が「budget 内（≤10 最上位）」と確定した設計を harness が「≥11（全
checkbox）」と誤って escalate する。本変更は、正準を `design-review-gate.md` に置いたまま harness
計数のみをそれに整合させ、閾値は一切変えずに二重計上を解消する。

## Requirements

### Requirement 1: harness タスク計数の正準整合

**Objective:** As a watcher 運用者, I want harness のタスク計数を Architect の正準計数と同一規約にしたい, so that 同じ tasks.md で Architect と harness が矛盾する判定（一方は budget 内・他方は escalate）を出さなくなる

#### Acceptance Criteria

1. The Tasks Count Gate shall 最上位 numeric ID の未完了タスク行（`- [ ]` で始まり整数 ID + `.` + 半角スペースで続く行、正準 regex `^- \[ \]\*? [0-9]+\. ` に一致する行）のみを計数対象とする
2. When tasks.md に子タスク行（`- [ ] 1.1` のような小数階層 ID）が含まれているとき, the Tasks Count Gate shall それらを計数対象から除外する
3. When tasks.md に完了済みタスク行（`- [x]` または `- [x]*` で始まる行）が含まれているとき, the Tasks Count Gate shall それらを計数対象から除外する
4. Where 最上位 deferrable テストタスク行（`- [ ]*` で始まり整数 ID + `.` で続く行）が含まれている場合, the Tasks Count Gate shall 正準 regex `^- \[ \]\*? [0-9]+\. ` の一致挙動に厳密一致させて当該行を計数対象に含める
5. When 同一の tasks.md を Architect の Budget overflow check 計数（正準 regex `^- \[ \]\*? [0-9]+\. `）と harness の計数の両方で評価したとき, the Tasks Count Gate shall Architect 計数と同一の件数を返す

### Requirement 2: 計数変更後の分類・抑止挙動の維持

**Objective:** As a watcher 運用者, I want 計数の意味が「最上位・残作業ベース」に変わっても安全網としての分類・抑止が維持されること, so that 真に過大な Issue が引き続き Developer の turn budget 超過から守られる

#### Acceptance Criteria

1. The Tasks Count Gate shall 最上位・未完了ベースで算出した件数を normal / warn / escalate の分類対象とする
2. While impl-resume などで一部タスクが `- [x]` 済みの状態, when harness が件数を分類するとき, the Tasks Count Gate shall 残る未完了の最上位タスク件数で normal / warn / escalate を判定する
3. When 最上位の未完了タスクが真にエスカレーション閾値（既定 11 件）以上であるとき, the Tasks Count Gate shall 計数変更後も引き続き escalate と分類する
4. The Tasks Count Gate shall normal / warn / escalate を分ける閾値（既定 `TC_WARN_LOWER`=8 / `TC_WARN_UPPER`=10 / `TC_ESCALATE_LOWER`=11）を本変更によって変更しない

### Requirement 3: 計数定義のドキュメント一元化と相互参照

**Objective:** As a 将来の保守者, I want harness と Architect で別実行基盤に置かれた同一の計数規約が文書上で一致し相互参照されること, so that 一方だけが更新されて計数が再び乖離する事故を検知できる

#### Acceptance Criteria

1. The 計数規約 shall harness 側（`issue-watcher.sh` の `tc_count_tasks` 周辺コメント）と Architect 側（`design-review-gate.md` の Budget overflow check）の双方で同一の正準 regex として明記される
2. The harness 側ドキュメント shall 正準が `design-review-gate.md` の Budget overflow check 計数である旨と、そこへの相互参照を含める
3. When 計数の意味（最上位・未完了のみ、子/完了/deferrable の扱い）を説明するとき, the README の Tasks Count Gate 節 shall design-review-gate.md の正準計数と整合した記述に更新される
4. The 回帰テスト（fixture / driver） shall 子タスク・完了 `[x]`・deferrable を含む tasks.md に対して最上位・未完了ベースの期待件数を検証する

### Requirement 4: per-issue override / per-task-loop からの独立性

**Objective:** As a watcher 運用者, I want 本計数修正が #214（per-issue override）や #21（per-task-loop）と独立して成立すること, so that 未実装機能の有無に依存せず計数の整合だけが先行して導入できる

#### Acceptance Criteria

1. Where per-issue override シグナル（#214）が未実装または当該 Issue に未付与の場合, the Tasks Count Gate shall override の存在を前提とせず最上位・未完了ベースの計数で判定する
2. The 本変更 shall per-task-loop（#21）の挙動を変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性と互換性影響の明示

1. When `TC_ENABLED` が `true` 以外であるとき, the Tasks Count Gate shall 本変更後も評価を一切行わず本機能導入前と同一の挙動を保つ
2. The README shall 計数変更により一部 Issue の判定が escalate から warn / normal に移ることが意図した挙動である旨を migration note として明記する
3. The 本変更 shall 既存 env var 名（`TC_ENABLED` / `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER`）とエスカレーションコメントの識別マーカー文字列（`<!-- idd-claude:tasks-count-overflow ... -->`）を変更しない

### NFR 2: 計数の決定性

1. When 同一内容の tasks.md を複数回評価したとき, the Tasks Count Gate shall 毎回同一の件数を返す（環境状態に依存しない決定的計数）

## Out of Scope

- 閾値の既定値変更（`TC_WARN_LOWER`=8 / `TC_WARN_UPPER`=10 / `TC_ESCALATE_LOWER`=11 は不変。本変更は計数定義のみ修正する）
- per-issue override 弁の実装（#214）。本計数修正は #214 と独立に成立させる
- per-task-loop（#21）の挙動変更
- Architect `design-review-gate.md` 側の計数 regex の変更（こちらを正準とし harness を寄せる）
- `tc_classify` の閾値ロジックそのものの変更（分類対象となる件数の意味のみが最上位・未完了ベースに変わる）
- 外部 Feature Flag SaaS 連携や新規外部サービス呼び出しの追加

## Open Questions

- design-review-gate.md の散文矛盾: 正準 regex `^- \[ \]\*? [0-9]+\. ` は最上位 deferrable `- [ ]*` に一致する（＝計数に含む）一方で、design-review-gate.md の散文は「`- [ ]*`（deferrable テストタスク）は本カウントでは数えません」と記載しており自己矛盾している。本 Issue は Architect 側 regex 変更をスコープ外とするため、harness は正準 regex の一致挙動に厳密一致させる（Req 1.4）方針を確定とする。ただし散文側の clarification（regex に合わせて「最上位 deferrable は含む」と書き換えるか、regex を `^- \[ \]\? ...` 相当へ将来見直すか）を本 PR で行うかは人間判断に委ねる。本要件では「harness が正準 regex と同一件数を返す」ことを正準とし、散文修正の要否はエスカレーションする。
- 計数定義の二重管理リスク: bash（harness）と LLM ルール（Architect）は実行基盤が異なり共有コードを持てないため、本要件は同一 regex を両所に明記し相互参照する「ドキュメントで担保」方式（Req 3.1 / 3.2）を確定とする。将来両所が乖離した際に機械的に検知する仕組み（例: regex 文字列の一致を検査する lint）を導入するかは本 Issue のスコープ外であり、必要性の判断を人間に委ねる。
