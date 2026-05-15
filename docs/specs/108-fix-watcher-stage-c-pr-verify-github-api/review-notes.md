# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-15T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-108-impl-fix-watcher-stage-c-pr-verify-github-api
- HEAD commit: f4b32083db3080019329d2f9ada17e1bb4c23124
- Compared to: main..HEAD
- Commits:
  - 0037754 fix(watcher): Stage C PR verify を retry-with-backoff 化 (#108)
  - 54cad3c test(watcher): verify_stagec_pr_or_retry の retry fixture テスト追加 (#108)
  - f4b3208 docs(specs): add impl-notes for #108
- Changed files:
  - `local-watcher/bin/issue-watcher.sh` (+103 / -8): `verify_stagec_pr_or_retry` 新設、Stage C `case 0)` の inline `gh pr view` 呼び出しを置換
  - `local-watcher/test/stagec_pr_verify_retry_test.sh` (+310 新規): retry 経路テスト（34 ケース）
  - `local-watcher/test/stagec_pr_verify_test.sh` (+16 / -3): サニティ grep の対象更新（既存 8 ケースは継続 pass）
  - `docs/specs/108-.../requirements.md` (+122 新規)
  - `docs/specs/108-.../impl-notes.md` (+163 新規)
- Note: 本 Issue は Architect 起動なし（`tasks.md` / `design.md` は存在しない）。境界制約は
  `requirements.md` の Scope 文（Stage C verify 区間に限定、Stage A 系・GH Actions 経路は非対象）
  と CLAUDE.md の境界方針（既存 env var / ラベル / cron 後方互換性）で評価した。
- Feature Flag Protocol: ルートの `CLAUDE.md` には `## Feature Flag Protocol` h2 節が存在しない。
  → opt-out として解釈し、flag 観点の確認は行わない。

## Verified Requirements

- 1.1 — 最大 4 回試行: `_max_attempts=4` (`issue-watcher.sh:3349`) / retry_test Test 4 (gh 呼出回数=4)
- 1.2 — 1 回目成功で即時継続: `if [ "$rc" -eq 0 ] && [ -n "$pr_url" ]` 直後の `return 0` / retry_test Test 1 (gh 呼出回数=1)
- 1.3 — N 回目成功で残りリトライ打ち切り: `while` ループからの `return 0` / retry_test Test 2（2 回目）/ Test 3（3 回目）
- 1.4 — 段階的待機 (0/5/10/20 秒、合計 35 秒): `_delays=(0 5 10 20)` / 数値合計が 35
- 1.5 — 1 試行 15 秒タイムアウト: `_gh_timeout=(timeout 15)` の inline 注入
- 1.6 — 自動リトライ上限 4: `while [ "$attempt" -le "$_max_attempts" ]` で 5 回目を呼ばない / retry_test Test 4 (gh 呼出回数=4)
- 2.1 — 4 回失敗で `stageC-pr-missing` 化: `return 1` 後の呼出側 `mark_issue_failed "stageC-pr-missing"` 配線 (`issue-watcher.sh:3726`) / retry_test Test 4 (rc=1)
- 2.2 — 全失敗で成功ログを出さない: 失敗パスは `tee` で `❌` を出力、`✅ Stage C 完了 / PR 作成済み` 行は成功パスのみ / retry_test Test 4 (`SUCCESS` 行不在 assert)
- 2.3 — 合計 35 秒以内: sleep 合計 0+5+10+20=35（実装値で担保）
- 2.4 — 一時失敗でも上限まで継続: 失敗時 `continue` 相当の `attempt+=1` のみ / retry_test Test 5 (exit=1/empty/timeout 混在で 4 回継続)
- 3.1 — N>=2 試行で単一行ログ: `outcome=...` 行を attempt=1 から残す / retry_test Test 2/Test 4 で `attempt=N/4 outcome=...` 行を検出
- 3.2 — 成功までの試行回数を識別可能に記録: `SUCCESS attempt=${attempt}/${_max_attempts}` 行 / retry_test Test 2/Test 3 で assert
- 3.3 — 全失敗時に Issue 番号 / 対象 branch / 試行回数 / 最終失敗要因: `FAILED after ${_max_attempts} attempts ... last_rc=${rc} last_pr_url='...'` / retry_test Test 4 で assert
- 3.4 — 1 回目成功時に従来の成功ログ: 呼出側 `echo "✅ #$NUMBER: Stage C 完了 / PR 作成済み"` を維持、関数内では 1 回目時のみログ抑止 / retry_test Test 1 (`$LOG` 空)
- 4.1 — 1 回目成功時の外形互換: 関数内 `if [ "$attempt" -gt 1 ]` で SUCCESS ログを 2 回目以降のみ出力 / retry_test Test 1 で `$LOG` 空を assert
- 4.2 — 既存 env var 不変更: 新規追加 `STAGEC_VERIFY_SLEEP_CMD` のみ。`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等は不変
- 4.3 — 既存ラベル契約不変更: 呼出側で `mark_issue_failed "stageC-pr-missing"` の配線を維持
- 4.4 — `stageC-pr-missing` 識別子継続使用: `issue-watcher.sh:3726` で文字列リテラル維持
- 4.5 — Stage A / A' / B 系の挙動不変更: `verify_pushed_or_retry` 関数本体に diff なし（新規追加箇所のみ）
- 5.1 — 1 回目成功テスト: `stagec_pr_verify_retry_test.sh` Test 1
- 5.2 — 途中試行で成功テスト: 同上 Test 2 / Test 3
- 5.3 — 全試行失敗テスト: 同上 Test 4 / Test 5
- 5.4 — 既存テスト継続 pass: `stagec_pr_verify_test.sh` 8 ケース pass を実行確認
- 5.5 — 外部ネットワーク呼出なし: `gh` / `timeout` を shell 関数で stub、`STAGEC_VERIFY_SLEEP_CMD=":"` で sleep を no-op 化
- 5.6 — テスト 1 件 30 秒以内: retry_test Test 6 で `ELAPSED < 30s` を assert（実測 0s）
- NFR 1.1 — 通常成功 +1 秒以内: 1 回目即時成功時は sleep 0 / log なし。手動スモークで 3ms 実測（impl-notes 記載）
- NFR 1.2 — 合計 35 秒以内: 待機合計 35 秒（実装値担保）
- NFR 1.3 — 1 試行 15 秒タイムアウト: `_gh_timeout=(timeout 15)`
- NFR 2.1 — 試行結果の種別識別可能: `outcome=timeout|exit=N|empty` 分類 / retry_test Test 3 / Test 5 で各種別 assert
- NFR 2.2 — Issue / branch スコープで突合可能: 全ログ行に `issue=#${issue_number}` `branch=${branch}` を含む / retry_test Test 2 / Test 4 で assert
- NFR 3.1 — cron / launchd / 依存 CLI 前提不変更: `bash -n` syntax check + 追加依存なし（既存 `gh` / `timeout` のみ）
- NFR 3.2 — self-hosting 対応: pure bash / 追加依存なし。次回 cron 実行で有効化

## Findings

なし

## Summary

要件 5 系統 / NFR 3 系統 / 全 numeric ID（合計 26 項目）について、対応する実装と
テストカバレッジの両方を確認した。`shellcheck` の新規警告ゼロ。retry_test 34 ケース / 既存
stagec_pr_verify_test 8 ケースともに pass。Stage C verify 区間外（Stage A 系 / GH Actions 経路）
への変更はなく、`requirements.md` のスコープ境界（Out of Scope を含む）を遵守している。
新規 env var `STAGEC_VERIFY_SLEEP_CMD` はテスト fixture 用途で関数定義上にコメントで
明示されており、既存 env var との衝突なし（Req 4.2 / NFR 3.1）。

RESULT: approve
