# 実装ノート — Issue #108

## 実装サマリ

GitHub API の eventual consistency に起因する Stage C PR verify の false negative を吸収するため、
`local-watcher/bin/issue-watcher.sh` に retry-with-backoff 関数 `verify_stagec_pr_or_retry` を新設し、
既存 Stage C 完了処理（`run_impl_pipeline` 内の `case "$_qa_rc_c" in 0)` ブロック）の inline `gh pr view`
呼び出しを新ヘルパー経由に置換した。

### 追加した関数

`verify_stagec_pr_or_retry`（`local-watcher/bin/issue-watcher.sh:3293-3380` 周辺）

- 引数: `$1` = 対象 branch、`$2` = Issue 番号（ログ識別用）
- 戻り値: 0（成功時 stdout に PR URL）/ 1（4 回全試行で取得失敗）
- 試行回数: 4 回 / 待機: `(0, 5, 10, 20)` 秒 / 1 試行 `timeout 15` 秒 — Issue 本文・要件で確定済みの値
- `command -v timeout` で timeout コマンドの有無を判定（既存 `verify_pushed_or_retry` と同方針）
- 各試行結果（empty / exit=N / timeout）を `outcome=...` 形で `$LOG` に分類記録

### 置換した呼び出し箇所

`run_impl_pipeline` 内 Stage C 完了 `case 0)` ブロック（`issue-watcher.sh:3614-3615` 付近）の inline
`gh pr view --repo "$REPO" --head "$BRANCH" --json url --jq '.url'` を `verify_stagec_pr_or_retry "$BRANCH" "$NUMBER"`
に置換。終了コード・ラベル遷移・`stageC-pr-missing` 識別子の意味は変更なし（Req 4 系後方互換性）。

## sleep fake 化の機構と env var 名

- env var 名: `STAGEC_VERIFY_SLEEP_CMD`
- デフォルト: `sleep`（本番運用では実時間待機）
- テストでは `STAGEC_VERIFY_SLEEP_CMD=":"` を設定して、shell builtin の `:` を no-op として注入
  （`:` は POSIX shell builtin で常に rc=0、引数を捨てる）
- 本 env var は内部 fixture 用で、本番運用での override は想定していない（CLAUDE.md の
  「既存 env var 名を後方互換性のため壊さない」方針には抵触しない — 新規追加であり既存 env var
  ではない）

## 追加した test ファイル

### `local-watcher/test/stagec_pr_verify_retry_test.sh`（新規 / 34 ケース PASS）

| Test | 目的 | 対応 Req |
|---|---|---|
| Test 1 | 1 回目で PR URL 取得 → 即時成功（外形互換）| Req 1.2 / Req 5.1 / NFR 1.1 / Req 4.1 |
| Test 2 | 1 回目空応答 → 2 回目で URL 取得 | Req 1.3 / Req 5.2 / Req 3.1 / Req 3.2 |
| Test 3 | 1 回目 empty / 2 回目 timeout / 3 回目で URL 取得 | Req 1.3 / Req 5.2 / NFR 2.1 |
| Test 4 | 4 回全て空応答 → rc=1（呼出側で claude-failed 化）| Req 1.6 / Req 2.1 / Req 2.2 / Req 3.3 |
| Test 5 | 失敗種別混在（exit=1 / empty / timeout）でも上限まで継続 | Req 2.4 / NFR 2.1 |
| Test 6 | 実時間待機なしで全テストが 30 秒以内 | Req 5.6 |

実装上の補足:
- `gh` / `timeout` を shell 関数で stub
- `verify_stagec_pr_or_retry` は `$(...)` で stdout 捕捉するため subshell 内実行となる。
  したがって gh 呼出回数を parent shell から観測するためにファイル (`$GH_COUNTER_FILE`) を介す
- gh stub の応答は `GH_RESPONSES` 配列で順序指定（空文字列 / `ERR:N` / URL 文字列のいずれか）

### `local-watcher/test/stagec_pr_verify_test.sh`（既存 / 全 8 ケース pass 継続）

- サニティチェックの grep 対象を新ヘルパー (`verify_stagec_pr_or_retry()` 定義 / 呼出配線 /
  ヘルパー内部の `gh pr view --head "$branch"`) に更新
- `_test_stagec_complete`（仕様レベル再現関数）の本体は変更なし — Req 4.1〜4.4（Issue #104 由来の
  spec contract）は新実装でも変わらないため、既存テストケースは全 8 件継続 pass する（Req 5.4）

## shellcheck 結果

`shellcheck local-watcher/bin/issue-watcher.sh` — 警告数 58 行（変更前と同数）。**新規警告ゼロ**。
既存 SC2317 / SC2012 (info) はすべて変更前から存在するもの。

