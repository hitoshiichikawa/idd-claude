# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: Config ブロックの `SECURITY_REVIEW_PROMPT` / `SECURITY_REVIEW_CLAUDE_CMD` 宣言を `export VAR="${VAR:-default}"` 形式に変更し、`bash -c` 子シェルへの env 継承を確立した。
- 重要な判断: 既定値の文字列リテラル（`claude -p "$SECURITY_REVIEW_PROMPT" ...` 形式）は変更せず、Req 4.3 / NFR 1.2 の意味的内容温存を守った。他の `SECURITY_REVIEW_*` env（`_ENABLED` / `_MODEL` / `_MAX_TURNS` 等）は子シェル内で `$VAR` として参照されないため export しない方針を踏襲（design.md「補強範囲を 2 変数に限定する理由」節準拠）。L323-L328 の既存コメント「既定値中の `\$SECURITY_REVIEW_PROMPT` はリテラル保持し、bash -c subshell が env から展開する」は温存し、export が必要な理由を 2〜3 行のコメントで補強した。
- 残存課題: なし（task 2 以降の前提としての export 化は本 commit で完了。shellcheck 警告ゼロ確認済み）。

### Task 2

- 採用方針: `sec_execute_security_review` の subshell 内、`git checkout` 成功後・`bash -c "$resolved_cmd"` 起動の直前に `if [ -z "${SECURITY_REVIEW_PROMPT:-}" ]; then ... fi` の早期 short-circuit ガードを追加し、result_file に新規 token `empty-prompt` を 1 行書き出して `exit 0` する形にした（design.md Service Interface コード例 L310-L321 準拠）。
- 重要な判断: (1) ガード位置は `git fetch` / `checkout` 成功後を選び、既存 result_file token プロトコル（`fetch-fail` / `checkout-fail` / `ran:<rc>:<state>`）と並列に扱える形に揃えた（design.md「配置位置の選択根拠」節）。(2) `sec_warn` メッセージに `empty-prompt` 識別語と head_ref を含め、他失敗原因と運用者が区別可能な形にした（NFR 2.2）。(3) CLI 未起動のためワークツリー変更は構造的に発生せず、read-only invariant 検査（`git status --porcelain`）は本ガード経路では走らせない方針（tasks.md L28-L29 / design.md）。(4) 新規 token `empty-prompt` は既存 case 文（`sec_run_review_for_pr` L910-L915 の `fetch-fail|checkout-fail` のみ）と名前空間衝突しないことを目視確認済み。
- 残存課題: 本 commit 時点では `sec_run_review_for_pr` 側の case 分岐に `empty-prompt` 経路が未追加のため、現状の `empty-prompt` token は case 分岐を抜けて後続の `awk -F: '{print $2}'` で空文字に解析され、`exec_rc="${exec_rc:-1}"` の fallback により `exec_rc=1` 扱いとなり「実行失敗（非ゼロ終了）」エラーコメント分岐に流れる（design.md 規定の専用 detail 文面ではない）。task 3 で `empty-prompt` 専用 case 分岐を追加し、`empty-prompt` 識別文面の scan-failed コメントを投稿する経路を確立する必要がある。

### Task 3

- 採用方針: `sec_run_review_for_pr` の result_file token 解析 case 文（既存 `fetch-fail|checkout-fail)` 直後）に `empty-prompt)` 分岐を追加し、`sec_error` で識別語付き 1 行を出した上で `sec_post_error_comment "$pr_number" "$sha" "scan-failed" "<empty-prompt 識別文面>"` を呼び `return 3` で既存 scan-error 集計に合流させた（design.md L340-L352 のコード例に準拠）。
- 重要な判断: (1) エラーコメント本文には `claude` CLI を起動せず scan-failed として中断した旨と、運用者向け対処として「watcher 起動環境で `SECURITY_REVIEW_PROMPT` が export されていること」「`SECURITY_REVIEW_CLAUDE_CMD` の `{PROMPT_FILE}` 経路への切替検討」の 2 経路を明示した（tasks.md L42-L43）。(2) 既存「空出力なら scan-failed」分岐（L961-L966）は CLI 起動後の output 側チェックとして温存し、本 case 分岐は CLI 起動前の input 側チェックとして独立した defense-in-depth に揃えた（design.md Error Handling 節 / Req 1.3）。(3) `sec_post_error_comment` の `kind=scan-failed` を踏襲することで、同一 SHA に対する重複コメント防止（Req 3.3）と既存 scan-failed 集計との互換性が成立する。(4) shellcheck 警告ゼロを確認済み（既存 disable=SC2016 等の指示は本 commit で増減なし）。
- 残存課題: なし（Task 3 完了により Req 1.3 / 3.3 / NFR 2.2 のトレーサビリティが design.md 通りに成立。Task 4 で予定されている shellcheck 全体確認 + コメント整合性確認 / Task 5 のスモーク fixture 追加が残るが、いずれも本 task のスコープ外）。
