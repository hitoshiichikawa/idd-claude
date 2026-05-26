# Implementation Plan

- [ ] 1. 可視化専用ロックの config を本体へ追加
- [x] 1.1 `issue-watcher.sh` に `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を定義
  - `LOG_DIR` 定義（370 行付近）より後ろに `PATH_OVERLAP_VISIBILITY_LOCK_FILE="${PATH_OVERLAP_VISIBILITY_LOCK_FILE:-${LOG_DIR}/flock-skip-visibility.lock}"` を追加
  - env override 可能・既定無害値（`PATH_OVERLAP_CHECK=off` 環境では未参照）であることをコメントで明記
  - 既存 env var 名・順序・書式を変更しない（後方互換）
  - _Requirements: 4.1, 6.5, NFR 1.1_
  - _Boundary: Config 追加（issue-watcher.sh）_

- [ ] 2. 可視化オーケストレータと内部ヘルパーを promote-pipeline.sh に追加
- [ ] 2.1 `po__visibility_evaluate_candidate` を追加（1 候補の read-only overlap 評価コア）
  - `po_check_dispatch_gate` 近傍（801-879 行付近）に追加。既存 po_* のシグネチャは変更しない
  - `po_load_edit_paths` → `po_collect_inflight_issues`（`po_resolve_holder_labels` で holder 集合解決）→ `po_compute_overlap` → overlap>0 かつ未付与なら `po_apply_awaiting_slot`、overlap=0 かつ既付与なら `po_clear_awaiting_slot`
  - 通常 dispatch 経路と同一の overlap 判定規約・出力形式を共有する（評価ロジックを分岐させない）
  - dispatch 制御の return（0=続行/1=skip）は持たず、戻り値は warn 判定用にのみ使う
  - _Requirements: 1.2, 1.3, 2.3, 3.1, 5.1, 5.2, 5.3, 7.1, 7.2, NFR 2.1, NFR 2.2, NFR 3.1, NFR 4.1_
  - _Boundary: po__visibility_evaluate_candidate_
- [ ] 2.2 `po_run_flock_skip_visibility` を追加（専用 flock + 候補列挙 + 候補ループ）
  - 冒頭で opt-in gate 二重防御（`[ "${PATH_OVERLAP_CHECK:-off}" = "true" ] || return 0`）
  - 別 fd（201）+ 別ファイル（`PATH_OVERLAP_VISIBILITY_LOCK_FILE`）で `flock -n` 非ブロッキング取得。取得失敗時は抑止ログ（`route=flock-skip visibility skipped`）を出し `return 0`
  - `cd "$REPO_DIR"`（po_* の cwd 前提を満たす最小初期化）。失敗時は warn + `return 0`
  - `gh issue list --label "$LABEL_TRIGGER" --state open` を read-only で実行し、通常 dispatcher と同等の除外句（`claude-claimed` / `claude-picked-up` / `claude-failed` 等）で処理中 Issue を候補から除外（Req 2.4）
  - 候補ごとに `po__visibility_evaluate_candidate` を呼ぶ。各候補失敗は warn して後続継続。終了時 fd close で flock 解放
  - 必ず `return 0`（NFR 3.2）。経路識別子 `route=flock-skip` を起動ログに含める（NFR 4.2）
  - claim / dispatch / worktree・slot・dispatch ロックを取得しない（Req 2.1 / 2.2）
  - _Requirements: 1.1, 2.1, 2.2, 2.3, 2.4, 4.1, 4.2, NFR 2.1, NFR 2.2, NFR 3.2, NFR 4.1, NFR 4.2_
  - _Boundary: po_run_flock_skip_visibility_
  - _Depends: 1.1, 2.1_

- [ ] 3. flock skip ブロックに可視化フックを挿入
- [ ] 3.1 `issue-watcher.sh` の flock skip ブロック（578-582 行）を修正
  - 既存スキップログ（`echo "...スキップ"`）は書式不変で残す（Req 6.5）
  - 既存ログ出力後 / `exit 0` 直前に `if [ "${PATH_OVERLAP_CHECK:-off}" = "true" ]; then po_run_flock_skip_visibility || true; fi` を挿入
  - フックは flock 失敗ブロック内にのみ置き、flock 成功時の通常 dispatch 経路には一切介入しない（Req 1.4 / NFR 1.2）
  - `exit 0` の値・意味は不変（NFR 1.1）
  - _Requirements: 1.1, 1.4, 6.1, 6.2, 6.5, NFR 1.1, NFR 1.2_
  - _Boundary: flock skip フック（issue-watcher.sh）_
  - _Depends: 2.2_

- [ ] 4. スモークテスト fixture/script を追加
- [ ] 4.1 `test-fixtures/test-flock-skip-visibility.sh` を作成
  - mock gh 環境で opt-in gate（off/未設定/不正値で gh を呼ばず return 0）を検証
  - 同一 lock file を保持する別プロセス下で `flock -n` 失敗 → 抑止ログ + return 0 を検証
  - 候補列挙クエリに `claude-claimed` / `claude-picked-up` 除外句が含まれることを検証（Req 2.4）
  - 候補列挙 mock 失敗時に return 0（fail-open / NFR 3.2）を検証
  - exit code / 出力が opt-in off で本機能導入前と差分等価であることを検証
  - _Requirements: 2.4, 4.1, 6.1, 6.2, NFR 1.1, NFR 3.2_
  - _Boundary: test-flock-skip-visibility.sh_
  - _Depends: 2.2, 3.1_

- [ ] 5. README を更新
- [ ] 5.1 Path Overlap Checker (Phase E) 節に flock skip 可視化を追記
  - flock skip 経路の可視化サブ節を追加（opt-in / 専用ロック多重起動抑止 / read+label/comment のみ / 経路識別子ログ）
  - 1801-1806 行付近の「別インスタンス稼働（flock skip）時の対象範囲」注記を本機能導入後の挙動へ更新
  - env var 表（1710 行付近）に `PATH_OVERLAP_VISIBILITY_LOCK_FILE`（既定 `$LOG_DIR/flock-skip-visibility.lock`）を追記
  - 後方互換（off 環境で no-op）と多重起動抑止ログ書式を Migration Note / 観測ログ節に追記
  - _Requirements: 4.2, 6.5, NFR 4.2_
  - _Boundary: README.md_
  - _Depends: 3.1_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/promote-pipeline.sh && bash docs/specs/243-feat-watcher-flock-dispatch-skip-path-ov/test-fixtures/test-flock-skip-visibility.sh
```
