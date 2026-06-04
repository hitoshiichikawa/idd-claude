# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-04T14:05:00Z -->

## Reviewed Scope

- Branch: claude/issue-286-impl-fix-watcher-security-review-processor-sc
- HEAD commit: ea6b72de43a63380110383c7ed3a298953e05573
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh` L316 周辺で `export SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-...}"` に変更（diff 確認済み）。default 構成で non-empty 文字列が parent env に確立される。test-export-inheritance.sh の child shell 出力非空 assert で確認（Reviewer 側再実走 OK）。
- 1.2 — test-export-inheritance.sh L80-86 で parent / child の文字列同一性を assert（`[ "$child_out" != "$SECURITY_REVIEW_PROMPT" ]` で不一致なら fail）。
- 1.3 — `local-watcher/bin/modules/security-review.sh` `sec_execute_security_review` L588-595 に空プロンプト・ガード（`[ -z "${SECURITY_REVIEW_PROMPT:-}" ]` → `printf 'empty-prompt\n' > "$result_file"; exit 0`）追加、`sec_run_review_for_pr` L927-937 に `empty-prompt)` case 分岐を追加して `sec_post_error_comment kind=scan-failed` を投稿し `return 3`。test-empty-prompt-shortcircuit.sh で result_file 内容と read-only invariant を assert。
- 1.4 — `process_security_review` の opt-in gate（既存 `[ ... != "true" ] && return 0`）は変更なし。差分にも該当箇所への手入れなし。
- 2.1 — `sec_post_review_comment` 既存実装変更なし（本修正により default 構成で CLI が起動し本来挙動が復旧する）。
- 2.2 — `sec_post_clean_comment` 既存実装変更なし。
- 2.3 — `kind=security-review` / `security-review-clean` / `scan-failed` の 3 種 marker 区別は既存実装で成立。本修正の empty-prompt 経路も `kind=scan-failed` を踏襲。
- 3.1 — `SECURITY_REVIEW_ENABLED != "true"` 時は `process_security_review` 早期 return のため export 追加の observable 影響なし。
- 3.2 — `git status --porcelain` 検査ロジック変更なし。empty-prompt 経路は CLI 未起動で構造的に変更不可、test-empty-prompt-shortcircuit.sh L111-118 の `worktree_status` assert で実機確認。
- 3.3 — `sec_build_marker` / `sec_already_processed` 変更なし。新規経路も `kind=scan-failed` で同一 SHA 重複防止が成立。
- 3.4 — `sec_run_review_for_pr` 先頭の `sec_already_processed` 判定変更なし。
- 3.5 — dispatcher 呼び出し位置・`review-notes.md` 経路は本 PR で触られていない。
- 3.6 — `sec_check_strict_request` / `_sec_resolved_mode` 変更なし（advisory 固定）。
- 4.1 — `export SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-default}"` 形式のため override 経路は不変。test-env-i-minimal.sh で minimal env 下の override 値継承を assert。
- 4.2 — `export SECURITY_REVIEW_CLAUDE_CMD="${SECURITY_REVIEW_CLAUDE_CMD:-default}"` 同上。
- 4.3 — 既定値文字列リテラル（`claude -p "$SECURITY_REVIEW_PROMPT" --output-format text --max-turns ... --model ... --permission-mode plan`）は diff 上で意味的に不変。env var 名も不変。
- NFR 1.1 — 既存 opt-in gate 温存により opt-out 観測挙動完全互換。
- NFR 1.2 — env var 名・既定値の意味的内容ともに不変。
- NFR 1.3 — test-env-i-minimal.sh が `env -i HOME=$HOME PATH=/usr/bin:/bin` で minimal env 動作を確認（Reviewer 側再実走 OK）。
- NFR 2.1 — 既存 `sec_log` / `sec_warn` / `sec_error` 呼び出しは温存。
- NFR 2.2 — `sec_warn "head '${head_ref}': SECURITY_REVIEW_PROMPT が空文字列です（empty-prompt）..."` および `sec_error "PR #${pr_number}: ... (empty-prompt)"` で `empty-prompt` 識別語付き 1 行を出力（Reviewer 側 stderr で実観測）。
- NFR 3.1 — `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/security-review.sh` 実行で警告ゼロを Reviewer 側でも再確認。
- NFR 4.1 — `security-review.sh` L552-557 のコメントを「Config ブロックで export 済み」表現へ更新済み（diff 確認）。

## Boundary 確認

tasks.md の指定変更ファイル（`local-watcher/bin/issue-watcher.sh` / `local-watcher/bin/modules/security-review.sh` + `docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/`）に閉じており、`_Boundary:_` 違反なし。`git diff --stat main..HEAD` 結果も spec ディレクトリ配下と上記 2 実装ファイルのみ。

Feature Flag Protocol は CLAUDE.md に `## Feature Flag Protocol` h2 節が存在しない（opt-out 扱い）ため、boundary 細目（旧パス温存 / flag 分岐 / flag-off mutation / flag 命名規約）は適用しない（Req 4.2 / NFR 1.1）。

## Findings

なし

## Summary

Tasks 1〜5 で要件全 ID（1.1〜1.4 / 2.1〜2.3 / 3.1〜3.6 / 4.1〜4.3 / NFR 1.1〜1.3 / NFR 2.1〜2.2 / NFR 3.1 / NFR 4.1）をカバーし、3 件のスモーク fixture を Reviewer 側でも再実走して all green、shellcheck も警告ゼロ。境界は tasks.md 指定範囲に閉じており、Feature Flag Protocol は未宣言（opt-out）のため細目適用なし。

RESULT: approve
