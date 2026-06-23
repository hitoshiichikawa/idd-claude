# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-389-impl-fix-promote-pipeline-staged-for-release
- HEAD commit: 713c0a3b35f471f115520019f8a1b68378512ced
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `pp_extract_linked_issues` 内 jq `capture("^claude/issue-(?<n>[0-9]+)-impl-")` で head ブランチ名からの `<N>` 抽出を実装（`promote-pipeline.sh:1083-1121`）。テスト Case 2/8/9 が観測
- 1.2 — jq `((closingIssuesReferences[].number) + (headRefName capture)) | unique` で和集合 + 重複排除（同関数内）。テスト Case 3/6 が観測
- 1.3 — head パターン不一致時は `capture // empty` で素通り。テスト Case 4（`feature/manual-fix` / `claude/issue-50-design-spec` 除外）が観測
- 1.4 — `closingIssuesReferences=[]` でも head 経路で `<N>` を収集。テスト Case 2/9（develop 想定）が観測
- 1.5 — `[[ "$issue_number" =~ ^[0-9]+$ ]]` の bash 防御層を `pp_collect_merged_issues:1165-1170` に追加。jq の `capture` でも数値 ID は保証。テスト Case 8 が観測
- 2.1 — `pp_issue_has_label` による既付与スキップ（既存ロジック未変更、`promote-pipeline.sh:1175`）
- 2.2 — `pp_log` フォーマット文字列（`source=auto`）を変更せず（diff 確認）
- 2.3 — fork PR 除外 `select((.headRepositoryOwner.login // "") == $owner)` を head 経路にも適用。テスト Case 5 が観測
- 2.4 — `staged-for-release` ラベル名・`source=auto` ログを単一化（diff で改変なし）
- 2.5 — WARN ログ `pp_warn` は既存挙動を維持（後段 while ループ未変更）
- 3.1 — `pp_collect_merged_issues` 呼び出し条件（`PROMOTE_PIPELINE_ENABLED`）は本 PR で変更されていない
- 3.2 — Case 1（closing 単独 #42）/ Case 3（両経路同一 #99）で main 既存挙動の不変を観測
- 3.3 — `LABEL_STAGED_FOR_RELEASE` / `PROMOTE_GIT_TIMEOUT` / `BASE_BRANCH` 参照のみで改名・追加なし（diff 確認）
- 3.4 — `--limit 50` / `--limit 100` は未変更（diff 確認）
- 3.5 — `gh pr list` 呼び出しは 1 回のまま、`--json` フィールドに `headRefName` を追加するのみ
- 4.1 — `pp_get_st_state` / `pp_resolve_merge_sha` / `ST_CHECK_RUN_NAME` 経路は未変更（diff は `pp_extract_linked_issues` 追加 + `pp_collect_merged_issues` のみ）
- 4.2 — `pp_handle_st_success` / `pp_handle_st_failure` の promote 動線は未変更
- 4.3 — `po_*` / `pp_get_st_state` / `pp_resolve_merge_sha` / `pp_resolve_st_log_url` の関数シグネチャ・stdout 形式は未変更
- 4.4 — `staged-for-release` 付き open Issue を後段に渡す stdout 形式は未変更（後段ループは保持）
- 5.1 — `local-watcher/test/pp_extract_linked_issues_test.sh` Case 1-4 で 4 ケースを観測
- 5.2 — テスト Case 5 で fork PR 除外を観測
- 5.3 — `bash local-watcher/test/pp_extract_linked_issues_test.sh` 単一スクリプトで起動可能（PASS=10 FAIL=0 を再実行確認）
- 5.4 — Case 9 で develop 想定入力に対する fail 出力（PR 番号 / head ブランチ名 / 期待 Issue 番号）を実装
- NFR 1.1 — Case 1/3 が main 既存運用の不変を観測、diff にラベル名・順序・ログ形式の改変なし
- NFR 1.2 — opt-in gate は本 PR で改変なし
- NFR 1.3 — `LABEL_STAGED_FOR_RELEASE` 定数参照を破壊せず
- NFR 2.1 — `bash -n` OK / `shellcheck local-watcher/bin/modules/promote-pipeline.sh` warnings 0 を再実行確認
- NFR 2.2 — 追加テストの `bash -n` OK / `shellcheck` warnings 0 を再実行確認
- NFR 3.1 — `pp_log` フォーマット文字列を改変せず（diff 確認、head 経路導出ログも同形式）
- NFR 3.2 — サマリログ書式と `added` / `skipped` 集計の合算（後段共通ループ通過）を保持
- NFR 3.3 — `pp_warn` フォーマットを改変せず（後段共通 while ループ通過）
- NFR 4.1 — `headRefName` は jq 内 `capture` で完結し、bash 展開を経由させない設計
- NFR 4.2 — bash 側 `[[ =~ ^[0-9]+$ ]]` + jq `capture` の二重検証

## Findings

なし

## Summary

`pp_collect_merged_issues` の Issue 番号導出を `closingIssuesReferences` 単独から
`pp_extract_linked_issues` ヘルパー経由の「closingIssuesReferences + head ブランチ名
`^claude/issue-([0-9]+)-impl-` capture」の和集合へ拡張する変更は、Requirements 1〜5 と
NFR 1〜4 をすべて充足。境界も `pp_collect_merged_issues` 周辺と新規 helper／近接テストに
局所化されており、`pp_get_st_state` / `pp_resolve_merge_sha` / promote 動線等のスコープ外
要素には触れていない。`bash -n` / `shellcheck` / 近接テスト（PASS=10 FAIL=0）を再実行
して green を確認した。

RESULT: approve
