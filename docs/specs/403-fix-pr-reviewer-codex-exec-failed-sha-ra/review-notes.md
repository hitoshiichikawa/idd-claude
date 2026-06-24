# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-403-impl-fix-pr-reviewer-codex-exec-failed-sha-ra
- HEAD commit: 01b144606ba1cf30aed6ad1959cf7a8803481b2b
- Compared to: main..HEAD

差分対象ファイル（`git diff --stat main..HEAD`）:

- `README.md`（+41 行 / 既定 / migration note / env 表追加）
- `docs/specs/403-.../impl-notes.md`（+160 行 / 新規）
- `docs/specs/403-.../requirements.md`（+188 行 / 新規）
- `local-watcher/bin/issue-watcher.sh`（+44 行 / Config block に PR_REVIEWER_EXEC_FAIL_LIMIT 等 4 変数を追加。既存 env は無改変）
- `local-watcher/bin/modules/pr-reviewer.sh`（+456 行 / 8 新規関数 + 既存 `pr_run_review_for_pr` の 3 失敗経路と success 経路への呼び出し追加 + summary log 拡張）
- `local-watcher/test/pr_reviewer_exec_fail_streak_test.sh`（+605 行 / 新規テスト）

reviewer 側追加検証:

- `shellcheck` 3 ファイル: rc=0（警告ゼロ）
- 新規テスト実行: `RESULT: PASS=54 FAIL=0`
- `repo-template/local-watcher/` ディレクトリは存在せず、`.claude/` 無変更 → NFR 4.1 sync 対象外（impl-notes の主張と一致）

## Verified Requirements

