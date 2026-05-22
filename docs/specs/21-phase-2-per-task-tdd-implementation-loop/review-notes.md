# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-21-impl-phase-2-per-task-tdd-implementation-loop
- HEAD commit: 465d460 (`docs(review): #21 per-task TDD ループの Reviewer 判定結果（approve）を追記`)
- Compared to: main..HEAD（23 commits / 7 files / +1284 / -61）
- Feature Flag Protocol 採否: 対象 repo (idd-claude) の `CLAUDE.md` に `## Feature Flag Protocol`
  節が存在しない（`CLAUDE.md:200` の rule 参照表に `feature-flag.md` 行が 1 行あるのみ）→
  **opt-out 扱い**。通常の 3 カテゴリ判定のみ適用し、flag 観点の追加判定は行わない。

## Verified Requirements

### Requirement 1: opt-in による既存挙動の保全

- 1.1 — `run_impl_pipeline` Stage A 分岐の else 側（`local-watcher/bin/issue-watcher.sh:7464-7507`）で従来の
  `build_dev_prompt_a` → `qa_run_claude_stage` 経路を完全温存（diff は新規 `if`/`else` 構造を導入したのみで else 内のコードは main と等価）
- 1.2 — true 分岐（`issue-watcher.sh:7452-7463`）で `run_per_task_loop` を呼び出し、後段の
  `verify_pushed_or_retry "stageA-push-missing"` も従来通り経由
- 1.3 — gate 判定が `[ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]` の厳密一致（lowercase 完全一致）。
  `True` / `1` / 空 / typo はすべて else 経路に流れる
- 1.4 — 既存 env var（`DEV_MODEL` / `REVIEWER_MODEL` / `DEV_MAX_TURNS` / `REVIEWER_MAX_TURNS` /
  `IMPL_RESUME_*` 等）の宣言行は不変（config block diff で確認）。新規 env は
  `PER_TASK_LOOP_ENABLED` / `PER_TASK_MAX_TASKS` の 2 件のみで既存 env 名と衝突なし
- 1.5 — 新 env は既定 OFF（`${PER_TASK_LOOP_ENABLED:-false}` / `${PER_TASK_MAX_TASKS:-0}`）の
  ため cron / launchd 登録文字列の変更不要

### Requirement 2: task 単位の fresh Implementer 起動

- 2.1 — `pt_extract_pending_tasks` (`issue-watcher.sh:5768-5781`) が `- [ ]` 行のみを `sort -V` で
  numeric 階層昇順抽出。reviewer 自身が `/tmp/test-tasks.md` fixture で `1` / `1.1` / `1.2` /
  `1.10` / `2` の昇順抽出と `- [x]` / `- [ ]*` の除外を実機確認済
- 2.2 — `run_per_task_implementer` (`issue-watcher.sh:6091-6134`) が `qa_run_claude_stage` 経由で
  `claude --print --model "$DEV_MODEL"` を独立 subprocess（fresh session）で起動
- 2.3 — regex `^- \[ \] [0-9]+(\.[0-9]+)*\.? ` で numeric 階層 ID のみ受理（`T-NN` 形式は構造的に排除）。
  design.md L186 表記との差異（末尾 `.` を optional に拡張）は impl-notes の「確認事項」で自己申告済。
  tasks-generation.md の親タスク慣習（`- [ ] 1. <title>`）と整合させるための実用上の補正であり、
  Req 2.3「numeric ID のみ使用、`T-NN` を生成・受理しない」を満たす（reject 対象外）
- 2.4 — `build_per_task_implementer_prompt` (`issue-watcher.sh:5881-5982`) で「`- [ ]` → `- [x]` +
  `docs(tasks): mark <id> as done` 専用 commit（tasks.md 以外を含めない）」を明示注入
- 2.5 — 同 prompt で「子全完了で親も `- [x]` 昇格 + 同形式 commit」を明示注入
- 2.6 — `run_per_task_loop` の case `*)` 分岐（`issue-watcher.sh:6300-6306`）で
  `mark_issue_failed "per-task-implementer-failed"` + return 1。残 task は `while read` を抜けるため処理されない
- 2.7 — pending 0 件で `pt_log "pending tasks=0 → no-op return 0"` + return 0（`issue-watcher.sh:6270-6273`）

