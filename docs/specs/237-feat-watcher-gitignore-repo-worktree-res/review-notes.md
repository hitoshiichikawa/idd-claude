# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-237-impl-feat-watcher-gitignore-repo-worktree-res
- HEAD commit: e6b3532567d610575580251b55453cebd6c6a7c2
- Compared to: main..HEAD
- 備考: design-less impl（design.md / tasks.md 不在）。`_Boundary:_` アノテーションは存在しないため、boundary 判定は requirements.md の Out of Scope（特に Req 4.4 / labels.sh 非配布）と変更ファイル範囲の突き合わせで実施。CLAUDE.md に `## Feature Flag Protocol` 節が無いため opt-out として解釈し、flag 観点の確認は行わない。

## Verified Requirements

- 1.1 — `core_utils.sh:_worktree_inject_claude`（wt 不在 + src 有のとき `cp -a` で注入）/ smoke Case (a)
- 1.2 — smoke Case (a) が `.claude/agents/developer.md` `.claude/rules/ears-format.md` の worktree 出現を assert
- 1.3 — `issue-watcher.sh:6814-6820`：`worktree reset OK` ログ直後・`_hook_invoke`（hook / agent 起動）の前に呼び出し（コードレビュー）
- 1.4 — 注入成功時 `slot_log ".claude を REPO_DIR から worktree へ注入 ..."` / smoke Case (a) がログ出力を assert
- 2.1 — `[ -e "$wt/.claude" ]` で即 return 0（上書きしない）/ smoke Case (b)（TRACKED-ORIGINAL 不変・rules 非混入）
- 2.2 — `[ ! -d "$src_repo_dir/.claude" ]` で即 return 0 / smoke Case (c)（.claude 未作成・warn 無し）
- 2.3 — tracked 運用 repo は reset 後 `.claude/` 復元 → NO-OP（smoke Case (b) + impl-notes 後方互換根拠）
- 2.4 — auto-detect 構造（env gate 無し / 既存挙動側へ倒れる）+ smoke Case (b)/(c)
- 3.1 — コピー失敗パスで `slot_warn ".claude の注入に失敗しました ..."`（コードレビュー）
- 3.2 — 関数が常に return 0（smoke 全 Case が rc=0 を assert）→ `set -euo pipefail` 下でも呼び出し側を倒さない
- 3.3 — 呼び出し側（issue-watcher.sh:6820）は `_slot_mark_failed` を呼ばない（コードレビュー）+ return 0
- 4.1 — 1 回目注入後は wt に `.claude/` が出来るため 2 回目は NO-OP（smoke Case (e)）
- 4.2 — `cp -a "$src/.claude" "$wt/"` がディレクトリ単位 / smoke Case (b) が rules 非混入を assert
- 4.3 — 呼び出し側で git add / commit を行わない（コードレビュー）。`.claude/` は gitignore 対象のまま untracked
- 4.4 — コピー対象は `.claude/` のみで `.github/scripts/idd-claude-labels.sh` に触れない（コードレビュー / 変更ファイル一覧でも labels.sh 無変更）
- NFR 1.1 — 新規 env var 追加なし・ラベル / exit code / ログ書式不変（shellcheck SC2317 件数 baseline 同一 / impl-notes）
- NFR 1.2 — `_worktree_reset` 本体未変更（diff は注入呼び出し追加と SRC_REPO_DIR 捕捉のみ。reset → clean 順序不変）
- NFR 1.3 — 後方互換を破っていない（migration 不要）
- NFR 2.1 — smoke Case (e) の冪等性で連続サイクル一貫性を担保
- NFR 2.2 — 注入は per-worktree（`$WT` / `$SRC_REPO_DIR` はサブシェル局所）で並列 slot 間非干渉（コードレビュー）
- NFR 3.1 — 注入時 `slot_log` / 失敗時 `slot_warn` / NO-OP 無ログで判別可能 + README に grep 例

## 独立再実行による裏取り

- `bash docs/specs/237-feat-watcher-gitignore-repo-worktree-res/test-fixtures/test-inject-claude.sh` → 全 14 アサーション PASS（exit 0）を Reviewer 側で再実行確認
- `shellcheck local-watcher/bin/modules/core_utils.sh` → 警告ゼロ（exit 0）
- `shellcheck docs/.../test-inject-claude.sh` → 警告ゼロ（exit 0）

## Findings

なし

## Summary

全 numeric AC（R1〜R4 / NFR 1〜3）に対応する実装またはテストが存在し、design-less impl のため boundary アノテーション逸脱もない（labels.sh / .github/scripts 無変更、Req 4.4 充足）。smoke テスト 14 件 PASS・shellcheck 警告ゼロを Reviewer 側で再実行確認した。

RESULT: approve
