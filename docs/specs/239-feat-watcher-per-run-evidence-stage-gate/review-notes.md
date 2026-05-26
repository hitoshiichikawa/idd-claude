# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-239-impl-feat-watcher-per-run-evidence-stage-gate
- HEAD commit: 64c80d718c84dc992487b3f6c56412d51522275c
- Compared to: main..HEAD

> 注: orchestrator が指定した `main..HEAD` の 2-dot diff は、本ブランチの分岐後に main が
> 6 PR（#254/#252/#250/#249/#247/#245）前進したため大量の「削除」が混入し誤読を招く。
> ブランチ固有の差分は merge-base `6fcbec0..HEAD` で判定した（9 ファイル / +874 −17）。
> File Structure Plan と一致し、`.claude/` 配下への変更は無し（二重管理規約 非該当を確認）。

## Verified Requirements

- 1.1 — `rs_emit`（run-summary.sh:247）を `_slot_run_issue` の EXIT trap（issue-watcher.sh:6863）で 1 件出力。fixture test-summary.sh case1/4
- 1.2 — `rs_set_mode` を MODE 確定 4 分岐（issue-watcher.sh:6991/6997/7129/7133）に配線。fixture case1/3
- 1.3 — `rs_set_issue "$NUMBER"`（issue-watcher.sh:6862）で `#<N>` 正規化記録。fixture 全 case の prefix
- 1.4 — EXIT trap は 1 サブシェル 1 回発火、`rs_emit` は単一行 echo。fixture case4（出力 1 行 assert）
- 1.5 — trap を worktree 初期化（issue-watcher.sh:6865）より前に設置。早期 return / set -e でも emit。fixture case4
- 2.1 — `rs_record_stage` を Stage A/A'/B/B'/C の実 claude 起動直後に配線（issue-watcher.sh:4776+/4897/5015/5113/5159/5203/5457）。fixture case1（stages=A,B,C）
- 2.2 — 未実行時は `stages=none` 既定（run-summary.sh:260）。fixture case4
- 2.3 — `rs_record_stage` の重複排除 + 実行順カンマ列挙、`A'`→`Ap`/`B'`→`Bp` 正規化（run-summary.sh:112-130）
- 3.1 — `run_reviewer_stage` 全 return に `rs_record_reviewer`（independent/degraded）配線（issue-watcher.sh:4151+/4168/4181/4184/4194）
- 3.2 — approve/reject verdict 記録（run-summary.sh:160-166）。fixture case1
- 3.3 — round 番号を `:r<n>` で記録（run-summary.sh:158）。fixture case1/2
- 3.4 — return 2（claude-exit-nonzero/parse-failed/unknown-result）を `degraded` 記録（run-summary.sh:167-169）。fixture case2
- 3.5 — design モードは reviewer 系を触れず既定 `reviewer=n/a` 維持。fixture case3
- 4.1 — `_SAV_LAST_OUTCOME`（stage-a-verify.sh:421+）を call site で `rs_record_sav`（issue-watcher.sh:5079）。fixture case1（success）
- 4.2 — disabled（stage-a-verify.sh:702）/ skip（:713,:733）を outcome 露出で区別
- 4.3 — round1/round2 を `_sav_handle_failure` 戻り値からマップ（stage-a-verify.sh:760-766/772-777）
- 5.1 — `_worktree_record_scaffolding` を `_worktree_inject_claude` の 4 return パスに配線（core_utils.sh:280+/302/307/316/325）。fixture case1（ok）
- 5.2 — 両 dir 不足時 `missing`（core_utils.sh:288-292）。fixture case2
- 5.3 — `$wt/.claude/{agents,rules}` 実体判定で既存 scaffolding 検査結果を流用（core_utils.sh:287）
- 6.1 — `rs_record_error` / `rs_scan_degraded_log` を各 stage 完了直後に累積実行。fixture case2
- 6.2 — degraded 兆候 SSoT 配列を grep し errors=yes（run-summary.sh:52-56/210-223）。fixture case2
- 6.3 — 兆候なし既定 `errors=no`（run-summary.sh:71）。fixture case1
- 7.1 — `rs_set_result` を hold/ready-for-review/needs-iteration/claude-failed の各終端に配線。fixture case1/2/3
- 7.2 — `mark_issue_failed`（issue-watcher.sh:4484）/ `_slot_mark_failed`（:5933）で `rs_set_result claude-failed`。fixture case2
- 8.1 — 固定 prefix `[ts] [$REPO] run-summary:`（run-summary.sh:267）。fixture 全 case
- 8.2 — key=value 固定順整形（run-summary.sh:267）
- 8.3 — 改行なし単一行 echo。fixture case4（1 行 assert）
- NFR 1.1/1.2 — 記録は変数代入のみ、既存ログ行・ラベル遷移・exit code 不変。sav_log フォーマット不変。shellcheck 4 ファイル clean
- NFR 1.3 — `RUN_SUMMARY_ENABLED=false` で `rs_emit` 即 return 0（run-summary.sh:249-251）。fixture case5
- NFR 2.1/2.2 — EXIT trap 1 回 / `rs_init` で毎サイクル初期化（追記のみ）
- NFR 3.1 — date/grep のみ、外部呼び出し追加なし
- NFR 4.1 — `rs_emit` fail-open + `trap 'rs_emit || true'` の二重吸収、`command -v` ガード（core_utils.sh:283）

## Boundary 確認

変更ファイルはすべて design.md「File Structure Plan / Modified Files / New Files」の範囲内:
run-summary.sh（新規）/ test-summary.sh（新規）/ core_utils.sh・stage-a-verify.sh・
issue-watcher.sh（Modified 明記）/ README.md（同一 PR 必須と design 明記）。`.shellcheckrc` は
verify ブロックの素 shellcheck を accepted info baseline（SC2317/SC2012）で通すための補助で、
severity を下げず warning/error は引き続き検出する。`.claude/` 配下は非変更。

> 補足: task 4 の `_Boundary:_` 表記は `run-summary.sh` のみだが、変更対象 `core_utils.sh` は
> design.md の File Structure Plan / Modified Files で本 scaffolding 配線用に明示指定されており、
> task 本文も `core_utils.sh` 改変を明記している。アノテーションの狭さであって設計範囲外への
> 逸脱ではないため boundary 逸脱に該当しない。

## Findings

なし

## Summary

merge-base 基準でブランチ固有差分を判定。全 numeric AC（Req 1〜8 / NFR 1〜4）に対応する
実装と fixture（test-summary.sh 17 assert 全 PASS）を確認し、`## Verify` 構造化ブロック
（shellcheck 4 ファイル + fixture）も exit 0 で green。AC 未カバー / missing test / boundary
逸脱のいずれも検出せず。

RESULT: approve
