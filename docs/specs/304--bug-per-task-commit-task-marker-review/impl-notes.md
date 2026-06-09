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

### Task 4

- **採用方針**: `pt_mark_diff_range_resolve_failed`（3498 行〜）直後に
  `pt_mark_post_marker_commits_detected <task_id> <round> <marker_sha> <post_marker_list>`
  を追加。HTML marker `<!-- idd-claude:per-task-post-marker-commits-detected:#<issue>:<task> -->`
  による重複コメント抑制、`gh issue edit` で `LABEL_CLAIMED` / `LABEL_PICKED` 除去 +
  `LABEL_FAILED` 付与、復旧手順本文の組み立てまで既存 `pt_mark_diff_range_resolve_failed`
  と byte レベルで対応する構造に揃えた。
- **重要な判断**:
  - 復旧手順は「reflog で push 前 commit を確認 → marker refresh（`git reset --soft <marker^>`
    または `git rebase -i ${BASE_BRANCH}`）→ \`docs(tasks): mark ${task_id} as done\` が
    \`${BASE_BRANCH}..HEAD\` の最終 commit になっているかを `git log --oneline` で確認」
    という順序付きフローに固定した。design.md の `Components and Interfaces` ＞
    `pt_mark_post_marker_commits_detected` 記載の「reflog で push 前 commit 確認 → marker
    refresh 手順 → marker contract 再周知」を該当 subsection に過不足なくマップ。
  - 切替 env (`POST_MARKER_RECOVERY_MODE`) の説明を末尾に追加し、運用者が
    `fail-with-diagnostic`（default）/ `extend-range` の意味と推奨度（marker contract 違反を
    黙って吸収する extend-range は通常変更不要）を Issue コメント内で判断できる形にした。
    task 3 の env 命名 / 不正値の default 化と整合。
  - post-marker SHA リストは CSV と bullet 表記の **両方** を本文に含める設計とした。CSV
    は grep 用、bullet は人間レビュー用で、`pt_mark_diff_range_resolve_failed` よりも
    情報密度を上げる方向に振った（marker contract 違反のような構造的失敗では運用者の
    手動 rescue が重要になるため）。
  - 本 commit 時点では本関数の呼び出し側は task 5 で `run_per_task_reviewer` の rc=5 経路
    （または `pt_handle_post_marker_commits` 内）から組み込む予定。task 3 の
    `pt_handle_post_marker_commits` は `return 5` のみで本関数を呼ばない設計のため、
    現状コードベース上では unused-function 状態だが、これは task 3 ↔ task 4 ↔ task 5 の
    順序依存（design.md `_Depends:_`）に従う中間状態。shellcheck warning は出ない
    （関数定義は使われない状態でも警告対象外）。
- **残存課題**: なし（task 5 で `run_per_task_reviewer` から本関数または
  `pt_handle_post_marker_commits` 経由で本関数を呼ぶ経路を接続する責務が残る。本関数の
  signature / 副作用は task 4 時点で確定）。

### Task 5

- **採用方針**: `run_per_task_reviewer`（3350 行〜）の `pt_resolve_diff_range` 成功直後に
  post-marker safety net を挿入し、`pt_detect_post_marker_commits "$range_end"` の rc に
  応じて 3 分岐（rc=0 / rc=1 / rc=2）。検出時は `pt_handle_post_marker_commits` を呼び、
  さらに rc=0 (extend-range) / rc=5 (fail-with-diagnostic) で分岐する 2 段 dispatcher
  構造とした。fail-with-diagnostic と extend-range の失敗 fallback（HEAD 解決失敗 / 想定外
  rc）の両方で `pt_mark_post_marker_commits_detected` を呼んで claude-failed を付与し、
  `run_per_task_reviewer` 自身も rc=5 を返す。`run_per_task_loop` の round=1 / round=2
  / round=3 (Debugger 経由) 各経路に `5)` ケースを既存 `diff-range-resolve-failed` (rc=3)
  分岐と同じ位置に挿入。
- **重要な判断**:
  - **`pt_mark_post_marker_commits_detected` を呼ぶ場所の選択**: design.md は両方の選択肢
    （`pt_handle_post_marker_commits` 内 / `run_per_task_reviewer` 内）を許容している
    が、`run_per_task_reviewer` 側で呼ぶ方針を採用した。理由: (a) `pt_handle_post_marker_commits`
    は fixture 参照実装と algorithm body の byte 同期責務を保持しており、ここに mark
    呼び出しを追加すると fixture との差分が出る (task 3 impl-notes の precedent と整合)、
    (b) `run_per_task_reviewer` は marker_sha (= range_end) / post_marker_list を自前で
    保持しているため情報のプランビング上自然、(c) rc=3（`diff-range-resolve-failed`）の
    既存 pattern と異なり、本経路は marker / post_marker SHA を含めた詳細復旧手順を要する
    ため loop 側にデータを引き上げず本関数で完結させる方が plumbing が簡潔。
  - **loop 側の `5)` ケースは追加投稿しない**: `run_per_task_reviewer` 内で
    `pt_mark_post_marker_commits_detected` 済みのため、loop 側は stdout / log のみで停止
    （`return 1`）。`publish_terminal_failure_artifacts` を重ねて呼ばない設計で、Issue
    コメントの重複を防ぐ。rc=3 の `pt_mark_diff_range_resolve_failed` も loop 側で呼ぶ
    pattern だが、こちらは `run_per_task_reviewer` 内で mark 済みなので分岐構造が違う。
    loop 側のコメント欄で「`run_per_task_reviewer` 内で `pt_mark_post_marker_commits_detected`
    済み」を明示して将来の読者が pattern 差を把握できるようにした。
  - **fail-safe（NFR 1.3）の徹底**: rc=2（git エラー）/ rc=* (想定外 rc) は既存ルートで
    fall-through する（既存挙動温存）。rc=0 経路内で `pt_handle_post_marker_commits` が
    想定外 rc を返した場合（rc=0/5 以外）も `pt_mark_post_marker_commits_detected` を
    呼んで rc=5 に倒す（安全側）。extend-range で stdout が空（HEAD 解決失敗等）の場合も
    同様に fail-with-diagnostic 相当の停止に倒す。
  - **`extended` ローカル変数の扱い**: task 6 で `build_per_task_reviewer_prompt` に
    `extended` 引数を追加する責務のため、task 5 では `extended` を log 行に出すに留め、
    prompt builder には渡さない。task 6 完了時に `build_per_task_reviewer_prompt` 呼び出し
    位置で `"$extended"` を 6 番目の引数として渡すよう改修される予定。
  - **rc=5 ドキュメント**: `run_per_task_reviewer` の戻り値コメント節を更新し、rc=5 の
    意味（`post-marker commit を検出 + fail-with-diagnostic で停止`）と rc=3 との
    使い分け（rc=3 は marker 不在 / rc=5 は marker は見つかったが後続に未レビュー commit）
    を明示した。
- **残存課題**:
  - task 6（`build_per_task_reviewer_prompt` への `extended` 引数追加）で、`run_per_task_reviewer`
    内 `prompt=$(build_per_task_reviewer_prompt ...)` 呼び出しに 6 番目の引数として
    `"$extended"` を渡すよう改修する責務が残る。本 task 時点では `extended="false"`（normal
    経路）/ `extended="true"`（extend-range 経路）の値が正しく分岐済みだが、prompt builder
    側で消費する subsection 追加は task 6 の責務。
  - task 7 / 8（agent prompt docs 更新と repo-template ミラー反映）も別 task として残る。
  - rc=5 経路の E2E 観測は idd-claude self-hosting 上で marker contract 違反の test issue を
    立てて挙動確認することが推奨だが、本 task では smoke test の case-3 / case-4 で
    `pt_handle_post_marker_commits` 単体の rc / stdout を検証している。`run_per_task_reviewer`
    の rc=5 全経路を smoke で検証するには `gh` mock が必要で本 fixture のスコープ外。
