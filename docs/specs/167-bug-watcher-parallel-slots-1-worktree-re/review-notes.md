# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-167-impl-bug-watcher-parallel-slots-1-worktree-re
- HEAD commit: b9f22bd4516666ee67c526f0a18595caabdf16f2
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out として解釈。flag 観点の確認は行わない（通常の 3 カテゴリ判定のみ）

## Verified Requirements

- 1.1 — `_worktree_reset()`（issue-watcher.sh:10114-10139）から per-slot `git fetch origin --prune` を削除。複数 slot 同時実行時の ref ロック取得競争元が関数から消滅。diff で担保
- 1.2 — 同上。fetch 削除により ref ロック競合起因の関数失敗が発生せず、競合のみを理由とした `claude-failed` 付与経路が断たれる
- 1.3 — 同上。失敗エラーコメント投稿の前提となる関数失敗が起きない
- 2.1 — `git reset --hard "origin/${BASE_BRANCH}"`（10131 行目）温存。HEAD を origin 最新へ強制一致。impl-notes CASE1 / CASE4 で確認
- 2.2 — `git reset --hard` + `git clean -fdx`（10135 行目）温存。tracked/untracked/ignored を消去。impl-notes CASE1（status --porcelain 空）で確認
- 2.3 — 親プロセスのサイクル冒頭 fetch（issue-watcher.sh:526-527 `cd "$REPO_DIR"; git fetch origin --prune`）が未変更であることを grep で確認。slot worktree は共有 .git の origin/$BASE_BRANCH 参照を起点に reset。impl-notes CASE4 で実証
- 3.1 — 末尾 `return 0`（10138 行目）温存。成功時 exit 0
- 3.2 — `[ ! -d "$wt" ]` ガード（10116 行目）、reset 失敗 `return 1`（10132 行目）、clean 失敗 `return 1`（10136 行目）すべて温存。失敗時 exit 1。impl-notes CASE2/CASE3 で確認
- 3.3 — reset/clean ロジック無変更。直列時は元々競合が起きず、削除した fetch 分の最新化は親 527 行目で代替。CASE4 で代替妥当性を実証
- NFR 1.1 — fetch 削除方針自体が ref stale を許容。NOTE コメント（10119-10129 行目）に明記。clean 起点確保を成功扱い
- NFR 2.1 — exit code 0/1 の意味不変。CASE1-4 で契約維持を確認
- NFR 2.2 — リセット後 worktree 状態（origin/$BASE_BRANCH 最新 + clean）不変。CASE1 で確認

## Boundary 確認

- 差分は `local-watcher/bin/issue-watcher.sh` の `_worktree_reset()`（10116-10137 行目）に閉じている。diff stat はスクリプト本体 19 行のみ
- 親プロセスのサイクル冒頭 fetch（527 行目）は未変更（grep で確認。10127 行目の `git fetch origin --prune` 出現は新規 NOTE コメント内の記述のみ）
- `_worktree_reset` 以外の `git fetch` 呼び出し箇所は未変更（Out of Scope 準拠）
- 採用された修正方針は人間確定の方針 (a)（per-slot fetch 削除 + 親 fetch 依拠）であり、方針 (b)(c) 非採用は要件通り。boundary 逸脱なし
- `bash -n` 構文チェック OK。後方互換性（exit code 契約 / `[ ! -d "$wt" ]` ガード / reset --hard / clean -fdx / PARALLEL_SLOTS=1 挙動）を確認

## Findings

なし

## Summary

全 AC（1.1-1.3 / 2.1-2.3 / 3.1-3.3 / NFR 1.1 / NFR 2.1-2.2）に対応する実装と検証が揃っている。変更は `_worktree_reset()` に閉じ、親 fetch・他 fetch 箇所・後方互換契約は温存。本リポジトリは unit test フレームワーク無しのため、impl-notes 記載の `bash -n` / shellcheck（新規警告なし）/ 実 git による 4 CASE 単体検証で検証手段は妥当。boundary 逸脱・missing test・AC 未カバーいずれも検出されず。

RESULT: approve
