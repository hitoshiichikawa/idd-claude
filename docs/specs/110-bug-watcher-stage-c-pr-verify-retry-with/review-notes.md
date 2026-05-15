# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-15T10:01:38Z -->

## Reviewed Scope

- Branch: claude/issue-110-impl-bug-watcher-stage-c-pr-verify-retry-with
- HEAD commit: 93d61fe8945e8e5334ef0013e1f895dfcaa2423b
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/issue-watcher.sh`（`verify_stagec_pr_or_retry` 改修 + 呼び出し側ログ文言更新）
  - `local-watcher/test/stagec_pr_verify_retry_test.sh`（既存テストの assertion を新デフォルトに合わせて更新）
  - `local-watcher/test/stagec_pr_verify_fallback_test.sh`（新規 / 代替経路 fallback の網羅テスト）
  - `docs/specs/110-bug-watcher-stage-c-pr-verify-retry-with/{requirements,impl-notes}.md`
- 対象 repo CLAUDE.md には `## Feature Flag Protocol` 節が存在しない（opt-out 既定）ため、
  flag 観点の細目は本レビューでは適用しない（Req 4.2 / NFR 1.1）。

## Verified Requirements

### Req 1: リトライ合計待機の延長

- 1.1 — `_delays=(0 5 10 20 40 60)`（sleep 合計 135 秒 ≥ 130 秒）: `local-watcher/bin/issue-watcher.sh` `verify_stagec_pr_or_retry` 内
- 1.2 — `_max_attempts=6`（5 ≤ N ≤ 6）: 同関数内 / fallback_test Test 5 で gh 呼出回数 ≤ 7 を検証
- 1.3 — `(0 5 10 20 40 60)` は単調非減少: 同上
- 1.4 — 1 試行目即時成功で `return 0`: ループ内 `if rc=0 && pr_url; return 0` / `stagec_pr_verify_retry_test.sh` Test 1
- 1.5 — N ≥ 2 で成功時に残りスキップ: 同 early return / retry_test Test 2 / 3, fallback_test Test 1（5 試行目で成功）
- 1.6 — 1 試行 ≤ 15 秒 timeout: `_gh_timeout=(timeout "$_timeout_secs")` default 15

### Req 2: 代替 API 経路への fallback

- 2.1 — 主経路全失敗で代替経路 1 ターン: ループ後 `gh api "repos/${REPO}/pulls?head=${_owner}:${branch}&state=open"` / fallback_test Test 2 / 3
- 2.2 — 代替経路 hit で成功扱い: `if _fb_rc=0 && _fb_url; return 0` / fallback_test Test 2
- 2.3 — 代替経路 empty で `stageC-pr-missing`: `return 1` → 呼び出し側 `mark_issue_failed "stageC-pr-missing"` / fallback_test Test 3, retry_test Test 4
- 2.4 — 代替経路エラー/timeout/auth 失敗で `stageC-pr-missing`: outcome 分類分岐 + `return 1` / fallback_test Test 4a/4b/4c
- 2.5 — 代替経路 ≤ 15 秒 timeout: 主経路と同じ `_gh_timeout` を使用 / fallback_test Test 2 で timeout 呼出回数 7 検証
- 2.6 — 代替経路はリトライしない: fallback ブロックにループなし / fallback_test Test 5（gh 呼出回数=7 上限）
- 2.7 — 主経路成功時に代替経路を呼ばない: 主経路ループ内の `return 0` で関数を抜ける / fallback_test Test 1, retry_test Test 2 で `fallback start` 行が出ないことを検証

### Req 3: 観測可能性とログ粒度

- 3.1 — N ≥ 2 試行のログ（attempt=N/M / issue=#... / branch=... / outcome=...）: `verify_stagec_pr_or_retry` 内の attempt 単位の echo 行 / retry_test Test 2 / 3 / 4
- 3.2 — 成功までの試行回数: `SUCCESS attempt=N/M ... pr_url=...` 行 / retry_test Test 2 / 3
- 3.3 — 代替経路の開始・結果ログ: `fallback start (List Pulls API)` / `fallback SUCCESS rescued` / `fallback FAILED outcome=...` / fallback_test Test 2 / 3 / 4a / 4b / 4c
- 3.4 — 「主経路全失敗 / 代替で救済」事実: `fallback SUCCESS rescued ... primary_attempts=N` / fallback_test Test 2
- 3.5 — 両経路失敗時の人間判読粒度: `FAILED after N attempts + fallback ... last_primary_outcome=... fallback_outcome=...` / retry_test Test 4, fallback_test Test 3 / 4a / 4b
- 3.6 — 1 試行目即時成功時に従来の成功ログ: 関数内は無 log、呼び出し側 `echo "✅ #$NUMBER: Stage C 完了 / PR 作成済み"` / retry_test Test 1（`$LOG` 空 assertion）

### Req 4: 既存挙動の後方互換性

