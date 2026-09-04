# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.8 timestamp=2026-08-28T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-529-impl-pr-iteration-slot-worktree-pr-head-branc
- HEAD commit: 6538214f8f40a498e509ac29d73cc08eb87b173f
- Compared to: main..HEAD
- 注記: 本 Issue は design-less impl（`design.md` / `tasks.md` 不在。requirements.md のみ）。
  boundary は tasks.md の `_Boundary:_` ではなく requirements.md「Out of Scope」で判定した。

## Verified Requirements

- 1.1 — `pi_detach_holding_worktrees`（pr-iteration.sh）を `git checkout -B` 直前で呼び出し（pr-iteration.sh:485）。`pi_detach_holding_worktrees_test.sh`「他 worktree 保持 → detach」
- 1.2 — detach で branch を解放し checkout 継続（fetch 成功後・checkout 前に detach）。同テストで rc=0 + slot detach を確認
- 1.3 — 呼び出しが kind 非依存の subshell checkout パス（pi_run_iteration）に 1 箇所配置され impl/design 双方が通過。関数に kind 分岐なし（コード確認）
- 1.4 — awk `branch refs/heads/<head_ref>` 完全一致で対象のみ列挙。`pi_detach_holding_worktrees_test.sh`「別 branch の slot-2 は detach されない」
- 1.5 — detach 失敗でも return 0（fail-safe）。同テスト「detach 失敗: それでも rc=0」
- 2.1 — `pi_processing_comment_posted` rc=0（既投稿）で `pi_post_processing_comment` が抑止（pr-iteration-state.sh:230-234）。`pi_processing_comment_dedupe_test.sh` 既投稿抑止ケース
- 2.2 — sentinel marker `<!-- idd-claude:pr-iteration-processing round=N -->` を round 別に付与（pr-iteration-state.sh:245）。新 round は未検出で 1 回投稿。同テスト「初回 1 回投稿」
- 2.3 — dedupe 判定失敗（rc=2）は投稿へ fail-open、常に return 0。同テスト fail-open ケース
- 3.1 — 着手前段失敗（`pi_preclaim_reached != true`）で `pi_next_no_progress_streak false prev_streak`（+1）計上（pr-iteration.sh:874-878）。`pi_preclaim_no_progress_test.sh` streak +1
- 3.2 — limit 未満は `pi_classify_round_outcome` = no-progress → return 1（needs-iteration 据え置き）。同テスト「limit 未満は据え置き」
- 3.3 — limit 到達で `pi_escalate_to_failed`（needs-iteration 除去 + claude-failed 付与）（pr-iteration.sh:885-890）。同テストでラベル遷移確認
- 3.4 — escalate ログ `PR #.. kind=.. round=.. no-progress-streak=.. limit=.. reason=preclaim-no-progress escalate`（pr-iteration.sh:888）+ escalate 本文が streak/limit を含む（同テスト）
- 3.5 — `pi_classify_round_outcome` が max_rounds 非依存で design（無制限）も打ち切り。同テスト「max_rounds 非依存で escalate」
- NFR 1.1/1.3/1.4 — 新 env / 新ラベル / exit code 変更なし。既存 `pi_escalate_to_failed` / `pi_finalize_labels` を再利用（コード確認）
- NFR 1.2 — 誰も head branch を保持しない正常系は detach 呼び出しなし（no-op）。`pi_detach_holding_worktrees_test.sh`「未保持 → no-op」
- NFR 2.1/2.2 — head_ref を awk `-v target=` / `grep -Fq --` に渡しオプション解釈させない。`-` 始まり head_ref を完全一致 detach（同テスト NFR 2.2）
- NFR 3.1 — detach / dedupe の全 git・gh 操作に `PR_ITERATION_GIT_TIMEOUT` 適用（コード確認）

## Findings

なし

## Summary

Req 1（holding worktree detach）/ Req 2（着手表明コメント dedupe）/ Req 3（着手前段失敗の
no-progress 計上 + 上限 escalate）の全 AC が pr-iteration.sh / pr-iteration-state.sh の実装と
新規 3 テスト（PASS 14/12/14）で観測でき、既存回帰テスト（no-progress invariant 21 /
classify 24 / max-rounds 24）も緑。変更は PR Iteration Processor モジュール内に限定され Out of
Scope の slot worker 側 detach には触れておらず boundary 逸脱なし。shellcheck / bash -n クリーン。
なお impl-notes 記載の `spec-html_test.sh` / `publish_terminal_failure_artifacts_test.sh` の
失敗は base でも再現する本 PR 非依存の既存事象であり判定対象外。slot worker 終了時 detach
（Out of Scope / Open Question）は現行確定 spec の範囲外であり別 Issue 還流の設計レベル指摘で
reject 理由には含めない。

RESULT: approve
