# Requirements Document

## Introduction

per-task Reviewer ループ運用下では、Architect が `tasks.md` で task ごとに宣言した
`_Requirements:_` の numeric ID が、当該 task 完了時点で per-task Reviewer によって
検証される。ここで Architect が「実行時挙動の変更」と「対応 regression / failure-path /
safety-fallback テスト追加」を異なる task に分割し、それでも先行 task の `_Requirements:_`
に当該テスト側 AC を含めたままにすると、per-task Reviewer はテストが未追加の状態で AC 紐付けを
評価することになり、`missing test` カテゴリで reject される。idd-codex 側で同種の失敗が複数回
観測されており、idd-claude 側も prompt / rule がほぼ同一系統のため、同じ事故を予防するための
規約強化を本 spec で行う。本要件定義は、Architect の `tasks.md` 生成および Developer / Reviewer
の参照ルールに対し、task 境界とテスト期待値を整合させるための明示的なルールを規定する。

## Requirements

### Requirement 1: task と test の境界整合（Architect ルール）

**Objective:** As an Architect, I want `tasks.md` 上で各 task の `_Requirements:_` と対応テスト追加
タイミングを明示的に整合させる規約を持ちたい, so that per-task Reviewer の `missing test` 誤判定を
設計段階で予防できる。

#### Acceptance Criteria

1. When Architect が `tasks.md` を生成するとき, the Architect rule shall 各 task ごとに対応テストを同一 task に含めるか、別 task に明示的に deferred するかを task 単位で決定するよう要求する
2. When 当該 task の `_Requirements:_` に regression coverage / failure path / API・parse failure handling / stale data safety / safety-side fallback の AC numeric ID が含まれるとき, the Architect rule shall 当該 task の詳細項目に対応するテスト追加作業を同 task 内に含めるよう要求する
3. When 当該 task が実行時挙動を変える（behavior-changing）task であるとき, the Architect rule shall 当該 task 内に最低限の regression / shell-level test 追加を含めるよう要求する
4. If 対応テストが後続 task に deferred されるとき, the Architect rule shall 先行 task の `_Requirements:_` から当該 deferred test 対応 AC を除外するか、当該 AC を partial として明示するよう要求する
5. The Architect rule shall partial 明示の canonical 記法（task 行レベルでの partial 明記方式）を 1 つに固定し、per-task Reviewer が同じ記法を partial 扱いと解釈できる状態にする

### Requirement 2: dedicated regression test task の境界制約

**Objective:** As an Architect, I want behavior-changing task と dedicated regression test task を
分離する場合の境界制約を明文化したい, so that 後続テスト task の存在が先行 task の per-task review を
不合格にしない。

#### Acceptance Criteria

1. When Architect が dedicated regression test task（テストのみを目的とする後続 task）を切り出すとき, the Architect rule shall 当該 test task の `_Requirements:_` を、先行 behavior-changing task の `_Requirements:_` と重複させないか、または partial 解消関係であることを明示するよう要求する
2. When dedicated regression test task が存在するとき, the Architect rule shall 当該 test task のスコープを E2E / 統合テスト / coverage 補完等、先行 task の per-task Reviewer 判定に影響しない範囲に限定するよう要求する
3. If 先行 task の per-task Reviewer 判定対象 AC（`_Requirements:_` 列挙）に対応するテスト追加が、dedicated regression test task に切り出されているとき, the Architect rule shall 先行 task の `_Requirements:_` から当該 AC を除外するか partial 明示するよう要求する

### Requirement 3: Developer / Reviewer の参照整合

**Objective:** As a Developer / Reviewer, I want Architect が決定した task-boundary contract を同じ
規約として参照したい, so that Developer が Reviewer の検証対象テストを別 task に deferred することで
per-task Reviewer 判定をすり抜ける事態を防げる。

#### Acceptance Criteria

