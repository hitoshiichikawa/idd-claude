# Review Notes: Issue #97 (round 1)

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-12T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-97-impl-watcher-pi-build-iteration-prompt-fails
- HEAD commit: 0db6aa266ee81f8fa1da510804ab72a9579991b3
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh`, `local-watcher/bin/iteration-prompt.tmpl`, `local-watcher/bin/iteration-prompt-design.tmpl`, `docs/specs/97-.../requirements.md`, `docs/specs/97-.../impl-notes.md`
- Feature Flag Protocol: 対象 repo CLAUDE.md に `## Feature Flag Protocol` 節なし → **opt-out 解釈**（flag 観点の細目チェックは行わない）

## Summary

`pi_build_iteration_prompt` から `gh pr diff` 取得処理、`PI_PR_DIFF` の export/unset、awk の `{{PR_DIFF}}` 分岐をすべて削除し、impl/design 両 template から `{{PR_DIFF}}` 節を撤廃。代わりに Iteration サブエージェントが Bash で `git diff --stat {{BASE_REF}}..{{HEAD_REF}}` / `git diff {{BASE_REF}}..{{HEAD_REF}} -- <path>` / `gh pr diff {{PR_NUMBER}} --repo {{REPO}}` を実行する手順を template 両方に追加。Reviewer prompt 側の先行修正（#92 / コミット `6e73820`）と方針一貫。boundary は `pi_build_iteration_prompt` 関数本体 + 2 templates 内に限定され、env var 名 / ラベル名 / exit code / cron 文字列 / kind 判定 / round 制御は未変更。impl-notes.md に smoke test 実行結果（impl=8027 B / design=11462 B 固定、外部から 200 KB 値を渡しても normal==big、他 placeholder 展開維持）と shellcheck 新規警告ゼロが記録されている。

## Verified Requirements

