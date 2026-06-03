# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-03T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-279-impl-feat-watcher-security-review-opt-in-pr-d
- HEAD commit: 118456bb703783c1a61cf322be7f27b9c92d9149
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `process_security_review` 冒頭の opt-in gate `[ "${SECURITY_REVIEW_ENABLED:-false}" != "true" ] && return 0`（security-review.sh:754）。`=true` 厳密一致以外は早期 return
- 1.2 — opt-in 一致時のみ ② sec_check_strict_request → ⑦ レビュー loop へ進む（security-review.sh:758〜824）
- 1.3 — dispatcher 配線 `process_security_review || sec_warn "..."`（issue-watcher.sh:1085）で fail-continue、entrypoint も `return 0` 固定
- 1.4 — opt-in 未設定時は `return 0` で本機能導入前と byte 等価（NFR 1.1 を優先した実装。impl-notes.md task 4 で根拠記録 / `security-review:` prefix のログは ON 時のみ）
- 2.1 — `sec_fetch_candidate_prs` で server-side `--state open --search "-draft:true"` + client-side fork 除外 + `SECURITY_REVIEW_HEAD_PATTERN`（既定 `^claude/issue-`）一致（security-review.sh:99〜121）
- 2.2 — `sec_execute_security_review` が subshell + EXIT trap 内で `bash -c "$resolved_cmd"` を timeout 付き実行（security-review.sh:358）
- 2.3 — server-side `-draft:true` + client-side `select(.isDraft == false)` の二重防御（security-review.sh:105, 117）
- 2.4 — `sec_already_processed` で同一 (sha, kind) marker 検出時に skip（security-review.sh:620〜627）
- 2.5 — `SECURITY_REVIEW_MAX_PRS`（既定 5）で truncate、overflow をログ記録（security-review.sh:777〜785）
- 2.6 — 非ゼロ終了 / workspace-modified / 空出力で `sec_post_error_comment` 投稿 + return 3（security-review.sh:673〜701）
- 3.1 — `sec_post_review_comment` が `gh pr comment` で 1 回投稿（security-review.sh:393）
- 3.2 — 見出し `## セキュリティレビュー結果` + review_text 本文に severity 情報を含める prompt 設計（security-review.sh:391、Prompt に `severity (critical/high/medium/low/info)` 指定 / issue-watcher.sh:316）
- 3.3 — `sec_post_clean_comment` が `## セキュリティレビュー結果: クリーン` 見出し + 0 件明示 + Model/Skill 行 + marker を投稿（security-review.sh:412〜428）
- 3.4 — `sec_build_marker` が `<!-- idd-claude:security-review sha=<sha> kind=<kind> -->` 形式で marker を構築、各 post 系で body 末尾に埋め込み（security-review.sh:48〜52）
- 3.5 — `sec_write_security_notes` が spec ディレクトリに `security-notes.md` を書き出し、特定不可時は WARN + skip（security-review.sh:501〜576、`sec_resolve_spec_dir` 経由）
- 4.1 — Reviewer の 3 カテゴリ判定領域に触れず、独立 module として実装（boundary 遵守）
- 4.2 — `review-notes.md` への介入なし（差分ファイルに含まれない / boundary 遵守）
- 4.3 — Reviewer 結果と独立して自身のコメント投稿のみを行う（dispatcher 配線が PR Reviewer の直後・独立 module）
- 4.4 — entrypoint return 0 固定（security-review.sh:825）+ dispatcher が `|| sec_warn` で吸収（issue-watcher.sh:1085）
- 5.1 — advisory 固定、ラベル付与・マージブロック操作なし（コードに `gh pr edit --add-label` 等が含まれない）
- 5.2 — cycle start ログに `mode=advisory strict=not-implemented (split to #281)` を記録（security-review.sh:763）
- 5.3 — `sec_check_strict_request` が strict 要求 env を WARN 1 行で吸収し常に `advisory` を返す（security-review.sh:68〜84）
- 6.1 — `sec_post_review_comment` / `sec_post_clean_comment` / `sec_post_error_comment` のいずれも body 末尾に marker 埋め込み（security-review.sh:390〜391, 417〜419, 454〜455）
- 6.2 — `sec_already_processed` が AND 一致で重複検出、`sec_run_review_for_pr` が冒頭で skip / `sec_post_error_comment` も投稿前に重複判定（security-review.sh:448〜451, 620〜627）
- 6.3 — head SHA が変わると marker が一致せず新規スキャンとして扱われる（marker に SHA を埋め込む設計の自然な帰結）
- 6.4 — `<!-- ... -->` HTML コメント形式で GitHub UI 上は非表示（security-review.sh:51）
- NFR 1.1 — opt-out 経路で security-review prefix ログ出力ゼロ、ラベル / dispatcher 順序 / exit code 不変（impl-notes.md task 6 isolated smoke で確認）
- NFR 1.2 — 既存 env var（`REPO` / `REPO_DIR` / `BASE_BRANCH` / `PR_REVIEWER_ENABLED` 等）の名前・既定値・意味を変更していない（diff で issue-watcher.sh 既存行に変更なし）
- NFR 1.3 — cron / launchd 登録文字列を変更しない（install.sh / setup.sh に変更なし）
- NFR 2.1 — 新規ランタイム導入なし。`claude` CLI headless 経路に限定
- NFR 2.2 — 既存 CLI（gh / jq / git / claude / timeout / sed / grep / mktemp）のみ利用
- NFR 2.3 — 既存最小 PATH（`PATH=/usr/bin:/bin` + watcher 本体冒頭の `$HOME/.local/bin` prepend）下で動作
- NFR 3.1 — 主要分岐点（opt-in skip / 候補件数 / draft 除外 / 重複 SHA / スキャン実行 / スキャン失敗 / コメント投稿 / 厳格度判定）をすべて sec_log / sec_warn / sec_error で記録
- NFR 4.1 — `sec_already_processed` + `sec_write_security_notes` の `Last SHA` 突合で同一 SHA に対する副作用 1 回限定
- NFR 5.1 — `shellcheck local-watcher/bin/modules/security-review.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` を再実行し exit 0（reviewer 環境で再確認）
- NFR 6.1 — README「オプション機能一覧」表に `SECURITY_REVIEW_ENABLED` 行追加 + h2「Security Review Processor (#279)」節を新設（README.md L1284 / L2229〜2499）
- NFR 6.2 — 同一 PR 内で README 更新を実施
- NFR 7.1 — 本 PR は `.claude/agents/*.md` / `.claude/rules/*.md` を編集しない（diff で確認）
- NFR 7.2 — `diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` 共に空（reviewer 環境で再確認、exit 0）

## Findings

なし

## Summary

requirements.md の全 numeric ID（1.1〜6.4 / NFR 1.1〜7.2）が実装またはログ / コメント / 成果物のいずれかで観測可能な形で実現されており、`_Boundary:_` 違反も検出されない。shellcheck 警告ゼロ・agents/rules ドリフトなしを reviewer 環境で再確認済み。AC 1.4 の「opt-in 未設定時 1 行ログ記録」は NFR 1.1（byte 等価）との明示的トレードオフとして Developer が impl-notes.md task 4 で根拠を記録しており、判定基準の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）の AC 未カバーとは言いがたい（NFR 1.1 を優先する設計判断は要件本文と整合）。

RESULT: approve
