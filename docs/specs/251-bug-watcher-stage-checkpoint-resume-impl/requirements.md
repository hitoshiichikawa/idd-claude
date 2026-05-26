# Requirements Document

## Introduction

Stage Checkpoint resume (#68) は impl 系パイプラインの再開時に、各 Stage の checkpoint 成果物
（`impl-notes.md` / `review-notes.md` / 既存 impl PR）を観測して `START_STAGE` を 1 つに決定し、
完了済み Stage の再実行を避ける機能である。現在 `impl-notes.md` が当該 branch HEAD で tracked
であれば「Stage A 完了」とみなし、`tasks.md` に必須タスクが残っていても Stage A（per-task ループ）
を skip して `START_STAGE=B`（Reviewer から再実行）を選んでしまう。

per-task ループ (#21) は task 完了ごとに `impl-notes.md` を commit するため、task 1 完了時点で
`impl-notes.md` が tracked になる。その結果、残タスクがあるのに次サイクル以降は Stage A が常に
skip され、per-task ループが二度と起動せず残タスクが永久に消化されない。後続タスクが生成する
成果物（test fixture 等）に依存する stage-a-verify ブロックは永遠に失敗し、round=1 ループ (#246)
と相まって churn する。本要件は、Stage A を skip する前に `tasks.md` の残必須タスクを確認し、
残っていれば per-task ループを再開させることで partial impl を完走可能にする。

## Requirements

### Requirement 1: 残必須タスクがある場合の Stage A 再開

**Objective:** As an idd-claude 運用者, I want per-task impl が中断後も残必須タスクを確実に消化できること, so that partial impl が後続サイクルで完走でき churn が止まる

#### Acceptance Criteria

1. While `tasks.md` に必須タスク（deferrable `- [ ]*` を除く `- [ ]`）が 1 件以上残っている場合, the Stage Checkpoint resume shall `impl-notes.md` が tracked であっても `START_STAGE=A` を選ぶ
2. When 必須タスクが残存し `START_STAGE=A` が選ばれた場合, the Stage Checkpoint resume shall per-task ループを再開させる経路（Stage A 実行）へ制御を渡す
3. While 必須タスクが残存し `START_STAGE=A` が選ばれた場合, the Stage Checkpoint resume shall `impl-notes.md` の tracked 有無に関わらず残タスク判定を優先する

### Requirement 2: 全タスク完了時の従来 Stage A skip 維持

**Objective:** As an idd-claude 運用者, I want 全タスク完了済みの impl は従来どおり Reviewer から再開されること, so that 完了済み Stage A を不要に再実行しない既存の効率が保たれる

#### Acceptance Criteria

1. When `tasks.md` の必須タスク（deferrable `- [ ]*` を除く `- [ ]`）が 0 件かつ `impl-notes.md` が tracked かつ `review-notes.md` が不在または解釈不能の場合, the Stage Checkpoint resume shall 従来どおり `START_STAGE=B` を選ぶ
2. When `tasks.md` の必須タスクが 0 件かつ `review-notes.md` の RESULT が `approve` の場合, the Stage Checkpoint resume shall 従来どおり `START_STAGE=C` を選ぶ

### Requirement 3: 介入対象分岐の限定

**Objective:** As an idd-claude 運用者, I want 残タスク確認の介入を impl-notes 有 / review-notes 無（rev_rc=2）の B 分岐に限定すること, so that approve / reject 系の既存判定や TERMINAL_FAILED 契約と衝突しない

#### Acceptance Criteria

1. Where `review-notes.md` の RESULT が `approve` の場合, the Stage Checkpoint resume shall 残必須タスクの有無に関わらず `START_STAGE=C` 判定を変更しない
2. Where `review-notes.md` の RESULT が `reject` かつ round=2 と判定される場合, the Stage Checkpoint resume shall 残必須タスクの有無に関わらず `START_STAGE=TERMINAL_FAILED` 判定を変更しない
3. Where `review-notes.md` の RESULT が `reject` かつ round=1 または round 不明と判定される場合, the Stage Checkpoint resume shall 既存どおり `START_STAGE=A` を選ぶ（残タスク確認の追加介入なしで結果が一致する）
4. The Stage Checkpoint resume shall 残必須タスク確認を impl-notes 有かつ review-notes 不在または解釈不能（従来 `START_STAGE=B` となる）分岐に限って適用し、それ以外の分岐の判定ロジックを変更しない

### Requirement 4: tasks.md 不在（design-less impl）の後方互換

**Objective:** As an idd-claude 運用者, I want tasks.md を持たない design-less impl の挙動が変わらないこと, so that per-task ループを使わない既存ワークフローが影響を受けない

#### Acceptance Criteria

1. Where `tasks.md` が存在しない（design-less impl）場合, the Stage Checkpoint resume shall 残必須タスク判定を行わず従来の `impl-notes.md` ベース判定を維持する
2. When `tasks.md` が存在せず `impl-notes.md` が tracked かつ `review-notes.md` が不在または解釈不能の場合, the Stage Checkpoint resume shall 従来どおり `START_STAGE=B` を選ぶ

### Requirement 5: 判定根拠の可観測性

**Objective:** As an idd-claude 運用者, I want 残タスク確認による判定分岐がログから追跡できること, so that resume が想定どおり Stage A を選んだか機械抽出で検証できる

#### Acceptance Criteria

1. When 残必須タスクが残存し `START_STAGE=A` を選んだ場合, the Stage Checkpoint resume shall `stage-checkpoint:` prefix で残必須タスクを理由とする判定根拠を 1 行以上ログに出力する
2. The Stage Checkpoint resume shall 残必須タスク件数を含む判定根拠を `grep stage-checkpoint` で機械抽出できる形式で出力する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `STAGE_CHECKPOINT_ENABLED=false` が明示指定された場合, the Stage Checkpoint resume shall 本要件導入前と完全に同一の挙動を維持する（残タスク判定を一切行わない）
2. The Stage Checkpoint resume shall 既存の env var 名（`STAGE_CHECKPOINT_ENABLED` / `SPEC_DIR_REL` / `REPO_DIR` 等）を変更せず新規 env var を追加せずに本判定を実現する
3. The Stage Checkpoint resume shall 既存のラベル遷移契約・exit code の意味・`stage-checkpoint:` ログ書式を変更しない
4. When 必須タスクが 0 件の per-task impl または design-less impl を再開した場合, the Stage Checkpoint resume shall 本要件導入前と同一の `START_STAGE` を返す

### NFR 2: 冪等性

1. When 同一 branch HEAD・同一 `tasks.md` 状態に対して resume 判定を複数回実行した場合, the Stage Checkpoint resume shall 毎回同一の `START_STAGE` を返す
2. The Stage Checkpoint resume shall 残必須タスク判定の過程で `tasks.md` / `impl-notes.md` / 当該 branch に対する破壊的副作用（編集・commit・push・ラベル変更）を行わない

### NFR 3: 堅牢性

1. If 残必須タスク抽出処理が内部エラーで失敗した場合, the Stage Checkpoint resume shall 安全側として `START_STAGE=A`（Stage A 再実行）へフォールバックする
2. The Stage Checkpoint resume shall 残必須タスク抽出に既存の deferrable 除外規約（`- [ ]*` を必須タスクとして数えない）を適用する

## Out of Scope

- per-task 全 task 完了ゲート (#194) 自体の挙動変更（本要件は resume 時の Stage A 選択のみを対象とし、ループ内の完了判定や ready-for-review 遷移ロジックは変更しない）
- stage-a-verify gate (#125) / round=1 ループ (#246) のロジック修正（残タスク完走により stage-a-verify の churn は副次的に解消するが、これらの gate 自体は本要件の修正対象ではない）
- `tasks.md` のタスク抽出規約（deferrable 印 `- [ ]*` の扱い、numeric 階層 ID 認識）の変更
- design-less impl（tasks.md 不在）に対する新たな verify / 完了判定の導入
- review-notes が approve / reject を持つ Stage B/C 完了側分岐への残タスク確認の適用（Req 3 で明示的に対象外とする）
- 既存 impl PR が存在する TERMINAL_OK 分岐の挙動変更

## Open Questions

- なし（Issue 本文および提案修正方針により、介入対象を「impl-notes 有 / review-notes 無（rev_rc=2）の B 分岐」に限定する scope が確定しているため、要件として Req 3 で明示した。review-notes が approve/reject を持つケースへの適用は Out of Scope として除外済み）
