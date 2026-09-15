# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-09-15T02:48:22Z -->

## Reviewed Scope

- Branch: claude/issue-535-impl-fix-promote-pipeline-issue-issue-gh-issu
- HEAD commit: 5ec27626ba8bc1ffa439ba63556f40fce49ba44e
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/promote-pipeline.sh` / `local-watcher/test/pp_labels_map_test.sh`（新規）/ `README.md` / spec 配下（`requirements.md` / `impl-notes.md`）
- design.md / tasks.md は本 Issue には存在しない（design-less impl）。`_Boundary:_` アノテーションは不在のため、境界判定は requirements.md の Out of Scope 節を正本とした。
- CLAUDE.md に `## Feature Flag Protocol` 節は存在しない（rules 参照表の言及のみ）。よって flag 観点は適用せず、通常 3 カテゴリ判定を実施。

## Verified Requirements

- 1.1 — `pp_fetch_issue_labels_map` が全リンク Issue を 1 回の `gh api graphql` alias クエリで一括取得（`promote-pipeline.sh`）。`pp_labels_map_test.sh` Case 1/2 が N=3/N=6 で graphql=1 定数を観測。
- 1.2 — per-Issue の 2 判定（ready / staged）が同一 in-memory マップ `PP_ISSUE_LABELS` を参照。Case 3 で `gh issue view`=0 を観測。
- 1.3 — マップは `pp_collect_merged_issues` 先頭で per-cycle に `local -A` として再構築（実ラベル状態から再導出）。Case 4 で自己修復を観測。
- 1.4 — 手動で `staged-for-release` を外した Issue の再付与を Case 4（#31）で観測。
- 1.5 — 取得対象を正確なリンク Issue 集合に限定（固定件数上限なし）。Case 6（全 alias 反映 / null alias 未 set）+ Case 2（N=6 全件）で欠落なしを観測。
- 2.1 — 未付与 Issue への `--add-label` 付与ロジックは温存。Case 3（#21/#24）で観測。
- 2.2 — 付与済は skip（API 再送なし）。Case 1（edit=0）/ Case 3（#22 add-label=0）で観測。
- 2.3 — `issue=#<N> action=label-add label=staged-for-release source=auto` ログを Case 3 で観測。
- 2.4 — 付与失敗 WARN（`staged-for-release 自動付与に失敗（後続 Issue は継続）`）は `pp_collect_merged_issues` 内に温存（本修正で edit ロジック不変）。
- 2.5 — `auto-label サマリ: staged-for-release-added=<n>, already-labeled-skipped=<m>` を Case 1/2/3 で現行書式で観測。
- 3.1 — `pp_remove_ready_for_review_if_present` の除去経路を温存。Case 3（#23/#24）で観測。
- 3.2 — ready 無しは除去 API を再送しない。Case 3（#22 remove=0）で観測。
- 3.3 — `issue=#<N> action=label-remove label=ready-for-review source=auto` ログを Case 3 で観測。
- 3.4 — 除去失敗 WARN は既存経路不変。既存 `pp_remove_ready_for_review_test.sh`（23 PASS）で回帰確認。
- 3.5 — 手動で付け直した `ready-for-review` の再除去を Case 4（#32）で観測。
- 4.1 — graphql 失敗（rc≠0）で WARN + per-Issue `gh issue view` フォールバック。Case 5 で観測（view=4 / 結果継続）。
- 4.2 — `gh pr list` 失敗時の既存 WARN + return は不変（`pp_collect_merged_issues` 冒頭 / 本修正で未変更）。
- 4.3 — Issue 番号 `^[0-9]+$` 再検証を `pp_fetch_issue_labels_map` stdin ループ + 結果パース + 既存ループ（`promote-pipeline.sh` 行 359）で実施。Case 6 で `-1` が GraphQL query に混入しないことを観測。
- 4.4 — graphql は gate 通過後の `pp_collect_merged_issues` 内でのみ発火。`process_promote_pipeline` の early return は不変。`sn_callsite_promote_test.sh`（15 PASS）で回帰確認。
- 5.1 — 結果等価。Case 3 の混合ケース + 既存 3 テスト無改変通過で担保。
- 5.2 — Case 1/2 が N を変えても確認系 API がコールトレース上 N に比例しない（graphql=1 定数）ことを観測。
- 5.3 — 既存 3 テスト通過を再実行で確認（`pp_remove_ready_for_review`=23 / `pp_extract_linked_issues`=10 / `sn_callsite_promote`=15、全 FAIL 0）。
- NFR 1.1/1.2/1.3 — env var / ラベル / exit code / cron / ログ出力先の変更なし。新規 opt-in gate 追加なし（結果等価方針）。
- NFR 2.1 — 2×N → 定数 1 を Case 1/2 で観測。
- NFR 2.2 — merged PR 取得 `--limit 50` は diff で未変更。
- NFR 3.1/3.2 — head ブランチ名の `--arg` / `--` 経路は既存不変。Issue 番号再検証は Case 6 で担保。GraphQL owner/name は `-f` 変数渡しで inline 展開しない。
- NFR 4.1 — 状態ファイルは導入せず自己修復を維持（Where 条件非該当）。
- NFR 5.1 — `bash -n` OK / `shellcheck`（`.shellcheckrc` baseline）警告増加 0 を再実行で確認。

## Findings

なし

## Summary

design-less impl。全 numeric AC（Req 1〜5 / NFR 1〜5）が最新差分または既存温存コードでカバーされ、
N 非依存化・結果等価・自己修復・異常系フォールバックの各挙動に対応する近接テスト
（`pp_labels_map_test.sh` 34 PASS）が追加されている。既存 3 テストも無改変で通過し、`bash -n` /
shellcheck もクリーン。変更は promote-pipeline.sh / 新規テスト / README / spec に限定され Out of Scope
の境界（ST 判定 / promote / revert / 他 processor）を侵していない。3 カテゴリいずれにも該当なし。

RESULT: approve
