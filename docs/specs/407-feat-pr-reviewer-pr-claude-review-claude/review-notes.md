# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-407-impl-feat-pr-reviewer-pr-claude-review-claude
- HEAD commit: a1845742854bb04a5213c236d34c815316664c48
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `pdr_fetch_design_prs` が `gh pr list --state open --search "-draft:true"` + jq filter
  （isDraft==false / 非 fork / head pattern 一致）で open + non-draft の設計 PR 候補を取得
  （`local-watcher/bin/modules/pr-design-reviewer.sh:118-143`）。`pdr_no_op_test.sh` Case で
  起動経路を検証
- 1.2 — `pdr_invoke_reviewer` が `spec_dir_rel` 配下の `requirements.md` / `design.md` /
  `tasks.md` を読み込み Claude prompt に inline 埋め込み
  （`local-watcher/bin/modules/pr-design-reviewer.sh:291-310`）。
  agent 定義 `.claude/agents/design-reviewer.md` の「必ず先に読むルール」節で 3 ファイル
  Read を指示
- 1.3 — `pdr_classify_design_pr` が `DESIGN_REVIEWER_HEAD_PATTERN`（既定
  `^claude/issue-[0-9]+-design-`）で head_ref を判定し非 design を rc=1 で除外
  （`local-watcher/bin/modules/pr-design-reviewer.sh:92-102`）。`pdr_classify_design_pr_test.sh`
  全 10 ケース PASS
- 1.4 — `pdr_already_processed` が hidden marker
  `<!-- idd-claude:pr-design-reviewer sha=<sha> kind=decision -->` を `gh api .../comments` +
  jq `--arg sha` で scan（`local-watcher/bin/modules/pr-design-reviewer.sh:163-191`）。
  `pdr_already_processed_test.sh` 12 ケース PASS
- 1.5 — `pdr_invoke_reviewer` は `--permission-mode plan` で Claude 側 Write/Edit/Bash を
  構造的にブロックし、実行後 `git status --porcelain` で workspace 変更を検出した場合は
  `git checkout -- .` で破棄し rc=2 を返す
  （`local-watcher/bin/modules/pr-design-reviewer.sh:357-369`）。
  prompt / agent 定義側でも read-only 規約を 3 重明示
- 2.1 — `design-review-prompt.tmpl` および `design-reviewer.md` の判定基準節で 3 観点
  （AC カバレッジ / design⇄tasks 整合 / Traceability）に限定
- 2.2 / 2.3 — `pdr_parse_verdict` が text 形式の `VERDICT: approve|reject` standalone 行
  および JSON `.verdict` を抽出（`local-watcher/bin/modules/pr-design-reviewer.sh:418-518`）。
  `pdr_parse_verdict_test.sh` 34 ケース PASS
- 2.4 — `pdr_run_review_for_pr` が parse / validate 失敗時に保守的 approve に倒す
  （`local-watcher/bin/modules/pr-design-reviewer.sh:842-848`）。prompt / agent 定義側でも
  保守的判定を明示
- 2.5 — `pdr_validate_verdict` が verdict と 3 観点 reason の non-empty 検証
  （`local-watcher/bin/modules/pr-design-reviewer.sh:535-555`）。decision コメントに
  3 観点 reason を 1:1 で展開
- 2.6 — prompt 本文「reject 禁止事項」節 / agent 定義「reject しない条件（絶対禁止）」節で
  スタイル / 命名 / typo / 表記揺れを reject 理由から除外
- 3.1 / 3.2 — `pdr_apply_status_decision` が `pr_publish_claude_status` を verdict 直渡しで
  呼び success / failure を確定（`local-watcher/bin/modules/pr-design-reviewer.sh:626-651`）。
  `pdr_apply_decision_test.sh` 38 ケース PASS
- 3.3 — `pdr_run_review_for_pr` が `invoke_rc != 0`（exec fail / timeout / workspace-modified）
  時に publish を呼ばず pending 据え置きで rc=2 を返す
  （`local-watcher/bin/modules/pr-design-reviewer.sh:820-825`）
- 3.4 — `pr_publish_claude_status` を **read-only 流用**することで context 名 `claude-review`
  を impl PR 経路と統一（`pr-reviewer.sh` 無変更を `git diff main -- ...` で確認）
- 3.5 — `pdr_apply_status_decision` は status のみ操作し `awaiting-design-review` ラベルには
  触れない（コード上の参照ゼロを確認）
- 4.1 / 4.2 — `pdr_apply_label_decision` が `gh pr edit --add-label` / `--remove-label` を
  verdict に応じて発火（`local-watcher/bin/modules/pr-design-reviewer.sh:573-608`）。
  `pdr_apply_decision_test.sh` で reject→add / approve→remove を検証
