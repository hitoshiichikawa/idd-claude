# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-413-impl-fix-promote-path-overlap-default-base-me
- HEAD commit: e9abd8539305ef7ea1368d1c89bd6bb8e1e848e0
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/promote-pipeline.sh` /
  `local-watcher/test/pp_remove_ready_for_review_test.sh`（新規） / `README.md` /
  spec ドキュメント 2 件（`requirements.md` / `impl-notes.md`）
- 注記: 本 Issue では `tasks.md` / `design.md` が生成されていないため、`_Boundary:_`
  アノテーション照合は requirements.md の Out of Scope 節を境界の代替として参照した

## Verified Requirements

- 1.1 — `pp_collect_merged_issues` の per-Issue ループ統合点（`linked_issues`
  ＝ `pp_extract_linked_issues` 出力 = closingIssuesReferences 経路を含む和集合）に
  `pp_remove_ready_for_review_if_present` 呼び出しを追加 / Case 1（closingIssuesReferences
  経路で gh issue edit が 1 回呼ばれ、`action=label-remove label=ready-for-review` ログ出力）
- 1.2 — 同統合点（pp_extract_linked_issues は head ブランチ名
  `^claude/issue-([0-9]+)-impl-` 経路を含む和集合を返す既存契約・#389）/ Case 2（head ブランチ名
  経路 Issue で除去 API が発火）
- 1.3 — `pp_remove_ready_for_review_if_present` 内で `pp_issue_has_label` による
  事前確認 / Case 3（同一 Issue 連続呼び出しで edit は 1 回のみ）/ Case 4（既未付与で
  gh issue edit を呼ばずスキップ）
- 1.4 — 統合点で構造的に保証: BASE_BRANCH = default branch の場合は GitHub auto-close 経路が
  既に ready-for-review を除去するため、本実装の追加除去経路は事前確認で skip され
  external observable な差異を生まない（pp_issue_has_label 早期 return）
- 1.5 — `pp_remove_ready_for_review_if_present` 内で edit 失敗時に `pp_warn` ログ出力 + 戻り値 0
  / Case 5（rc=1 でも `pp_remove_ready_for_review_if_present` 戻り値 0）/ Case 7（連続呼び出しで
  1 件失敗しても 2 件目処理が継続）
- 1.6 — `pp_extract_linked_issues` 出力の和集合 + 重複排除済 Issue 番号配列を
  per-Issue ループに渡す既存構造を流用 / Case 3 で本関数自体の冪等性も担保
- 2.1 / 2.2 / 2.3 / 2.4 — 新規実装なし（#221 既存契約として宣言）。本 PR では path-overlap-checker
  関連コードに変更なし（diff 上でも `po_*` 関数群は touch されていない）。多重防御として既存契約が
  機能し続けることを宣言する位置付け（要件 Decisions / impl-notes と整合）
- 3.1 — `pp_extract_linked_issues` の head 経路が `^claude/issue-([0-9]+)-impl-` 限定のため、
  設計 PR `claude/issue-<N>-design-*` / 人間 PR / 他フォーマット PR は本関数入力集合に含まれない
  （既存構造で担保 / 既存 `pp_extract_linked_issues_test.sh` 9 ケース）
- 3.2 — 同じく `pp_extract_linked_issues` の fork PR 除外条件
  （`headRepositoryOwner.login != $repo_owner`）が `ready-for-review` 除去経路にも適用される
  （入力集合段階で fork PR は除外済）
- 3.3 — `pp_remove_ready_for_review_if_present` 冒頭で `^[0-9]+$` 再検証 / Case 6（`-1` / 空文字
  で gh issue view / gh issue edit を呼ばないことを観測）
- 3.4 — 統合点が `pp_collect_merged_issues` → `process_promote_pipeline` 配下にあり、
  `PROMOTE_PIPELINE_ENABLED != "true"` で早期 return される既存構造で保証
- 3.5 — `pp_collect_merged_issues` 内の `gh pr list` エラー早期 return は本 PR で変更されていない
  （diff で当該条件分岐は touch されていない）
- 4.1 — `pp_log "issue=#${issue_number} action=label-remove label=${LABEL_READY} source=auto"`
  / Case 1, 2, 7 でログ形式 string-match を観測
- 4.2 — 既未付与スキップでは pp_log / pp_warn を一切呼ばない実装 / Case 4（LOG / WARN 出力空を観測）
- 4.3 — `pp_warn "issue=#${issue_number} ready-for-review 除去に失敗（後続 Issue は継続）"` /
  Case 5, 7 で WARN 形式の string-match を観測
- NFR 1.1 / 1.2 / 1.3 / 1.4 — 既存 env var / ラベル名 / exit code / cron 文字列 / ログ出力先 /
  path-overlap holder 計上挙動を本 PR で変更していない（diff 上で env / 定数定義および
  po_* 系コードは touch されていない）
- NFR 2.1 / 2.2 — `pp_collect_merged_issues` 内の `gh pr list --limit 50` /
  `gh issue list --label staged-for-release --limit 100` は本 PR で変更されていない。追加で発火する
  API は per-Issue の `gh issue view --json labels`（pp_issue_has_label 経由）+ 条件付き
  `gh issue edit --remove-label` のみで、`gh issue list` / `gh pr list` の新規呼び出しなし
- NFR 3.1 / 3.2 — `gh issue edit` 引数は `$REPO` / `$LABEL_READY` 定数 + `^[0-9]+$` 検証済 Issue 番号
  のみ。`-` 始まりや正規表現メタ文字を含む値は事前 ID 検証で fall through する
- NFR 4.1 — Reviewer 側で `bash -n local-watcher/bin/modules/promote-pipeline.sh` を実行し
  構文エラー 0 を確認
- NFR 4.2 — `pp_remove_ready_for_review_if_present_test.sh` が NFR 4.2 列挙の必須 5 ケース
  （closingIssuesReferences 単独経路 = Case 1 / head ブランチ名単独経路 = Case 2 /
  両方からの和集合 = Case 3 / 既未付与スキップ = Case 4 / 失敗 WARN ログ = Case 5）を
  Case 1〜5 で網羅。Case 6, 7 は境界補強。Reviewer 側で実行し PASS=23 FAIL=0 を確認

## Findings

なし

## Summary

Promote Pipeline の `pp_collect_merged_issues` per-Issue ループに
`pp_remove_ready_for_review_if_present` 呼び出しを 1 行追加することで、impl PR merge 済 Issue
から `ready-for-review` を `BASE_BRANCH` の default 性に依存せず除去する経路が成立している。
新規関数は数値 ID 再検証 / ラベル事前確認による副作用最小化 / 失敗時 fail-continue + WARN ログ を
備え、要件 1.1〜1.6 / 3.3 / 4.1〜4.3 / NFR 2.1 / 3.2 をすべて満たす。Req 2.x / 3.4 / NFR 1.x / 2.x /
3.1 / 4.x は構造的保証 + 既存 #221 / #389 契約の宣言で担保。境界面では promote-pipeline.sh 以外の
processor（pr-reviewer / auto-merge / merge-queue / auto-rebase / pr-iteration / security-review /
stage-a-verify / path-overlap）に touch されておらず、Out of Scope と整合。新規テスト 7 ケース
23 assertion を Reviewer 側で実行し PASS=23 FAIL=0 を確認、`bash -n` 構文チェックも合格。

RESULT: approve
