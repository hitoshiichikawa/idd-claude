# 実装ノート (#243 flock skip 経路 path-overlap 可視化)

## Implementation Notes

### Task 1

- **採用方針**: 可視化専用ロックファイルパス `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を `issue-watcher.sh` の config ブロックに env override 可能・既定無害値（`${LOG_DIR}/flock-skip-visibility.lock`）で 1 行追加した（design.md の canonical 書式準拠）。
- **重要な判断**:
  - 配置位置は `LOG_DIR` / `LOCK_FILE` 定義（370-371 行）の直後とした。design.md の指示（`PATH_OVERLAP_CHECK` 近傍 = 336 行付近、ただし `LOG_DIR` 定義 370 行より後ろ）のうち「LOG_DIR が参照できる位置」を最優先し、`${LOG_DIR}` を安全に参照できる LOG_DIR/LOCK_FILE 定義直後を選択した。
  - 既存 env var の名前・順序・書式は一切変更せず、新規行の追加のみ（後方互換 / Req 6.5 / NFR 1.1）。既定値は `PATH_OVERLAP_CHECK=off` 環境では未参照のため挙動に影響しない。
  - shellcheck はこの追加行で新規警告ゼロ。既存の SC2317（info / 間接呼び出し ERROR ロガーへの誤検知）11 件は変更前から存在し本変更とは無関係であることを `git stash` 比較で確認済み。
- **残存課題**: なし。本 config は task 2（`po_run_flock_skip_visibility` が `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を `exec 201>` で参照）の前提となる。task 2 以降の関数追加・フック挿入・テスト・README は未着手（本起動の対象外）。

### Task 2

- **採用方針**: `po_check_dispatch_gate` の overlap 判定コア（809-878 行）を `po__visibility_evaluate_candidate` として切り出し（評価規約を分岐させず同一の po_* 関数群を再利用）、その上に専用 flock + 候補列挙 + 候補ループの `po_run_flock_skip_visibility` を `promote-pipeline.sh` の `po_check_dispatch_gate` 直後へ追加した。
- **重要な判断**:
  - `po__visibility_evaluate_candidate` は `po_check_dispatch_gate` 本体と同一の関数・引数（`po_load_edit_paths` / `po_resolve_holder_labels "dispatch"` / `po_collect_inflight_issues` / `po_compute_overlap` / `po_apply_awaiting_slot` / `po_clear_awaiting_slot`）を用い、dispatch 固有の return（0=続行/1=skip）を捨てて戻り値を warn 判定用（0=完了/1=警告）に再定義した（Req 7.1 / 7.2）。ログには通常経路の `po_log` 書式に `route=flock-skip` 経路識別子を前置した（NFR 4.1 / 4.2）。
  - 候補列挙の除外句（`vis_search_filter`）は design.md の設計判断どおり `_dispatcher_run` の `local search_filter` を共有せず本関数内で自前再構築した。除外集合に処理中ラベル（`LABEL_CLAIMED` / `LABEL_PICKED`）を含めることで Req 2.4 を構造的に保証する。`flock -n 201` 取得失敗時は `route=flock-skip visibility skipped` 抑止ログを出し（Req 4.2）、全エラー経路で fd close + `return 0` の fail-open とした（NFR 3.2 / NFR 1.1）。
  - shellcheck はこの追加で新規警告ゼロ（`.shellcheckrc` 導入済みで baseline もクリーン）。`bash -n` 構文チェックも pass。
- **残存課題**: task 3（`issue-watcher.sh` の flock skip ブロック 578-582 行への `po_run_flock_skip_visibility || true` フック挿入）が本関数の唯一の呼び出し元として未着手。task 4（`test-flock-skip-visibility.sh` スモーク）/ task 5（README）も未着手。これらは別の fresh Implementer 起動で消化される。tasks.md の stage-a-verify ブロックは task 4 で作成される test スクリプトを参照するため、本起動の検証は shellcheck のみで実施した。