1. The Developer rule shall task ごとの `_Requirements:_` 列挙 AC に対し、当該 task 内で対応テストを実装する責務を負うことを明示する
2. If Developer が当該 task 内で対応テストを実装できないと判断するとき, the Developer rule shall `tasks.md` を書き換えず PR 本文「確認事項」または Issue コメントで Architect への差し戻しを提案するよう要求する
3. The Reviewer rule shall per-task Reviewer 起動時、当該 task の `_Requirements:_` 列挙 AC に対応するテスト追加が当該 task 範囲（per-task diff range）内にあるかを `missing test` カテゴリで判定するよう要求する
4. Where 当該 AC が `tasks.md` で partial 明示されているとき, the Reviewer rule shall 当該 AC のテスト未追加を `missing test` の reject 理由としないよう要求する
5. The Developer rule and the Reviewer rule shall Architect rule と同一の task-boundary contract（partial 記法・後続 test task の境界制約）を参照する

### Requirement 4: root / repo-template の二重管理整合

**Objective:** As an idd-claude maintainer, I want root `.claude/{agents,rules}/` と
`repo-template/.claude/{agents,rules}/` の更新が byte 一致で同期されることを規約化したい,
so that consumer repo と idd-claude self-hosting の双方で同じ task-boundary contract が適用される。

#### Acceptance Criteria

1. When 本 spec のルール更新を `.claude/agents/architect.md` / `.claude/rules/tasks-generation.md` 等に反映するとき, the update shall 同一 PR 内で root と `repo-template/` の両系統に byte 一致で反映される
2. When `.claude/agents/developer.md` / `.claude/agents/reviewer.md` を更新するとき, the update shall 同一 PR 内で root と `repo-template/` の両系統に byte 一致で反映される
3. The repository shall `diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` が本 spec 反映後に空である状態を満たす

### Requirement 5: 既存運用との後方互換

**Objective:** As an idd-claude maintainer, I want per-task Reviewer ループを使わない既存運用に
影響を出さずに本規約を導入したい, so that opt-out 環境の既存挙動が変化しない。

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED` が未指定 / `=true` 以外であるとき, the new rule shall 既存単一 Developer 一括実装フローの挙動を変化させない
2. The new rule shall 既に main に merge 済みの `tasks.md` に対する遡及的な書き換えを要求しない
3. The new rule shall 既存の `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` / `- [ ]*` の各アノテーション規約を破壊的に変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The new rule shall 既存 spec（main 済み）の `tasks.md` を本規約違反として遡及的に報告しない
2. The new rule shall `PER_TASK_LOOP_ENABLED=true` を有効化していない運用環境において、既存単一 Developer 一括実装フローの挙動を変化させない
3. The new rule shall 既存 checkbox enforcement check / Budget overflow check / verify block well-formed check の判定ロジックを変更しない

### NFR 2: 規約整合性

1. The new rule shall `.claude/rules/tasks-generation.md` および `.claude/agents/architect.md` の既存アノテーション規約と矛盾しない記述で導入される
2. The new rule shall root `.claude/{agents,rules}/` と `repo-template/.claude/{agents,rules}/` の両系統に byte 一致で反映され、`diff -r` 検証が空である状態を維持する
3. The new rule shall partial 明示の canonical 記法を 1 つに固定し、複数表記の混在を生まない

### NFR 3: 検証容易性

1. Where shell-level fixture を導入する場合, the fixture shall 生成された task 計画が test coverage 対応 AC を実装専用 task に同 task テスト指示なしで割り当てていないことを機械的に検証できる構造を持つ

## Out of Scope

- idd-codex の `.codex` prompt 更新（idd-codex 側 #6 / #13 の実装復旧は対象外）
- per-task Reviewer の判定カテゴリ体系の変更（既存 3 カテゴリ: AC 未カバー / missing test / boundary 逸脱 を維持する）
- per-task Reviewer のテスト要件を緩和する変更（test を不要扱いにする運用緩和は対象外）
- 既に main に merge 済みの `tasks.md` の retrofit（遡及的修正は不要）
- `PER_TASK_LOOP_ENABLED=true` 以外の既存運用フローへの追加規約導入

## Open Questions

- partial 明示の canonical 記法として、(a) `_Requirements: 1.1 (partial), 1.2_` のような行内サフィックス方式と、(b) `_Requirements_partial: 1.1_` のような独立アノテーション方式のどちらを採用するか — Architect 段階で決定し design.md / tasks-generation.md に反映する
- shell-level fixture 検証（NFR 3.1）を本 spec で実装するか、別 Issue として切り出すか — Architect 判断
