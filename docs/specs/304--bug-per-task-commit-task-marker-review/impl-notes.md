# Implementation Notes

per-task ループの 1 タスクごとの learning を記録する。

## Implementation Notes

### Task 1

- **採用方針**: 既存 #164 fixture (`test-pt-resolve.sh`) と同じ「参照実装を本 script 内に
  複製して assert を回す」形式で `test-post-marker-detect.sh` を新規作成。task 2〜4 で
  追加する `pt_detect_post_marker_commits` / `pt_handle_post_marker_commits` を本 script に
  先行ミラーすることで、watcher 本体実装と fixture を並行で書ける構造にした。
- **重要な判断**:
  - case-5 の「silent truncate を許容しない expectation（assert で fail にする）」は、
    (a) `pt_resolve_diff_range` の range_end が marker と一致すること（silent truncate の証拠）、
    (b) post-marker commit が `range_start..range_end` の外側にあること、(c) `pt_detect_post_marker_commits`
    hook で当該 commit を検出できること、の 3 段構成で assert した。将来 hook が外された場合
    (c) が fail し、本 test 全体が `SMOKE_RESULT: fail` で停止する。
  - case-3 では env 明示設定（fail-with-diagnostic）／env 未設定／env 不正値の 3 パターンで
    rc=5 になることを assert し、design.md 記載の「不正値も default 化」契約をテストでも
    担保した。
  - 参照実装の関数は task 2〜4 で `issue-watcher.sh` に追加する実装と byte 同期させる責務がある
    （ヘッダコメントで明示）。乖離した場合は本体側を fixture に再同期する原則（既存 #164
    fixture と同方針）。
- **残存課題**: なし（task 2 以降で `issue-watcher.sh` に参照実装と同じシグネチャ・rc 体系で
  関数を追加する際に、本 fixture の参照実装と byte 一致させる責務が残る）。

### Task 2

- **採用方針**: `pt_resolve_diff_range`（2638 行付近）直後に `pt_detect_post_marker_commits
  <marker_sha>` を追加し、`git log --format=%H <marker_sha>..HEAD` の結果で rc=0/1/2 を返す
  最小実装に集約。algorithm body は fixture 参照実装と byte 同期し、stderr の log prefix のみ
  既存 `pt_warn` を使うことで NFR 2.1 を満たす。
- **重要な判断**:
  - stderr 行の prefix は fixture 側 `[smoke] post-marker-commits-detect: ...` と本体側
    `[YYYY-MM-DD HH:MM:SS] per-task: WARN: post-marker-commits-detect: ...` で差を許容した。
    既存 #164 `test-pt-resolve.sh` ↔ `pt_resolve_diff_range` でも同じ差異が確立済みで、
    fixture は smoke コンテキスト識別のために `[smoke]` prefix を使う precedent と整合する
    （algorithm body のみ byte 同期、stderr 表面文字列は対応を許容）。
  - git エラー時は `pt_warn` で stderr に出して rc=2 を返し、呼び出し側（task 5 で
    `run_per_task_reviewer` に組み込む経路）が fail-safe で fall-through できるようにした
    （NFR 1.3 と同方針）。
- **残存課題**: なし（task 3 で `pt_handle_post_marker_commits`、task 4 で
  `pt_mark_post_marker_commits_detected` を追加する際に本関数の rc 体系を前提として呼び出す
  予定。本関数自体の API / log 書式は確定）。
