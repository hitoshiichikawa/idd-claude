# 実装ノート (#243 flock skip 経路 path-overlap 可視化)

## Implementation Notes

### Task 1

- **採用方針**: 可視化専用ロックファイルパス `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を `issue-watcher.sh` の config ブロックに env override 可能・既定無害値（`${LOG_DIR}/flock-skip-visibility.lock`）で 1 行追加した（design.md の canonical 書式準拠）。
- **重要な判断**:
  - 配置位置は `LOG_DIR` / `LOCK_FILE` 定義（370-371 行）の直後とした。design.md の指示（`PATH_OVERLAP_CHECK` 近傍 = 336 行付近、ただし `LOG_DIR` 定義 370 行より後ろ）のうち「LOG_DIR が参照できる位置」を最優先し、`${LOG_DIR}` を安全に参照できる LOG_DIR/LOCK_FILE 定義直後を選択した。
  - 既存 env var の名前・順序・書式は一切変更せず、新規行の追加のみ（後方互換 / Req 6.5 / NFR 1.1）。既定値は `PATH_OVERLAP_CHECK=off` 環境では未参照のため挙動に影響しない。
  - shellcheck はこの追加行で新規警告ゼロ。既存の SC2317（info / 間接呼び出し ERROR ロガーへの誤検知）11 件は変更前から存在し本変更とは無関係であることを `git stash` 比較で確認済み。
- **残存課題**: なし。本 config は task 2（`po_run_flock_skip_visibility` が `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を `exec 201>` で参照）の前提となる。task 2 以降の関数追加・フック挿入・テスト・README は未着手（本起動の対象外）。
