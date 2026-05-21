# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-21T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-15-impl-phase-b-promote-pipeline-st-base-branch
- HEAD commit: cc97f2e12e361d3c432d37ad460ca0c012a66b9a
- Compared to: main..HEAD
- Diff scope (`git diff --stat main..HEAD`):
  - `.github/scripts/idd-claude-labels.sh` (+1)
  - `CLAUDE.md` (+1)
  - `QUICK-HOWTO.md` (±1)
  - `README.md` (+176)
  - `docs/specs/15-.../impl-notes.md` (+272 new)
  - `docs/specs/15-.../tasks.md` (checkbox updates only)
  - `local-watcher/bin/issue-watcher.sh` (+781)
  - `repo-template/.github/scripts/idd-claude-labels.sh` (+1)

## Feature Flag Protocol 確認

CLAUDE.md に `## Feature Flag Protocol` 節は **存在しない**。`grep` 結果 No matches。
→ 通常の 3 カテゴリ判定（AC 未カバー / missing test / boundary 逸脱）のみで判定する。
`PROMOTE_PIPELINE_ENABLED` は Feature Flag Protocol の flag ではなく、Phase B 機能自体の
opt-in env var であり、flag-off path 等価性チェックの対象外（impl-notes.md と整合）。

## Verified Requirements

### Requirement 1: Opt-in gate と適用条件

- 1.1.1 — `process_promote_pipeline()` 冒頭の `[ "$PROMOTE_PIPELINE_ENABLED" != "true" ] && return 0`（issue-watcher.sh 内、Phase B Promote Pipeline Processor セクション）
- 1.1.2 — gate 通過後 `pp_log "サイクル開始 ..."` → `pp_resolve_target_branch` → 本体実行のフローで実装
- 1.1.3 — `pp_resolve_target_branch()` の `[ "$BASE_BRANCH" = "$PROMOTION_TARGET_BRANCH" ]` 早期 return 1（no-op log 付き）
- 1.1.4 — Config block で既存 env var を読み取りのみ。`MERGE_QUEUE_*` / `BASE_BRANCH` / `LOG_DIR` 等の値・既定値に代入なし（diff 確認済み）
- 1.2.1 — `PROMOTION_TARGET_BRANCH="${PROMOTION_TARGET_BRANCH:-main}"`（Config block）
- 1.2.2 — `pp_resolve_target_branch()` の `git ls-remote --exit-code --heads origin "$PROMOTION_TARGET_BRANCH"` 失敗時に `pp_error` + return 1

### Requirement 2: ST 連携と `staged-for-release` 自動付与

- 2.1.1 — `pp_collect_merged_issues()` 内の `gh issue edit --add-label "$LABEL_STAGED_FOR_RELEASE"` 呼び出し
- 2.1.2 — `gh issue list --label staged-for-release` で人間付与と自動付与を統合取得（source 区別なし）
- 2.1.3 — `pp_issue_has_label` で既付与確認 → 既付与なら `skipped++` で `continue`（API 再送なし）
- 2.2.1 — `pp_get_st_state()` の `gh api repos/$REPO/commits/$merge_sha/check-runs` 呼び出し
- 2.2.2 — `jq --arg n "$ST_CHECK_RUN_NAME" '... select(.name == $n) ... | sort_by(.completed_at) | last'` で完全一致 + 最新採用
- 2.2.3 — `pp_get_st_state` 冒頭 `[ -z "$ST_CHECK_RUN_NAME" ] && echo "skip-warn"` + 呼び出し元 `pp_warn`
- 2.2.4 — `pp_process_one_issue` の `pending` ケースで `pp_log "ST=pending action=skip-next-cycle"`、ラベル変更なし
- 2.2.5 — `pp_resolve_merge_sha` 失敗 / check-runs 取得失敗 → `missing` → `pp_warn`
- 2.3.1 — `pp_handle_st_success` の `gh issue edit --remove-label "$LABEL_STAGED_FOR_RELEASE"`
- 2.3.2 — `PROMOTE_CANDIDATES+=("$issue_number")` で promote 集合に追加
- 2.4.1 — `pp_handle_st_failure` の `gh issue edit --add-label "$LABEL_ST_FAILED"`
- 2.4.2 — `pp_do_revert()` 内で `git revert -m 1 --no-edit` + `git push --force-with-lease`
- 2.4.3 — `gh issue reopen` + ST log URL を含む `gh issue comment`（同関数内、heredoc で body 構築）
- 2.4.4 — 同 `gh issue edit` call で `--remove-label "$LABEL_STAGED_FOR_RELEASE"` を `--add-label` と同時実施
- 2.4.5 — per-Issue 失敗時に `pp_warn` + `return 1`。`process_promote_pipeline` の `while read` ループは `|| pp_warn` で吸収して継続
- 2.4.6 — `pp_do_revert` exit 1（push 失敗）時に `pp_warn "... revert push 失敗 ..."` + st-failed 付与スキップ

