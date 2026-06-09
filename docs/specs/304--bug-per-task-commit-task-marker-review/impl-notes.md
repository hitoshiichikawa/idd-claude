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

### Task 3

- **採用方針**: `pt_detect_post_marker_commits` 直後（2745 行付近）に
  `pt_handle_post_marker_commits <task_id> <round> <range_start> <marker_sha> <post_marker_list>`
  を追加。env `POST_MARKER_RECOVERY_MODE`（default=`fail-with-diagnostic`、不正値も default 化）で
  `extend-range` / `fail-with-diagnostic` に case 分岐し、algorithm body は fixture 参照実装
  line 139〜172 と byte 同期させた。env 宣言は `PER_TASK_LOOP_ENABLED` 直後（497〜506 行）に
  `POST_MARKER_RECOVERY_MODE="${POST_MARKER_RECOVERY_MODE:-fail-with-diagnostic}"` を 1〜2 行
  コメント付きで追加。
- **重要な判断**:
  - stderr ログは「NFR 2.1 メインイベントログ」と「warn ログ」を **書式分離** した。
    メインログは fixture line 158 と同じ `[YYYY-MM-DD HH:MM:SS] per-task:
    post-marker-commits-detected ...` 書式の単一行を直接 `echo` で出す（`pt_warn` の `WARN:`
    接頭辞を **付けない** 設計）。一方、不正 env 値検知 / `git rev-parse HEAD` 失敗等の
    abnormal 通知は `pt_warn`（`WARN:` 接頭辞付き）に置換した。Task 2 で確立した
    「algorithm body は byte 同期 / stderr 表面文字列は対応許容」precedent を踏襲しつつ、
    NFR 2.1 のメインイベントログは fixture と書式一致させる方針。
  - `fail-with-diagnostic` 分岐は `pt_mark_post_marker_commits_detected`（task 4 で追加）を
    呼ばず単に `return 5` で終わる設計とした。task 4 の関数追加後に `run_per_task_reviewer`
    経路（task 5）または本関数の改修で `mark` 呼び出しを補完する。fixture 参照実装も
    同じ設計（line 170〜171）であり前方参照を作らない。
  - `extend-range` 経路で `git rev-parse HEAD` が失敗した場合は `extend-range` を諦めて
    rc=5 を返す保守的設計とした（fixture line 162〜164 と同一）。HEAD が取れない状況での
    range 拡張は意味を持たないため、`fail-with-diagnostic` 相当の rc に倒すことで
    呼び出し側（task 5 で組み込む `run_per_task_reviewer`）の分岐を統一できる。
- **残存課題**: なし（task 4 で `pt_mark_post_marker_commits_detected` を追加する際、本関数の
  `fail-with-diagnostic` 分岐から呼び出す経路の組み込み判断が残る。design.md は
  `run_per_task_reviewer`（task 5）側で呼ぶ設計に倒しているが、task 4 完了後に task 5 で
  両者を接続するため、本関数自体は task 3 時点の signature / rc 体系で確定）。
