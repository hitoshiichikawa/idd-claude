# Implementation Plan

- [x] 1. run-summary.sh モジュールの新規作成（状態コレクタ + emitter）
- [x] 1.1 `run-summary.sh` の骨格と logger / 状態変数初期化を実装
  - `local-watcher/bin/modules/run-summary.sh` を新規作成（ファイル冒頭コメントで用途 / 配置先 / 依存 / セットアップ参照先を明記）
  - `RUN_SUMMARY_*` サブシェルスコープ変数群と `rs_init`（既定値セット）を実装
  - `RUN_SUMMARY_ENABLED` を `"${RUN_SUMMARY_ENABLED:-true}"` で override 可能にする
  - _Requirements: 1.2, 1.3, NFR 1.3, NFR 2.2, NFR 3.1_
  - _Boundary: run-summary.sh_
- [x] 1.2 記録系 `rs_*` 関数（mode / issue / stage / scaffolding / reviewer / sav / error / result）を実装
  - `rs_set_mode` / `rs_set_issue` / `rs_record_stage`（重複排除・Ap/Bp 表記）/ `rs_set_scaffolding` / `rs_record_reviewer` / `rs_record_sav` / `rs_record_error` / `rs_set_result` を変数代入のみの副作用で実装（戻り値常に 0）
  - `rs_scan_degraded_log` を実装（`$LOG` を `grep -q` で走査し degraded 兆候パターンで errors=yes。パターン集合をモジュール内定数で SSoT 化）
  - _Requirements: 2.1, 2.2, 2.3, 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, 5.1, 5.2, 6.1, 6.2, 6.3, 7.1, 7.2, NFR 1.2, NFR 3.1_
  - _Boundary: run-summary.sh_
- [x] 1.3 `rs_emit`（終端 1 行整形 emitter）を実装
  - 固定 prefix `[ts] [$REPO] run-summary:` + key=value 固定順（issue mode stages reviewer stage-a-verify scaffolding errors result）で 1 行 echo
  - `RUN_SUMMARY_ENABLED=false` 時は即 return 0（無効化）。内部を `|| true` 相当で fail-open 化し exit code を変えない
  - _Requirements: 1.1, 1.4, 8.1, 8.2, 8.3, NFR 1.3, NFR 2.1, NFR 4.1_
  - _Boundary: run-summary.sh_

- [x] 2. 本体への source 追加と EXIT trap による終端 emit 配線
  - `issue-watcher.sh` 冒頭の modules source ブロックに `run-summary.sh` を追加（glob source なら不要を確認）
  - `_slot_run_issue` 冒頭（Issue メタデータ抽出直後）で `rs_init` → `rs_set_issue "$NUMBER"` → `trap 'rs_emit || true' EXIT` を仕込む
  - dispatcher の INT/TERM trap・既存サブシェル EXIT trap と非干渉であること（既存 EXIT trap 不在を grep 確認、存在時は chain）
  - _Requirements: 1.1, 1.3, 1.5, NFR 1.1, NFR 4.1_
  - _Boundary: run-summary.sh_

- [ ] 3. mode 確定箇所への `rs_set_mode` 記録差し込み
  - `_slot_run_issue` の MODE 確定箇所（impl-resume / skip-triage→impl / design / impl 各分岐）に `rs_set_mode` を 1 行ずつ差し込む
  - design モードでは Reviewer 非該当の既定 `reviewer=n/a` が維持されることを確認
  - _Requirements: 1.2, 3.5, NFR 1.2_
  - _Boundary: run-summary.sh_

- [ ] 4. scaffolding 検査結果の記録差し込み（core_utils.sh）
  - `_worktree_inject_claude` に、worktree の `.claude/agents` `.claude/rules` 有無判定結果を `rs_set_scaffolding ok|missing` で記録する 1 行を追加（既存 scaffolding 検査結果の流用 / Req 5.3）
  - fail-open（記録失敗で注入処理 / `_slot_run_issue` を倒さない）
  - _Requirements: 5.1, 5.2, 5.3, NFR 1.2, NFR 4.1_
  - _Boundary: run-summary.sh_
  - _Depends: 1.2_

- [ ] 5. stage 実行と stage-a-verify 結果の記録差し込み（run_impl_pipeline）
  - Stage A / A'(Ap) / B / B'(Bp) / C の各実行直後に `rs_record_stage` を差し込む
  - stage-a-verify call site の戻り値分岐（success / round1 / round2 / skip / disabled）に `rs_record_sav` を差し込む（`sav_log` 出力フォーマットは変更しない）
  - 各 stage 完了直後に `rs_scan_degraded_log "$LOG"` を呼び degraded 兆候を反映
  - _Requirements: 2.1, 2.2, 2.3, 4.1, 4.2, 4.3, 6.1, 6.2, 6.3, NFR 1.1, NFR 1.2_
  - _Boundary: run-summary.sh, stage-a-verify.sh_
  - _Depends: 1.2_

- [ ] 6. Reviewer 起動・verdict・round と最終遷移の記録差し込み
  - `run_reviewer_stage` の return 直前に `rs_record_reviewer`（return 0→independent:approve / 1→independent:reject / 2→degraded / 99→independent:quota、round 付き）を差し込む
  - `mark_issue_failed` / `_slot_mark_failed` に `rs_set_result claude-failed`、round=1 defer に `rs_set_result hold`、Stage C 成功に `rs_set_result ready-for-review`、Reviewer reject 終端に `rs_set_result needs-iteration` を差し込む
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 7.1, 7.2, NFR 1.1, NFR 1.2_
  - _Boundary: run-summary.sh_
  - _Depends: 1.2_

- [ ] 7. README 更新（grep 例 + オプション機能一覧）
  - 「複数リポ運用時の cron.log grep 例」節に `run-summary:` の grep 例とフォーマット enum 表を追加
  - 「オプション機能一覧」節に `RUN_SUMMARY_ENABLED`（既定 true / `=false` で無効化）を追加
  - 本機能が `.claude` 配下を変更せず root↔repo-template byte 一致規約の対象外であることを確認
  - _Requirements: 8.1, NFR 1.1, NFR 1.3_
  - _Boundary: run-summary.sh_

- [ ] 8. fixture スモークスクリプトの追加（stage-a-verify gate の必須再実行対象）
  - `docs/specs/239-feat-watcher-per-run-evidence-stage-gate/test-fixtures/test-summary.sh` を作成し、`run-summary.sh` を source して impl 正常 / degraded / design / 未初期化フェイルセーフ / 無効化の各ケースで `rs_emit` 出力 1 行を grep assert
  - 本タスクは非 deferrable（必須）。`## Verify` ブロックの stage-a-verify gate が `bash .../test-summary.sh` を Stage A で再実行するため、fixture が存在しないと gate が必ず失敗する。よって defer 不可（gate 依存のためタスク 8 を必須化）
  - _Requirements: 1.1, 1.4, 1.5, 3.4, 5.2, 6.2, 8.2, 8.3, NFR 1.3, NFR 4.1_
  - _Boundary: run-summary.sh_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/run-summary.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/modules/stage-a-verify.sh local-watcher/bin/issue-watcher.sh && bash docs/specs/239-feat-watcher-per-run-evidence-stage-gate/test-fixtures/test-summary.sh
```
