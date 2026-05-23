# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T11:03:48Z -->

## Reviewed Scope

- Branch: claude/issue-166-impl-bug-watcher-per-task-loop-enabled-impl-m
- HEAD commit: a9b065d3dbf7105fbabd6f20c8dd66c5acb54311
- Compared to: main..HEAD

変更ファイル: `local-watcher/bin/issue-watcher.sh`（+27/-4）, `README.md`（+7）,
spec 配下の `requirements.md` / `impl-notes.md` / `test-pt-fallback.sh`（新規）。

Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節は存在しない →
opt-out として解釈。flag 観点（boundary 細目）は適用せず通常の 3 カテゴリ判定のみ実施。
tasks.md / design.md は spec 配下に不在（本 Issue は Architect 不要 triage を通過した
ケースであり、これ自体が修正対象の文脈と整合）。境界判定は requirements.md の NFR 2.1
（per-task ループ dispatcher 本体を変更しない）を基準に確認した。

## Verified Requirements

- 1.1 — `issue-watcher.sh:9146-9156` の事前分岐。`PER_TASK_LOOP_ENABLED=true` かつ
  `tasks.md` 不在のとき `_pt_loop_enabled=false` のまま従来 Stage A の `else`（9179行〜）へ
  フォールスルー。`claude-failed` を付けない。smoke: `AC1: flag=true + tasks.md 不在 →
  stage-a-fallback`（[OK]）
- 1.2 — 事前分岐は `echo ... | tee -a "$LOG"` のログ行のみで `mark_issue_failed` /
  `gh issue comment` を呼ばない（9151-9154行）。失敗通知コメントが投稿されないことを確認
- 1.3 — フォールバック先は無変更の従来 Stage A `else` ブランチ（`build_dev_prompt_a` →
  `qa_run_claude_stage "StageA"` → `verify_pushed_or_retry` → 後続 Stage B/C）。main との
  diff で `else` ブロック本体が byte 等価であることを確認（Implementer → Reviewer → PR の
  従来順序を維持）
- 1.4 — フォールバック後は従来 Stage A `else` の失敗ハンドリング（9226行〜の `mark_issue_failed
  "stageA"` 系）を無変更で流用。失敗時の `claude-failed` 付与挙動は導入前と同一
- 2.1 — `_pt_loop_enabled=true`（tasks.md あり + flag=true）で `run_per_task_loop` を呼び出し。
  loop 本体（7160行以降）は main と byte 等価（diff は関数頭の +3 行コメントによる行ずれのみ）。
  smoke: `AC3: flag=true + tasks.md あり → per-task-loop`（[OK]）
- 2.2 — `run_per_task_loop` 内の pending=0 → `return 0`（無変更）。tasks.md 存在ケースは
  上位判定で per-task ループへ入るため到達可能
- 2.3 — `[ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]` の厳密一致判定は main と同一。
  flag 未指定 / false / typo（True / 1）はいずれも `_pt_loop_enabled=false` で従来 Stage A
  直行。smoke: NFR1.1 各ケース（空 / false / True / 1）が `stage-a-traditional`（[OK]）
- 3.1 — `issue-watcher.sh:9153` の判別可能ログ行 `--- per-task: tasks.md 不在 → Stage A
  fallback（<path>）---` を slot ログ（`tee -a "$LOG"`）へ出力。smoke:
  `AC5: フォールバック発生時に判別可能ログ行`（[OK]）
- NFR 1.1 — flag off 時は `if PER_TASK_LOOP_ENABLED=true` の内側でのみ fallback 判定するため
  ログ行も出さず従来 `else` へ直行。smoke: NFR1.1 各ケースで fallback ログなしを確認（[OK]）
- NFR 1.2 — `run_per_task_loop` 本体無変更により tasks.md 存在時の per-task 結果は導入前と同一
- NFR 2.1 — dispatcher 本体ループ（7160行〜）は main と byte 等価。追加は上位 gate と
  不在ブランチの失敗→no-op 化のみ。main との region diff で本体に意味的差分なしを確認

## 追加で確認した点

- `run_per_task_loop` の唯一の呼び出し元は 9158行のみ。修正後この呼び出しは
  `_pt_loop_enabled=true`（= tasks.md 存在）のときだけ到達するため、関数内 tasks.md 不在
  ブランチの `return 0`（旧 `mark_issue_failed`+`return 1` を撤去）は通常経路から到達せず、
  防御ガードとして無害。旧 `return 1` に依存していた他呼び出し元は存在しない
- `bash -n local-watcher/bin/issue-watcher.sh` → SYNTAX_OK
- `./docs/specs/166-.../test-pt-fallback.sh` → 12 ケース全 [OK] / `SMOKE_RESULT: pass`（再実行で確認）
- smoke の `resolve_stage_a_route` 参照実装は impl の gate ロジック（9146-9156行）と同一
- README の per-task 節にフォールバック挙動の migration note が追記され二重管理規約を満たす

## Findings

なし

## Summary

全 numeric ID（1.1〜3.1）と NFR 1.1 / 1.2 / 2.1 について実装とスモークテストで担保を確認した。
従来 Stage A `else` ブロックと per-task ループ dispatcher 本体は main と byte 等価で後方互換を
維持。boundary 逸脱・missing test・AC 未カバーいずれも検出されず。

RESULT: approve