- 4.3 / 4.4 — dispatcher 配線は `process_pr_iteration` 既存 call site の **前**に
  `process_pr_design_reviewer` を 1 行挿入のみ（`local-watcher/bin/issue-watcher.sh:1929-1938`）。
  `pr-iteration.sh` 無変更
- 5.1 — `pdr_post_decision_comment` が hidden marker 付き判定サマリを `gh pr comment` で投稿
  （`local-watcher/bin/modules/pr-design-reviewer.sh:671-712`）
- 5.2 — `pdr_run_review_for_pr` 末尾の `pdr_log` で 1 行サマリを出力
  （`local-watcher/bin/modules/pr-design-reviewer.sh:856`）
- 5.3 — marker prefix `pr-design-reviewer` は `pi_general_filter_self` の `pr-iteration`
  prefix と前方一致しない（impl-notes に substring 検証あり、`pdr_apply_decision_test.sh` の
  C.1 fixture で文字列検証）
- 5.4 — `pdr_log` / `pdr_warn` / `pdr_error` を core_utils.sh 末尾に既存 `adj_log` と同形式で
  追記（`local-watcher/bin/modules/core_utils.sh:190-202`）
- 6.1 — `DESIGN_REVIEWER_ENABLED` の `case true) ... *) false ;;` 正規化を Config 節で実装
  （`local-watcher/bin/issue-watcher.sh:749-753`）。`pdr_resolve_gate_test.sh` 14 ケース PASS
- 6.2 — `process_pr_design_reviewer` 冒頭で gate OFF → 即 return 0
  （`local-watcher/bin/modules/pr-design-reviewer.sh:874-878`）。`pdr_no_op_test.sh` 16 ケース PASS
- 6.3 — 既存 `PR_REVIEWER_ADJUDICATOR_*` 等の env 宣言行は無変更（`git diff` で増分のみ確認）
- 6.4 — 既存ラベル `needs-iteration` / context `claude-review` を流用、新規ラベル / 新規 context は
  追加されていない（diff 上でも新規ラベル定義なし）
- 6.5 — dispatcher 配線は `|| pdr_warn ...` で rc=0 吸収するため exit code 意味不変
- 6.6 — `diff -r .claude/agents repo-template/.claude/agents` および
  `diff -r .claude/rules repo-template/.claude/rules` が空（reviewer による確認済み）
- 7.1 — `.claude/agents/design-reviewer.md` を新規追加し `reviewer.md` は無変更
  （`git diff main -- .claude/agents/reviewer.md repo-template/.claude/agents/reviewer.md` 空を確認）
- 7.2 — 新規 `process_pr_design_reviewer` 経路で `pr-reviewer.sh` は無変更
  （`git diff main -- local-watcher/bin/modules/pr-reviewer.sh` 空を確認）
- 7.3 — `adjudicator.sh` / `adjudicator-prompt.tmpl` も無変更
  （`git diff main` 空を確認）。impl-notes に `PR_REVIEWER_ADJUDICATOR_*` 6 env declaration が
  行番号・既定値ともに不変であることを記録
- 7.4 — `pdr_classify_design_pr` で design 専用 head pattern 厳格化（impl PR は rc=1 で除外）
- NFR 1.1 — gate OFF 早期 return / ON 時もサマリ 1 行 + 操作系 3〜4 行で 10 行以下
- NFR 1.2 — Req 5.3 と同
- NFR 2.1 — `pdr_no_op_test.sh` で gate OFF 時 stub claude / gh 発火ゼロを確認
- NFR 2.2 — `pr_publish_commit_status_test.sh` / `adj_*_test.sh` / `pi_*_test.sh` の既存 6 テストの
  退行ゼロが impl-notes に記録
- NFR 3.1 — `local-watcher/test/pdr_*_test.sh` 6 ファイル 124 PASS（reviewer が再実行確認）
- NFR 4.1 — `DESIGN_REVIEWER_EXEC_TIMEOUT` 既定 300 秒 + `timeout` コマンドで強制

## Findings

なし

## Summary

tasks.md 9 タスクすべて完了し、新規モジュール `pr-design-reviewer.sh`・prompt template・
agent 定義 1 系統が独立に追加され、impl PR Reviewer / #404 adjudicator のコード・env・
ラベル運用には一切触れていない。requirements.md の Req 1.1〜7.4 および NFR 1.1〜4.1 すべてが
コード / テスト / 設定 / ドキュメントのいずれかで担保されており、新規 6 テスト計 124 件が
PASS、root↔repo-template byte 一致同期も差分ゼロ。boundary 違反・AC 未カバー・missing test の
いずれも検出されなかった。

RESULT: approve
