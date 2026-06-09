# Requirements Document

## Introduction

per-task Implementer ループでは、各タスクの完了時に `docs(tasks): mark <id> as done`
marker commit を積み、watcher はその marker を per-task Reviewer の review range の終端として
利用する。Reviewer reject 後に Implementer / Debugger 経由 Implementer が修正 commit を追加
する際、修正 commit が既存 marker より後ろに積まれると、watcher の range 解決が marker で
止まり、修正 commit が review 対象から漏れる。idd-codex 側 #14 で実際に発生し、retry 後の
修正内容が妥当だったにもかかわらず古い range だけが再評価されて `codex-failed` 終了に至った。
idd-claude も同一系統の per-task contract を持つため、同一 failure mode が潜在しないかを
点検し、prompt と watcher の両面で予防策を導入する。

## Requirements

### Requirement 1: Marker commit の生成タイミング契約

**Objective:** As a per-task Implementer, I want marker commit を当該 task の終端 commit として
扱う契約を共有したい, so that retry 時に修正 commit が marker より後ろに積まれて review range
から漏れる事故を防げる。

#### Acceptance Criteria

1. When per-task Implementer marks a task as done, the per-task Implementer shall create the
   `docs(tasks): mark <id> as done` marker commit only after all task-scope implementation,
   validation, and learning updates for that attempt are complete.
2. When per-task Implementer is re-run after Reviewer reject or Debugger guidance, the per-task
   Implementer shall not leave new task-scope fixes after an older `docs(tasks): mark <id> as done`
   marker without refreshing the marker so that the marker remains the terminal commit of the
   task's reviewed range.
3. The per-task Implementer prompt shall document the marker contract（marker は task の終端
   commit であり、retry 時に marker 後ろに修正を残さない）in a位置 that the Implementer reads
   before adding any commit.

### Requirement 2: Watcher による review range と marker の整合保証

**Objective:** As watcher が per-task Reviewer に渡す review range の解決責任者, I want marker
より後ろに未レビュー commit が存在する状態を silent に通さない, so that retry 後の修正 commit が
Reviewer から見えないまま再 reject される事故を防げる。

#### Acceptance Criteria

1. When the watcher resolves a review range for a per-task Reviewer invocation, the watcher shall
   not silently exclude commits authored after the selected marker but before the Reviewer
   invocation when they belong to the same retry attempt.
2. If commits exist after the selected marker before Reviewer invocation, the watcher shall
   either include those commits in the Reviewer review range or abort the per-task Reviewer
   invocation with a clear diagnostic message describing the marker / post-marker commit
   mismatch and the recovery instruction.
3. When the watcher aborts due to post-marker commits, the watcher shall surface the diagnostic
   via the existing per-task failure path（人間がログ / Issue から原因を識別できる形式）so that
   the failure is not silently classified as a normal Reviewer reject.

### Requirement 3: Reviewer prompt の review range 明示

**Objective:** As per-task Reviewer, I want 自分が判定対象とする SHA range を明示的に受け取り、
range 外の commit を判定していないことを認識したい, so that range 漏れが起きた場合に判定結果と
実態の乖離を最小化できる。

#### Acceptance Criteria

1. When the watcher invokes the per-task Reviewer, the Reviewer prompt shall contain the
   reviewed SHA range（開始 SHA と終端 SHA）in an explicit, machine-parseable form.
2. The per-task Reviewer prompt shall include a warning that commits outside the provided SHA
   range are not being judged, so that Reviewer does not implicitly assume HEAD coverage.
3. Where the watcher detects post-marker commits and proceeds with an extended range, the
   per-task Reviewer prompt shall reflect the extended range（marker ではなく HEAD ベース等）
   instead of the original marker-bounded range.

### Requirement 4: Root と repo-template 両系統の整合

**Objective:** As idd-claude メンテナ, I want prompt / rule の更新が root（idd-claude self-hosting
用）と `repo-template/`（consumer repo 配布用）の両系統で同期されることを保証したい, so that
consumer repo に変更が届かない / idd-claude 自身が古い規約で動くドリフトを発生させない。

#### Acceptance Criteria

1. Where both root `.claude/{agents,rules}` and `repo-template/.claude/{agents,rules}` contain
   the same file path, the per-task marker contract update shall be applied to both copies
   so that `diff -r` between them remains empty after the change.
2. When prompt or rule files are added or modified for this fix, the change set shall keep root
   と `repo-template/` の対応ファイルを byte-identical に保つ。

### Requirement 5: 回帰テスト fixture

**Objective:** As 自動化基盤, I want idd-codex #14 と同型の commit 列（marker + 後続修正 commit）
に対する watcher の挙動を回帰確認できる fixture を持ちたい, so that 将来の watcher / prompt 変更で
同一 failure mode が再発した際に早期に検知できる。

#### Acceptance Criteria

1. The regression fixture shall reproduce the commit shape of「marker commit followed by one or
   more corrective commits before Reviewer invocation」, modeled after idd-codex #14.
2. When the regression fixture is exercised against the watcher's per-task range resolution,
   the test shall verify that the corrective commit is either included in the Reviewer review
   range or the watcher aborts with a diagnostic before Reviewer is invoked.
3. If the watcher silently truncates the range at the marker and excludes the corrective commit,
   the regression test shall fail.

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The per-task loop shall preserve existing env var names（`PER_TASK_LOOP_ENABLED` など）, exit
   code semantics, and log output destinations after this fix is applied.
2. The marker commit message format `docs(tasks): mark <id> as done` shall remain unchanged so
   that既存 consumer repo の git log / 既存 fixture との互換性が維持される。
3. Where existing per-task runs do not exhibit post-marker commits, the watcher shall behave
   identically to the pre-fix implementation（fix 適用前後で観測挙動が変わらない）.

### NFR 2: 観測可能性

1. When the watcher detects post-marker commits, the watcher shall emit a log line that
   identifies the marker SHA, the post-marker SHA list, and the chosen recovery action（range
   extension または abort）on stderr so that 運用者がログから failure mode を即座に切り分け
   できる。

## Out of Scope

- idd-codex #14 そのものの実装修正（別 repo であり本 Issue の scope 外）
- hitoshiichikawa/idd-claude#303 で扱う「Architect の task 分割と per-task review の test 期待値
  ずれ」（原因が異なるため別 Issue）
- Reviewer の判定カテゴリ（approve / reject の分類軸）の変更
- per-task loop の全体設計刷新（marker contract 以外のループ構造変更）
- idd-codex 固有の `.codex` prompt 更新
- per-task loop 以外の review path（Stage A / 通常 impl mode 等）の range 解決変更

## Open Questions

- 仮案・判断を委ねたい点（Issue 本文より）: 「prompt の明文化だけだと再発余地が残るため、
  Developer / Implementer prompt の強化と、watcher 側の「marker 後の未レビュー commit」検出
  安全弁の両面実装が望ましい」という方針は要件として採用してよいか。本 requirements では
  Requirement 1（prompt 契約）と Requirement 2（watcher 検出）の両方を必須として記述している
  が、watcher 側の検出を warn-only にとどめるか fail させるかの最終判断は design.md で確定する
  ものとして残す。
- watcher が post-marker commit を検出した際の recovery action として「range 拡張」「abort +
  diagnostic」のどちらを default にするかは design.md（Architect）で確定する。本 requirements
  は両方のいずれかを満たせば AC を充足する形にしている。
