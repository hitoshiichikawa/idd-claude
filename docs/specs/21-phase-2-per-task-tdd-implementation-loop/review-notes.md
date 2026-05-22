# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-21-impl-phase-2-per-task-tdd-implementation-loop
- HEAD commit: a066390 (`docs(tasks): mark 8 as done`)
- Compared to: main..HEAD（22 commits / 6 files / +1198 / -61）
- Feature Flag Protocol 採否: 対象 repo (idd-claude) の `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しないため opt-out 扱い（通常の 3 カテゴリ判定のみ適用 / flag 観点の追加判定は行わない）

## Verified Requirements

### Requirement 1: opt-in による既存挙動の保全

- 1.1 — `run_impl_pipeline` Stage A 分岐の else 側で従来 `build_dev_prompt_a` → `qa_run_claude_stage` 経路を温存（`local-watcher/bin/issue-watcher.sh:7464-7507`）
- 1.2 — true 分岐で `run_per_task_loop` 呼び出し（`issue-watcher.sh:7452-7463`）
- 1.3 — `[ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]` 厳密一致（`True` / `1` / typo はすべて else 経路に流れる）
- 1.4 — 既存 env var（`DEV_MODEL` / `REVIEWER_MODEL` / `DEV_MAX_TURNS` / `REVIEWER_MAX_TURNS` / `IMPL_RESUME_*` 等）の宣言行は不変（config block diff 確認）
- 1.5 — 新 env は `PER_TASK_*` 名前空間に限定。既定 OFF で cron / launchd 文字列の変更不要

### Requirement 2: task 単位の fresh Implementer 起動

- 2.1 — `pt_extract_pending_tasks` が `- [ ]` 行のみを `sort -V` で numeric 階層昇順抽出（`issue-watcher.sh:5772-5792`、helper smoke test で 1.2 < 1.10 を実機確認）
- 2.2 — `run_per_task_implementer` が `qa_run_claude_stage` 経由で `claude --print --model "$DEV_MODEL"` を独立 subprocess 起動（`issue-watcher.sh:6093-6135`）
- 2.3 — regex `^- \[ \] [0-9]+(\.[0-9]+)*\.? ` で numeric 階層 ID のみマッチ（`T-NN` 形式は構造的に排除）。design.md L186 の regex から末尾 `.` を optional に拡張した divergence は impl-notes の確認事項に記録済で、tasks-generation.md の親タスク表記（`- [ ] 1. ...`）との整合のため妥当
- 2.4 — Implementer prompt で「`- [ ]` → `- [x]` + `docs(tasks): mark <id> as done` 専用 commit（tasks.md 以外を含めない）」を明示注入（`build_per_task_implementer_prompt` 内）
- 2.5 — 同 prompt で「子全完了で親も `- [x]` 昇格 + 同形式 commit」を明示注入
- 2.6 — `run_per_task_implementer` 非 0 exit で `run_per_task_loop` case `*)` 分岐が `mark_issue_failed "per-task-implementer-failed"` + return 1。残 task は処理されない（`issue-watcher.sh:6302-6306`）
- 2.7 — pending 0 件で `pt_log "pending tasks=0 → no-op return 0"` + return 0（`issue-watcher.sh:6270-6273`）

### Requirement 3: task 単位の Reviewer 起動と差し戻し

- 3.1 — `run_per_task_reviewer` が `qa_run_claude_stage` 経由で `claude --print --model "$REVIEWER_MODEL"` を fresh subprocess 起動
- 3.2 — `pt_resolve_diff_range` が `git log --grep="^docs(tasks): mark "` で時系列前後を解決し、`<range_start_sha>\t<range_end_sha>` を Reviewer prompt に明示（初回 task は `$BASE_BRANCH` SHA を range_start として使用）
- 3.3 — Reviewer prompt で「reviewer.md の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）と RESULT 行規約を流用」「`_Requirements:_` の AC のみ verify、`_Boundary:_` 違反は常に reject」を明示
- 3.4 — round=1 reject 時に Implementer 再起動 → Reviewer round=2 を実行する case 構造（`issue-watcher.sh:6319-6373`）
- 3.5 — approve 時は case `0)` で次 task の `while read` イテレーションへ continue
- 3.6 — 再 reject / Implementer 失敗 / Reviewer 異常で `mark_issue_failed` + 即 return 1。残 task の `while read` を抜けるため後続 PjM も起動されない
- 3.7 — round=1 / round=2 のみで、それ以上の自動再起動なし（case 構造に追加ネストなし）

### Requirement 4: learnings 前方伝播

- 4.1 — Implementer prompt で「`### Task <id>` 見出しを `## Implementation Notes` 配下に追記」を明示注入
- 4.2 — 同 prompt で「先行 task の `### Task <id>` を改変・削除・並び替えしない」を明示注入
- 4.3 — `pt_extract_learnings` の出力を Implementer prompt に markdown code block で inline 埋め込み（`build_per_task_implementer_prompt` 内）
- 4.4 — 同 prompt で「`## Implementation Notes` セクション外は触れない」を明示注入。`pt_extract_learnings` 自体も次の `## ` 見出しで停止する awk スクリプト（helper smoke test で確認）
- 4.5 — `pt_extract_learnings` はセクション不在 / ファイル不在で空文字 + return 0（Test 5/6 で確認）。`run_per_task_loop` は pending 1 件の場合も 1 周で完結

