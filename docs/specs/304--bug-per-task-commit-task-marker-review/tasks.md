# Implementation Plan

- [x] 1. 回帰テスト fixture の追加（idd-codex #14 同型 commit shape）
  - `docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/test-post-marker-detect.sh`
    を新規作成し、以下 5 ケースを assert で検証する
    - case-1: marker 後に commit 無し → 検出 0 件で既存挙動温存
    - case-2: marker + 修正 commit 2 件（idd-codex #14 同型）→ 検出 2 件
    - case-3: `POST_MARKER_RECOVERY_MODE=fail-with-diagnostic` で rc=5（abort）
    - case-4: `POST_MARKER_RECOVERY_MODE=extend-range` で rc=0 + 新 range pair
    - case-5: silent truncate を許容しない expectation（assert で fail にする）
  - `docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/README.md` を新規作成し、
    fixture の用途・実行手順・対応 requirement を記載
  - `set -euo pipefail` / `mktemp` / EXIT trap で一時 git repo を作成・cleanup
  - 既存 `docs/specs/164-bug-watcher-per-task-reviewer-task-id-ma/test-pt-resolve.sh` と同様、
    参照実装の関数を本 script に複製して assertion を回す形式（issue-watcher.sh 側関数追加と
    並行可能にするため fixture 側は先に書ける）
  - 末尾で `SMOKE_RESULT: pass` / `fail` を出力
  - _Requirements: 5.1, 5.2, 5.3_

- [x] 2. watcher への post-marker 検出関数の追加（`pt_detect_post_marker_commits`）
  - `local-watcher/bin/issue-watcher.sh` の `pt_resolve_diff_range`（2638 行付近）直後に
    新規関数 `pt_detect_post_marker_commits <marker_sha>` を追加
  - `git log --format=%H <marker_sha>..HEAD` で post-marker commit を列挙
  - rc=0 (1 件以上) / rc=1 (0 件) / rc=2 (git エラー) の 3 値を返す
  - 既存 `pt_log` / `pt_warn` 書式と整合する stderr ログ規約（NFR 2.1）
  - shellcheck 警告ゼロ
  - 単体動作確認: `test-post-marker-detect.sh` の case-1, case-2 が pass
  - _Requirements: 2.1, NFR 1.3, NFR 2.1_

- [x] 3. watcher への recovery dispatcher の追加（`pt_handle_post_marker_commits`）
  - `local-watcher/bin/issue-watcher.sh` の `pt_detect_post_marker_commits` 直後に
    `pt_handle_post_marker_commits <task_id> <round> <range_start> <marker_sha> <post_marker_list>` を追加
  - env `POST_MARKER_RECOVERY_MODE` を読み（default=`fail-with-diagnostic`、不正値も default 化）、
    `extend-range` / `fail-with-diagnostic` に応じて分岐
  - `extend-range`: stdout に新 `<range_start>\t<HEAD_SHA>` を出力、rc=0
  - `fail-with-diagnostic`: 後続タスクで追加する `pt_mark_post_marker_commits_detected` を呼び rc=5
  - 既存 env var 宣言領域（`PER_TASK_LOOP_ENABLED` 近傍 / 494 行付近）に
    `POST_MARKER_RECOVERY_MODE="${POST_MARKER_RECOVERY_MODE:-fail-with-diagnostic}"` を追加
  - NFR 2.1 準拠の単一行 stderr ログを必ず出力
  - 単体動作確認: `test-post-marker-detect.sh` の case-3, case-4 が pass
  - _Requirements: 2.2, 2.3, 3.3, NFR 1.1, NFR 2.1_
  - _Depends: 2_

- [x] 4. 失敗カテゴリ通知関数の追加（`pt_mark_post_marker_commits_detected`）
  - `local-watcher/bin/issue-watcher.sh` の `pt_mark_diff_range_resolve_failed`（3374 行付近）と
    同セクション末尾に新規関数 `pt_mark_post_marker_commits_detected <task_id> <round> <marker_sha> <post_marker_list>` を追加
  - HTML marker `<!-- idd-claude:per-task-post-marker-commits-detected:#<issue>:<task> -->` で
    重複コメント抑制（既存 `pt_mark_diff_range_resolve_failed` と同パターン）
  - 復旧手順本文に以下を含める:
    - 失敗カテゴリ / task ID / round / marker SHA / post-marker SHA リスト / ログパス
    - `git reflog` で push 前 commit 確認 → marker refresh 手順
    - marker contract（marker は終端 commit / retry 時 refresh）の再周知
  - ラベル付け替え: `LABEL_CLAIMED` / `LABEL_PICKED` 除去 + `LABEL_FAILED` 付与
  - shellcheck 警告ゼロ
  - _Requirements: 2.3, NFR 2.1_
  - _Depends: 3_

