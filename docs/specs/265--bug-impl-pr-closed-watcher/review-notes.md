# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-265-impl--bug-impl-pr-closed-watcher
- HEAD commit: 7c867be05ffbf68ca5a01e6847d851fdd769a84c
- Compared to: main..HEAD

差分構成:

- `local-watcher/bin/issue-watcher.sh` — `stage_checkpoint_find_impl_pr` の jq 採用ロジック組み替え + `include_closed` 引数追加 + CLOSED 除外時の観測ログ追加。`stage_c_existing_pr_guard` を `include_closed=true` で呼ぶよう変更（Issue #212 経路維持）。`stage_checkpoint_resolve_resume_point` / `stage_a_crossing_probe` / `spec_artifacts_completeness_guard` のドキュメントコメント更新（コード変更は引数追加なしの既定 false 呼び出しのまま）
- `docs/specs/265--bug-impl-pr-closed-watcher/test-fixtures/` — 7 fixture JSON + jq 採用ロジック等価再現スクリプト（14 ケース）
- `docs/specs/265--bug-impl-pr-closed-watcher/{requirements,impl-notes}.md` — 仕様 + 実装メモ

本 spec は design-less impl（PM 直 → Dev）のため `tasks.md` は存在しない。boundary は本 Issue spec dir + Stage Checkpoint モジュール本体に限定される。

## Verified Requirements

- 1.1 (CLOSED 未マージ PR を停止根拠から除外) — `test-find-impl-pr.sh` の `closed-only/default=NONE`（jq rc=1） + 新規 `sc_log "find-impl-pr: excluded-closed pr=#... reason=closed-unmerged-not-stop-signal ..."` 出力（`issue-watcher.sh:1140-1142`）
- 1.2 (OPEN → 既存挙動維持) — `open-only/default=201,OPEN` および `open-only/include_closed=201,OPEN` PASS
- 1.3 (MERGED → 既存挙動維持) — `merged-only/default=301,MERGED` および `merged-only/include_closed=301,MERGED` PASS
- 1.4 (CLOSED のみ → 既存 PR なし扱い) — `closed-only/default=NONE` PASS、`resolve_resume_point` 内で rc=1 case が後段 checkpoint へ進む経路（`issue-watcher.sh:1188-1189` の case 1 分岐へ流れる）
- 1.5 (OPEN/MERGED + CLOSED 混在 → OPEN/MERGED 優先) — `open-and-closed/* = 201,OPEN`、`merged-and-closed/* = 301,MERGED`、`open-merged-closed/* = 202,OPEN`（配列順序が CLOSED→MERGED→OPEN でも OPEN 優先採用を確認）
- 2.1 (claude-failed 除去後の自動再開継続) — `resolve_resume_point` が rc=1 を受け取り「既存 PR なし」相当の経路で Stage A 再開へ流れる（コード追跡: `issue-watcher.sh:1188-1189` case 1）
- 2.2 (CLOSED PR への副作用なし) — `stage_c_existing_pr_guard` 以外は include_closed=false で呼ぶため CLOSED PR 採用分岐に到達せず、ラベル / コメント / close 操作は発火しない
- 2.3 (既存 Decision Table を本要件導入前と同一規則で適用) — Decision Table コードに変更なし（コメント追記のみ）。CLOSED-only → existing-impl-pr=none → 従来の D-1〜D-7 分岐
- 3.1 (OPEN: Stage C 冪等ガード挙動不変) — `stage_c_existing_pr_guard` が `find_impl_pr true` で呼び、OPEN は今までどおり OPEN 分岐に到達。`open-only/include_closed=201,OPEN` で OPEN 採用を確認
- 3.2 (MERGED: Stage C 冪等ガード挙動不変) — 同上、`merged-only/include_closed=301,MERGED` で MERGED 採用を確認
- 3.3 (越境観測ヘルパ: OPEN/MERGED のみ越境記録 / CLOSED 除外) — `stage_a_crossing_probe` が `find_impl_pr`（include_closed=false 既定）で呼ぶ（`issue-watcher.sh:1459`）。CLOSED-only → rc=1 → 越境根拠として記録されない
- 3.4 (spec 完全性ガード: MERGED のみ docs-only 補完起動 / OPEN/CLOSED/none は起動しない) — `spec_artifacts_completeness_guard` が `find_impl_pr`（include_closed=false 既定）で呼ぶ（`issue-watcher.sh:1756`）。CLOSED-only → rc=1 → pr_state="(none)" → MERGED マッチに到達せず
- 4.1 / 4.3 (CLOSED 除外時の `stage-checkpoint:` prefix 観測ログ 1 行以上、grep 抽出可能) — 新規 `sc_log "find-impl-pr: excluded-closed pr=#${closed_num} count=${closed_count} reason=closed-unmerged-not-stop-signal branch=${BRANCH} issue=#${NUMBER:-?}"`（`issue-watcher.sh:1140-1142`）。既存 `sc_log` 関数を流用するため書式 `[%F %T] stage-checkpoint: ...` 完全一致
- 4.2 (Stage A 再開時の既存 Decision Table ログ出力) — 既存 `sc_log "decision: START_STAGE=A reason=..."` 経路に変更なし
- NFR 1.1 / 1.2 (`STAGE_CHECKPOINT_ENABLED=true` 以外は 1 行も実行せず) — gate `[ "${STAGE_CHECKPOINT_ENABLED:-true}" != "true" ]` 経路に変更なし。本修正は `stage_checkpoint_*` 関数群配下のロジックのみ変更し、各呼び出し元の gate より下流で動作
- NFR 1.3 (既存ラベル名 / Issue 候補抽出フィルタ不変) — mark_issue_failed / LABEL_* 系の参照に変更なし
- NFR 1.4 (OPEN / MERGED 1 件以上存在する全ケースで挙動不変) — `open-*` / `merged-*` fixtures（6 ケース）が修正前後で同一結果 = OPEN/MERGED を含む場合は OPEN/MERGED を返す
- NFR 2.1 (3 段書式 grep 抽出可能) — `sc_log` 関数流用で書式完全一致
- NFR 3.1 / 3.2 (read-only 観測、副作用なし) — 新規追加は観測ログ 1 行のみ。`gh pr list` は元から read-only