### Requirement 5: resume 時の per-task ループ整合

- 5.1 — `pt_extract_pending_tasks` の grep で `- [x]` 行は構造的に除外（`- [ ]` 行のみ抽出）→ resume 時の自動 skip
- 5.2 — pending 空で `run_per_task_loop` が return 0（Stage A 完了相当として `verify_pushed_or_retry` → `stage-a-verify` → Stage B → Stage C の既存経路に合流）
- 5.3 — per-task loop は Stage A の case 分岐内で起動。Stage Checkpoint resume（START_STAGE=B|C）/ `IMPL_RESUME_PRESERVE_COMMITS` / `IMPL_RESUME_PROGRESS_TRACKING` の挙動は分岐の外で従来通り作用
- 5.4 — `impl-notes.md` は base ブランチ / 既存 commit に既存。Implementer は append のみで `pt_extract_learnings` が既存セクションをそのまま読み出す

### Requirement 6: ドキュメント整合と運用者向け説明

- 6.1 — README「オプション機能一覧」表に `PER_TASK_LOOP_ENABLED` 行を追加（既存表組フォーマットを踏襲）
- 6.2 — 専用解説節「Per-task TDD Implementation Loop (#21)」で「opt-in 手順 / 環境変数 / 新挙動（5 ステップ）/ learnings 前方伝播 / 観測可能性 / 累積コスト警告 / Migration Note」を運用者視点で記述
- 6.3 — `repo-template/.claude/agents/developer.md` 末尾に「per-task ループ下での Implementer の責務」節を追記（既存節は不変）
- 6.4 — `repo-template/.claude/agents/reviewer.md` 末尾に「per-task ループ下での Reviewer の責務」節を追記（既存節は不変）
- 6.5 — README 専用節の Migration Note 節に「既定で従来挙動維持」「1 件 Issue でも完結」「累積コスト 3〜5 倍」を明記

### Non-Functional Requirements

- NFR 1.1 — Strategy 分岐 else 側で従来経路完全温存。`PER_TASK_LOOP_ENABLED` 未指定で副作用ゼロ（構造的検証）
- NFR 1.2 — 既存ラベル名・付与契約に変更なし（diff 内で既存ラベル定義の改変なし）
- NFR 1.3 — 既存 exit code / `LOG_DIR` 配下のログフォーマット不変。`pt_log` は既存 `rv_log` と同一形式（`[YYYY-MM-DD HH:MM:SS] per-task: ...`）
- NFR 1.4 — #67 / #112 / #20 / #66 / #68 の挙動契約は再実装せず流用のみ
- NFR 2.1 — `pt_log` で 4 イベント（implementer start / end / reviewer start / end）を記録する実装を構造的に確認
- NFR 2.2 — 全 `pt_log` エントリに `task=<id>` を含める実装（`pt_log "task=$task_id ..."` 形式）
- NFR 2.3 — reject 時に `parse_review_result` 結果（categories / targets）を `pt_log` に出力する case `reject)` 分岐
- NFR 3.1 — README 専用節「累積コスト警告」で 3〜5 倍を明記、`PER_TASK_MAX_TASKS` の存在も明記
- NFR 4.1 — shellcheck 実測: main 35 件（SC2012=1 + SC2317=34）/ HEAD 15 件（SC2012=1 + SC2317=14）。**新規警告 0 件**（むしろ既存警告が減少）
- NFR 4.2 — YAML 変更なしのため自動的に達成

## Findings

なし

## Summary

22 commits / 6 files の変更を全件確認した。要件定義（Req 1〜6 / NFR 1〜4）の全 numeric ID について、`local-watcher/bin/issue-watcher.sh` の 9 個の per-task helper + Strategy 分岐 / `developer.md` / `reviewer.md` / README の追記いずれかで観測可能な実装を確認できた。File Structure Plan に列挙されたファイル以外への変更はなく boundary 逸脱なし。`shellcheck` 実測でも新規警告 0 件（NFR 4.1 達成）。impl-notes.md に静的解析結果 / helper smoke test 結果 / AC 達成確認テーブル / 確認事項（design.md regex 差異の自己申告 / dry run #2 を task 8.1 deferrable に委ねた判断）が記録されており、検証手段の事後判別性も担保されている。

RESULT: approve
