# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-08T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-296-impl-fix-watcher-reviewer-review-notes-md-rc
- HEAD commit: 425b8d72e5744b80fb32054ee53e9dd4320486f6
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `parse_review_result` がファイル不在で `rc=3` を返す（`local-watcher/bin/issue-watcher.sh:4827`）。`parse_review_result_test.sh` の "missing file: parse rc=3" で検証
- 1.2 — ファイルあり + RESULT 抽出失敗で `rc=2` 維持（同 `:4835`）。`no-result: parse rc=2` で検証
- 1.3 — `rv_log` / `pt_log` の reason 文字列が `missing-file` / `missing-file-after-retry` / `parse-failed` で区別される（`:3253-3266` / `:4965-4978`）
- 2.1 — `run_reviewer_stage` / `run_per_task_reviewer` の `for attempt in 1 2; do` ループで同一 round 内 1 回再起動（`:4906` / `:3206`）。`test-retry-loop.sh` Pattern A/B で検証
- 2.2 — リトライで approve 生成時に通常経路（`break` → `result` 取得）に合流（`:4961` / `:3253-3261`）。Pattern A で rc=0 を確認
- 2.3 — リトライ後も不在で `rc=4` を返し、呼び出し側 6 箇所で `reviewer-missing-file` / `per-task-reviewer-missing-file` カテゴリの `mark_issue_failed` を呼ぶ（`:6253` / `:6239` / `:6192` / `:3860` / `:3840` / `:3796`）。Pattern B で検証
- 2.4 — ループ上限を `for attempt in 1 2; do` で 2 回固定。Pattern B/E で `RETRY_ATTEMPT_COUNT=2` を確認
- 2.5 — `rv_log "round=$round attempt=2 retry reason=missing-file"` 等で観測可能（`:4920` / `:3211`）
- 3.1 — `parse_review_result` は `notes_path` 引数のファイル内 RESULT トークンのみを参照（既存挙動を維持、orchestrator 最終メッセージ・トランスクリプトに依存する経路は実装にない）
- 3.2 — 実装変更なし（既存ふるまいの維持）。orchestrator 最終メッセージを判定に使う経路は存在しない
- 3.3 — トランスクリプト中 `RESULT:` 文字列に依存する fallback は実装にない
- 4.1 — 単発 Reviewer 経路 `run_reviewer_stage` に retry loop + rc=4 を実装（`:4870-4985`）
- 4.2 — per-task Reviewer 経路 `run_per_task_reviewer` に対称実装（`:3174-3274`）
- 4.3 — Debugger 経由 round=3 の rc=4 case も両経路に追加（`:6189-6195` 単発 / `:3793-3799` per-task）
- 5.1 — 装飾耐性パース（`extract_review_result_token` 経由）に変更なし。`decoration approve/reject: parse rc=0` で維持確認
- 5.2 — 「最後のマッチを採用」挙動に変更なし。`multi-last-wins approve/reject: parse rc=0` で維持確認
- 5.3 — 装飾起因 `rc=2` ではリトライしない（case 文で `*) return 2` 即時返却）。Pattern D で `RETRY_ATTEMPT_COUNT=1` を確認
- NFR 1.1 — 既存 env var / ラベル / exit code（rc=0/1/2/99）の意味不変。新規 rc=3 / rc=4 のみ追加
- NFR 1.2 — 既存正常系（即時 approve）の挙動同値。Pattern C + 既存 19 ケース継続 PASS
- NFR 2.1 — round / attempt / reason を 1 行ログに記録（`rv_log` / `pt_log`）
- NFR 2.2 — `reviewer-missing-file` / `per-task-reviewer-missing-file` カテゴリは既存 `reviewer-error` と grep で区別可能
- NFR 3.1 — `for attempt in 1 2; do` 固定で 2 回を超える起動は構造的に不可能
- NFR 3.2 — `claude-failed` 付与後に `return 1` / `return 4` で抜けるため round を超えた追加再起動は発生しない

## Findings

なし

## Summary

Issue #296 の全 AC（Req 1.1〜5.3 + NFR 1.1〜3.2、合計 16 件 + 関連）に対する実装とテストが揃っている。`parse_review_result` がファイル不在で新規 `rc=3` を返し、`run_reviewer_stage` / `run_per_task_reviewer` の双方が同一 round 内 1 回限定リトライを実施、失敗時は `rc=4` を返して呼び出し側 6 箇所が `reviewer-missing-file` / `per-task-reviewer-missing-file` カテゴリで `claude-failed` を付与する。装飾耐性パース（#63）はリグレッションなし。`parse_review_result_test.sh` 23 件 + `test-retry-loop.sh` 11 件 PASS、`shellcheck` 警告ゼロを再現確認した。境界違反なし（変更は `local-watcher/bin/issue-watcher.sh` / `local-watcher/test/` / spec 配下 fixture のみで、agents/rules の二重管理対象は不触）。

RESULT: approve
