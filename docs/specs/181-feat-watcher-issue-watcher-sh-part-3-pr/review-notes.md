# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T21:12:00Z -->

## Reviewed Scope

- Branch: claude/issue-181-impl-feat-watcher-issue-watcher-sh-part-3-pr
- HEAD commit: e2bfe44
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out 解釈。通常の 3 カテゴリ判定のみ実施（flag 観点の確認は行わない）

## Verified Requirements

- 1.1 — `process_pr_iteration` が `modules/pr-iteration.sh` に move（main 版と byte-equal, 134 行）。`pi_max_rounds_kind_test.sh` repoint 後 green
- 1.2 — `pi_run_iteration`（350 行）/ `pi_resolve_max_rounds`（36 行）が byte-equal で pr-iteration.sh に存在。反復継続ロジック不変
- 1.3 — `pi_read_round_counter` / `pi_read_no_progress_streak` repoint テストが green。上限到達挙動の関数群を byte-equal で移設
- 1.4 — pr-iteration.sh の全 `pi_*` 関数定義（28 関数）が main と byte-equal（シグネチャ・本文不変）
- 2.1/2.2 — `po_*`（13 関数）が `modules/promote-pipeline.sh` に同居移設（design decision 3）、全て byte-equal。`po_check_dispatch_gate` の呼び出し配線は entry point 6671 行に残置
- 2.3 — 全 `po_*` 関数が byte-equal（シグネチャ不変）
- 3.1 — `stage_a_verify_run`（57 行）が `modules/stage-a-verify.sh` に move（byte-equal）。Region 1/2 を 1 ファイルへ統合（source-before-execution で挙動不変）
- 3.2 — `_sav_handle_failure`（44 行, 戻り値 1/2 のエスカレーション分岐）byte-equal。`stage_a_verify_run` 呼び出し配線は run_impl_pipeline 内 4435 行に残置
- 3.3 — `sav_*` / `stage_a_verify_*`（12 関数）全て byte-equal。`extract-driver.sh` を移動先へ repoint し全 fixture green
- 4.1 — `pp_*`（17 関数）/ `process_promote_pipeline`（61 行）が promote-pipeline.sh に move、全て byte-equal
- 4.2 — `PROMOTE_PIPELINE_ENABLED="${PROMOTE_PIPELINE_ENABLED:-false}"`（entry point 112 行）据置。`process_promote_pipeline || pp_warn`（661 行）の orchestration 配線も entry point に残置。dry-run スモークで未設定時に promote 起動ログ無し
- 4.3 — 全 `pp_*` 関数が byte-equal（シグネチャ不変）
- 5.1 — `PROMOTE_PIPELINE_ENABLED` / `PR_ITERATION_ENABLED` / `STAGE_A_VERIFY_ENABLED` 等の env var 定義が entry point に同一デフォルトで残置
- 5.2 — top-level orchestration 配線（`process_promote_pipeline ||` 661 行 / `process_pr_iteration ||` 937 行 / `po_check_dispatch_gate` 6671 行 / `stage_a_verify_run` 4435 行）が entry point に残り module に含まれない
- 5.3 — logger（`sav_log` 等）・ラベル定数・exit code を変更せず move。`repo_prefix_log_test.sh` は不変（`pi_log` は core_utils.sh から解決, impl-notes 確認事項 2）で green
- 5.4 — 移動した 68 関数すべてが main と byte-equal（機能追加・削除・バグ修正なし、純粋 move）。entry point の関数定義数 161→93（差 68 = 移動数と一致, orphan/新規定義なし）
- 5.5 — 互換破壊なしのため migration note 追記不要（妥当）
- 6.1/6.2 — `local-watcher/test/*.sh` + `tests/local-watcher/*/*.sh` = 全 16 件 exit 0（reviewer 自身が再実行確認）
- 6.3 — pi 系 2 テスト（→ `PR_ITERATION_SH`）/ extract-driver（→ `_STAGE_A_VERIFY_SH`）の抽出元を移動先 module へ repoint 済み、抽出解決して green
- 6.4 — extract-driver / extract_function は抽出失敗時に空出力→関数未定義→exit 非0 のガードを維持（repoint 漏れがあれば失敗で観測可能）
- 7.1/7.2 — `shellcheck -S warning issue-watcher.sh modules/*.sh` exit 0（reviewer 再実行確認）。info レベル SC2317/SC2012 は baseline 既存・新規増加なし（CLAUDE.md「警告ゼロを目指す」を warning severity で達成）
- 8.2 — Part 3 が切り出す 4 群の関数定義を entry point から完全除去（残置 0 件確認）。REQUIRED_MODULES に 3 module を `.sh` 付きで追加（計 7 要素, 507 行）
- 8.1 — 本体 6747 行で 1,000 行未達だが、requirements.md AC 8.2 / design.md が「1,000 行以下は Part 1/2/3 累積完了を前提依存」と明文化しており、Part 3 単独スコープでは未達が設計どおり。本 Part の責務（4 群除去 = AC 8.2）は充足。reject 対象外
- NFR 1.1 — 純粋 move による外部観測差分等価。dry-run スモークで module loader（7 module source）・config 解決・起動ログまで正常到達
- NFR 1.2 — dogfooding 次サイクルでの完走は cron 環境に委ねる旨を impl-notes に記載（Part 3 単独で検証不能な領域）
- NFR 2.1/2.2 — module loader（`BASH_SOURCE` 基準解決）は Part 1 所有。本 Part はマニフェスト要素追加のみで loader 機構を変更せず

## Findings

なし

## Summary

純粋なモジュール分割リファクタリングとして全 numeric AC をカバー。移動した 68 関数すべてが
main 版と byte-equal（差分等価）であり、entry point の関数定義数の減少（161→93, 差 68）が移動数と
完全一致し orphan/新規定義なし。orchestration 配線・env var・logger・exit code を据置、test repoint も
正しく、shellcheck warning ゼロ・全 16 テスト green を reviewer 自身が再確認した。AC 8.1（1,000 行以下）
未達は requirements.md / design.md が明記する Part 1/2/3 累積前提依存であり Part 3 単独スコープ外。
boundary 逸脱・missing test なし。

RESULT: approve