- [x] 5. `run_per_task_reviewer` への post-marker hook 組込みと rc=5 対応
  - `run_per_task_reviewer`（3226 行付近）内、`pt_resolve_diff_range` 成功直後に
    `pt_detect_post_marker_commits "$range_end"` を呼ぶ
  - 検出 0 件（rc=1）または git エラー（rc=2）: 既存ルートで Reviewer 起動（NFR 1.3 fail-safe）
  - 検出 1 件以上（rc=0）: `pt_handle_post_marker_commits` を呼び、rc に応じて分岐
    - rc=0 (extend-range): 新 range で `build_per_task_reviewer_prompt` を `extended=true` で呼ぶ
    - rc=5 (fail-with-diagnostic): `run_per_task_reviewer` 自身も rc=5 を返す
  - `run_per_task_loop`（3558 行以降）の round=1 / round=2 / round=3 各経路で rc=5 を捕捉し、
    `per-task-post-marker-commits-detected` カテゴリの claude-failed として停止（既存
    `diff-range-resolve-failed` 分岐と同じ位置に挿入）
  - 既存 rc=0/1/2/3/4/99 の意味は変更しない（NFR 1.1）
  - 単体動作確認: 既存 `test-pt-resolve.sh` が引き続き pass（NFR 1.1 non-regression）
  - _Requirements: 2.1, 2.2, 2.3, NFR 1.1, NFR 1.3_
  - _Depends: 4_

- [x] 6. Reviewer prompt への range 明示と extended フラグ対応
  - `build_per_task_reviewer_prompt`（3060 行付近）の signature に第 6 引数 `extended`
    （"true"/"false"、省略時 "false"）を追加
  - prompt 本文に `## 判定対象 SHA range（machine-parseable）` subsection を追加し、
    `range_start_sha:` / `range_end_sha:` / `range_extended:` を機械パース可能な形で列挙
  - 既存「reviewer は **本 range のみ** を判定対象としてください」記述の直後に
    range 外 commit が判定対象外である旨の **Warning** を追加（Req 3.2）
  - `extended=true` の場合、watcher が marker 後の post-marker commit を検出したため
    HEAD ベースに range を拡張した旨を明示（Req 3.3）
  - 呼び出し側（既存 `run_per_task_reviewer` 内 normal 経路）は省略 / `false` を渡す形で
    後方互換維持
  - _Requirements: 3.1, 3.2, 3.3_
  - _Depends: 5_

- [x] 7. developer.md / reviewer.md への marker contract 節と range 警告追記（root 系統）
  - `.claude/agents/developer.md` の「per-task ループ下での Implementer の責務」節（369 行以降）
    に新 subsection `## Marker contract（marker は task の終端 commit）` を追加
    - 1.1: marker は task 終端 commit である契約
    - 1.2: retry 時に旧 marker 後ろに修正を残さない契約
    - 推奨 refresh 手順: 旧 marker 特定 → 修正 commit → `git reset --soft <marker^>` で剥がし
      新 marker 作成 → push
    - 禁止例: 旧 marker をそのままに修正 commit を marker 後ろに積む
  - `.claude/agents/reviewer.md` の「判定対象 diff range の限定」 subsection（283 行以降）に
    range 外 commit の判定対象外性（Req 3.2）と `range_extended: true` シグナルの解釈
    （Req 3.3）を追記
  - _Requirements: 1.1, 1.2, 1.3, 3.2, 3.3_

- [ ] 8. developer.md / reviewer.md の repo-template ミラー反映（byte 一致）
  - タスク 7 で root 系統に加えた変更を、`repo-template/.claude/agents/developer.md` /
    `repo-template/.claude/agents/reviewer.md` に **byte 一致** で適用する
  - 反映後に `diff -r .claude/agents repo-template/.claude/agents` が空であることを確認
  - rules 側（`.claude/rules/` / `repo-template/.claude/rules/`）の変更は本 Issue では行わない
    （`diff -r .claude/rules repo-template/.claude/rules` は変更前後で同じ状態を維持）
  - _Requirements: 4.1, 4.2_
  - _Depends: 7_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下の
構造化ブロックで宣言する。bash モジュール変更を含むため shellcheck、agent ファイルの
二重管理整合性のため diff、idd-codex #14 同型 commit shape の回帰のため fixture スモークを
連結実行する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules && \
  bash docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/test-post-marker-detect.sh && \
  bash docs/specs/164-bug-watcher-per-task-reviewer-task-id-ma/test-pt-resolve.sh
```
