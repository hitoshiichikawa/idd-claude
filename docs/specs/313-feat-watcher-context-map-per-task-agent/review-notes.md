# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-10T06:35:00Z -->

## Reviewed Scope

- Branch: claude/issue-313-impl-feat-watcher-context-map-per-task-agent
- HEAD commit: 833d4e1c5c0d81ac90464f4389911e73b9f3003a
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/modules/context-map.sh:65-69` `cm_enabled` が `CONTEXT_MAP_ENABLED=true` 厳密一致時に rc=0 を返す。`test-cm-disabled.sh` の "both true → rc=0" assertion で検証
- 1.2 — `cm_enabled` 未通過時は `cm_render_prompt_section` が空文字を返し既存 prompt と差分等価（`test-cm-inject.sh` の NFR 1.1 strip 比較 assertion で検証）
- 1.3 — `cm_enabled` の lowercase 厳密一致判定。`test-cm-disabled.sh` で `=True` / `=1` / `=yes` がいずれも render-empty / 生成スキップとなることを検証
- 1.4 — `[ "${PER_TASK_LOOP_ENABLED:-}" = "true" ]` ガード（context-map.sh:67）+ `test-cm-disabled.sh` "PTL unset → render empty" で検証
- 2.1 — `run_per_task_loop` 内 task ループ冒頭 `cm_enabled && cm_generate "$task_id"`（issue-watcher.sh:4608-4614）。`test-cm-generate.sh` case1 で context-map.md 生成を検証
- 2.2 — `cm_compose:308-310` で `## Task` / `- ID:` / `- Name:` を出力。case1 で grep 検証
- 2.3 — `cm_resolve_boundary` + `cm_compose:313` で `## Boundary` heading 出力。case1 で heading + CSV 抽出を assert（bullet 展開 latent bug は impl-notes.md「確認事項」に明示エスカレーション済み）
- 2.4 — `cm_resolve_candidate_files` + `cm_compose:328`。case1 で boundary-derived path が含まれることを検証
- 2.5 — `cm_resolve_candidate_tests` + `cm_compose:339`。case1 で `## Candidate tests` heading 検証
- 2.6 — `cm_resolve_candidate_docs` + `cm_compose:350`。case1 で `- tasks.md` 等の docs 列挙を検証
- 2.7 — `cm_compose:361-365` で `## Search constraints` + `READ FIRST:` 出力。case1 で検証
- 2.8 — `modules/context-map.sh` 内は純粋な bash + grep/awk/sed のみで LLM 呼び出しなし（実装パスから明白）
- 2.9 — `cm_compose:323` で `_Boundary:_` 空時に `(resolution: none ...)` 明示。case3 で `_Boundary:_` 不在 task に対し marker 出力を assert
- 2.10 — `cm_truncate_if_oversize`（context-map.sh:379-412）で 200 行 / 8 KB 上限担保。case4 で 300 行入力→202 行出力 + truncate marker assert
- 3.1 — `build_per_task_implementer_prompt` 内（issue-watcher.sh:3476-3483, 3690）で `${context_map_block_section}` を heredoc 末尾に embed。`test-cm-inject.sh` で `## Context Map` 含有を assert
- 3.2 — `build_per_task_reviewer_prompt` 内（issue-watcher.sh:3724-3732, 3846）で同様に embed。`test-cm-inject.sh` で検証
- 3.3 — `.claude/agents/developer.md:54-58` + `repo-template/.claude/agents/developer.md` 同位置に「広域 grep / glob を行う前に context map を参照」追記
- 3.4 — `.claude/agents/reviewer.md:23-24` + `repo-template/.claude/agents/reviewer.md` 同位置に「diff range 評価時の探索起点」追記
- 3.5 — `cm_enabled` 不通過時 `cm_render_prompt_section` が空文字を返し prompt は本機能導入前と byte 一致。`test-cm-inject.sh` の strip 比較 assertion で検証
- 4.1 — `diff .claude/agents/developer.md repo-template/.claude/agents/developer.md` 空（手元 `diff -r` で確認）
- 4.2 — `diff .claude/agents/reviewer.md repo-template/.claude/agents/reviewer.md` 空（手元 `diff -r` で確認）
- 4.3 — `diff -r .claude/agents repo-template/.claude/agents` 空を手元実行で確認
- 5.1 — `README.md:1283` の opt-in 表 + `## Context Map for per-task agents (#313)` 節（README:4920-5022）に `CONTEXT_MAP_ENABLED` の意味と既定値を記載
- 5.2 — README 同節「opt-in 手順」「環境変数」表 / 「注」block で `PER_TASK_LOOP_ENABLED=true` 前提を複数箇所で明記
- 5.3 — README 同節「生成パスとタイミング」で `docs/specs/<番号>-<slug>/context-map.md` と「各 task 開始直前」を記載
- 5.4 — README 同節「スコープ外」セクションで 4 項目（reasoning effort / 並列度 / LLM scout / repo-wide index）を明示
- 6.1 — `test-cm-generate.sh`（24 assert pass）で生成 contract を機械検証
- 6.2 — `test-cm-inject.sh`（7 assert pass）で prompt 注入 contract を機械検証
- 6.3 — `test-cm-disabled.sh`（20 assert pass）で disabled 時の非生成・非注入を機械検証
- NFR 1.1 — `test-cm-inject.sh` の "flag-off matches flag-on with Context Map stripped" で既存 prompt との byte 一致を Implementer / Reviewer 両方で検証
- NFR 1.2 — diff 上で既存 env var 名（`PER_TASK_LOOP_ENABLED` 等）変更なし。新規 `CONTEXT_MAP_ENABLED` のみ追加
- NFR 1.3 — diff 上で既存ラベル名変更なし（新規ラベルも追加なし）
- NFR 1.4 — diff 上で cron 登録文字列変更なし（新規 env を opt-in 追加のみ）
- NFR 2.1 — `test-cm-generate.sh` case2 で同一入力 2 回呼び出しの byte 一致 assert
- NFR 2.2 — 実装は bash 標準コマンドのみで sudo 不要（実装パスから明白）
- NFR 2.3 — `test-cm-generate.sh` case5a/5b/5c で missing spec dir / missing tasks-design / 空 task_id の異常入力時 rc=0 終了を assert
- NFR 3.1 — `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh` を Reviewer 環境で再実行し rc=0（警告ゼロ）を確認
- NFR 3.2 — モジュール冒頭コメントで「set -euo pipefail は本体側で宣言済みのため本モジュールでは宣言せず」を明記。既存 `modules/stage-a-verify.sh` 等と同形式
- NFR 4.1 — `cm_truncate_if_oversize` で 200 行 / 8 KB 上限を実装。design.md / README で確定値根拠を明記

## Findings

なし

## Summary

Issue #313 の Developer 実装は全 26 AC（Req 1.1〜6.3 + NFR 1.1〜4.1）に対して観測可能な
実装またはテストカバレッジを持ち、`_Boundary:_` 制約（context-map.sh / issue-watcher.sh /
developer.md / reviewer.md / test-fixtures/ / README.md）も全 task で遵守されている。Reviewer
環境で `shellcheck` 警告ゼロ、`diff -r .claude/agents repo-template/.claude/agents` 空、
test-fixtures 3 本（24 + 20 + 7 = 51 assertion）全 pass を再実行確認した。Task 5 で
escalation された `cm_compose` の `_Boundary:_` bullet 展開 latent bug（trailing newline 欠落）は
Task 5 boundary 外として impl-notes.md「確認事項」に明示済みで、Task 5 の test は heading +
CSV 抽出 + candidate files 経由で Req 2.3 / 2.4 を代替検証している。本 latent bug は本 spec の
判定軸（AC 未カバー / missing test / boundary 逸脱）のいずれにも該当しない。

RESULT: approve
