# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T02:48:19Z -->

## Reviewed Scope

- Branch: claude/issue-164-impl-bug-watcher-per-task-reviewer-task-id-ma
- HEAD commit: f5cdccf6522af4116fa5b33637ee878d04574adc
- Compared to: main..HEAD
- Feature Flag Protocol: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しない
  ため、本レビューでは flag 観点（boundary 逸脱の細目）は **適用しない**（通常の 3 カテゴリ
  判定のみ）

## Verified Requirements

### Requirement 1: Developer prompt の厳格化（1 commit = 1 task ID）

- 1.1 — `build_per_task_implementer_prompt` 内の「進捗マーカー更新」節（issue-watcher.sh:6664
  付近）に「**【重要 / Issue #164】1 つの marker commit には 1 つの task ID のみを含めること**」
  が明示追加されている（diff +6672 行目）
- 1.2 — 同 prompt 中「親 task の完了昇格も別 commit に分割」「子 `1.1` 完了で親 `1` も全完了に
  なる場合、まず `docs(tasks): mark 1.1 as done` を 1 commit で作成し、続けて
  `docs(tasks): mark 1 as done` を別 commit として続けて作成する」が明示
- 1.3 — diff を確認したが既存 prompt 内に複数 ID を 1 commit にまとめる例示・テンプレは
  存在せず、新規追加された NG 例示（`mark 1 / 1.1 as done` / `mark 1, 1.1 as done`）が
  禁止表記の役割を果たしている
- 1.4 — `build_per_task_implementer_prompt` は `run_per_task_implementer` から呼ばれ、これは
  `run_per_task_loop` 内の per-task ループからのみ呼ばれる。`run_per_task_loop` は
  issue-watcher.sh:9137 で `PER_TASK_LOOP_ENABLED=true` でのみ起動する dispatcher gate に
  守られている（grep で他経路からの呼び出し無しを確認）

### Requirement 2: 連記 marker commit からの task ID 解決の許容

- 2.1 — `pt_resolve_diff_range`（issue-watcher.sh:6511）の (a) 単記 marker 検索ループが
  従来通り `subject = "docs(tasks): mark ${task_id} as done"` を完全一致で解決
  （smoke test case1 全 4 件 pass）
- 2.2 — 同関数の (b) 連記 marker fallback 検索が `sed -nE 's/^docs\(tasks\): mark (.+) as
  done$/\1/p'` で `<ids>` 部を抽出し `tr '/,' '  '` で正規化 + word splitting + 完全一致照合
  （smoke test case2 slash 区切り 3 件 / case3 comma 区切り 2 件 pass）
- 2.3 — `pt_resolve_diff_range` の最終出力は `printf '%s\t%s\n' "$range_start" "$current_mark"`
  で、連記内の各 task ID が同一 `current_mark` SHA を返す（smoke test case2 で task=1 /
  1.1 / 1.2 が同一 `708d0d00...` を返すこと、case3 で task=1 / 1.1 が同一 `59eafb17...` を
  返すことを確認）
- 2.4 — (a) を (b) の前段に置くことで単記優先を保証。case6 で task=1 が単記 marker
  `C6_SINGLE_1` を返し、連記マーカは無視されることを確認（smoke test case6 pass）。
  選択基準は `via=single-id-marker` / `via=multi-id-marker` の内部変数で識別可能（NFR 2.1
  の stdout ログ出力で観測可能）
- 2.5 — 単記マッチは `subject = "docs(tasks): mark ${task_id} as done"` の完全一致、連記
  マッチは word splitting + `[ "$tok" = "$task_id" ]` の文字列完全一致で、`1` が `1.1` /
  `11` に誤マッチしない（smoke test case2 で task=11 が rc=1、task=2 が rc=1、case3 で
  task=1.2 が rc=1 を返すこと確認）

### Requirement 3: 既存単記 marker commit との後方互換性

- 3.1 — 単記マッチを (a) で優先採用し、見つかった時点で (b) を skip。case1 全 4 件で
  本変更前と同一の SHA pair を返す（smoke test pass）
- 3.2 — 連記経由解決時のみ `via=multi-id-marker` ログを stderr に出力する条件分岐
  （issue-watcher.sh:6583）により、単記のみのリポジトリでは追加ログが発生しない
  （smoke test case1 / case6 task=1 / case4 task=1, 1.1 の出力に `via=multi-id-marker`
  ログが現れないこと確認）
- 3.3 — `pt_resolve_diff_range` / `pt_mark_diff_range_resolve_failed` の呼び出し元は
  `run_per_task_reviewer` および `run_per_task_loop` のみで、いずれも
  `PER_TASK_LOOP_ENABLED=true` の dispatcher gate (issue-watcher.sh:9137) の内側
  （grep 結果で確認）

### Requirement 4: 失敗時の Issue コメントに具体的な原因と復旧手順を明示