### Requirement 3: task 単位の Reviewer 起動と差し戻し

- 3.1 — `run_per_task_reviewer` (`issue-watcher.sh:6148-6241`) が `qa_run_claude_stage` 経由で
  `claude --print --model "$REVIEWER_MODEL"` を fresh subprocess 起動
- 3.2 — `pt_resolve_diff_range` (`issue-watcher.sh:5825-5866`) が
  `git log --grep="^docs(tasks): mark "` で時系列 SHA 列を取得し、当該 task の前後で
  `<range_start_sha>\t<range_end_sha>` を解決。初回 task では `range_start = $BASE_BRANCH SHA`。
  解決値が Reviewer prompt の Bash 実行ガイドに明示注入される
- 3.3 — `build_per_task_reviewer_prompt` (`issue-watcher.sh:5996-6079`) で「reviewer.md の 3
  カテゴリ（AC 未カバー / missing test / boundary 逸脱）と RESULT 行規約を流用」「当該 task の
  `_Requirements:_` の AC のみ verify、`_Boundary:_` 違反は depth に関わらず常に reject」を明示
- 3.4 — `run_per_task_loop` の case `1)`（`issue-watcher.sh:6319-6373`）で round=1 reject 時に
  Implementer 再起動 → Reviewer round=2 を実行する case 構造。再 reject で
  `mark_issue_failed "per-task-reviewer-reject2"` + return 1
- 3.5 — approve 時は case `0)` で次 task の `while read` イテレーションへ continue
- 3.6 — 再 reject / Implementer 失敗 / Reviewer 異常で `mark_issue_failed` + 即 return 1。
  Strategy 分岐の親 `if ! run_per_task_loop; then return 1; fi` が後段（stage-a-verify / Stage B /
  Stage C / PjM）を発火させない
- 3.7 — round=1 / round=2 のみで、それ以上の自動再起動なし（case 構造に追加ネストなし）。
  round=2 の case `1)` は `mark_issue_failed` で打ち切り、勝手な round=3 起動は構造的に不可能

### Requirement 4: learnings 前方伝播

- 4.1 — Implementer prompt で「`### Task <id>` 見出しを `## Implementation Notes` 配下に追記」を明示注入
- 4.2 — 同 prompt で「先行 task の `### Task <id>` を改変・削除・並び替えしない」を明示注入
- 4.3 — `pt_extract_learnings` (`issue-watcher.sh:5795-5811`) の出力を Implementer prompt に
  markdown code block で inline 埋め込み（`build_per_task_implementer_prompt` 内の
  `learnings_block` 変数）
- 4.4 — 同 prompt で「`## Implementation Notes` セクション外は触れない」を明示注入。
  `pt_extract_learnings` 自体も awk スクリプトで `## Implementation Notes` 見出しから
  次の `## ` 見出し直前までに限定して抽出
- 4.5 — `pt_extract_learnings` はセクション不在 / ファイル不在で空文字 + return 0（impl-notes Test 5/6 で確認）。
  `run_per_task_loop` は pending 1 件の場合も `while IFS= read -r task_id` を 1 周で完結

### Requirement 5: resume 時の per-task ループ整合

- 5.1 — `pt_extract_pending_tasks` の grep が `- [ ]` 行のみ抽出するため `- [x]` 済 task は
  構造的に除外 → resume 時の自動 skip。reviewer fixture テストで確認済
- 5.2 — pending 空で `run_per_task_loop` が return 0（Stage A 完了相当として
  `verify_pushed_or_retry` → `stage-a-verify` → Stage B → Stage C の既存経路に合流）
- 5.3 — per-task loop は Stage A の case 分岐内で起動。Stage Checkpoint resume
  （START_STAGE=B|C）/ `IMPL_RESUME_PRESERVE_COMMITS` / `IMPL_RESUME_PROGRESS_TRACKING` は
  分岐の外で従来通り作用（`issue-watcher.sh:7509-7513` の `B|C)` 分岐は不変）
- 5.4 — `impl-notes.md` は base ブランチ / 既存 commit に既存。Implementer prompt は append 規約のみ
  明示し、`pt_extract_learnings` が既存セクションをそのまま読み出す

### Requirement 6: ドキュメント整合と運用者向け説明

