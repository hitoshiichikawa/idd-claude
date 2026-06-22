# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T15:25:00Z -->

## Reviewed Scope

- Branch: claude/issue-356-impl-fix-watcher-per-task-post-marker-commit
- HEAD commit: 7885959a3e3ffbbf0ebe53fc4fe4bc7ea434b5db
- Compared to: main..HEAD
- 構成: 5 commits / 6 files / +866 -3
  - `feat(watcher)`: docs-only post-marker auto-refresh 本体
  - `test(watcher)`: 近接テスト 39 アサーション
  - `docs(agents)`: developer.md Marker contract 順序条項
  - `docs(readme)`: post-marker docs-only auto-refresh 節
  - `docs(impl-notes)`: 実装ノート
- 備考: 本 spec は `tasks.md` / `design.md` を持たない単一実装パス（Architect 起動なし）。`_Boundary:_` アノテーションは存在しないため、boundary 逸脱は変更ファイル群と Req スコープの整合で判定した。

## Verified Requirements

- 1.1 — `pt_classify_post_marker_paths` 新設 + `pt_handle_post_marker_commits` 前段ブロックで mode != extend-range 時の docs-only auto-refresh を実装。`pt_post_marker_classify_test.sh` Case 1/2/A で観測可能（rc=0 + `<range_start>\tHEAD_SHA` 返却）
- 1.2 — `pt_handle_post_marker_commits` の `echo "[${ts}] per-task: post-marker-commits-detected task_id=... round=... marker=... post_marker_shas=... recovery=docs-only-auto-refresh"` 行（issue-watcher.sh:3432）。Case A で stderr に `recovery=docs-only-auto-refresh` / `task_id=1.2` / `post_marker_shas=post001,post002` を assert
- 1.3 — `pt_post_docs_only_auto_refresh_comment` 新設（issue-watcher.sh:4791〜）。`run_per_task_reviewer` の rc=0 経路で `_recovery_kind = "docs-only-auto-refresh"` のときのみ呼ばれる（issue-watcher.sh:4341〜4343）。HTML コメントマーカーで重複抑制
- 1.4 — auto-refresh 経路（rc=0）は `pt_mark_post_marker_commits_detected` を呼ばないため `claude-failed` が付かない（issue-watcher.sh:4317〜4348 case 0 で確認）。Case A test の rc=0 + Case B test との挙動差で間接担保
- 1.5 — `POST_MARKER_DOCS_ALLOWLIST` 既定値 `**/impl-notes.md,docs/specs/**/*.md` を env var 宣言コメント（issue-watcher.sh:595〜610）と README（「docs-only auto-refresh」節）の両方で明示
- 2.1 — `pt_classify_post_marker_paths` の allowlist 外 1 件で `mixed` 判定（first_unmatched 返却）。Case 3/4 test で code/test ファイル含む → rc=1 + verdict=mixed を assert
- 2.2 — mixed / allowlist 空 / 変更 0 件はすべて保守的に mixed に倒し fail-with-diagnostic 経路（rc=5）に fall through。Case 6/7/B test で確認
- 2.3 — `pt_mark_post_marker_commits_detected` 経路は変更しておらず、`run_per_task_reviewer` 側 case 5 で従来どおり呼ばれる（issue-watcher.sh:4349〜4353）。claude-failed 付与 + diagnostic コメントの既存挙動を温存
- 2.4 — `pt_classify_post_marker_paths` rc=2（git エラー）は `_classify_reason="classify-git-error"` でログを残しつつ `if classify_rc=0 && verdict=docs-only` 条件を満たさないため mode dispatch（fail-with-diagnostic）に倒れる。Case 5 test で git diff エラー時の挙動確認
- 3.1 — `pt_detect_post_marker_commits` 0 件時の rc=1 は変更なし。`run_per_task_reviewer` の case 1 で `:` no-op として既存 fall-through を維持。Case F test で確認
- 3.2 — `POST_MARKER_RECOVERY_MODE` の `case` 文（issue-watcher.sh:3393〜3399）は変更なし。既存 2 値解釈温存
- 3.3 — `if [ "$mode" != "extend-range" ]` ガード（issue-watcher.sh:3417）で extend-range mode 時は docs-only 判定を完全 skip。Case C/D test で確認
- 3.4 — 不正値は既存 case 文で fail-with-diagnostic に正規化された後、本ガードを通過して docs-only 判定が適用される。Case E test で `bogus-mode-value` + docs-only → auto-refresh rc=0 を確認
- 3.5 — env var 名（`POST_MARKER_RECOVERY_MODE`）/ ラベル名（`claude-failed`）/ exit code（rc=5）/ cron 登録文字列 / ログ出力先はいずれも変更なし
- 4.1 — `.claude/agents/developer.md` の Marker contract 節に「順序条項（Issue #356 / 必読）」サブセクションを新設し、(1) impl-notes/learning を marker より前に積む、(2) marker は task の最終 commit、の 2 条項を明示
- 4.2 — `diff -r .claude/agents repo-template/.claude/agents` 実行結果が空（byte 一致確認済み）
- 4.3 — 同節内で「後続作業が必要になった場合は『retry 時の marker refresh 契約』に従って旧 marker を剥がし、追加 commit を積んだ上で marker を作り直す」と明示。既存 retry セクションを参照する形で順序保持
- 4.4 — 「watcher 側 safety net との関係」末尾に docs-only auto-refresh の defense-in-depth 説明を追加し、Developer 単体で読んだとき auto-refresh 機構の存在意義と発火条件が自己完結
- NFR 1.1 — README 「Post-marker commit safety net (#304 / #356)」節を全面追加。`POST_MARKER_RECOVERY_MODE` の値表 + 「docs-only auto-refresh」サブ節で発火条件・allowlist・ログ書式・既存運用との関係を明示
- NFR 1.2 — `diff -r .claude/agents repo-template/.claude/agents` 空 / `diff -r .claude/rules repo-template/.claude/rules` 空（手元で再確認）
- NFR 1.3 — docs-only-auto-refresh / fail-with-diagnostic / extend-range のいずれも single-line stderr ログ（`[ts] per-task: post-marker-commits-detected ... recovery=<kind>`）として出力。kind tag のみが分岐
- NFR 2.1 — `impl-notes.md` の「merge 後の運用 follow-up」節で「暫定 `POST_MARKER_RECOVERY_MODE=extend-range` を撤去できる」事実を明記
- NFR 2.2 — `recovery=docs-only-auto-refresh` という単一行 tag は `grep` で発火件数集計可能（既存 `recovery=` 命名規約と整合）
- NFR 3.1 — `local-watcher/test/pt_post_marker_classify_test.sh` に正常系（Case 1/2/A）・異常系（Case 3/4/B/5）・境界系（Case 6/7/F/G/H/C/D/E）の 3 系統 39 アサーション追加。`bash local-watcher/test/pt_post_marker_classify_test.sh` → PASS: 39, FAIL: 0 で再確認済み
- NFR 3.2 — `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/test/pt_post_marker_classify_test.sh` 警告ゼロ / `bash -n` OK を再確認

## Findings

なし

## Summary

すべての numeric AC（Req 1.1〜1.5 / Req 2.1〜2.4 / Req 3.1〜3.5 / Req 4.1〜4.4 / NFR 1.1〜1.3 / NFR 2.1〜2.2 / NFR 3.1〜3.2）について実装またはテストで観測可能なカバレッジを確認した。実装は既存 `pt_handle_post_marker_commits` の前段に docs-only 判定を追加する最小侵襲な構成で、後方互換性（extend-range mode の温存 / env var・ラベル・exit code 不変）が保たれている。テストは fake git stub による 39 アサーションが PASS / shellcheck・bash -n クリーン / root↔repo-template の `diff -r` 空。Developer agent の Marker contract 強化（Fix B）も両系統で byte 一致反映済み。AC 未カバー / missing test / boundary 逸脱 のいずれにも該当しない。

RESULT: approve
