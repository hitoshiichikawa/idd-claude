# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-177-impl-feat-watcher-issue-watcher-sh-part-1
- HEAD commit: 04957aa88ae86319b8d7a09ff8c75c0659e4a7ed
- Compared to: main..HEAD（本 HEAD の差分は per-task ループの task 1 commit と一致。tasks 2-6 は未着手のため後続 fresh Implementer/Reviewer が担当する）
- 対象 task: 1（_Requirements: 3.1-3.9 / _Boundary: CoreUtils.Loggers, CoreUtils.DateFormat, CoreUtils.Worktree, CoreUtils.Slot, CoreUtils.Hook）
- レビュー方式: per-task ループ（issue-watcher.sh L317-323 / spec #21 Phase 2）。task 1 commit を task 1 の `_Requirements:_` / `_Boundary:_` に照らして判定する。Requirement 1（install）/ 2（ModuleLoader）/ 4（test 互換）は task 3 / 2 / 4 の担当であり本 review の対象外
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out 扱い（flag 観点の確認は行わない）

## Verified Requirements

- 3.1 — `local-watcher/bin/modules/core_utils.sh` に `qa_`/`mq_`/`ar_`/`pp_`/`pi_`/`drr_` 各系の `_log`/`_warn`/`_error` を集約（削除側 issue-watcher.sh と追加側 core_utils.sh の関数定義集合が完全一致）。`mqr_` 系は Part 1 移動対象外として本体 `issue-watcher.sh:2195-2201` に残置（design.md TestCompat 注記に整合）
- 3.2 — issue-watcher.sh の削除全 358 非空行が core_utils.sh に文字単位で一致することを機械検証（`grep -Fxq` で missing=0）。出力先・時刻 prefix・`[$REPO]` 挿入・processor prefix・書式は分割前と同一
- 3.3 — `qa_format_iso8601` を同一定義で移動。GNU date（`-d @epoch -Iseconds`）/ BSD date / epoch フォールバックを保持
- 3.4 — `_worktree_ensure` を同一定義で移動。`_worktree_path` / `_worktree_is_registered` 依存をモジュール内に閉じた
- 3.5 — `_worktree_reset` を同一定義で移動（Issue #167 の per-slot fetch 削除コメント含め原文保持）
- 3.6 — `_slot_acquire` を同一定義で移動。fd 210+N 規約・`flock -n` 非ブロッキング・`eval "exec"`（bash 4.0 互換）・`_slot_lock_path` 依存を保持
- 3.7 — `_slot_release` を同一定義で移動
- 3.8 — `_hook_invoke` を同一定義で移動。直接 exec（シェル展開なし）/ Issue #170 の同期 stderr 捕捉 / no-op 既定を保持
- 3.9 — 全関数を cut & paste（改変なし）で同一シグネチャ・戻り値・副作用で公開。core_utils.sh の非コメント機能行はすべて main の issue-watcher.sh に存在（新規挙動の混入ゼロ）。移動後の関数は issue-watcher.sh 側に重複定義されておらずクリーンな move
- 補足: `core_utils.sh` は `bash -n` / `shellcheck` ともにクリーン。issue-watcher.sh は追加 0 行・削除 358 行の純削除で `bash -n` も通過

## Findings

なし

## Summary

task 1 は core_utils.sh への純粋な cut & paste（差分等価）リファクタ。削除 358 行が core_utils.sh に
verbatim で一致（missing=0）、新規挙動の混入ゼロ、bash -n / shellcheck もクリーンで、AC 3.1-3.9 を
カバー。変更は CoreUtils.* 境界（core_utils.sh 新規 + issue-watcher.sh の削除側）と spec docs に限定され
boundary 逸脱なし。関数移動に伴うロード機構不在・既存スモークテストの一時 failing は per-task ループの
想定された中間状態であり task 2/4 の担当（本 review 対象外）。本リポジトリに unit test framework は無く
挙動 delta ゼロのため missing test 非該当。

RESULT: approve
