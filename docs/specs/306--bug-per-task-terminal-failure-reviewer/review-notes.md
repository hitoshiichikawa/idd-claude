# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-09T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-306-impl--bug-per-task-terminal-failure-reviewer
- HEAD commit: a468b4fabc292b2a436a28cdb18b26b8a78a46d8
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `publish_terminal_failure_artifacts` ヘルパー（`local-watcher/bin/issue-watcher.sh`）が 5 経路（reject2 / reject3 / reviewer-error / reviewer-missing-file / debugger-notes-invalid）で `mark_issue_failed` 直前に diagnostic commit 試行と本文埋め込みの両方を実施。テスト Case 1（commit push 成功） / Case 3（埋め込み fallback）で担保
- 1.2 — tracked + pushed artifact 状態で `_need_commit` フラグが立たず diagnostic commit を実施しない。テスト Case 2 で bare repo の commit 数不変 + status `tracked-pushed` 表示を assert
- 1.3 — `_ptfa_artifact_status` が untracked / modified / tracked-unpushed を検出して `_need_commit=1` を設定。テスト Case 1 / Case 3 で担保
- 1.4 — `_commit_pushed != 1` 時の fallback ブロックが artifact 本文を `artifact_embed` に埋め込む。テスト Case 3 で push 失敗時の marker 埋め込みを assert
- 1.5 — 全分岐の最後に必ず `mark_issue_failed "$stage" "$merged_body"` を呼ぶ。テスト Case 1〜6 全てで MARK_FAILED_CALL_COUNT=1 を assert
- 2.1 — `push_state_block` が branch / local HEAD / origin HEAD / ahead count / worktree path を全て埋め込む。テスト Case 1 で全項目の存在を assert
- 2.2 — artifact 毎に `_ptfa_artifact_status` の戻り値を `artifact_lines` として出力。テスト Case 1（untracked → committed） / Case 2（tracked-pushed）で担保
- 2.3 — `origin_head="未 push"` 初期値と BASE_BRANCH..HEAD からの ahead count 算出。テスト Case 4 で `origin_head=未 push` の LOG 記録を assert
- 2.4 — 同一 `publish_terminal_failure_artifacts` ヘルパーを 5 経路で共有することでフォーマット統一を構造的に担保
- 3.1 / 3.2 — `.claude/agents/reviewer.md` / `.claude/agents/debugger.md` への変更なし（diff stat で確認済み）。git 権限付与なし
- 3.3 — `publish_terminal_failure_artifacts` は watcher 側コードで、サブエージェント return 後に呼ばれる（call site は per-task ループ内）
- 3.4 — diff 内に `git reset` / `git rebase` / `--force` の追加なし（コメント文の「使わない」記述のみ）
- 4.1 — `verify_pushed_or_retry` を変更せず、新規ヘルパーで意味論を分離。`mark_issue_failed` 直前で push state を verify する一貫性を確保
- 4.2 — push 失敗時も `mark_issue_failed` 呼び出しを完遂する設計（テスト Case 3 で担保）
- 4.3 — 非 per-task 経路（Stage A / Stage B / design / triage）の `mark_issue_failed` 呼出は変更されていない（diff 確認）
- 5.1 — `local-watcher/test/publish_terminal_failure_artifacts_test.sh` Case 1 で `per-task-reviewer-reject3` シナリオを再現し review-notes.md / debugger-notes.md を untracked 状態で投入
- 5.2 — Case 1 で bare repo commit 数 2 件到達を assert、Case 3 で本文 marker `EMBED-MARKER-CASE3-CONTENT-XYZ` の埋め込みを assert
- 5.3 — Case 1 で branch 名 / local HEAD ラベル / origin HEAD ラベル / ahead count ラベル / worktree path を全て assert
- NFR 1.1 — `verify_pushed_or_retry` 既存 helper / 既存 env var 名（REPO / REPO_DIR / LOG_DIR / LOCK_FILE）に変更なし
- NFR 1.2 — Case 1 で既存 extra_body 文言「per-task ループの Reviewer (task=...) reject」の保持を assert
- NFR 2.1 — 例外時の最終 `mark_issue_failed` 呼出を全テストケースで担保
- NFR 2.2 — `echo "[$(date '+%F %T')] terminal-failure-artifacts: ..." >> "$LOG"` の grep 可能なフォーマットで複数行記録。Case 1 で LOG 内容を assert
- NFR 3.1 — `_max_chars=16384` 閾値超過時に先頭 80 行 + 末尾 80 行 + `(中略 / 全文 N 文字)` の抜粋モードに切替。Case 5 で 600 行入力時の `(中略` 含有と `TAIL-MARKER-CASE5-END` 含有を assert

## Findings

なし

## Summary

5 つの per-task terminal failure 経路（reject2 / reject3 / reviewer-error / reviewer-missing-file / debugger-notes-invalid）に対し新規ヘルパー `publish_terminal_failure_artifacts` を導入する設計で、Req 1-5 と NFR 1-3 を全てカバー。29 アサーションの新規回帰テストが全て pass し、既存テストへの破壊なし。Reviewer / Debugger サブエージェントへの git 権限付与を伴わず（`.claude/agents/` 無変更）、watcher 側で push state verify と diagnostic artifact 保全を完遂する設計が要件と整合している。

RESULT: approve
