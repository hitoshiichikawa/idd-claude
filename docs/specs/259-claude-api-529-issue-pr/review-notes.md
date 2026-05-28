# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-28T09:26:56Z -->

## Reviewed Scope

- Branch: claude/issue-259-impl-claude-api-529-issue-pr
- HEAD commit: c9be515434dbcba95be28dc8f13d7d703bd072de
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/core_utils.sh` / `local-watcher/bin/modules/pr-iteration.sh` /
  `local-watcher/bin/issue-watcher.sh` / `README.md` / `docs/specs/259-claude-api-529-issue-pr/` 配下
  （requirements.md / impl-notes.md / test-fixtures/）
- 本 spec は design-less impl（`tasks.md` / `design.md` 不在）であり、AC は `requirements.md` の
  numeric ID 4 大要件 + NFR 3 件で形式的に追跡可能。`_Boundary:_` annotation は存在しないため
  既存 watcher 失敗経路への局所変更であることを diff から確認した。

## Verified Requirements

- 1.1 — `local-watcher/bin/modules/pr-iteration.sh:1222-1233` `case "$_pi_529_rc" in 0)` 分岐で
  `gh pr comment "$pr_number"` を発行し、529 警告本文を投稿している（`pi_run_iteration` の
  `claude_rc -ne 0` ブロック内）。
- 1.2 — 同上の `0)` 分岐は警告コメント投稿のみ実施し、既存の `recover_status` / no-progress
  streak / `needs-iteration` ラベル付与・除去には触れていない（diff 上で `recover_status` /
  `needs-iteration` 周辺の修正なし）。
- 1.3 — `*)` 分岐 (line 1237-1239) が `pi_log "...not detected"` だけで `gh pr comment` を
  呼ばないことで担保。
- 1.4 — 529 検知ブロック全体が `if [ "$claude_rc" -ne 0 ]` 配下 (line 1207) にのみ存在し、
  正常終了経路では検知自体が走らない。
- 1.5 — `claude_log_detect_529` が rc=2（ファイル不在 / 読み取り不能）を返した場合、`2)` 分岐
  (line 1234) は `pi_warn` のみで `gh pr comment` を呼ばない。post-round-recover 経路への
  分岐は変更されていないため既存処理を妨げない。test-fixtures の rc=2 ケース 2 件で関数挙動を
  確認済み。
- 2.1 — `local-watcher/bin/issue-watcher.sh:4565-4575` の `mark_issue_failed` 内
  `case "$_mif_529_rc" in 0)` 分岐で `body` 末尾に 529 警告ブロックを追加してから既存の
  `gh issue comment` 投稿に流す。
- 2.2 — `*)` 分岐 (line 4579-4581) は `body` を改変せず `$LOG` への 1 行追記のみ。
- 2.3 — `mark_issue_failed` は本機能導入前から失敗経路（`run_impl_pipeline` の各 stage 失敗 /
  Reviewer error / reject2 等）からのみ呼ばれており、本 PR でも呼び出し箇所の追加・改変なし。
- 2.4 — `2)` 分岐 (line 4576-4578) は `body` を改変しない。直前の `gh issue edit ... --add-label
  claude-failed` (line 4546-4547) および直後の `gh issue comment "$NUMBER" --repo "$REPO"
  --body "$body" || true` (line 4594) はいずれも 529 検知 rc に依存しないため、ラベル付与と
  コメント投稿責務は完遂される。
- 3.1 — PR / Issue 双方の警告本文に `Claude API 一時混雑エラー (529 Overloaded)` を日本語で
  明示（pr-iteration.sh:1226 / issue-watcher.sh:4574）。
- 3.2 — PR 側: `混雑のため一時処理を中断しました`。Issue 側: `一時的な混雑によるエラーの可能性
  があるため`。いずれも一時障害である旨を運用者に伝える文言を含む。
- 3.3 — PR 警告本文に `進捗（Round数等）は据え置かれ、次のポーリングサイクルで自動再試行します`
  を明記（pr-iteration.sh:1226）。
- 3.4 — Issue 警告本文に `時間をおいて再試行してください` を明記（issue-watcher.sh:4574）。
- 4.1 — `claude_log_detect_529` の実装は `grep -qE` によるローカルログファイル読み取りのみで
  Claude API への新規呼び出しなし（core_utils.sh:151-185）。
- 4.2 — `claude-failed` / `needs-iteration` / `claude-picked-up` を扱う `gh issue edit` /
  `gh pr edit` 行に変更なし（diff 上で該当行の追加・削除なし）。
- 4.3 — 既存ログ行への変更なし。529 関連の新規ログは `pi_log` / `pi_warn` / `echo "..." >>"$LOG"`
  の独立行追加のみ。
- 4.4 — `claude_log_detect_529` 呼び出しは `|| _rc=$?` で rc を握り、`$LOG` への append は
  `|| true` で失敗を吸収。`gh pr comment` 失敗は `pi_warn` のみで既存処理に伝播しない
  （pr-iteration.sh:1229-1232）。
- NFR 1.1 — `set -euo pipefail` 配下でも `claude_log_detect_529` の grep 戻り値は関数内で
  `return 0/1/2` に変換されており致命化しない。呼び出し元も `|| _rc=$?` で吸収。
- NFR 1.2 — PR 側は `pi_run_iteration` が round あたり 1 回呼ばれる構造により自然に 1 コメント /
  round に収まる（hidden marker `<!-- idd-claude:pr-iteration-529-warning round=N -->` も同梱）。
  Issue 側は失敗通知コメント本文に内包するため 1 失敗イベント = 1 コメント。
- NFR 2.1 — detected / not-detected / log-missing の 3 状態それぞれが `pi_log` / `pi_warn` /
  `$LOG` 直接 append で 1 行記録されている。
- NFR 3.1 — 新規 env 変数なし、既存 env / ラベル / cron 文字列への変更なし（diff 上で
  該当箇所の追加・削除なし）。

## Findings

なし

## Summary

requirements.md の全 numeric ID（1.1〜1.5 / 2.1〜2.4 / 3.1〜3.4 / 4.1〜4.4 / NFR 1.1, 1.2, 2.1, 3.1）に
ついて、対応する実装またはテスト fixture が確認できた。`claude_log_detect_529` は副作用なしの
純粋関数として core_utils.sh に分離され、PR / Issue 双方の失敗経路に対し defensive な呼び出し
（`|| _rc=$?` / `|| true`）で組み込まれているため、既存挙動（needs-iteration 据え置き / claude-failed
ラベル遷移 / 失敗通知コメント投稿）の後方互換性が維持されている。fixture スモークテスト 10 件
PASS および shellcheck クリーンも reviewer 側で再実行して確認した。tasks.md / design.md 不在の
design-less impl だが Issue #259 の要件範囲は局所的（watcher 失敗経路への警告ブロック追加）で
あり、_Boundary:_ アノテーション不在による境界判定不能の問題は発生しない。

RESULT: approve