- 6.1 — `README.md:1100` の「オプション機能（標準有効 / 常時有効）一覧」表の opt-in（既定 OFF）
  サブセクションに `PER_TASK_LOOP_ENABLED` 行を追加（既存表組フォーマットを踏襲）
- 6.2 — `README.md:3205-3340` 周辺の専用解説節「Per-task TDD Implementation Loop (#21)」で
  「opt-in 手順 / 環境変数 / 新挙動（5 ステップ）/ learnings 前方伝播 / 観測可能性 /
  累積コスト警告 / Migration Note」を運用者視点で記述
- 6.3 — `repo-template/.claude/agents/developer.md` 末尾に「per-task ループ下での Implementer の
  責務」節を追記（既存節は不変。diff の context で先行行が変更されていないことを確認）
- 6.4 — `repo-template/.claude/agents/reviewer.md` 末尾に「per-task ループ下での Reviewer の責務」
  節を追記（既存節は不変）
- 6.5 — README 専用節の「Migration Note（既存ユーザー向け）」サブ節に「既定で従来挙動維持」
  「1 件 Issue でも完結」「累積コスト 3〜5 倍」を明記

### Non-Functional Requirements

- NFR 1.1 — Strategy 分岐 else 側で従来経路を完全温存。`PER_TASK_LOOP_ENABLED` 未指定で副作用ゼロ
- NFR 1.2 — 既存ラベル名・付与契約に変更なし（diff に既存ラベル定義の改変なし。新規付与のみ
  `per-task-implementer-failed` / `per-task-reviewer-reject2` 等を `mark_issue_failed` の
  第 1 引数識別子として使用するが、`claude-failed` ラベル名自体は不変）
- NFR 1.3 — 既存 exit code / `LOG_DIR` 配下のログフォーマット不変。`pt_log` は既存 `rv_log` と
  同一形式（`[YYYY-MM-DD HH:MM:SS] per-task: ...`）
- NFR 1.4 — #67 / #112 / #20 / #66 / #68 の挙動契約は再実装せず流用のみ。Stage A 分岐の外側で
  既存 stage-a-verify / Stage B / Stage C / Stage Checkpoint resume が従来通り動作
- NFR 2.1 — `pt_log` で 4 イベント（implementer start / end / reviewer start / end）を記録
  （`issue-watcher.sh:6096, 6116, 6175, 6228`）
- NFR 2.2 — 全 `pt_log` エントリに `task=<id>` を含める実装
  （例: `pt_log "task=$task_id implementer start ..."`）
- NFR 2.3 — reject 時に `parse_review_result` 結果（categories / targets）を `pt_log` に出力する
  case `reject)` 分岐（`issue-watcher.sh:6231-6234`）
- NFR 3.1 — README 専用節「累積コスト警告（重要）」で 3〜5 倍を明記、`PER_TASK_MAX_TASKS` の
  存在も明記
- NFR 4.1 — reviewer 自身の実測: main = 35 SC2317 + 2 SC2012、HEAD = 35 SC2317 + 2 SC2012。
  **新規警告 0 件**を独立確認（main を `git show main:...` で取り出して shellcheck 0.10.0 で対比）
- NFR 4.2 — YAML 変更なし（`git diff --name-only main..HEAD` で `.github/` 配下に変更なし）→
  自動的に達成

## Findings

なし

## Summary

23 commits / 7 files の変更（README.md / docs/specs/21-.../{impl-notes, review-notes, tasks}.md /
local-watcher/bin/issue-watcher.sh / repo-template/.claude/agents/{developer, reviewer}.md）を
独立 context で全件再確認した。要件定義（Req 1〜6 + NFR 1〜4）の全 numeric ID について
観測可能な実装またはテストを確認できた。File Structure Plan に列挙されたファイル以外への
変更はなく boundary 逸脱なし。shellcheck を main / HEAD 双方で実行し新規警告 0 件を独立検証
（NFR 4.1 達成）。`pt_extract_pending_tasks` の regex は impl-notes の「確認事項」で design.md
表記との差異を自己申告済かつ tasks-generation.md の親タスク慣習との整合のため妥当で、
3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）いずれにも該当しない。impl-notes.md に
helper smoke test 結果と AC 達成確認テーブルが記録されており、事後判別性も担保されている。

RESULT: approve
