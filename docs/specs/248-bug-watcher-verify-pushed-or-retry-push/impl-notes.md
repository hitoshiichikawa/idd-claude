# 実装ノート（Issue #248）

## 変更概要

`local-watcher/bin/issue-watcher.sh` の `verify_pushed_or_retry` の **push 成功パス**
（`ahead>0`（または `unknown`）検出 → 自動 push リトライ成功時）を修正した。

- **Issue コメント投稿を抑止**: 旧実装は push リトライ成功時に毎回 `⚠️ ... 自動 push
  リトライで復旧しました` という Issue コメントを投稿していた。idd-claude は commit-only 設計
  （Developer は push しない / push は watcher が集約）であり `ahead>0` はほぼ全 impl Issue で
  発生する正常状態のため、このコメントは「サブエージェントの push 漏れ」という誤った原因
  示唆を伴う誤検知ノイズだった。`comment_body` 構築 + `gh issue comment` 呼び出しを削除した。
- **成功 info 行に監査トレーサビリティ用フィールドを追加**: 既存の `$LOG` 成功 info 行を
  単一行のまま機械可読化し、Issue 番号 / stage 識別子 / branch / 復旧 commit 数（ahead 数）を
  フィールド形式で追記した。新しい成功 info 行:

  ```
  [YYYY-MM-DD HH:MM:SS] <stage_label> 自動 push リトライ成功 → 継続 issue=#<N> stage_id=<stage_id> branch=<branch> recovered_commits=<ahead>
  ```

  - 「push 漏れ」「復旧 commit 数」等の誤原因示唆文言を info 行から排除（コメント削除に伴い
    自然に解消するが、ログ文言にも残さない）。
  - return 0 / temp ファイル cleanup / qa_warn の `auto-push retry SUCCESS` 行は維持。

push 失敗パス（失敗通知コメント投稿・`mark_issue_failed` escalate・return 1・失敗通知書式・
失敗時ログ行書式・リトライ 1 回）、`ahead==0` の無音 return 0、`ahead==unknown` の安全側経路は
一切変更していない。

## 各 AC への対応

| AC | 対応 | 担保するテスト |
|---|---|---|
| Req 1.1（成功時コメント抑止） | `gh issue comment` 呼び出し + `comment_body` 構築を削除 | Case 2: `LAST_GH_ARGS` 空 / `LAST_GH_COMMENT_BODY` 空 / `$LOG` に「push 漏れ」文言なし |
| Req 1.2（成功 info 行 1 件記録） | 成功 info 行を `$LOG` へ echo（維持） | Case 2: 成功 info 行 1 行のみ（`SUCCESS_LINE_COUNT==1`） |
| Req 1.3（return 0） | `return 0` 維持 | Case 2: `rc=0` |
| Req 1.4（escalate しない） | `mark_issue_failed` を呼ばない（成功パス） | Case 2: `LAST_MARK_FAILED_STAGE` 空 |
| Req 2.1（Issue 番号） | info 行に `issue=#${NUMBER}` 追記 | Case 2: `issue=#106` を含む |
| Req 2.2（stage 識別子） | info 行に `stage_id=${stage_id}` 追記 | Case 2: `stage_id=stageA-push-missing` を含む |
| Req 2.3（対象 branch） | info 行に `branch=${branch}` 追記 | Case 2: `branch=work-branch` を含む |
| Req 2.4（復旧 commit 数） | info 行に `recovered_commits=${ahead_count}` 追記 | Case 2: `recovered_commits=2` を含む |
| Req 3.1〜3.5（失敗時挙動維持） | 失敗パス未変更 | Case 3 / Case 4: rc=1 / `mark_issue_failed` stage 識別子 / 失敗 body に branch・commit 数 / Stage B 識別子伝搬 |
| Req 4.1, 4.2（ahead==0 無音 + return 0） | `ahead==0` 早期 return 未変更 | Case 1: rc=0 / `$LOG` 行数 0 |
| Req 5.1, 5.2（unknown 安全側 + 成功時 Req 1 同一） | unknown→push 経路未変更。成功パスは共通のため Req 1 と同一挙動が適用される | Case 2 の成功パスが ahead 値に依存せず同経路を通ることで担保（unknown も同一の成功 info 行を出力） |
| NFR 1.1〜1.4（後方互換） | env var 名 / 失敗通知書式 / 失敗時ログ書式 / stage 識別子伝搬契約 未変更 | Case 3 / Case 4 で失敗書式・stage 識別子伝搬を回帰確認 |
| NFR 2.1, 2.2（冪等・無害） | 成功時コメント新規投稿なし / ahead==0 で副作用なし | Case 1 / Case 2 |
| NFR 3.1（単一行 grep 可能） | 成功 info 行を 1 行に集約（複数行分割しない） | Case 2: `SUCCESS_LINE_COUNT==1` |

> Req 5.2 の補足: 成功時挙動（コメント抑止 + info ログのみ）は push 成功パスに 1 経路で集約
> されており、ahead が数値でも `unknown` でも同一の成功 info 行を出力する。Case 2 は数値 ahead
> ケースで成功経路を直接検証しており、unknown ケースも同経路を通るため挙動は同一である。

## 検証結果

- `shellcheck local-watcher/bin/issue-watcher.sh` → exit 0（警告ゼロ。root `.shellcheckrc` の
  accepted baseline 前提）
- `bash local-watcher/test/verify_pushed_or_retry_test.sh` → **PASS: 21, FAIL: 0**（exit 0）
  - Case 1（ahead==0 無音）/ Case 3・4（失敗パス）のアサーションは不変要件の回帰防止として
    変更せず、全て PASS を維持。
  - Case 2（push 成功）を新挙動（コメント未投稿 + 成功 info 行のトレーサビリティフィールド）に
    更新し全 PASS。

## 後方互換性の確認

- 既存 env var 名（`REPO` / `REPO_DIR` / `LOG` / `NUMBER` 等）変更なし。
- push 失敗パスの失敗通知コメント書式・失敗時ログ行書式・`mark_issue_failed` 呼び出し・
  return 1・リトライ 1 回固定はすべて未変更（Case 3 / Case 4 で回帰確認）。
- stage 識別子 `stageA-push-missing` / `stageA-prime-push-missing` / `stageB-push-missing` の
  呼び出し側（全 call site）および伝搬契約は未変更（テスト冒頭の grep サニティ + Case 3/4 で確認）。
- `ahead==0` の無音 return 0、`ahead==unknown` の安全側 push 経路は未変更。
- README は `verify_pushed_or_retry` の役割（push 集約・完了済み commit の push リトライ）を
  記述しているが、成功時 Issue コメント投稿の挙動には言及していないため修正不要（既存記述と
  矛盾なし）。本変更は `.claude/agents` / `.claude/rules` の二重管理対象外。

## 確認事項

- なし（要件・後方互換要件が明確であり、Open Questions も「なし」。仕様の拡大解釈は行っていない）。

STATUS: complete
