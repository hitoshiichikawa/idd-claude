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

### Task 4

- 採用方針: (a) `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/security-review.sh` を実行し exit code 0 / 警告ゼロを確認した（NFR 3.1）。(b) `security-review.sh` L555-557 のコメント「parent shell の env に解決済み（${VAR:-default} 展開）」を、Config ブロックで `export VAR="${VAR:-default}"` 済みであることと bash -c subshell に env として継承される契約を明示する形へ書き換えた（NFR 4.1 / design.md「README / spec #279 design.md の同期」節）。(c) README の Security Review Processor env 表（L2418-L2429）と利用方法（opt-in 手順）節（L2435-L2451）を確認したが、env 表は運用者向けの env var 名・既定値・用途の説明であり internal export 有無を記述する箇所ではなく、cron 例は `VAR=value cmd` 形式で既に子プロセスへ環境変数が渡る前提のため、本修正と矛盾する記述は無いと判断し README 更新は行わなかった。
- 重要な判断: (1) コメント更新は意味的変更（挙動への影響）を伴わない docs commit として独立させ、Conventional Commits 上は `docs(watcher):` scope を採用した（fix ではなく docs。実装挙動変更を含まない）。(2) README 更新の判断根拠は「env 表は user-facing 既定値と用途の説明」「cron 例の `VAR=value` 形式は環境変数として子プロセスへ伝播する POSIX シェル契約」の 2 点で、今回の internal export 化（idd-claude が watcher 内部で `bash -c` の子シェルへ env 継承を確立する目的）は user-facing な env 規約には影響しないため、文面更新は不要と判断した。(3) repo-template に README 重複は存在しないため二重管理対象外。
- 残存課題: なし（Task 4 完了。NFR 3.1 = shellcheck 警告ゼロ / NFR 4.1 = コメント整合性が成立）。Task 5（スモーク fixture）と Task 6（opt-out no-op 回帰確認、deferrable）が残るが、いずれも本 task のスコープ外。

### Task 5

- 採用方針: `docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/` を新規作成し、3 つの bash スモークスクリプトを配置した（design.md Testing Strategy 節 1〜2 + Integration Test 5 に対応）。いずれも `set -euo pipefail` / `command -v` ベース / 既存 #224 / #263 fixture と同じ「scratch dir + module 抽出 + 期待値 assert」パターンに揃え、成功時 `echo "OK: <name>"` / 失敗時 非ゼロ exit + stderr 詳細出力という慣習を維持した。
- 重要な判断: (1) `test-export-inheritance.sh`: watcher main flow（lock 取得・cron ループ・logging）を起動せず、`grep -E '^export SECURITY_REVIEW_PROMPT='` で当該 Config 行だけを抽出し eval する方式を採用した。既存 #263 fixture が awk で関数本体を抽出した同パターンに揃えており、副作用ゼロで env 解決をシミュレートできる。assert は (a) parent shell で非空に解決、(b) `bash -c` 子シェルへ env 継承、(c) `Use the /security-review skill` prefix 一致、(d) parent / child 同一性（Req 1.2）の 4 点。(2) `test-empty-prompt-shortcircuit.sh`: 一時 bare repo + 作業 repo + base/head ブランチを構築して `sec_execute_security_review` を直接呼び出す。`claude` / `gh` が起動されない（空プロンプト早期 short-circuit）ため網外依存ゼロで再現可能。`resolved_cmd` には `echo "SHOULD_NOT_RUN" >&2; exit 99` を渡し、万一短絡を抜けて CLI 経路に流れた場合に stderr で検出できる二重防御を入れた。(3) `test-env-i-minimal.sh`: `env -i HOME=$HOME PATH=/usr/bin:/bin SECURITY_REVIEW_ENABLED=true SECURITY_REVIEW_PROMPT=test-prompt` で inner bash を起動し、`${VAR:-default}` の override 経路で test-prompt が採用されて子シェルに継承されることを確認する。NFR 1.3（cron-like 最小 PATH 動作）の回帰確認に直結する。
- 残存課題: なし。3 fixture すべて単独で pass し、tasks.md 末尾の構造化 stage-a-verify ブロック（`shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/security-review.sh && bash <3 fixture>`）も最終確認で 4/4 OK で完了。shellcheck も fixture 自体（3 件）に対して警告ゼロ。Task 6（opt-out no-op 回帰確認）は deferrable のまま本 sub-issue のスコープ外。

#### Requirement ID トレーサビリティ（Task 5 までで覆われた AC のテスト対応）

| Req ID | カバー手段 | 検証スクリプト |
|---|---|---|
| 1.1 | export 継承による非空保証 | test-export-inheritance.sh |
| 1.2 | parent / child 同値性 | test-export-inheritance.sh の同一性 assert |
| 1.3 | 空プロンプト早期 short-circuit | test-empty-prompt-shortcircuit.sh + 既存 case 分岐 (`sec_run_review_for_pr`) |
| 1.4 | opt-out gate | 既存 `process_security_review` 早期 return（変更なし。Task 6 deferrable で回帰確認予定） |
| 2.1〜2.3 | コメント kind 区別 | 既存実装変更なし（design.md Traceability に従い本修正で復旧） |
| 3.1〜3.6 | 不変条件 | export は env 継承のみ変更し既存挙動を温存（design.md Migration Strategy） |
| 4.1〜4.3 | override 経路維持 | test-export-inheritance.sh + test-env-i-minimal.sh（override 値が継承されることを確認） |
| NFR 1.1 | opt-out 完全互換 | `SECURITY_REVIEW_ENABLED != "true"` で process_security_review 早期 return（既存温存） |
| NFR 1.2 | env var 名・既定値温存 | Task 1 で diff 確認済み |
| NFR 1.3 | cron-like 最小 PATH | test-env-i-minimal.sh |
| NFR 2.1〜2.2 | ログ識別 | sec_warn / sec_error の `empty-prompt` 識別語（Task 2, 3 で確認済み） |
| NFR 3.1 | shellcheck 警告ゼロ | Task 4 + 本 task で改めて確認（fixture 3 件含む） |
| NFR 4.1 | コメント整合性 | Task 4 で実施済み |
