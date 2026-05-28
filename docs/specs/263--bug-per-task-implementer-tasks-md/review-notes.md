# Review Notes (Round 1)

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-28T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-263-impl--bug-per-task-implementer-tasks-md
- HEAD commit: 93a6ecc109471b0971595a9a6dd8e051d8d95342
- Compared to: main..HEAD
- 差分規模: 4 files changed, +667/-4
  - `local-watcher/bin/issue-watcher.sh`: +175/-4（`pt_check_task_completed` 新規 / `pt_mark_no_progress_failed` 新規 / 4 箇所の `case "$impl*_rc" 0)` 分岐に進捗検証フック挿入）
  - `docs/specs/263--.../{requirements.md,impl-notes.md}`: spec ドキュメント
  - `docs/specs/263--.../test-fixtures/test-pt-check-task-completed.sh`: 17 ケースの fixture テスト
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節は **不在** のため opt-out（flag 観点判定は適用しない）

## Summary

`PER_TASK_LOOP_ENABLED=true` 配下で per-task Implementer が rc=0 を返したにもかかわらず対象 task の checkbox を `- [ ] → - [x]` に遷移させていないケースを検出して `claude-failed` 化する修正。`local-watcher/bin/issue-watcher.sh` 単一ファイルへの変更で完結し、4 箇所すべての rc=0 分岐（initial / blocked-redo / round2-redo / round3-redo）に検証フックが対称に挿入されている。fixture テスト 17 ケース全 pass、`shellcheck` exit 0 を再現確認した。requirements.md の全 numeric AC (1.1〜1.4, 2.1〜2.5, 3.1〜3.4, 4.1〜4.6, 5.1〜5.3, NFR 1.1〜3.1) は実装または既存ハンドラ流用で裏打ちされている。

## Verified Requirements

- **1.1** — `pt_check_task_completed` (issue-watcher.sh:2227-2252) が `- [x]` / `- [ ]` を grep で判定。fixture 17 ケースで遷移検証
- **1.2** — `PER_TASK_LOOP_ENABLED` 未設定 / `true` 以外時に `run_per_task_loop` 自体が呼ばれない既存 dispatcher 経路は無修正（構造的 skip）
- **1.3** — 4 箇所の rc=0 分岐すべてに検証フック挿入を diff で確認: initial (3040-3056), blocked-redo (3112-3125), round2-redo (3154-3167), round3-redo (3213-3228)
- **1.4** — rc=99 / 非 0 分岐は diff で変更なし。検証フックは `0)` 分岐内に閉じている
- **2.1, 2.2** — `pt_mark_no_progress_failed` が `mark_issue_failed "per-task-implementer-no-progress" ...` を呼出。`mark_issue_failed` (issue-watcher.sh:4713-4714) で claude-claimed / claude-picked-up 除去 + claude-failed 付与
- **2.3, 2.4** — 4 箇所すべてで helper 呼出後 `return 1` により per-task ループ即時打ち切り。後続 Reviewer / PR / ready-for-review に到達しない
- **2.5** — 1 つの rc=0 case 分岐内で `pt_mark_no_progress_failed` を高々 1 回呼出 + 即 `return 1`
- **3.1** — `_pt_check_rc=0`（完了）ケースは検証フック内で何もせず既存続行経路に流れる
- **3.2** — 検証フックは rc=0 分岐内に閉じており、Reviewer / Debugger Gate / Stage A 完了ゲートの判定ロジックに変更なし
- **3.3** — `pt_check_task_completed` の判定パターン `^- \[[ x]\] <id>\.? ` は `- [ ]*` deferrable を「`\[ \]` 直後の空白要求」で除外。fixture でも rc=2 と確認
- **3.4** — 判定単位は単一 task_id 引数のみで他 task に依存しない
- **4.1** — Issue コメント本文に `対象 task ID: \`${task_id}\`` を含む (issue-watcher.sh:2972)
- **4.2** — 「rc=0 で終了したが `- [ ]` → `- [x]` 遷移が確認できなかった」旨を本文に記載 (2979-2980)
- **4.3** — 「自動再開を停止しました」+ `ログ: \`$LOG\`` の参照を含む (2974, 2982-2983)
- **4.4** — `pt_log "task=${task_id} implementer end rc=0 progress=zero phase=${stage_phase} check_rc=${check_rc} → claude-failed (per-task-implementer-no-progress)"` (2992) で grep 可能
- **4.5** — 本文に「## 次の手順」セクション + `mark_issue_failed` 末尾の `build_recovery_hint` 流用
- **4.6** — 新規 stage 識別子 `per-task-implementer-no-progress` を `mark_issue_failed` 第 1 引数で渡す (2994)
- **5.1** — 各 rc=0 分岐で `pt_check_task_completed` 1 回呼出 + `pt_mark_no_progress_failed` 1 回呼出
- **5.2** — 既存 `claude-failed` ラベル除外条件は無修正のため、再 pickup されない既存挙動を継承
- **5.3** — `pt_check_task_completed` rc=2（tasks.md 不在 / 該当行不在）も `pt_mark_no_progress_failed` 経路に乗せる fail-safe 設計。fixture で確認
- **NFR 1.1** — `PER_TASK_LOOP_ENABLED` 無効時は `run_per_task_loop` が呼ばれず本機能のコードは 1 行も実行されない
- **NFR 1.2** — `mark_issue_failed` を引数違いで呼ぶのみ。失敗ハンドラの挙動変更なし
- **NFR 1.3** — Reviewer reject / Debugger Gate / Stage A 完了ゲートの判定ロジックは無修正
- **NFR 2.1** — 既存識別子 `per-task-implementer-failed` 等と異なる新規識別子で区別可能
- **NFR 2.2** — `pt_log "task=<id> implementer end rc=0 progress=zero ..."` で既存書式 (`task=<id> implementer end ...`) と整合
- **NFR 3.1** — `pt_check_task_completed` 内 grep 高々 2 回（`- [x]` ヒット時は 1 回で終了）

