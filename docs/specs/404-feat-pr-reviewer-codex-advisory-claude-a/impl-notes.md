# Implementation Notes

## 確認事項

なし

## Implementation Notes

### Task 1
- 採用方針: `core_utils.sh` 末尾に `adj_log` / `adj_warn` / `adj_error` の 3 関数を既存 `pr_log` / `pi_log` と同形式（`[YYYY-MM-DD HH:MM:SS] [$REPO] adjudicator:` prefix）で追加。`issue-watcher.sh` Config ブロックの `PR_REVIEWER_STATUS_CHECK_ENABLED`（#349 / line 638-659）直後・`SECURITY_REVIEW_ENABLED`（#279 / line 661 以降）直前に「PR Reviewer Adjudicator 設定 (#404)」節を追加し、6 env を `${VAR:-default}` で解決。
- 重要な判断: (1) `ENABLED` の正規化は既存 `PR_REVIEWER_STATUS_CHECK_ENABLED` の `case … in true) … *) false ;;` パターンを踏襲（Req 5.5 既存規約整合）。(2) `EXEC_TIMEOUT` / `MAX_FINDINGS` の数値正規化は既存 `PR_REVIEWER_EXEC_FAIL_LIMIT`（issue-watcher.sh:603-611）と同じ `case ''|*[!0-9]*) … *) lt 1 ;;` イディオムを採用。(3) `FALLBACK_ON_FAIL` の既定は design.md「Architecture Decision: claude-review publisher contention」と「env var 仕様」表に従い `passthrough`（adjudicator SPOF 緩和 / 独立 Reviewer の verdict 尊重）に倒し、コメントに根拠を 1 段落で明記。(4) `MODEL` は空文字の場合に既定 `claude-sonnet-4-5` へ追加 fallback する明示分岐を入れた（`${VAR:-default}` だけだと `=""` 明示の場合に空文字が通る既知挙動の救済）。
- 残存課題: なし。本 task 終了時点で gate OFF 既定下の挙動は未変更（adjudicator.sh / REQUIRED_MODULES への登録は task 3 のスコープ。task 2 以降が `adj_log` / 6 env を消費する前提を整備済み）。検証結果: `bash -n` / `shellcheck` 警告ゼロ / 既存テスト 3 種（pr_publish_commit_status / pr_publish_claude_status_from_branch / pr_default_prompt）退行ゼロ / env 解決スモークで既定値 6 件 + 不正値正規化 4 件 + 合法 ON 値 5 件をすべて期待値どおり確認。

## AC Traceability

| Requirement | 担保方法 |
|---|---|
| Req 5.1（opt-in gate / 安全側正規化） | `PR_REVIEWER_ADJUDICATOR_ENABLED` の `case true) ... *) false` 正規化、`FALLBACK_ON_FAIL` の `legitimate|passthrough` 以外を `passthrough` に倒す `case`、数値 env の `case ''|*[!0-9]*) ... lt 1` 正規化（env 解決スモークで `True` / `invalid_value` / `abc` / `-5` がすべて既定値に倒れることを確認） |
| Req 5.3（既存 env 名・既定値・意味の不変性） | 既存 env 名（`PR_REVIEWER_STATUS_CHECK_ENABLED` / `SECURITY_REVIEW_ENABLED` / 周辺）は touch せず、新規 6 env のみ追加。既存テスト 3 種が PASS=178 で退行ゼロを確認 |
| Req 5.5（既存 exit code・ログ stderr/stdout 契約の不変性） | `adj_log` は stdout、`adj_warn` / `adj_error` は `>&2`。既存 `pr_log` / `pi_log` / `sec_log` 群と同一の関数シグネチャを保持。Config 節は env 解決と正規化のみで exit code を変更しない |
| Req 4.4（ログ prefix・timestamp 書式の既存規約整合） | 3 関数の出力書式が `[YYYY-MM-DD HH:MM:SS] [$REPO] adjudicator:` で既存 `pr_log` 等と byte レベルで揃う（diff 確認） |

## 検証コマンドと結果

| コマンド | 結果 |
|---|---|
| `bash -n local-watcher/bin/modules/core_utils.sh` | OK |
| `bash -n local-watcher/bin/issue-watcher.sh` | OK |
| `shellcheck local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh` | 警告ゼロ |
| `bash local-watcher/test/pr_publish_commit_status_test.sh` | PASS=74 FAIL=0 |
| `bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh` | PASS=52 FAIL=0 |
| `bash local-watcher/test/pr_default_prompt_test.sh` | PASS=52 FAIL=0 |
| env 解決スモーク（既定値 / 不正値 / 合法 ON 値の 3 系統） | 既定 6 env 期待値一致、不正値 4 件すべて既定に正規化、合法 ON 値 5 件透過 |

STATUS: complete