- 4.1 — `pt_mark_diff_range_resolve_failed`（issue-watcher.sh:7015）の body 内
  「## 失敗カテゴリ」節で「カテゴリ: `diff-range-resolve-failed`」「対象 task ID:
  `${task_id}`」「失敗 round: ${round}」を明示
- 4.2 — 同 body の「## 復旧手順（重要 / データ損失リスク回避）」節で `git reflog --date=iso`
  / `git push origin <current-branch>` / `git branch <rescue-branch-name> <reflog-sha>`
  を bash code block で明示、「次サイクルで本ブランチの worktree が reset される可能性が
  あります」を文章で明示
- 4.3 — 同 body の「## 推奨される marker commit 分割の規約（1 commit = 1 task ID）」節で
  「1 つの `docs(tasks): mark <id> as done` commit には 1 つの task ID のみを含める」
  「親 task の完了昇格も別 commit に分割する」を明示。
  `repo-template/.claude/agents/developer.md` への参照も含む
- 4.4 — HTML marker `<!-- idd-claude:per-task-diff-range-resolve-failed:#${NUMBER}:${task_id} -->`
  を body 末尾に埋め込み、`gh issue view --json comments | jq` で既存マーカコメントを検索
  して件数 > 0 なら header を「**追記コメント** / 詳細な復旧手順は既存コメントを参照」に
  切り替える dedup ロジックを実装

### Requirement 5: 既存テンプレ・ドキュメント・既存 PR への副作用を生まない

- 5.1 — `pt_resolve_diff_range` は単記マッチを優先採用 → 既存規約の温存。本変更は (b) の
  fallback 追加と stderr ログ追加のみで、既存単記処理の挙動を反転させない
- 5.2 — 既存 env var（`PER_TASK_LOOP_ENABLED` / `BASE_BRANCH` / `LABEL_CLAIMED` /
  `LABEL_PICKED` / `LABEL_FAILED` / `NUMBER` / `REPO` 等）は新規追加・名前変更なし。
  `run_per_task_reviewer` の return code は rc=2 既存維持 + rc=3 新規追加（既存意味の
  破壊なし）
- 5.3 — `repo-template/.claude/agents/developer.md` の diff（+7 行）は「per-task ループ
  下での Implementer の責務」節への **追加 bullet** のみで、既存記述の意味反転なし
- 5.4 — Req 1.4 / 3.3 と同根。`pt_resolve_diff_range` / `pt_mark_diff_range_resolve_failed` /
  prompt 修正部 は `run_per_task_loop` 経由でのみ呼ばれ、`PER_TASK_LOOP_ENABLED=true` 限定で
  本変更経路に到達する

### Non-Functional Requirements

- NFR 1.1 — smoke test case1（単記のみ）で 4/4 件が既存挙動踏襲。SHA pair と rc 分布
  （rc=0 解決成功 / rc=1 未解決）の両方を fixture で確認
- NFR 1.2 — `pt_mark_diff_range_resolve_failed` の HTML marker dedup ロジック
  （`gh issue view --json comments | jq '... contains($marker) | length'`）で同一 marker
  既存時に header を追記モードに切り替え、重複コメントの内容混乱を防止
- NFR 2.1 — `pt_resolve_diff_range` の末尾で via=multi-id-marker 経由解決時に `>&2` で
  `[date] per-task: diff-range resolved via=multi-id-marker task_id=${task_id} sha=${current_mark}`
  をログ出力（smoke test の case2 / case3 / case4 / case6 で出力を観測）
- NFR 2.2 — `run_per_task_reviewer` 内 `pt_log` で `reason=diff-range-resolve-failed
  detail=no-marker-commit-found(single-id-and-multi-id-both-missing)` を明示
- NFR 3.1 — `pt_mark_diff_range_resolve_failed` 本文に「失敗カテゴリ」「原因」「復旧手順
  （reflog 確認 → push 保護 → marker 補完）」「推奨される marker commit 分割の規約」の 4 節を
  構造化し、bash code block で具体的なコマンドを提示

## Findings

なし

## Summary

Issue #164 が要求する 5 つの functional Requirements（合計 18 個の AC）+ 4 つの NFR の
すべてが実装 / smoke test / Issue コメント本文に観測可能な形で実装されている。Smoke test
`docs/specs/164-.../test-pt-resolve.sh` を実際に実行し 19/19 PASSED で完走することを reviewer
側でも確認した。後方互換性は単記マッチを (a) で優先採用する設計と `PER_TASK_LOOP_ENABLED=true`
dispatcher gate により厳格に維持されている。境界逸脱（`local-watcher/bin/issue-watcher.sh` /
`repo-template/.claude/agents/developer.md` / `docs/specs/164-...`）も Issue #164 のスコープ内に
収まっている。

RESULT: approve