## Verification Results

reviewer 側でも以下を独立再実行して確認した:

- `bash docs/specs/265--bug-impl-pr-closed-watcher/test-fixtures/test-find-impl-pr.sh` → `Summary: PASS=14 FAIL=0` (exit 0)
- `shellcheck local-watcher/bin/issue-watcher.sh docs/specs/265--bug-impl-pr-closed-watcher/test-fixtures/test-find-impl-pr.sh` → 警告ゼロ

## Boundary Check

本 spec は design-less impl のため `tasks.md` 不在。差分は以下に限定:

- `local-watcher/bin/issue-watcher.sh` — Stage Checkpoint モジュール本体（Issue #265 の修正対象）
- `docs/specs/265--bug-impl-pr-closed-watcher/**` — 当該 Issue spec dir

CLAUDE.md「禁止事項」「root↔repo-template 二重管理」等の boundary 違反なし（`.claude/agents` / `.claude/rules` / `repo-template/**` は本修正の対象外で触れていない。Stage Checkpoint モジュールは root の `local-watcher/` のみが正本）。

CLAUDE.md `## Feature Flag Protocol` 節は存在しない → opt-out 解釈、flag 観点の細目チェックは適用外。

## Findings

なし

## Summary

Issue #265 の CLOSED 未マージ impl PR を resume 地点判定から除外する修正は、Req 1〜4 / NFR 1〜3 のすべての AC をカバーしており、14 ケースの fixture テストが PASS。OPEN/MERGED の既存挙動は jq 採用優先順位の組み替えにより本要件導入前と完全に同一（NFR 1.4）。Stage C CLOSED ガード（Issue #212 経路）は `include_closed=true` 明示渡しで温存（Out of Scope と整合）。観測ログは既存 `sc_log` 流用で書式統一。shellcheck 警告ゼロ。

RESULT: approve
