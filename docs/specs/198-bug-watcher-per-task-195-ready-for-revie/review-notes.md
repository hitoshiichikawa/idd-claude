# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T10:51:27Z -->

## Reviewed Scope

- Branch: claude/issue-198-impl-bug-watcher-per-task-195-ready-for-revie
- HEAD commit: 88218e40efcf6f479e60ba6bd16036963cf0299d
- Compared to: main..HEAD

差分は 5 ファイル（+440/-3）。コア実装は `local-watcher/bin/issue-watcher.sh` の
`run_impl_pipeline()` 内 per-task 全 task 完了ゲート保留分岐（9192-9224 行）へのラベル除去追加。
付随して README.md（挙動同期）、新規スモーク `test-pt-hold-relabel.sh`、impl-notes.md、
requirements.md の取り込み。tasks.md / design.md は本 spec ディレクトリに存在しない
（Architect 不要 triage を通過した bug fix のため `_Boundary:_` アノテーションは無し）。
CLAUDE.md に `## Feature Flag Protocol` 節は存在しないため opt-out 扱いとし、flag 観点の判定は
適用しない。

## Verified Requirements

- 1.1 — issue-watcher.sh:9215-9217 で保留時に `--remove-label "$LABEL_PICKED"` を実行。
  dispatcher 候補クエリ（issue-watcher.sh:11587 の `-label:"$LABEL_PICKED"` 除外）から外れていた
  Issue が再選択候補に戻る。test-pt-hold-relabel.sh Case 1（hold-resumable + remove-label 呼出）で検証
- 1.2 — ラベル除去で bare auto-dev candidate 化 → 次 tick で mode 判定が既存 spec/branch を検出し
  impl-resume を起動。既存 dispatcher / impl-resume 機構へ委譲（impl-notes.md 設計判断に明記）。
  observable な「再選択可能状態」への遷移は実装で担保
- 1.3 — 全 task 完了時は保留分岐（issue-watcher.sh:9187 `if [ -n "$_pt_remaining" ]`）に入らず
  9226 行以降の既存 Stage A 完了後フロー（verify → Reviewer → PR → ready-for-review）へ進む。
  test Case 2 / #194 回帰スモークで検証
- 1.4 — ラベル除去で運用者の手動操作なしに後続 tick 再開可能状態へ遷移。test Case 1 / Case 4
  （gh edit 失敗時も hold-resumable 維持）で検証
- 1.5 — deferrable（`- [ ]*`）は `pt_extract_pending_tasks`（regex `^- \[ \] [0-9]`）で未完了に
  数えない。test Case 3 / #194 回帰スモークで検証
- 2.1 — 完了済み `- [x]` task の再実行禁止は既存 impl-resume skip 機構に委譲、本修正で変更なし
  （impl-notes.md 設計判断に明記）。ゲート判定ロジックを触っていないため担保
- 2.2 — 保留分岐は毎 tick 再評価され、再開後も必須未完了が残れば再び hold-resumable で `return 0`。
  ゲート判定不変。#194 回帰スモークの hold-resumable ケースで担保
- 2.3 — quota 再中断は `qa_handle_quota_exceeded` の別経路（`needs-quota-wait` 付与）で本保留と独立。
  ゲート判定不変のため ready-for-review へ進めず維持
- 2.4 — 変更は「保留時のラベル除去」一点のみ。#195 ゲート判定（pt_extract_pending_tasks /
  deferrable 除外 / return 0）は不変。#194 回帰スモーク全 pass で担保
- 3.1 — 本保留は `needs-quota-wait` を一切付与しない。quota 待機中 Issue は候補クエリ
  （issue-watcher.sh:11587 の `-label:"$LABEL_NEEDS_QUOTA_WAIT"` 除外）で引き続き除外され、
  reset 前の再選択は起きない
- 3.2 — 本保留はラベル除去のみで `needs-quota-wait` 非関与 → quota processor 走査対象
  （needs-quota-wait のみ）に乗らず同一 tick 二重処理は構造的に起きない。test Case 1
  （needs-quota-wait 不付与の assert）で検証
- 3.3 — `qa_handle_quota_exceeded` / `process_quota_resume` に変更なし（diff に含まれない）
- NFR 1.1 — 変更は `_pt_loop_enabled=true` 分岐内のみ。PER_TASK_LOOP 無効時の else ブランチ
  （issue-watcher.sh:9243-）は不変。通常 Developer 経路を維持
- NFR 1.2 — 変更箇所に env var の追加・改名なし（既存定数 `$LABEL_PICKED` / `$LABEL_CLAIMED` を参照）
- NFR 1.3 — ラベル名の新設・改名なし。既存ラベル定数（issue-watcher.sh:60-61）を参照するのみ
- NFR 1.4 — `return 0`（resumable）を維持。exit code 意味の変更なし
- NFR 1.5 — 全 task 完了の正常ケースは保留分岐に入らず gh edit を呼ばない。test Case 2 で検証
- NFR 2.1 — issue-watcher.sh:9190/9218/9222 で Issue 番号・未完了件数・保留理由・ラベル除去事実を
  `pt_log ... | tee -a "$LOG"` で grep 可能形式に記録（pt_warn は stderr のため tee で別途残す）
- NFR 2.2 — 再開発生の判別は既存 dispatcher pickup ログ + 本ラベル除去ログ（9218 行）で可能
- NFR 3.1 — ラベル除去 → 再 pickup → impl-resume → 1 task 消化の循環で進捗保証。full loop の
  E2E は dogfooding 委ねだが、本スコープの「再 pickup 可能化」ラベル除去はスモークで担保
  （impl-notes.md 確認事項に E2E 担保境界を明示）

## Findings

なし

## Summary

全 numeric AC（Req 1.1-1.5 / 2.1-2.4 / 3.1-3.3 / NFR 1.1-1.5 / 2.1-2.2 / 3.1）が実装と
スモークテストでカバーされている。変更は PM 推奨の案 1（保留時の `claude-picked-up` 除去）に
沿う最小変更で、`_pt_loop_enabled=true` 分岐内に限定され後方互換性（env var 名・ラベル名・
exit code・冪等性・#195 ゲート判定）を破壊しない。新規スモーク（SMOKE_RESULT: pass）と #194
回帰スモーク（SMOKE_RESULT: pass）を再実行し green を確認。shellcheck は HEAD 39 件 =
main baseline 39 件で新規警告ゼロ。AC 未カバー / missing test / boundary 逸脱はいずれも無し。

RESULT: approve
