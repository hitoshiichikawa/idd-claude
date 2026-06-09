# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-10T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-305-impl--enhancement-per-task-retry-reviewer-deb
- HEAD commit: 76f40f76ff1ca1a2210ad4248b43e7768bb56e26
- Compared to: main..HEAD
- 対象 task 群: 1〜8（全完了）

## Verified Requirements

- 1.1 — `build_per_task_implementer_prompt` の `redo_mode=after-round1` 分岐で `## 直前 round の Reviewer Findings` ブロックを inline 注入（issue-watcher.sh 行 3325 付近）。`run_per_task_loop` の round=2 redo 呼び出しが `run_per_task_implementer_redo "$task_id" "after-round1"` に置換済み（行 4304 付近）
- 1.2 — `redo_mode=after-debugger` 分岐で Reviewer Findings + Debugger Fix Plan の両方を inline 注入（行 3370 付近）。`run_per_task_loop` の Debugger 経由 round=3 redo 呼び出しが `run_per_task_implementer_redo "$task_id" "after-debugger"` に置換済み（行 4391 付近）
- 1.3 — `pt_extract_findings_block` は `## Findings` セクションを **そのまま** 抽出するため `**Target**` / `**Category**` / `**Detail**` / `**Required Action**` 行が保持される。`pt_extract_findings_block_test.sh` の Finding 内容 assertion で検証
- 1.4 — `redo_mode=initial` の場合は `findings_block_section` / `debugger_block_section` / `closure_matrix_section` の 3 変数が空文字のまま heredoc 末尾で展開され、既存 1 引数呼び出しと byte 一致（impl-notes.md Task 3 手動スモーク 1, 2 で検証）
- 1.5 — `pt_extract_findings_block` / `pt_extract_debugger_section` の return 1 を吸収して 1 行明示 + `pt_log "... inject=skipped reason=..."` を出力。test スクリプトの「ファイル不在時 rc=1」「見出し不在時 rc=1」assertion で検証
- 2.1 — `developer.md` に「per-task retry 時の Finding Closure Matrix 記録義務」h2 節を追加（行 405 付近）。`impl-notes.md` の `### Task <id>` 末尾に Matrix を追記する規約を明示
- 2.2 — Matrix の 4 列構造（Finding / Target / Fix Commit / Added/Updated Test / Verification）を規約テンプレで明示
- 2.3 — Fix Commit 列の enum 値（`未対応` / `対応不可（理由: <理由>）` / `次 round へ持ち越し`）を canonical として明示
- 2.4 — 「先行 task / 先行 round の Matrix 改変禁止」節として明示。round=3 では既存 round=2 Matrix を温存して新規見出しで追加する規約
- 2.5 — `redo_mode=after-debugger` のみ 5 列目「Fix Plan Step」を追記する規約を明示。`build_per_task_implementer_prompt` の after-debugger 分岐が「5 列目「Fix Plan Step」も必ず追記」を prompt に運ぶ構造と整合
- 3.1 — `pt_check_fail_fast` 内部の `_pt_ff_extract_tuples` awk で両 review-notes.md から `(category, target)` tuple set を抽出。`pt_check_fail_fast_test.sh` の 5 ケースで検証
- 3.2 — fail-fast 成立時に `task=<id> fail-fast match category=<cat> target=<tgt> test-diff-empty range=<a>..<b>` の grep 可能 1 行を stdout に出力。`run_per_task_loop` が `printf '[%s] [%s] per-task: %s\n'` で LOG に転記
- 3.3 — `pt_mark_fail_fast_failed` が `mark_issue_failed "per-task-implementer-fail-fast-loop" "<extra_body>"` 経由で claude-failed 化 + Issue コメント投稿。extra_body には検出条件・対象 task ID・Finding 概要・参照ファイルパス・次の手順が含まれる
- 3.4 — pt_check_fail_fast が return 1（不成立）の場合は `if [ "$_pt_ff_rc" = "0" ]` ブロックを skip して既存 Debugger Gate 経路へ進む構造。test の「共有なし」「テスト差分あり」ケースで return 1 を検証
- 3.5 — テストファイル判定基準を design.md「テストファイル判定基準」節（行 410 付近）に明示。拡張子 + ディレクトリの 2 軸 OR 結合（`_test.sh` / `.test.ts` 系 / `_test.go` / `_test.py` / `test_*.py` + `/test/` / `/tests/` / `/__tests__/` / `/spec/` + `local-watcher/test/fixtures/**` 特例）
- 4.1 — `.claude/agents/developer.md` に Finding Closure Matrix 記録義務節を追加（前述 2.1）
- 4.2 — reviewer.md に diff なし（`git diff --stat main..HEAD` で reviewer.md 不変を確認）
- 4.3 — 既存制約節（PR 作成禁止 / spec 書き換え禁止 / `### Task <id>` 追記規約 / 既存 commit 温存等）は heredoc 内で温存。新規 section は heredoc 末尾 `${findings_block_section}${debugger_block_section}${closure_matrix_section}` 1 展開点に集約
- 4.4 — `diff -r .claude/agents repo-template/.claude/agents` 空出力で byte 一致を実機確認
- 5.1 — `pt_extract_findings_block_test.sh`（20 assertion PASS）で round=1 reject → round=2 経路の Findings 抽出を検証
- 5.2 — `pt_extract_debugger_section_test.sh`（24 assertion PASS）で `## Task <id>` セクション抽出を検証。round=3 経路の Findings + Fix Plan 双方注入は build_per_task_implementer_prompt の after-debugger 分岐が両 helper を呼ぶ構造で構造保証
- 5.3 — `pt_check_fail_fast_test.sh`（18 assertion PASS）で 成立 / 共有なし / カテゴリ違い + テスト差分あり / snapshot 不在 / 共有あり + テスト差分あり の 5 ケースを検証
- 5.4 — `build_per_task_implementer_prompt` は per-task ループ内部関数であり `PER_TASK_LOOP_ENABLED=false` 経路では呼ばれない構造的隔離が保たれる。default 値 `initial` で notes 注入ブロックが空文字に倒れる
- 5.5 — `redo_mode=initial`（既定 / round=1 approve 経路で呼ばれる経路）で 3 セクション変数が空文字のまま展開されることを impl-notes.md Task 3 手動スモーク 1 / Task 8 構造検証で確認
- NFR 1.1 — 1 引数呼び出し（`build_per_task_implementer_prompt 1.2`）と `build_per_task_implementer_prompt 1.2 initial` の stdout diff 0 行を impl-notes.md Task 3 手動スモーク 1 で確認
- NFR 1.2 — `run_per_task_loop` の round=1 approve 分岐は無改変。round=1 approve 経路で `run_per_task_implementer` は task あたり 1 回のみ起動される
- NFR 1.3 — 既存 `claude-failed` 分類カテゴリは温存。新規 `per-task-implementer-fail-fast-loop` のみを追加する形で意味の変更を回避
- NFR 2.1 — `diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` の空出力を実機確認
- NFR 3.1 — `pt_log "task=$task_id redo_mode=$redo_mode inject=$_inject_files" >> "$LOG"` で grep 可能な 1 行を出力
- NFR 3.2 — `pt_mark_fail_fast_failed` の extra_body に検出条件・対象 task ID・Finding 概要・参照ファイルパス・次の手順を運用者向けに記載
- NFR 4.1 — `pt_extract_findings_block` は引数で渡された **1 つの review-notes.md** のみを参照（直近 round のみ）。過去 round や別 task の Findings は参照しない
- NFR 4.2 — `pt_extract_debugger_section` は task_id を `[.]` escape して `^## Task <escaped_id>$` 行頭マッチで当該 task のみを抽出。test の「他 task の本文混入なし」assertion で構造を検証

## Findings

なし

## Summary

Issue #305 の per-task retry Reviewer/Debugger inline 注入 + Finding Closure Matrix 義務化 + fail-fast 検出
の 3 機能が全 task（1〜8）で完了。全 numeric requirement ID（Req 1.1〜5.5 + NFR 1.1〜4.2）に
対応する実装または規約反映が確認でき、tasks.md の `_Boundary:_` 制約からの逸脱なし。新規 3 test
スクリプト（62 assertion 全 PASS）/ shellcheck 警告ゼロ / `diff -r .claude/agents` および
`diff -r .claude/rules` の byte 一致 / 既存 1 引数呼び出しの後方互換性（NFR 1.1）はいずれも実機確認済み。

RESULT: approve