## Findings

### AC 未カバー

なし。requirements.md の全 numeric AC を実装または既存ハンドラ流用でカバー済み。

### Missing Test

なし。

- AC 1.1 / 5.3 / 3.3 は新規 fixture `test-pt-check-task-completed.sh` の 17 ケース全 pass で検証済（reviewer 再実行で `PASS=17 FAIL=0` 確認）
- AC 1.2 / 1.3 / 1.4 / 3.1 / 3.2 / NFR 1.x は構造的・コードレビュー担保（rc=0 分岐限定で挿入したため diff の範囲が証拠）
- AC 2.x / 4.x は `mark_issue_failed` 既存挙動の流用（NFR 1.2 規定）で既存ハンドラのカバレッジを継承

### Boundary 逸脱

なし。

- 本 Issue は design-less impl（`tasks.md` 不在）であり明示的 `_Boundary:_` 宣言は存在しないが、変更範囲は per-task ループの所有モジュール `local-watcher/bin/issue-watcher.sh` 1 ファイル + spec 文書 + 新規 fixture テストに収まっている
- 既存 env var 名 / cron 登録文字列 / exit code 意味 / ラベル遷移契約はすべて無修正（impl-notes 後方互換性節と一致）
- `repo-template/.claude/` 配下 / README / `idd-claude-labels.sh` 等への波及なし

## Verdict Rationale

全 numeric AC（1.1〜1.4, 2.1〜2.5, 3.1〜3.4, 4.1〜4.6, 5.1〜5.3, NFR 1.1〜3.1）が実装・既存ハンドラ流用・fixture テストのいずれかで裏打ちされており、4 箇所の rc=0 分岐すべてに検証フックが対称に挿入されている。`shellcheck` クリーン / fixture 17 ケース全 pass を reviewer 自身で再実行確認した。境界逸脱・missing test・AC 未カバーのいずれも検出されないため approve。

RESULT: approve