- 1.1 — `pr_increment_exec_fail_streak`（marker `<!-- idd-claude:pr-reviewer-exec-fail-streak sha=<sha> streak=<N> tool=<tool> last-updated=<ISO8601> -->`）を `pr_run_review_for_pr` の workspace-modified / exec-failed（非ゼロ終了）/ 空出力の 3 経路で呼び出し。Test Section 4.A/4.C
- 1.2 — sha 変化時リセット: `pr_increment_exec_fail_streak` の sha 不一致時 1 から再スタート + `pr_reset_exec_fail_streak` + `pr_exec_fail_limit_reached` の sha 不一致 → 未到達扱い。Test Section 4.B / 5.C / 6.D
- 1.3 — 成功時リセット: `pr_post_review_comment` 直後 `pr_reset_exec_fail_streak`。Test Section 5.B
- 1.4 — 永続化媒体: PR body hidden marker 形式（pr-iteration の no-progress-streak と整合）。Test Section 1 / 2 / 3
- 1.5 — read/write 失敗時の安全側: `pr_read_exec_fail_streak` は WARN + `\t0` 返却、`pr_write_exec_fail_streak` は WARN + rc=1。Test Section 2.B / 3.C
- 1.6 — 観測ログ 1 行: `pr_run_review_for_pr` 冒頭 `pr_log "PR #${pr_number}: exec-fail-streak observe pr=#... sha=... recorded_sha=... streak=... limit=..."`
- 2.1 — 未到達時継続: `pr_exec_fail_limit_reached` rc=1 で通常フロー。Test Section 6.A
- 2.2 — 上限到達時候補除外: `pr_run_review_for_pr` で `pr_exec_fail_limit_reached` 判定後 `return 2`（外部ツール未実行）。Test Section 6.B / 6.C
- 2.3 — advisory 1 回投稿: `pr_post_exec_fail_escalation_comment` + `pr_already_processed "$pr_number" "$sha" "exec-fail-escalated"` 重複防止。Test Section 9.A / 9.B / 9.C
- 2.4 — 同一 sha 継続中は再開しない: 早期 return ロジックが毎サイクル同一判定を返す設計（test 6.B/C と sha 不変前提から自然に成立）
- 2.5 — sha 変化時候補再投入: `pr_exec_fail_limit_reached` の sha 不一致 → rc=1。Test Section 6.D
- 2.6 — PR 独立: 各関数が PR 番号 + sha で marker を一意化。共有 state 無し
- 2.7 — 遷移先選択 = advisory のみ: `pr_post_exec_fail_escalation_comment` 内にラベル付与経路なし。Test Section 9.A（`--add-label` 不在検証）
- 3.1 — stderr 拡張: `PR_REVIEWER_STDERR_EXCERPT_BYTES=8192` 既定 + `pr_truncate_stderr_tail "$err_file" "${PR_REVIEWER_STDERR_EXCERPT_BYTES:-8192}"`。Test Section 7
- 3.2 — コメント本文の包含: exec-failed 経路の `detail=$(printf '...exit=%s, tool=%s, head sha=%s）...連続失敗カウンタ: %s/%s...stderr artifact...: \`%s\`\nstderr 末尾抜粋（最大 %s バイト）:\n\`\`\`\n%s\n\`\`\`' ...)` で exit / tool / sha / streak / limit / artifact_path / excerpt を含める
- 3.3 — 観測ログ 1 行: `pr_warn "PR #${pr_number}: exec-failed pr=#... sha=... tool=... exit=... streak=... limit=... artifact='...'"`
- 3.4 — 1MB 超末尾優先: `pr_save_stderr_artifact` 内 `tail -c "$max_bytes"` + 観測ログ。Test Section 8.B
- 3.5 — artifact 保存先: 既定 `$HOME/.issue-watcher/pr-reviewer-artifacts/<repo_slug>/pr-<N>-<sha8>-<tool>-<ts>.log`、`/tmp` 直下不使用。Test Section 8.A、未信頼入力検証あり（PR 番号 `^[0-9]+$` / sha `^[0-9a-f]+$` / tool sanitize）Test Section 8.D
- 4.1 — streak=0 時の挙動不変: 早期 return は `pr_exec_fail_limit_reached` true 時のみ。streak=0 は通常フロー継続。reset は streak=0+sha 一致時 no-op（gh edit 呼び出し抑止 / Test Section 5.A）
- 4.2 — VERDICT → needs-iteration ラベル付与経路不変: `pr_detect_iteration_keyword` / `pr_add_iteration_label` / status publish は diff 内で無改変
- 4.3 — 候補列挙挙動不変: `pr_fetch_candidate_prs` / head pattern / fork / draft / MAX_PRS truncate は diff 内で無改変
- 4.4 — `kind=conflict-tool` / `kind=not-installed` / `kind=not-authenticated` broadcast 不変: `pr_broadcast_error_to_prs` は diff 内で無改変
- NFR 1.1 — 既定 ON: 追加 opt-in gate 無し。`PR_REVIEWER_ENABLED=true` 経路内でのみ動作する既存構造を維持
- NFR 1.2 — env 不正値の安全側正規化: `issue-watcher.sh` の `case "$VAR" in ''|*[!0-9]*) ... esac` + `-lt 1` チェックで全 4 変数を正規化
- NFR 1.3 — 既存 env 不変: `PR_REVIEWER_*` 既存変数は diff 内で無改変
- NFR 1.4 — prefix: 新関数は全て `pr_` prefix、新 env は全て `PR_REVIEWER_` prefix
- NFR 2.1 — 上限既定 3: `PR_REVIEWER_EXEC_FAIL_LIMIT="${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"`
- NFR 2.2 — 新 sha で抑止解除: Test Section 6.D で確認
- NFR 3.1 — サマリログにエスカレート件数: `escalated=0` 初期化 + ループ内増分 + `pr_log "サマリ: ... escalated=${escalated} overflow=..."`
- NFR 3.2 — WARN ログ 1 行: 上記 Req 3.3 と同一行で実装
- NFR 4.1 — root ↔ repo-template byte 一致: `repo-template/local-watcher/` ディレクトリ不在、`.claude/` 無変更のため sync 対象外（reviewer 側で `ls repo-template/` を確認済み）
- NFR 4.2 — 冪等性: `pr_reset_exec_fail_streak` の no-op 分岐 + `pr_already_processed` 既存重複防止。Test Section 5.A / 9.B
- NFR 4.3 — `PR_REVIEWER_ENABLED!=true` で early return: `process_pr_reviewer` の既存 early return を維持（diff 内で無改変）

## Findings

なし

## Summary

`modules/pr-reviewer.sh` への exec-failed リトライ抑止 / 診断性向上の追加実装は、requirements.md
の全 numeric ID（Req 1.1–4.4 / NFR 1.1–4.3）について該当する関数・呼び出し点・テストを揃えて
おり、トレーサビリティが完全。`shellcheck` 警告ゼロ、新規テスト 54/54 PASS（reviewer 再実行で
確認）、既存 env / ラベル / VERDICT 経路 / broadcast 経路の改変なし、新変数の不正値は安全側に
正規化、`/tmp` 直下を避け `$HOME/.issue-watcher/` 配下に artifact 保存、advisory コメントは
重複防止 marker で 1 回投稿のみ、と境界制約も満たす。tasks.md 不在の単一実装パスのため
`_Boundary:_` 制約はなく、変更範囲は pr-reviewer 主体 + Config block + README + テスト + spec で
自然境界内。

RESULT: approve