### Requirement 3: `BASE_BRANCH` → `PROMOTION_TARGET_BRANCH` の昇格

- 3.1.1 — `pp_do_promote` の `git push origin refs/remotes/origin/$BASE_BRANCH:refs/heads/$PROMOTION_TARGET_BRANCH`（自然 ff push）
- 3.1.2 — `git merge-base --is-ancestor "origin/$PROMOTION_TARGET_BRANCH" "origin/$BASE_BRANCH"` ガード
- 3.1.3 — ancestor 不成立時に `pp_warn "promote-failed: ... 祖先でないため fast-forward 不可"` + return（ラベル変更なし）
- 3.1.4 — `pp_do_promote` のサブシェル + `trap 'git checkout $BASE_BRANCH' EXIT` で復帰保証
- 3.2.1 — Config `PROMOTE_MODE="${PROMOTE_MODE:-on-demand}"` で 3 値受付
- 3.2.2 — `pp_do_promote_if_eligible` の `case *)` で WARN + fallback（on-demand 動作）
- 3.2.3 — `case continuous)` で `[ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ] && pp_do_promote`
- 3.2.4 — `case batched)` で `pp_match_cron "$PROMOTE_CRON"` 一致時のみ `pp_do_promote`
- 3.2.5 — `case on-demand)` `pp_log "mode=on-demand 人間トリガーを待つ → promote は実行しない"`、`pp_handle_st_success` も on-demand で label-remove スキップ
- 3.2.6 — `case batched)` で `PROMOTE_CRON` 未設定 → `pp_warn`、不一致 → `pp_log` + 本サイクル no-op
- 3.3.1 — `pp_do_promote` の各失敗パスで `pp_warn "promote-failed: ..."`
- 3.3.2 — `pp_notify_promote_failure` の `[[ "$PROMOTE_FAIL_NOTIFY_ISSUE" =~ ^[0-9]+$ ]]` 分岐で `gh issue comment`
- 3.3.3 — 上記条件不成立時は `return 0`（log のみ）

### Requirement 4: ラベル定義と既存ラベル契約

- 4.1.1 — `.github/scripts/idd-claude-labels.sh` の LABELS 配列に `st-failed|d73a4a|...` 追加
- 4.1.2 — description prefix `【Issue 用】` を既存 `needs-quota-wait` / `staged-for-release` と整合
- 4.1.3 — `repo-template/.github/scripts/idd-claude-labels.sh` にも同一行を追加（diff で同一性確認）
- 4.1.4 — 既存ループ（`gh label list` → `gh label create --force`）の冪等性に内在、追加処理なし
- 4.2.1 — 既存 12 ラベルの定義は変更なし（diff で確認）
- 4.2.2 — `staged-for-release` ラベル名・色・description は無変更、付与・除去契約のみ Phase B が拡張
- 4.2.3 — `needs-rebase` 関連処理は Phase A コードに一切触れていない

### Requirement 5: ロギング・可観測性

- 5.1.1 — `pp_log` / `pp_warn` / `pp_error` の `[$(date '+%F %T')]` 書式（Issue Watcher と一致）
- 5.1.2 — `pp_process_one_issue` の各分岐で `issue=#N ST=<state> action=<action>` 形式の 1 行 log
- 5.1.3 — `pp_summary` で `サマリ: st-success-promoted=X, st-failure-reverted=Y, pending-skip=Z, missing-skip=M, promote-success=P, promote-failed=Q, fail=F` を 1 行出力
- 5.1.4 — 新規 LOG_DIR を作らず、既存 watcher の stdout/stderr 出力に集約
- 5.1.5 — 全 log 行に `[$REPO] promote-pipeline:` prefix（grep 集計用識別語）

### Requirement 6: ドキュメント更新（DoD）

- 6.1.1 — README.md「Promote Pipeline Processor (Phase B)」h2 セクション（目的 / 対象 / タイミング）
- 6.1.2 — 同セクション内「環境変数」表（6 種 + `PROMOTE_GIT_TIMEOUT`）
- 6.1.3 — README.md「ラベル一覧」表 + 「ラベル状態遷移まとめ」表に `st-failed` 行追加
- 6.1.4 — README.md「Phase B: Promote Pipeline 補助フロー」サブセクション（状態遷移表 + Mermaid 図）
- 6.1.5 — 「既存 `staged-for-release`（#100）との共存」段落で同一ラベル共有を明記
- 6.1.6 — README.md「Migration Note（既存ユーザー向け）」サブセクション
- 6.2.1 — QUICK-HOWTO.md「作成されるラベル」一覧に `st-failed` 追記
- 6.2.2 — `st-failed` は全ドキュメントで lowercase / ハイフン区切り完全一致