- 1.1 — `pi_build_iteration_prompt` 内の `pr_diff` 取得処理（旧 1671-1674 行）と awk の `{{PR_DIFF}}` 分岐を削除（`issue-watcher.sh:1671-1674`, `1737` 周辺）。template 本文の `{{PR_DIFF}}` 節も両系で削除。
- 1.2 — `export PI_PR_DIFF="$pr_diff"` と `unset PI_PR_DIFF` を削除（`issue-watcher.sh:1708-1711, 1754`）。awk -v / ENVIRON[] のいずれにも diff 全文を保持する単一 env var は残っていない。
- 1.3 — `gh pr diff` 呼び出し自体を削除し、後続の `pi_run_iteration` → `claude --print` 起動経路は touch されていない（`pi_build_iteration_prompt` の戻り値経路 / 関数 I/F は維持）。
- 1.4 — fallback 文字列 `(diff の取得に失敗)` を含むコード行は完全削除。`grep -R "diff の取得に失敗"` 相当の確認は impl-notes.md の検証手段に記録あり。
- 1.5 — `iteration-prompt.tmpl` / `iteration-prompt-design.tmpl` の両方で `{{PR_DIFF}}` 節を撤廃し、同等の「現在の diff の取得」節を追加。`grep '{{PR_DIFF}}' local-watcher/` で本文一致ゼロ確認済。
- 2.1 — 両 template の「現在の diff の取得」節に `git diff --stat {{BASE_REF}}..{{HEAD_REF}}` と `gh pr diff {{PR_NUMBER}} --repo {{REPO}}` の両形式を明示。
- 2.2 — 同節に `git diff {{BASE_REF}}..{{HEAD_REF}} -- <path>` を明示（impl/design 両方）。
- 2.3 — `{{BASE_REF}}` / `{{HEAD_REF}}` / `{{PR_NUMBER}}` / `{{REPO}}` の placeholder で実値展開される設計。smoke test で `main..claude/issue-123-foo` / `gh pr diff 42 --repo owner/test` が展開済として出現することを impl-notes.md で確認。
- 2.4 — impl / design 両 template に「現在の diff の取得」節が 1 箇所追加されている（impl: tmpl L65-， design: tmpl L70-）。
- 3.1 — awk `-v` に `repo` / `pr_number` / `pr_title` / `pr_url` / `head_ref` / `base_ref` / `round` / `max_rounds` / `issue_number` / `spec_dir` を保持（`issue-watcher.sh:1713-1723`）。
- 3.2 — `{{LINE_COMMENTS_JSON}}` / `{{GENERAL_COMMENTS_JSON}}` / `{{REQUIREMENTS_MD}}` の ENVIRON[] 展開分岐は維持（`issue-watcher.sh:1735-1737`）。
- 3.3 — `pi_classify_pr_kind` / `pi_select_template` を含む kind 判定は git diff 上で touch されていない（diff `--name-only` で issue-watcher.sh の変更領域は `pi_build_iteration_prompt` 関数のみ）。
- 3.4 — `PR_ITERATION_MAX_ROUNDS` / `pi_escalate_to_failed` 周辺は未変更（21 件の参照は本 PR の編集領域外）。
- 3.5 — 着手 marker / コメント投稿 / fresh context Claude 起動 / base branch 復帰のいずれも未変更。
- 4.1 — `REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `PR_ITERATION_DEV_MODEL` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_MAX_TURNS` / `PR_ITERATION_GIT_TIMEOUT` いずれも touch されていない。
- 4.2 — `needs-iteration` / `claude-failed` / `ready-for-review` / `awaiting-design-review` のラベル参照は変更されていない。
- 4.3 — `pi_run_iteration` の戻り値（0/1/2/3）の意味は未変更（変更領域外）。
- 4.4 — `install.sh` / `setup.sh` / `README.md` の cron 登録文字列は touch されていない（`git diff --name-only` で確認）。
- 4.5 — `PI_PR_DIFF` は内部実装専用で外部公開 API ではなかったため、削除は要件文書の規定通り。
- 5.1 — smoke test で impl/design いずれの出力にも `{{PR_DIFF}}` が残らないことを impl-notes.md に記録。
- 5.2 — 他 placeholder（REPO / PR_NUMBER / PR_TITLE / PR_URL / HEAD_REF / BASE_REF / ROUND / MAX_ROUNDS / ISSUE_NUMBER / SPEC_DIR / LINE_COMMENTS_JSON / GENERAL_COMMENTS_JSON / REQUIREMENTS_MD）の展開は awk ロジック保持 + smoke test で確認。
- 5.3 — impl / design 両 template から `{{PR_DIFF}}` を一括撤廃（template 冒頭のプレースホルダ一覧コメントからも削除）。
- NFR 1.1 — smoke test 実測: impl 8027 B / design 11462 B（いずれも 131,072 B 未満）。
- NFR 1.2 — `awk` に export される env var は `PI_LINE_JSON` / `PI_GENERAL_JSON` / `PI_REQS_MD` の 3 つのみで、いずれも diff 全文を保持しない。
- NFR 1.3 — 外部から `PI_PR_DIFF` に 200 KB のダミー値を渡しても出力バイト数が変わらないことを smoke test で実証（normal=8027, big=8027）。
- NFR 2.1 — shellcheck 新規警告ゼロ（impl-notes.md 検証結果に記録）。
- NFR 3.1 / 3.2 — `awk` の env var 値長は実運用で数十 KB 程度に収まり、diff 全文を保持する単一変数は無いため E2BIG 起点は排除された。
- NFR 4.1 — prompt サイズが差分サイズに非依存（固定）であるため、self-hosting 上の大規模 PR でも問題なく起動できる設計。

## Findings

なし。

## Summary

3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）いずれにも該当する欠落・違反は検出されなかった。すべての AC が実装・smoke test・shellcheck のいずれかで裏打ちされており、Reviewer prompt 側の先行修正（#92）と一貫した方針で実装されている。

RESULT: approve
