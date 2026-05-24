# Requirements Document

## Introduction

per-task ループモード（`PER_TASK_LOOP_ENABLED=true`）では、`run_per_task_loop` の dispatcher が
未完了 task を逐次消化する。しかし dispatcher の戻り値 0 は「全 task 消化成功」と「中間で quota
超過等により早期 return した状態」の両方を含むため、呼び出し側はこれを一律「Stage A 完了」とみなし、
後続の Reviewer → PR 作成 + `ready-for-review` 付与まで進めてしまう。結果として tasks.md の後続 task が
未完了（`[ ]`）のまま PR が ready-for-review 化され、main がビルド/実行不能な中間状態のまま merge され得る。
実際に Issue #177 Part 1（PR #189）で task 1 のみ完了の状態で merge され、main の watcher が機能停止した
（復旧は #193）。本要件は、per-task ループにおいて「tasks.md の必須 task が全て完了するまで PR を
ready-for-review へ遷移させない」ことを中核とし、per-task ループ無効時の通常フローへの非干渉を保証する。

## Requirements

### Requirement 1: per-task ループの全 task 完了判定

**Objective:** As a 運用者, I want per-task ループが tasks.md の必須 task を全て完了させた場合のみ PR を ready-for-review 化すること, so that 後続 task 未完で main がビルド/実行不能になる中間状態のまま merge される事故を防げる

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED=true` の per-task ループ実行中, when tasks.md の必須 task に未完了（`[ ]`）が 1 件以上残った状態でループが終了したとき, the Watcher shall 当該 Issue の PR を `ready-for-review` ラベルへ遷移させない
2. While `PER_TASK_LOOP_ENABLED=true` の per-task ループ実行中, when tasks.md の必須 task が全て完了（`[x]`）した状態でループが終了したとき, the Watcher shall 既存の Stage A 完了後フロー（Reviewer 起動・PR 作成・`ready-for-review` 付与）へ進む
3. The per-task loop 完了判定 shall deferrable テストタスク（`- [ ]*` 表記）を未完了 task として扱わず、必須 task の充足のみで全 task 完了とみなす
4. If per-task ループが quota 超過等により必須 task を残したまま早期に処理を中断したとき, the Watcher shall 当該回の処理を `ready-for-review` へ進めず、未完了状態として後続 tick での再開対象とする
5. When 必須 task に未完了が残った状態で per-task ループが終了したとき, the Watcher shall 未完了 task が残存している旨と件数を運用ログへ記録する

### Requirement 2: per-task ループ無効時の後方互換性

**Objective:** As a 既存運用者, I want per-task ループ無効時の通常フローが本修正の影響を一切受けないこと, so that 既存の cron / launchd 運用と consumer repo を壊さずに defect 修正を取り込める

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED` が未設定または `false`（既定）, the Watcher shall 本修正導入前と同一の Stage A → Reviewer → PR 作成 + `ready-for-review` フローを実行する
2. The Watcher shall 本修正の前後で既存環境変数名（`PER_TASK_LOOP_ENABLED`, `PER_TASK_MAX_TASKS`, `REPO`, `REPO_DIR` ほか）の名称と意味を変更しない
3. The Watcher shall 本修正の前後で `ready-for-review` を含む既存ラベルの名称とラベル遷移契約を変更しない
4. The Watcher shall 本修正の前後で既存の exit code の意味（成功/失敗/quota 待ち等）を変更しない
5. While `PER_TASK_LOOP_ENABLED=true` かつ tasks.md の必須 task が全て完了している正常ケース, the Watcher shall 本修正導入前と同一の `ready-for-review` 付与挙動を保つ

## Non-Functional Requirements

### NFR 1: 可観測性

1. When per-task ループが必須 task 未完了のため `ready-for-review` 遷移を保留したとき, the Watcher shall 保留理由（未完了 task 残存）と当該 Issue 番号を運用ログ（`$LOG`）から判別可能な形で記録する

### NFR 2: 冪等性

1. While `PER_TASK_LOOP_ENABLED=true` で必須 task が未完了のまま中断した Issue, when 後続 tick で再度処理対象になったとき, the Watcher shall 既に完了済みの task を再実行せず未完了 task のみを消化する（既存の per-task ループ resume 挙動を変更しない）

## Out of Scope

- 受入観点 #2「各 task は main を壊さない粒度」の **設計段階での強制**（task 統合や `_Depends:_` 連結による中間 merge 防止）。これは Architect / tasks 生成ルールの領分であり、本 Issue の実装 AC には含めない（確認事項参照）。
- 受入観点 #3「Reviewer ゲートの責務見直し」。中間状態 build 破壊を Reviewer が approve すべきか否かの判断基準変更・Reviewer 定義変更は本 Issue では行わない（確認事項参照）。
- 受入観点 #4「マージ側ガード（CI / ラベルによる incomplete task 残存時の merge 防止）」。Issue 本文で「任意」とされており、本 Issue では実装しない（確認事項参照）。
- tasks.md の必須 task / deferrable task の表記規約自体の変更（`tasks-generation.md` の既存規約に従う）。
- PR #189 で破壊された main の復旧（#193 で対応済み）。

## Open Questions

- 受入観点 #2・#3・#4 を本 Issue の Out of Scope（Non-Goal）として確定してよいか、それとも別 Issue として起票すべきか。本 Issue 本文では #2 が「強制」、#3 が「確認」、#4 が「任意」と温度差があり、PM は中核を #1 + #5（後方互換）に絞ることが妥当と判断したが、#2・#3・#4 の扱い（Non-Goal 確定 / 別 Issue 起票）の最終確定は人間判断を仰ぎたい。
- 「必須 task」の判定境界について、deferrable は `- [ ]*` 表記のみを対象とする前提でよいか（`tasks-generation.md` の規約に整合する想定だが、別の deferrable 表記運用があれば要確認）。