### Non-Functional Requirements

- NFR 1.1 — `process_promote_pipeline` 冒頭の opt-in gate で `PROMOTE_PIPELINE_ENABLED != true` は no-op return
- NFR 1.2 — Config block で既存 env var の値・既定値は無変更（diff で確認）
- NFR 1.3 — 既存 12 ラベル定義は無変更、Phase B 関連の付与契約のみ拡張
- NFR 2.1 — `pp_do_revert` の `--force-with-lease`、`pp_do_promote` の自然 fast-forward push のみ。`--force` 単独は未使用
- NFR 2.2 — `pp_do_promote` の `git merge-base --is-ancestor` ガードで non-fast-forward を中止
- NFR 2.3 — `process_promote_pipeline` 冒頭の `git status --porcelain` で dirty tree を検知し ERROR + 中止
- NFR 2.4 — `pp_collect_merged_issues` の jq フィルタ `select(.headRepositoryOwner.login == $owner)` で fork PR を除外
- NFR 3.1 — per-Issue ループの `|| pp_warn`、`pp_do_promote_if_eligible || true` で fail-continue
- NFR 3.2 — 全 gh / git 操作を `timeout "$PROMOTE_GIT_TIMEOUT"` で wrap
- NFR 4.1 — `pp_log` / `pp_summary` の `promote-pipeline:` / `promote-success:` / `promote-failed:` 識別語
- NFR 4.2 — `pp_log` → stdout、`pp_warn` / `pp_error` → `>&2` の分離
- NFR 5.1 — 各 git / gh 操作に 60 秒 timeout、`gh pr list --limit 50` / `gh issue list --limit 100` で件数制限
- NFR 5.2 — 1 Issue あたり最大 5 回程度の API call で要件 10 回以内に収まる

## Boundary 検証

- tasks.md の `_Boundary:_` アノテーションは task 1.1 (Labels Setup Script) と task 6.1 (Documentation Set) の 2 件のみ。
  task 2〜5 は `(P)` なしの直列タスクで `_Boundary:_` は記載されていない（`_Requirements:_` のみ）
- 実差分のファイル分布:
  - Labels Setup Script: `.github/scripts/idd-claude-labels.sh`, `repo-template/.github/scripts/idd-claude-labels.sh` ✓
  - Documentation Set: `README.md`, `QUICK-HOWTO.md`, `CLAUDE.md` ✓
  - Phase B 本体: `local-watcher/bin/issue-watcher.sh` ✓
  - Spec: `docs/specs/15-.../impl-notes.md`, `tasks.md` ✓
- 設計の File Structure Plan（design.md）と完全に整合。tasks の `_Boundary:_` 違反なし。

## Test 観点（missing test 判定）

- tasks.md task 7 は `- [ ]*`（アスタリスク付き = deferrable optional）として明示的に分離されており、
  本サイクルでは未実装でも親タスクの完了判定から除外される（tasks-generation.md の規約に準拠）
- 本リポジトリの CLAUDE.md「テスト規約」セクションは `shellcheck` / `actionlint` / 手動スモークテストの
  組み合わせで検証する方針（unit test フレームワーク非採用）
- impl-notes.md には `shellcheck` クリーン（追加 `pp_*` 関数に警告ゼロ、残置 warning は pre-existing）、
  `bash -n` 構文チェック OK、後方互換性確認の結果が記載されている
- 新規追加 AC に対応する「テストケースの不足」は本 repo の規約上 missing test に該当しない
  （unit test 不要、手動検証で代替）

## Findings

なし

## Summary

Phase B Promote Pipeline 機能の実装は requirements.md の全 numeric ID（1.1.x / 1.2.x / 2.1.x / 2.2.x /
2.3.x / 2.4.x / 3.1.x / 3.2.x / 3.3.x / 4.1.x / 4.2.x / 5.1.x / 6.1.x / 6.2.x / NFR 1〜5）と一致しており、
tasks.md の `_Boundary:_` 範囲内に変更が収まっている。Feature Flag Protocol は repo CLAUDE.md で
未宣言（既定 opt-out）のため通常フロー判定を適用。task 7 は `- [ ]*` で deferrable 化されており、
本サイクル未実装でも親タスク完了判定に影響しない。`shellcheck` / `bash -n` も新規追加分にゼロ警告で
クリーン。

RESULT: approve
