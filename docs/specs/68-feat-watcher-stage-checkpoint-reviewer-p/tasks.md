# Implementation Plan

各タスクは独立した 1 commit 単位。`STAGE_CHECKPOINT_ENABLED=false`（既定）で
旧挙動が維持されることを各タスクの完了条件に含めること。

- [ ] 1. Config 拡張: `STAGE_CHECKPOINT_ENABLED` env var 追加
- [ ] 1.1 `local-watcher/bin/issue-watcher.sh` の Config ブロックに `STAGE_CHECKPOINT_ENABLED="${STAGE_CHECKPOINT_ENABLED:-false}"` を追加（既存 `PR_ITERATION_ENABLED` の近傍に配置）
  - ヘッダ冒頭コメントの状態機械説明（L1〜L24 周辺）に「checkpoint resume 経路」を 1 段落で追記
  - `bash -n` / `shellcheck` で警告ゼロを維持
  - **完了条件**: env 未設定で起動して旧挙動と完全一致（dry run）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, NFR 1.1, NFR 4.1_

- [ ] 2. Stage Checkpoint Module（観測関数群）の実装
- [ ] 2.1 ロガー `sc_log` / `sc_warn` / `sc_error` を追加 (P)
  - `mq_log` / `pi_log` と同じ命名・形式 (`stage-checkpoint:` prefix、stderr 分離)
  - _Requirements: NFR 2.1, NFR 2.2, 5.3_
  - _Boundary: Stage Checkpoint Module_
- [ ] 2.2 `stage_checkpoint_has_impl_notes` を追加 (P)
  - `git ls-tree --name-only HEAD -- $SPEC_DIR_REL/impl-notes.md` で branch HEAD tracked 判定
  - working tree のみの未 commit ファイルは不採用
  - _Requirements: 1.1, 4.1, 4.2, 4.4_
  - _Boundary: Stage Checkpoint Module_
- [ ] 2.3 `stage_checkpoint_read_review_result` を追加 (P)
  - 既存 `parse_review_result` を再利用（契約変更しない）
  - branch HEAD tracked チェックを先行
  - 戻り値: 0 = approve / 1 = reject / 2 = 不在 or 欠落、stdout は parse_review_result の TSV 形式を踏襲
  - _Requirements: 1.2, 4.3, 4.4_
  - _Boundary: Stage Checkpoint Module_
- [ ] 2.4 `stage_checkpoint_find_impl_pr` を追加 (P)
  - `gh pr list --repo $REPO --head $BRANCH --state all --json number,state` で OPEN/MERGED/CLOSED 検出
  - 戻り値: 0 = 既存あり / 1 = なし / 2 = gh API エラー
  - _Requirements: 1.3, 2.6_
  - _Boundary: Stage Checkpoint Module_

- [ ] 3. `stage_checkpoint_resolve_resume_point` の実装
- [ ] 3.1 decision table をコード化し `START_STAGE` を確定する関数を追加
  - 評価順: TERMINAL_OK（既存 PR）→ INCONSISTENT 検出 → A/B/C 判定 → TERMINAL_FAILED
  - round=1 reject vs round=2 reject は review-notes.md 内 `<!-- idd-claude:review round=N -->` で判別（D-3）
  - 1 ログブロックで input/output を出力（NFR 2.1）
  - 内部エラー時は return 1 + safe fallback `START_STAGE="A"`
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 5.1, 5.3, 5.4, NFR 2.1, NFR 2.2_
  - _Boundary: Stage Checkpoint Module_
  - _Depends: 2.1, 2.2, 2.3, 2.4_

- [ ] 4. `run_impl_pipeline` への skip ガード組み込み
- [ ] 4.1 関数冒頭で `STAGE_CHECKPOINT_ENABLED=true` のときのみ resolve を呼び `START_STAGE` を取得
  - TERMINAL_OK → `return 0`（自動進行停止、ラベル不変）
  - TERMINAL_FAILED → 既存 `mark_issue_failed "stage-checkpoint-terminal-failed" "..."` で claude-failed 化
  - Stage A / Stage B / Stage C の各既存ブロックを `case "$START_STAGE"` で skip 制御
  - flag false / 未設定では関数の挙動が 1 行も変わらないこと（外形的同一性）
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 3.2, 3.3, 5.2, 5.4, NFR 1.1, NFR 3.1, NFR 3.2_
  - _Boundary: Reviewer Stage Pipeline (run_impl_pipeline)_
  - _Depends: 3.1_

- [ ] 5. ドキュメント更新
- [ ] 5.1 `README.md` の opt-in 一覧に `STAGE_CHECKPOINT_ENABLED` 行を追加 (P)
  - 表（L598 周辺）に行追加 / 既定値 false / 期待される効果
  - cron 例（L622 / L932 / L1184 等）は **書き換えず**、新規例として「全機能有効化例」末尾に追加するか節を分ける
  - _Requirements: 6.1, 6.3, NFR 1.2_
  - _Boundary: README.md_
- [ ] 5.2 `README.md` に新セクション `### Stage Checkpoint (#68)` を追加 (P)
  - Stage A / B / C と checkpoint の対応表
  - 再開判定の decision table（design.md と同期）
  - `STAGE_CHECKPOINT_ENABLED=false` 時の挙動（旧挙動と完全一致）
  - 限界・既知 Risk（手動編集を採用しない設計、round=N 残骸処理）の明示
  - _Requirements: 6.2, 6.3_
  - _Boundary: README.md_

- [ ]* 6. 手動スモークテスト実施結果を impl-notes.md に記録
  - design.md「Testing Strategy」のシナリオ 1〜7 の実行結果を `impl-notes.md` に列挙
  - dogfooding（シナリオ 8）と PARALLEL_SLOTS 共存（シナリオ 9）も実施し記録
  - NFR 3.1 / 3.2 の token 削減効果を `claude --print` 呼び出し回数で記録（シナリオ 10, 11）
  - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 4.3, 5.1, NFR 1.1, NFR 3.1, NFR 3.2, NFR 4.1_
