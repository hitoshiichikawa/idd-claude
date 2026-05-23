# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-167-impl-bug-watcher-parallel-slots-1-worktree-re
- HEAD commit: b6c2d9bcbda6a49a6caec21fa7fe1e854130243e
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out として解釈（impl-notes でも opt-out 宣言）。flag 観点の確認は行わず、通常の 3 カテゴリ判定のみ実施
- 設計フェーズ: 本 Issue は small fix のため tasks.md / design.md は存在しない。boundary 判定は requirements.md の Out of Scope と impl-notes の対象範囲で実施

## Verified Requirements

- 1.1 — `_worktree_reset()`（issue-watcher.sh:10114-10139）から per-slot `git -C "$wt" fetch origin --prune` を削除。複数 slot 同時実行時の ref ロック取得競争元が関数から消滅。diff で担保
- 1.2 — 同上。fetch 削除により ref ロック競合起因の関数失敗が発生せず、競合のみを理由とした `claude-failed` 付与経路が断たれる
- 1.3 — 同上。失敗エラーコメント投稿の前提となる関数失敗が起きない（並列同時実行の実競合発生は E2E でのみ最終確認可能だが、根本原因の除去はコード差分で担保）
- 2.1 — `git reset --hard "origin/${BASE_BRANCH}"`（issue-watcher.sh:10131）温存。HEAD を origin 最新へ強制一致。impl-notes CASE1 / CASE4 で確認
- 2.2 — `git reset --hard` + `git clean -fdx`（issue-watcher.sh:10135）温存。tracked/untracked/ignored を消去。impl-notes CASE1（status --porcelain 空）で確認
- 2.3 — 親プロセスのサイクル冒頭 fetch（issue-watcher.sh:527 `cd "$REPO_DIR"; git fetch origin --prune`）が main と HEAD で同一であることを確認（diff に含まれない）。slot worktree は共有 .git の origin/$BASE_BRANCH 参照を起点に reset。impl-notes CASE4 で実証
- 3.1 — 末尾 `return 0`（issue-watcher.sh:10138）温存。成功時 exit 0
- 3.2 — `[ ! -d "$wt" ]` ガード（10116）、reset 失敗 `return 1`（10132）、clean 失敗 `return 1`（10136）すべて温存。失敗時 exit 1。impl-notes CASE2/CASE3 で確認
- 3.3 — reset/clean ロジック無変更。直列時は元々 ref ロック競合が起きず、削除した fetch 分の最新化は親 527 行目で代替。impl-notes CASE4 で代替妥当性を実証
- NFR 1.1 — fetch 削除方針自体が ref stale を許容。NOTE コメント（10119-10129）に明記。clean 起点確保を成功扱い
- NFR 2.1 — exit code 0/1 の意味不変。impl-notes CASE1-4 で契約維持を確認
- NFR 2.2 — リセット後 worktree 状態（origin/$BASE_BRANCH 最新 + clean）不変。impl-notes CASE1 で確認

## Boundary 確認

- 差分は `local-watcher/bin/issue-watcher.sh` の `_worktree_reset()`（10116-10138）に閉じている。実コードの変更は (1) per-slot fetch ブロックの削除、(2) NOTE コメント追加、(3) 残ステップのコメント番号 1./2. への振り直しのみ（reset/clean の挙動変更なし）
- 親プロセスのサイクル冒頭 fetch（527 行目）は main / HEAD で同一（diff に出現せず）。10127 行目の `git fetch origin --prune` 出現は新規 NOTE コメント内の記述のみで実行コードではない
- `_worktree_reset` 以外の `git fetch` 呼び出し箇所、worktree 作成ロジックは未変更（Out of Scope 準拠）
- 採用された修正方針は人間確定の方針 (a)（per-slot fetch 削除 + 親 fetch 依拠）。方針 (b) retry-with-backoff / (c) flock は非採用（Out of Scope 準拠）。boundary 逸脱なし
- `bash -n` 構文チェック OK。変更領域（10110-10140）に新規 shellcheck 警告なしを reviewer 側でも再確認

## テスト確認（missing test 観点）

- 本リポジトリは unit test フレームワークを持たず、CLAUDE.md「テスト・検証」節では静的解析（`bash -n` / shellcheck）+ 手動スモークテスト + 実 git ロジック検証が検証手段の正本
- impl-notes に `bash -n`（OK）、shellcheck（新規警告なし・既存件数完全一致）、実 git の bare repo を用いた 4 CASE 単体検証（CASE1 正常系 / CASE2 パス不在 / CASE3 reset 失敗 / CASE4 親 fetch のみで最新化）が記録され、各 AC との対応表も明示
- dry run の未完了は origin remote 未設定による早期 exit（527 行目）が原因で本変更箇所に到達しないため、本修正と無関係。CLAUDE.md テスト規約に照らし missing test 該当なし

## Findings

なし

## Summary

全 AC（1.1-1.3 / 2.1-2.3 / 3.1-3.3 / NFR 1.1 / NFR 2.1-2.2）に対応する実装と検証が揃っている。変更は `_worktree_reset()` に閉じ、親 fetch・他 fetch 箇所・後方互換契約（exit code 0/1・reset --hard・clean -fdx・PARALLEL_SLOTS=1 挙動）はすべて温存。Out of Scope（retry/flock 非採用・親 fetch 未変更・他 fetch 未変更・worktree 作成未変更）も準拠。AC 未カバー・missing test・boundary 逸脱いずれも検出されず。

RESULT: approve
