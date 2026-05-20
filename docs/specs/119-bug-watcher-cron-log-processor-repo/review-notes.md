# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-20T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-119-impl-bug-watcher-cron-log-processor-repo
- HEAD commit: 29782578cb0d6a2c26f550fd71c0c9b5f2ed3cec
- Compared to: main..HEAD
- CLAUDE.md `## Feature Flag Protocol` 節: 存在しない（opt-out として扱い、flag 観点の細目チェックはスキップ）
- 変更ファイル: 5 件（issue-watcher.sh / README.md / repo_prefix_log_test.sh / impl-notes.md / requirements.md）+701/-15 行

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh` の `pi_log` / `pi_warn` / `pi_error` が `[$REPO]` を時刻 prefix と `pr-iteration:` の間に挿入（issue-watcher.sh:1175-1186）。`repo_prefix_log_test.sh` Req 1.1 ケースで検証
- 1.2 — `mq_log` / `mq_warn` / `mq_error` に `[$REPO]` 挿入（issue-watcher.sh:734-746）。`repo_prefix_log_test.sh` Req 1.2 ケースで検証
- 1.3 — `mqr_log` / `mqr_warn` / `mqr_error` に `[$REPO]` 挿入（issue-watcher.sh:1033-1045）。`repo_prefix_log_test.sh` Req 1.3 ケースで検証
- 1.4 — `drr_log` / `drr_warn` / `drr_error` に `[$REPO]` 挿入（issue-watcher.sh:2148-2157）。`repo_prefix_log_test.sh` Req 1.4 ケースで検証
- 1.5 — `qa_log` / `qa_warn` / `qa_error` に `[$REPO]` 挿入（issue-watcher.sh:346-357）。`repo_prefix_log_test.sh` Req 1.5 ケースで検証
- 1.6 — `[$REPO]` で env 値そのままを埋め込む（テストで `my-org/keynest_for_mimamowellness` を実機事例として確認）
- 1.7 — 各ロガー出力で `[$REPO]` の出現回数が 1 行に 1 つのみ（`assert_count "1"` で pi_log / mq_log を検証）
- 1.8 — REPO=`owner/your-repo` のデフォルト値も `[owner/your-repo]` としてそのまま出力（Req 1.8 ケース）
- 2.1 — 時刻 prefix `[YYYY-MM-DD HH:MM:SS]` は不変。`assert_match_regex` で先頭一致を検証
- 2.2 — 既存 processor prefix（`pr-iteration:` / `merge-queue:` / `merge-queue-recheck:` / `design-review-release:` / `quota-aware:`）を不変保持（Req 2.2 / Req 2.3 ケース）
- 2.3 — 5 種類の processor prefix を空 args で出力して末尾 regex `prefix: ?$` を検証
- 2.4 — `[<REPO>] pr-iteration:` の隣接配置（Req 2.4 ケースで `[owner/test-repo] pr-iteration:` の連続を verify）。本文の句読点・カウンタ名は変更なし
- 3.1 — `git status --porcelain` で dirty 判定し `watcher: [$REPO] dirty working tree blocks BASE_BRANCH checkout` を 1 行目に出力（issue-watcher.sh:311-318）
- 3.2 — 続く 4 値 `current_branch=${_current_branch}` / `dirty_files=${_dirty_files}` / `head=${_head_sha}` / `action=escalate` を連続出力（issue-watcher.sh:319-322）。source-level test で 4 件確認
- 3.3 — dirty 検出ブロックが 318 行目、`process_merge_queue` メインフロー呼び出しが 1163 行目で構造的に上位。`exit 1` でも保証（issue-watcher.sh:323）
- 3.4 — dirty 検出後 `exit 1`（非 0）（issue-watcher.sh:323、test Req 3.4 で source 検査）
- 3.5 — dirty event 行に `[$REPO]` prefix が含まれ、Req 1 と同じ grep キー（`grep '\[owner/name\]'`）で抽出可能
- 4.1 — README.md「複数リポ運用時の cron.log grep 例」サブセクション追加（diff 593+42 行）
- 4.2 — `grep '\[owner/repo-a\]' $HOME/.issue-watcher/cron.log` 例（README 例 1）
- 4.3 — `grep -E 'pr-iteration: (WARN|ERROR|skip)' ...` 例（README 例 2）
- 4.4 — `grep 'watcher: \[.*\] dirty working tree blocks BASE_BRANCH checkout' ...` 例（README 例 3 / 4、`-A 4` 拡張版含む）
- 5.1 — 既存 README に `[<REPO>]` 前提の grep / sed サンプルは存在しないため、新節が新フォーマット例として機能（impl-notes に説明あり）。既存サンプルとの矛盾なし
- 5.2 — 同一 PR 内に挙動変更（commit `fix(watcher): ...`）と doc 追加（commit `docs(readme): ...`）が同居（git log で確認）
- 6.1 — `local-watcher/test/repo_prefix_log_test.sh` で 15 ロガー関数の出力に `[$REPO]` prefix が含まれることを 36 ケースで検証
- 6.2 — Req 3 の checkout 失敗イベント 4 行（current_branch / dirty_files / head / action）が cron.log に残ることを source-level test で検証（実機 E2E は impl-notes の手動スモークテスト手順でカバー）
- 6.3 — 既存 9 ファイル + 新規 1 ファイル = 10 テスト全件 PASS をローカル実行で確認（reviewer 側で再現済み）
- NFR 1.1〜1.4 — 既存 env var 名（`REPO` / `REPO_DIR` / `BASE_BRANCH` / `LOG_DIR` / `LOCK_FILE` 等）、cron 登録文字列、ログ出力ファイルパス、ラベル名、exit code 意味は全て不変
- NFR 2.1 — 各 echo は 1 イベント 1 行（改行なし）。`grep -c '^'` で行数 1 を verify
- NFR 2.2 — `[$REPO]` を時刻 prefix と processor prefix の間に固定配置することで `grep "\[owner/name\]"` の単一 grep で当該 repo の processor / watcher 系全行を抽出可能
- NFR 2.3 — dirty event 5 行を同一 stream（stderr）に連続 echo するため隣接行として観測可能
- NFR 3.1 — dirty 検出は `git status --porcelain` 1 回（既存 `git fetch` のコストに対して無視可）、`[$REPO]` 挿入は文字列リテラル（0ms）
- NFR 3.2 — 通常パス（dirty でない場合）の追加処理は `git status --porcelain` のみ。サイクル完了時間に影響なし

## Findings

なし

## Summary

Issue #119 の Requirement 1〜6 / NFR 1〜3 の全 numeric ID（合計 30 項目）が実装 + テストでカバーされており、boundary 逸脱なし。全 10 テスト + 新規 36 ケースが PASS（reviewer 側で再現確認済み）。shellcheck も既存 info 警告のみで新規追加分は 0 件。CLAUDE.md に Feature Flag Protocol opt-in 宣言がないため、通常の 3 カテゴリ判定のみを適用。

RESULT: approve