`shellcheck local-watcher/test/stagec_pr_verify_retry_test.sh local-watcher/test/stagec_pr_verify_test.sh` —
SC2317 (info, 呼び出し元が間接呼出のため unreachable 判定) のみ。**error / warning は 0 件**。
SC2016（単一引用符内の `\$` を文字列リテラルとして grep する箇所）は意図的なため `# shellcheck disable=SC2016` で抑止済み。

## 手動スモークテスト

`/tmp/smoke-stagec.sh` で `verify_stagec_pr_or_retry` を extract → 1 回目で URL を返す happy path を実行:

```
Smoke result: 'https://github.com/owner/test/pull/108' (elapsed: 3ms / NFR 1.1: <1000ms 増分)
LOG content (should be empty for 1 回目即時成功 / Req 4.1):
(end)
```

- NFR 1.1 充足: 通常成功ケースで verify 全体 < 1 秒（実測 3 ms）
- Req 4.1 充足: 1 回目即時成功時に `$LOG` への追加進捗ログなし（本変更前と外形互換）

また `bash -n local-watcher/bin/issue-watcher.sh` で構文チェックを通している。

## 全テスト実行結果

```
local-watcher/test/parse_review_result_test.sh      19 PASS / 0 FAIL
local-watcher/test/qa_detect_rate_limit_test.sh     10 PASS / 0 FAIL
local-watcher/test/qa_run_claude_stage_test.sh      23 PASS / 0 FAIL
local-watcher/test/stagec_pr_verify_retry_test.sh   34 PASS / 0 FAIL  (新規)
local-watcher/test/stagec_pr_verify_test.sh          8 PASS / 0 FAIL  (sanity check 更新)
local-watcher/test/verify_pushed_or_retry_test.sh   17 PASS / 0 FAIL
────────────────────────────────────────────────────────────────
合計                                               111 PASS / 0 FAIL
```

## 要件 numeric ID → テストカバレッジ対応

