# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-251-impl-bug-watcher-stage-checkpoint-resume-impl
- HEAD commit: 14d20def52d6ac1a4ac2ca2f7e9b20711e576ecb
- Compared to: main..HEAD

本 Issue は design-less impl（`design.md` / `tasks.md` は本 spec dir に不在）。CLAUDE.md に
`## Feature Flag Protocol` 節が存在しないため opt-out 扱いとし、通常の 3 カテゴリ判定のみを実施。

## Verified Requirements

- 1.1 — issue-watcher.sh:1241-1246（rev_rc=2 分岐で残必須タスク 1 件以上 → `START_STAGE=A`）。テスト Case1（impl有/review無/残必須2件 → A）
- 1.2 — issue-watcher.sh:4796-4815（`case "$START_STAGE" in A)` → `run_per_task_loop` へ制御を渡す既存経路）。START_STAGE=A 解決で per-task ループ再開
- 1.3 — issue-watcher.sh:1224-1246（rev_rc=2 内で tracked 有無に依らず `[ -f tasks.md ]` → 残タスク抽出を先に評価し優先）。Case1
- 2.1 — issue-watcher.sh:1249-1250（残必須 0 件 → `START_STAGE=B` + reason 据え置き）。テスト Case2 + reason 維持ログアサート
- 2.2 — issue-watcher.sh:1254-1257（approve → `START_STAGE=C`、既存ロジック不変）。テスト Case5
- 3.1 — issue-watcher.sh:1254-1257（rev_rc=0 分岐未変更）。テスト Case5（approve は残必須あっても C）
- 3.2 — issue-watcher.sh:1259-1265（reject round=2 → TERMINAL_FAILED、未変更）。テスト Case6
- 3.3 — issue-watcher.sh:1266-1270（reject round=1 → A、未変更）。テスト Case7
- 3.4 — 介入は rev_rc=2 分岐に限定（diff 上 rev_rc=0 / rev_rc=1 分岐は無変更）。Case5/6/7 で他分岐不変を確認
- 4.1 — issue-watcher.sh:1223-1227（`[ ! -f tasks.md ]` → 残タスク判定スキップし従来 B）。テスト Case3
- 4.2 — 同上（design-less impl で従来どおり `START_STAGE=B`）。テスト Case3
- 5.1 — issue-watcher.sh:1246（`sc_log "decision: START_STAGE=A reason=pending-tasks-remain count=$sc_pending_count"`、`stage-checkpoint:` prefix）。テスト Case1 ログアサート
- 5.2 — 同上（`count=N` を含み `grep stage-checkpoint` で機械抽出可能）。テスト Case1 ログアサート（`count=2` 一致）
- NFR1.1 — issue-watcher.sh:4767（`STAGE_CHECKPOINT_ENABLED != true` 時は resolve をスキップ、START_STAGE=A 維持）
- NFR1.2 — diff 上で新規 env var 追加なし（既存 `REPO_DIR` / `SPEC_DIR_REL` のみ使用）
- NFR1.3 — `stage-checkpoint:` ログ書式 / exit code / ラベル遷移契約を変更せず（既存 reason 文字列を据え置き）
- NFR1.4 — 全完了 per-task impl（Case2）/ design-less impl（Case3）で従来同一 START_STAGE
- NFR2.1 — テスト Case8（同一 HEAD で 3 回呼び同一 START_STAGE=A）
- NFR2.2 — テスト Case9（resolve 前後で HEAD / ファイル sha1 / git status 不変。read-only 判定）
- NFR3.1 — issue-watcher.sh:1233-1239（抽出 rc≠0 で安全側 `START_STAGE=A` フォールバック）。`[ -f ]` 先行分離で tasks.md 不在の return 1 は Case3 の B に分離
- NFR3.2 — `pt_extract_pending_tasks`（issue-watcher.sh:2192-2204）が deferrable `- [ ]*` を除外。テスト Case4

## Findings

なし

## Summary

design-less impl の rev_rc=2（impl-notes 有 / review-notes 無）分岐に限定して残必須タスク
確認を追加し、残っていれば `START_STAGE=A` で per-task ループを再開する修正。全 numeric ID
（Req 1-5 / NFR 1-3）が実装とスモークテスト（全 11 アサーション pass）でカバーされ、approve/reject
系の既存判定・design-less 後方互換・冪等性・副作用ゼロも担保。shellcheck クリーン、README の
二重管理も同一 PR で更新済み。boundary 逸脱・AC 未カバー・missing test いずれも無し。

RESULT: approve
