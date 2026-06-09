# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-09T19:03:18Z -->

## Reviewed Scope

- Branch: claude/issue-304-impl--bug-per-task-commit-task-marker-review
- HEAD commit: 94fb95aa5a3087286c8b491d47375f2fc8c2fc48
- Compared to: main..HEAD（実質 merge-base 2d6cce6..HEAD。main は本ブランチ作成後に
  #311 等が merge され進行しているため、`main..HEAD` 差分には branch 自身が触れていない
  削除ファイルが見かけ上含まれる。実際の本 branch 変更は merge-base 2d6cce6..HEAD で
  確認した 9 ファイル / +1373 / -15 のみ）

## Verified Requirements

- 1.1 — `.claude/agents/developer.md` 「marker 作成タイミングの契約」subsection（root +
  repo-template、byte 一致）。task-scope の全成果物完了後に marker を作る契約を明文化
- 1.2 — `.claude/agents/developer.md` 「retry 時の marker refresh 契約」subsection。
  旧 marker 後ろに修正 commit を残してはならないことと推奨 refresh 手順を明文化
- 1.3 — developer.md の per-task ループ責務節配下に「Marker contract」h2 subsection を配置。
  Implementer が commit 追加前に読む位置（per-task ループ責務節内）に契約が文書化されている
- 2.1 — `local-watcher/bin/issue-watcher.sh` `pt_detect_post_marker_commits`（新規関数）+
  `run_per_task_reviewer` への組込み（`pt_resolve_diff_range` 成功直後）で marker 後の
  commit を検出。silent truncation を防ぐ
- 2.2 — `pt_handle_post_marker_commits`（新規関数）で
  `POST_MARKER_RECOVERY_MODE=extend-range`（include 経路）/ `=fail-with-diagnostic`
  （abort 経路）を分岐。env 不正値は default の fail-with-diagnostic にフォールバック
- 2.3 — `pt_mark_post_marker_commits_detected`（新規関数）が
  `per-task-post-marker-commits-detected` カテゴリで `claude-failed` ラベル付与 + 復旧手順
  付き Issue コメント投稿。既存 per-task failure path（`pt_mark_diff_range_resolve_failed`）
  と同パターンで実装
- 3.1 — `build_per_task_reviewer_prompt` の prompt 本文に
  `## 判定対象 SHA range（machine-parseable）` subsection を追加。fenced code block 内に
  `range_start_sha:` / `range_end_sha:` / `range_extended:` の 3 行を machine-parseable
  形式で配置
- 3.2 — prompt 本文に「reviewer は **本 range のみ** を判定対象としてください」記述の
  直後に blockquote `> **Warning（Issue #304 Req 3.2）**:` を配置。
  `.claude/agents/reviewer.md`「range 外 commit の判定対象外性」h3 subsection も併せて追記
- 3.3 — `build_per_task_reviewer_prompt` 第 6 引数 `extended`（省略時 "false"）を追加し、
  `extended="true"` 時のみ prompt 末尾に `### Extended range` 説明 block を出力。
  `run_per_task_reviewer` の extend-range 経路で `"$extended"` を実際に渡す経路を組込済。
  `.claude/agents/reviewer.md`「Extended range シグナルの解釈」h3 subsection も追記
- 4.1 / 4.2 — `diff -r .claude/agents repo-template/.claude/agents` および
  `diff -r .claude/rules repo-template/.claude/rules` がいずれも exit 0（差分なし）。
  task 7 の root 系統変更が task 8 で repo-template/ にも byte 一致で反映されている
- 5.1 — `docs/specs/304--.../test-fixtures/test-post-marker-detect.sh` の case-2（marker +
  修正 commit 2 件）が idd-codex #14 同型の commit shape を一時 git repo で構築
- 5.2 — 同 fixture の case-3（fail-with-diagnostic で rc=5）と case-4（extend-range で
  rc=0 + 新 range pair）が abort / include の両経路を assert で検証
- 5.3 — case-5(a)(b)(c) が silent truncate の証拠（range_end == marker / post-marker
  commit が range 外）と検出 hook の発火（rc=0）を 3 段構成で assert。hook が外れた場合
  (c) が fail し SMOKE_RESULT: fail で停止する設計
- NFR 1.1 — 既存 rc=0/1/2/3/4/99 の意味は不変、rc=5 は新規追加（additive）。
  `POST_MARKER_RECOVERY_MODE` は新規 env で既存 env 名に影響なし。
  `test-pt-resolve.sh`（#164 fixture）が 19/19 pass で非回帰確認
- NFR 1.2 — marker commit message format `docs(tasks): mark <id> as done` の変更なし
- NFR 1.3 — post-marker 0 件のとき `pt_detect_post_marker_commits` が rc=1 を返し、
  `run_per_task_reviewer` の case 分岐 `1)` で既存ルートに fall-through。git エラー
  （rc=2）も fail-safe で fall-through
- NFR 2.1 — `pt_handle_post_marker_commits` が
  `[YYYY-MM-DD HH:MM:SS] per-task: post-marker-commits-detected task_id=<id> round=<n>
  marker=<sha> post_marker_shas=<csv> recovery=<mode>` の単一行ログを stderr に出力。
  fixture と書式整合

## Verification 補足

- 構造化 verify ブロック（tasks.md `## Verify`）を実行確認:
  - `shellcheck local-watcher/bin/issue-watcher.sh` 警告ゼロ
  - `diff -r .claude/agents repo-template/.claude/agents` exit 0
  - `diff -r .claude/rules repo-template/.claude/rules` exit 0
  - `test-post-marker-detect.sh` → 14 PASSED / 0 FAILED / SMOKE_RESULT: pass
  - `test-pt-resolve.sh`（#164 fixture）→ 19 PASSED / 0 FAILED / SMOKE_RESULT: pass
- tasks.md の 8 件のタスクすべてが `- [x]` で marker commit 済み
- 境界違反なし: 差分は per-task ループ関連の watcher 関数追加、Reviewer prompt 拡張、
  agent docs（developer.md / reviewer.md）の subsection 追記、spec 配下 fixture / impl-notes /
  tasks.md のみ。他の Issue 領域 / 他コンポーネントへの侵食なし

## Findings

なし

## Summary

Issue #304 の AC（Req 1.1〜1.3 / 2.1〜2.3 / 3.1〜3.3 / 4.1〜4.2 / 5.1〜5.3 / NFR 1.1〜1.3 /
NFR 2.1）はすべて diff 内の実装・テスト・ドキュメントで観測可能にカバーされている。
構造化 verify（shellcheck / diff -r / 2 件の smoke）はいずれも pass。境界逸脱なし。

RESULT: approve
