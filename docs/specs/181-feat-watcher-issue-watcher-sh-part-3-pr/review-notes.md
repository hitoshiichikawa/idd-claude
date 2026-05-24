# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T21:17:30Z -->

## Reviewed Scope

- Branch: claude/issue-181-impl-feat-watcher-issue-watcher-sh-part-3-pr
- HEAD commit: fd3b9dc7b9022e20c4fb201269a0715db9f129f3
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out 解釈。通常の 3 カテゴリ判定のみ実施（flag 観点の確認は行わない）

## Verified Requirements

- 1.1 — `process_pr_iteration` を main 本体と `modules/pr-iteration.sh` で diff し IDENTICAL（純粋 move）。`pi_max_rounds_kind_test.sh` repoint 後 green
- 1.2 — `pi_run_iteration` / `pi_resolve_max_rounds` 等 `pi_*` が byte-equal で pr-iteration.sh に存在。反復継続ロジック不変
- 1.3 — `pi_escalate_to_failed` / `pi_read_round_counter` / `pi_read_no_progress_streak` が byte-equal 移設。上限到達挙動不変
- 1.4 — pr-iteration.sh の全 `pi_*` + `build_recovery_hint` + `process_pr_iteration` が main と byte-equal（シグネチャ・本文不変）
- 2.1 — `po_check_dispatch_gate` を main 本体と `modules/promote-pipeline.sh` で diff し IDENTICAL。`po_apply_awaiting_slot` も一致移動（design decision 3: promote へ同居）
- 2.2 — `po_clear_awaiting_slot` 等 `po_*` 群が一致移動。dispatcher 内の `po_check_dispatch_gate` 呼び出し配線は entry point 6671 行に残置
- 2.3 — 全 `po_*`（13 関数）が byte-equal でシグネチャ不変
- 3.1 — `stage_a_verify_run` を main 本体と `modules/stage-a-verify.sh` で diff し IDENTICAL。Region 1/2 を 1 ファイルへ統合（source-before-execution で挙動不変）
- 3.2 — `_sav_handle_failure`（戻り値 1/2 のエスカレーション分岐）byte-equal。`stage_a_verify_run` 呼び出しは run_impl_pipeline 内 4435 行に残置
- 3.3 — `sav_*` / `_sav_*` / `stage_a_verify_*`（12 関数）全て byte-equal。`extract-driver.sh` を移動先へ repoint し全 fixture green
- 4.1 — `process_promote_pipeline` を main 本体と `modules/promote-pipeline.sh` で diff し IDENTICAL。`pp_*`（17 関数）一致移動
- 4.2 — dry-run スモーク（`PROMOTE_PIPELINE_ENABLED` 未設定）で promote 起動ログ出力なし。gate 判定据置。top-level 配線 `process_promote_pipeline ||`（661-662 行）entry point 残置
- 4.3 — 全 `pp_*` 関数が byte-equal でシグネチャ不変
- 5.1 — env var 定義（config ブロック）に変更差分なし。logger/ラベル定数据置
- 5.2 — orchestration 配線（`process_promote_pipeline ||` 661 / `process_pr_iteration ||` 937 / `po_check_dispatch_gate` 6671 / `stage_a_verify_run` 4435）すべて entry point に残り module に含まれない。スモークで loader 7 モジュール解決後に通常進行
- 5.3 — ログ出力先・書式・ラベル遷移・exit code 据置。`repo_prefix_log_test.sh` 含む全テスト緑で `[REPO]` prefix 維持（`pi_log` は core_utils.sh から解決、impl-notes 確認事項 2）
- 5.4 — 移動関数 68 個すべてが main 本体定義とバイト単位一致（exhaustive diff: mismatch=0 / missing=0）。機能追加・削除・バグ修正なし、純粋 move
- 5.5 — README にディレクトリ構成追記のみ。互換破壊なしのため migration note 不要は妥当
- 6.1 — `local-watcher/test/*.sh` 全 pass（reviewer 再実行: PASS=16 FAIL=0）
- 6.2 — `tests/local-watcher/*/*.sh`（extract-driver 含む）全 pass
- 6.3 — `pi_max_rounds_kind_test.sh` / `pi_detect_quota_soft_fail_test.sh` が `PR_ITERATION_SH`、`extract-driver.sh` が `_STAGE_A_VERIFY_SH` へ repoint し移動先から抽出解決
- 6.4 — repoint 後の抽出失敗時は `! [ -s ]` / `declare -F` チェックで exit 非0。成功扱いで隠さない
- 7.1 — `shellcheck -S warning local-watcher/bin/issue-watcher.sh` 警告ゼロ（reviewer 再実行確認）。info SC2317 は baseline 既存・新規増加なし
- 7.2 — `shellcheck -S warning` で promote-pipeline / pr-iteration / stage-a-verify 全モジュール警告ゼロ
- 8.1 — 本体 6747 行で 1,000 行未達だが、requirements.md AC 8.2 / design.md が「1,000 行以下は Part 1/2/3 累積前提依存」と明文化。Part 3 単独スコープでは未達が設計どおり。reject 対象外
- 8.2 — 本体 9969 → 6747 行。4 群（`pp_*` / `po_*` / `pi_*` / `sav_*` / `stage_a_verify_*` / `process_*`）の関数定義を本体から完全除去（grep で本体内定義 0 件確認）。REQUIRED_MODULES に 3 module を `.sh` 付きで追加（計 7 要素, 507 行）
- NFR 1.1 — 純粋 move による外部観測差分等価。68 関数バイト一致 + 全テスト緑 + dry-run スモーク（loader 7 module source → config → 起動ログ）正常到達
- NFR 1.2 — dogfooding 次サイクル完走は cron 環境に委ねる旨 impl-notes 記載（Part 3 単独で検証不能な領域）。bash -n / loader スモークで読み込み健全性確認
- NFR 2.1 / 2.2 — module loader（`BASH_SOURCE` 基準解決）は Part 1 所有。本 Part は `REQUIRED_MODULES` への 3 要素追加のみで loader 機構を変更せず

## Findings

なし

## Summary

純粋なモジュール分割リファクタリングとして全 numeric AC をカバー。移動した 68 関数すべてが
main 版とバイト単位一致（exhaustive diff で mismatch=0 / missing=0）であり、本体から 4 群の関数定義が
完全除去（grep 0 件）されている。orchestration 配線・env var・logger・exit code を据置、test repoint も
移動先を正しく指す。shellcheck（warning severity）全緑・全 16 テスト green を reviewer 自身が再確認した。
AC 8.1（1,000 行以下）未達は requirements.md / design.md が明記する Part 1/2/3 累積前提依存であり本 Part の責務外。
boundary 逸脱・missing test なし。

RESULT: approve