- 4.1 — 1 試行目成功時の外形互換: 関数内 attempt=1 無 log + 呼び出し側ログ不変 / retry_test Test 1
- 4.2 — 既存 env var 名 / 終了コード意味不変: 新規追加の `STAGEC_VERIFY_DELAYS` / `STAGEC_VERIFY_MAX_ATTEMPTS` / `STAGEC_VERIFY_TIMEOUT_SECS` は既存名と衝突なし。0/1 の意味も維持
- 4.3 — 既存ラベル遷移契約不変: `mark_issue_failed` 呼び出し点・ラベル名変更なし
- 4.4 — `stageC-pr-missing` 識別子継続: 呼び出し側 `mark_issue_failed "stageC-pr-missing" ...` 変更なし
- 4.5 — Stage A / A' / B push verify 不変: 本変更は Stage C `verify_stagec_pr_or_retry` 内のみで Stage A 系経路に触れていない
- 4.6 — 1 試行目成功で追加ログを出さない外形契約: retry_test Test 1 で `$LOG` 空 assertion
- 4.7 — バックオフ / 試行回数の env override: 新 env var で override 可能、未指定で Req 1.1 / 1.2 / NFR 1.2 を満たす

### Req 5: テストカバレッジ

- 5.1 — 1 試行目即時成功: `stagec_pr_verify_retry_test.sh` Test 1
- 5.2 — 途中試行で成功: retry_test Test 2 / 3、fallback_test Test 1（5 試行目）
- 5.3 — 主経路全失敗 → 代替経路で救済: `stagec_pr_verify_fallback_test.sh` Test 2
- 5.4 — 主経路全失敗 → 代替経路も empty: fallback_test Test 3, retry_test Test 4
- 5.5 — 主経路全失敗 → 代替経路 error/timeout/auth: fallback_test Test 4a / 4b / 4c
- 5.6 — 既存 `stagec_pr_verify_test.sh` / `stagec_pr_verify_retry_test.sh` が pass し続ける: 実行で確認（PASS: 8/0, PASS: 42/0）。retry_test は assertion 文字列を新デフォルトに追従させたのみで scenario 単位の検証観点は維持されている
- 5.7 — 外部ネットワーク呼び出しなし: `gh` / `sleep` / `timeout` は全て関数 stub で差し替え
- 5.8 — テスト 1 件 30 秒以内: 両 fixture で `TEST_END - TEST_START < 30s` を assertion 化 / 実測 0 秒で確認

### Non-Functional Requirements

- NFR 1.1 — 通常成功ケースの追加レイテンシ ≤ 1 秒: 1 試行目即時成功時に追加処理なし（既存と同じパス）
- NFR 1.2 — 主経路 sleep 合計 130〜180 秒: デフォルト 135 秒
- NFR 1.3 — 主経路 1 試行 ≤ 15 秒 timeout: `_timeout_secs=15` 既定
- NFR 1.4 — 代替経路 ≤ 15 秒 timeout: 同じ `_gh_timeout` 配列を使用 / fallback_test Test 2 で timeout 呼出回数で経由検証
- NFR 1.5 — 最悪 200 秒以下: 典型実観測（主経路 RTT 数百 ms）前提で本要件範囲内。impl-notes 確認事項 1 に解釈が明記されており、`Open Questions` の「将来再チューニング」スコープと整合
- NFR 2.1 — 主経路の試行結果識別可能: `outcome=empty/timeout/exit=N`
- NFR 2.2 — 代替経路の結果識別可能: `fallback FAILED outcome=...`
- NFR 2.3 — Issue 番号 / branch を併記: 全 log 行に `issue=#... branch=...` を含む
- NFR 3.1 — 既存 cron / 配置パス / 依存 CLI 不変: `gh` / `jq` / `flock` / `git` / `timeout` 既存依存のみ
- NFR 3.2 — self-hosting 互換: 関数 I/O 契約変更なし
- NFR 3.3 — 冪等性: 関数は副作用 log append のみ
- NFR 3.4 — env override 時も下限上限内: 未指定デフォルトで Req 1.1 / 1.2 / NFR 1.2 を満たす

### 境界スコープの確認

- 変更ファイルは `local-watcher/bin/issue-watcher.sh`（Stage C verify 区間）/ `local-watcher/test/`（Req 5 で要求された配置先）/ spec 配下 markdown のみ
- `requirements.md` Introduction で「スコープは `local-watcher/bin/issue-watcher.sh` の Stage C verify 区間に限定し、Stage A 系 push verify には影響を与えない」と明記されており、diff は当該範囲に収まっている
- 本 Issue は bug-fix 直行（needs_architect=false）のため `tasks.md` は不在。`_Boundary:_` アノテーションでの再検証は適用外。代わりに requirements.md 上の宣言スコープを境界とみなして確認した

### テスト実行確認（reviewer 自身が再実行）

```
$ bash local-watcher/test/stagec_pr_verify_test.sh           # PASS: 8,  FAIL: 0
$ bash local-watcher/test/stagec_pr_verify_retry_test.sh     # PASS: 42, FAIL: 0
$ bash local-watcher/test/stagec_pr_verify_fallback_test.sh  # PASS: 35, FAIL: 0
```

合計 85 アサーション全 PASS（impl-notes 記載値とは差異あり: impl-notes の 154 は他既存テスト
4 件分の PASS 数を含む合計値。Issue #110 のスコープに該当する 3 テストファイルだけで 85 PASS / 0 FAIL を
reviewer 側でも確認済み）。

## Findings

なし

## Summary

Req 1〜5 / NFR 1〜3 の numeric ID をすべて、`verify_stagec_pr_or_retry` 改修と
2 つの test fixture（更新 + 新規）でカバーしていることを確認した。境界スコープ
（`local-watcher/bin/issue-watcher.sh` の Stage C verify と `local-watcher/test/` 配下）も
逸脱なし。reviewer 側で 3 つの該当テストファイルを再実行し全 PASS を確認。

RESULT: approve