| Req ID | カバレッジ |
|---|---|
| Req 1.1 (最大 4 回試行) | retry_test Test 4（4 回呼出を gh call counter で確認）|
| Req 1.2 (1 回目成功で即時継続) | retry_test Test 1（gh 呼出回数=1）|
| Req 1.3 (N 回目で成功時に残りリトライ打ち切り) | retry_test Test 2（呼出回数=2）/ Test 3（呼出回数=3）|
| Req 1.4 (待機 0/5/10/20 秒、合計 35 秒以内) | 実装値そのもの（`_delays=(0 5 10 20)`）/ retry_test Test 6（fake sleep 注入下で全テスト 30s 以内）|
| Req 1.5 (1 試行 timeout 15 秒) | 実装値そのもの（`_gh_timeout=(timeout 15)`）|
| Req 1.6 (リトライ上限 4) | retry_test Test 4（5 回目を呼ばないことを呼出回数=4 で確認）|
| Req 2.1 (4 回失敗で `stageC-pr-missing` 化) | retry_test Test 4（rc=1 + 呼出側で `mark_issue_failed "stageC-pr-missing"` 配線維持） + 既存 stagec_pr_verify_test の PR 不在ケース |
| Req 2.2 (全失敗で成功ログなし) | retry_test Test 4 (`$LOG` に SUCCESS 行なし)|
| Req 2.3 (合計 35 秒以内) | retry_test Test 6（fake sleep 下で実測）/ 実装値で担保（待機合計 35 秒）|
| Req 2.4 (一時失敗でも上限まで継続) | retry_test Test 5（exit=1 / empty / timeout 混在で 4 回継続）|
| Req 3.1 (N >= 2 試行で単一行ログ) | retry_test Test 2 / Test 4 (`attempt=N/4` 行を含む)|
| Req 3.2 (成功までの試行回数を記録) | retry_test Test 2 / Test 3 (`SUCCESS attempt=N/4` 行)|
| Req 3.3 (全失敗時に Issue / branch / 試行回数 / 失敗要因) | retry_test Test 4 (`FAILED after 4 attempts` + `issue=#108` + `branch=...`)|
| Req 3.4 (1 回目成功時に従来の成功ログ) | retry_test Test 1（`$LOG` 空）+ 既存 stagec_pr_verify_test の "Stage C 完了 / PR 作成済み" |
| Req 4.1 (1 回目成功時の外形互換) | retry_test Test 1（`$LOG` 空 + stdout=PR URL）+ 既存 stagec_pr_verify_test |
| Req 4.2 (既存 env var 不変更) | 新 env var `STAGEC_VERIFY_SLEEP_CMD` は新規追加で既存名と衝突なし。grep で目視確認 |
| Req 4.3 (既存ラベル契約不変更) | 呼出側コード差分が `mark_issue_failed "stageC-pr-missing"` の経路を維持していることをコード確認 |
| Req 4.4 (`stageC-pr-missing` 識別子継続使用) | 既存 stagec_pr_verify_test の sanity grep + Stage C `case 0)` のソース確認 |
| Req 4.5 (Stage A / A' / B 系の挙動不変更) | 既存 verify_pushed_or_retry_test 17 ケース継続 pass |
| Req 5.1 (1 回目成功テスト) | retry_test Test 1 |
| Req 5.2 (途中試行で成功テスト) | retry_test Test 2 / Test 3 |
| Req 5.3 (全試行失敗テスト) | retry_test Test 4 / Test 5 |
| Req 5.4 (既存テスト継続 pass) | stagec_pr_verify_test 8 ケース継続 pass |
| Req 5.5 (外部ネットワーク呼出なし) | gh / timeout / sleep を全て shell 関数 / no-op で stub |
| Req 5.6 (テスト 1 件 30 秒以内) | retry_test Test 6 で経過時間を実測（fake sleep 下で 0 秒）|
| NFR 1.1 (1 回目成功で +1 秒以内) | 手動スモークテスト 3 ms 実測 |
| NFR 1.2 (合計 35 秒以内) | 実装値（待機 0+5+10+20=35）|
| NFR 1.3 (1 試行 15 秒タイムアウト) | 実装値（`timeout 15`）|
| NFR 2.1 (試行結果の種別識別可能) | retry_test Test 5（exit=N / empty / timeout 全種別の outcome ログ確認）|
| NFR 2.2 (Issue / branch スコープで突合可能) | retry_test Test 2 / Test 4（log に `issue=#108` `branch=...` が含まれる）|
| NFR 3.1 (cron / launchd / 依存 CLI 前提不変更) | bash 構文チェック + 既存 watcher 全テスト pass |
| NFR 3.2 (self-hosting でも有効) | 本変更は idd-claude repo 自身に対する dogfooding で次回 cron 実行から有効化される。pure bash / 追加依存なし |

## 確認事項（レビュワー / Architect へ）

1. **新規 env var `STAGEC_VERIFY_SLEEP_CMD` の妥当性**  
   テスト用 fake 注入点として導入したが、本番運用で override する用途は想定していない。
   ハードコード sleep でも実装可能だが、Req 5.6（テスト 1 件 30 秒以内）を実時間待機なしで満たすため
   env var 経由の差し替えポイントとした。命名は既存スタイル（`STAGE_CHECKPOINT_ENABLED` 等）に合わせて
   全大文字スネークケース。Reviewer が「本番運用で override されないことが明示されていない」と
   判定する場合、関数定義箇所のコメント補強で対応可。

2. **Req 1.4 と「合計 35 秒以内」の解釈**  
   要件では「リトライ系列全体の合計待機時間を 35 秒以内」と「個々の試行に 15 秒タイムアウト」が並記
   されている。素直に読むと「待機 (0+5+10+20=35 秒) + 個々の RTT/タイムアウト (max 15s×4=60s)」で
   最悪 95 秒になりうる。実装は前者を Sleep 合計、後者を試行ごとの上限として独立に扱った（Issue 本文の
   設計判断と整合）。Reviewer が「合計 35 秒に試行 RTT も含むべき」と読む場合は requirements の
   差し戻しが必要だが、本実装ではそうは解釈していない（Req 1.4 / NFR 1.2 を「sleep 合計」と読んだ）。

3. **既存 `stagec_pr_verify_test.sh` の `_test_stagec_complete` を新関数で動かさなかった判断**  
   既存テストの `_test_stagec_complete` は inline gh 呼び出しを再現する仕様レベルテストとして残し、
   sanity check (grep) のみ更新した。新関数の挙動テストは新規 `stagec_pr_verify_retry_test.sh` に集約。
   この分離理由は、既存テストの fake gh は「単一呼出シナリオ」用に書かれており、retry を含む新挙動を
   表現する責務を負わせるよりも、責務分離した方が読みやすいため。Req 5.4（既存 8 ケース継続 pass）の
   担保は新旧両系統で達成している。

4. **Issue コメント通知の更新メッセージ**  
   全リトライ失敗時の Issue コメント本文に「4 回リトライ後」を追記した（既存テストとの整合性のため
   本文の他部分は不変）。これは Out of Scope（リトライ進捗の Issue コメント化は不要）に抵触しないが、
   人間オペレーターが「retry が走ったうえでの失敗」と「retry なし即時失敗」を区別できるよう、
   失敗時のサマリにのみ情報を追加した。Reviewer が冗長と判断する場合は削除可。
