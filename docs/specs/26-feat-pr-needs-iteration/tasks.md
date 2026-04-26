# Implementation Plan

本 tasks.md は `design.md` と対になる実装分割です。各タスクは 1 commit で独立完了可能な粒度とし、
`_Requirements:_` は requirements.md の numeric ID（1.1, 2.3 など）を列挙します。

並列可能タスクには `(P)` と `_Boundary:_` を付けています。idd-claude は現状シングル Developer 運用ですが、
将来の並列化・レビュー観点の明確化のためにアノテーションを残します。

- [ ] 1. ラベル定義とインストーラの整備
- [ ] 1.1 `.github/scripts/idd-claude-labels.sh` と `repo-template/.github/scripts/idd-claude-labels.sh` の `LABELS` 配列に `needs-iteration` を追加 (P)
  - 色 `d4c5f9`（Phase A `needs-rebase` の黄系 `fbca04` と視覚的に区別する紫系パステル）
  - description: `PR レビューコメントの反復対応待ち（#26 PR Iteration Processor が処理）`
  - 既存エントリの順序・フォーマットを維持し、末尾に 1 行追記のみ
  - 冪等性（既存追加処理で再実行時スキップ）に変更は加えない
  - 2 ファイル間で完全に同期することを diff で確認
  - _Requirements: 6.5_
  - _Boundary: idd-claude-labels.sh (root and repo-template)_
- [ ] 1.2 `install.sh --local` で `iteration-prompt.tmpl` を `$HOME/bin/` にコピーする処理を追加 (P)
  - 既存の `triage-prompt.tmpl` コピー処理の直後に同パターンで追記
  - ファイルが無い状態で `install.sh` を実行しても既存挙動を壊さないよう、`cp` 前の存在確認を既存に合わせる
  - sudo 不要であることを再確認
  - _Requirements: 10.4_
  - _Boundary: install.sh_

- [ ] 2. `iteration-prompt.tmpl`（新規テンプレート）の作成
- [ ] 2.1 `local-watcher/bin/iteration-prompt.tmpl` を design.md の「Prompt テンプレート」節に従って作成
  - 変数プレースホルダ: `{{PR_NUMBER}}`, `{{PR_TITLE}}`, `{{PR_URL}}`, `{{HEAD_REF}}`, `{{BASE_REF}}`, `{{ROUND}}`, `{{MAX_ROUNDS}}`, `{{ISSUE_NUMBER}}`, `{{SPEC_DIR}}`, `{{LINE_COMMENTS_JSON}}`, `{{GENERAL_COMMENTS_JSON}}`, `{{PR_DIFF}}`, `{{REQUIREMENTS_MD}}`
  - 責務セクションで: 1:1 返信の原則 / git fetch + merge --ff-only の手順 / force push 禁止 / spec ファイル非書き換え / resolve 禁止を明記
  - line コメント返信 API（`POST /repos/{O}/{R}/pulls/{N}/comments/{CID}/replies`）と general 返信（`gh pr comment`）を具体的な call 例で記載
  - テンプレ冒頭コメントで用途・配置先（`~/bin/iteration-prompt.tmpl`）・依存を明記（triage-prompt.tmpl と同形式）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 4.1, 4.2, 4.3, 4.4, 4.5, 5.1, 5.2, 5.3, 5.4, 5.5_

- [ ] 3. `issue-watcher.sh` への PR Iteration Processor 実装
- [ ] 3.1 Config ブロックに PR Iteration 用 env var 群と新ラベル定数を追加
  - `PR_ITERATION_ENABLED`（デフォルト `false`）
  - `PR_ITERATION_DEV_MODEL`（デフォルト `claude-opus-4-7`）
  - `PR_ITERATION_MAX_TURNS`（デフォルト `60`）
  - `PR_ITERATION_MAX_PRS`（デフォルト `3`）
  - `PR_ITERATION_MAX_ROUNDS`（デフォルト `3`）
  - `PR_ITERATION_HEAD_PATTERN`（デフォルト `^claude/`）
  - `PR_ITERATION_GIT_TIMEOUT`（デフォルト `60`）
  - `LABEL_NEEDS_ITERATION="needs-iteration"` 定数
  - `ITERATION_TEMPLATE`（デフォルト `$HOME/bin/iteration-prompt.tmpl`）
  - 既存変数は一切触らない（git blame で確認可能な最小差分に抑える）
  - `PR_ITERATION_ENABLED=true` の場合のみ `[ -f "$ITERATION_TEMPLATE" ]` 存在チェックを有効化（false では template 未配置でも起動できる）
  - _Requirements: 2.3, 2.4, 2.5, 2.6_
- [ ] 3.2 ロガー（`pi_log` / `pi_warn` / `pi_error`）と PR 検出 / フィルタ関数を実装
  - `pi_log` / `pi_warn` / `pi_error`: Phase A の `mq_*` と同じパターン、prefix `pr-iteration:`
  - `pi_fetch_candidate_prs`: `gh pr list --search 'label:"needs-iteration" -label:"claude-failed" -label:"needs-rebase" -draft:true'` + `--json number,headRefName,baseRefName,isDraft,url,labels,headRepositoryOwner,body` + jq client filter（head pattern / fork / draft 再確認）
  - すべての `gh` 呼び出しを `timeout "$PR_ITERATION_GIT_TIMEOUT"` で wrap
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 8.4, 9.5_
- [ ] 3.3 iteration round counter とラベル遷移のヘルパー関数を実装
  - `pi_read_round_counter(pr_number)`: `gh pr view --json body` で body 取得 → hidden marker regex で round 抽出（無ければ 0）
  - `pi_post_processing_marker(pr_number, new_round)`: body を `gh pr edit --body` で更新（既存 marker 置換 or 末尾追記）+ 着手表明コメント 1 件投稿
  - `pi_finalize_labels(pr_number)`: `gh pr edit --remove-label needs-iteration --add-label ready-for-review`（1 コマンド原子的実行）
  - `pi_escalate_to_failed(pr_number, round, max_rounds)`: ラベル遷移（needs-iteration 除去 + claude-failed 付与）+ エスカレコメント投稿
  - 各関数は失敗時に `pi_warn` を出し、戻り値 0/1 で成功可否を呼び出し元に返す
  - _Requirements: 6.1, 6.2, 6.4, 7.1, 7.2, 7.3, 7.4_
- [ ] 3.4 `pi_run_iteration`（= iterate_pr_once）と `process_pr_iteration` の本体実装
  - `pi_run_iteration`: round 取得 → 上限判定 → 着手表明 → head branch checkout（サブシェル + `trap EXIT` で main 復帰）→ `pi_build_iteration_prompt` → `claude --print ... --max-turns ...` → 成功なら `pi_finalize_labels`、失敗なら `needs-iteration` 残存 + WARN ログ
  - `pi_build_iteration_prompt`: PR 基本情報 / diff / 最新 review の line コメント / `@claude` mention 付き general コメント / 関連 `requirements.md` を `iteration-prompt.tmpl` に sed 置換で注入（triage-prompt.tmpl と同形式）
  - `process_pr_iteration`: opt-in gate → dirty working tree チェック → 候補取得 → `PR_ITERATION_MAX_PRS` で先頭 N 件 truncate（overflow をサマリに集計）→ while ループで `pi_run_iteration` 呼び出し → サマリ行出力
  - `process_merge_queue || mq_warn ...` の**直後**に `process_pr_iteration || pi_warn ...` を追加（Phase A と同じ防御パターン）
  - サブシェル exit 時と呼び出し元の両方で `git checkout main` を保険実行
  - _Requirements: 1.6, 2.1, 2.2, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 6.3, 8.1, 8.2, 8.3, 8.5, 9.1, 9.2, 9.3, 9.4_
  - _Depends: 2.1, 3.1, 3.2, 3.3_

- [ ] 4. Developer サブエージェントのドキュメント拡充
- [ ] 4.1 `repo-template/.claude/agents/developer.md` に「PR iteration モード（#26）」節を追記 (P)
  - 入力（PR 番号 / line コメント / general コメント / diff / requirements.md）を列挙
  - 作業フロー（ff-only merge → 修正 → 返信 → exit 0）を手順化
  - 禁止事項（force push / spec 書き換え / resolve / main push）を箇条書き
  - **1:1 返信の原則**（論点 3 の決定）を強調し、まとめ返信が許可されない理由を明記
  - 既存節（impl / impl-resume ガイダンス）は変更しない
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 5.1, 5.2, 5.3, 5.4, 5.5_
  - _Boundary: developer.md_

- [ ] 5. README 更新（DoD ドキュメント）
- [ ] 5.1 README.md に「PR Iteration Processor (#26)」セクションを追加 (P)
  - Phase A セクションと同構造で配置（「Merge Queue Processor (Phase A)」の直後を推奨）
  - 概要・対象 PR 判定・挙動表（成功 / 失敗 / 上限到達 / skip）
  - 環境変数表（名称 / デフォルト / 推奨 / 用途）を `PR_ITERATION_*` 7 個分
  - ラベル一覧と状態遷移図に `needs-iteration` を追記（既存 `needs-rebase` の行に並列）
  - Phase A との住み分け: 対象 PR 集合が直交すること、`needs-rebase` 付き PR は本機能 skip、併存時は人間判断
  - Migration Note: `PR_ITERATION_ENABLED=false` デフォルトで既存挙動完全一致、`install.sh --local` 再実行で template 配置、ラベルスクリプト再実行で冪等追加、依存コマンド追加なし
  - `hidden marker によるリセット手順`（PR body から `idd-claude:pr-iteration round=N` 行を削除すれば round=0 に戻る）
  - watcher 再配置の案内（Phase A と同じ注意書きを参照する形で記述）
  - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_
  - _Boundary: README.md_

- [ ] 6. 自動検証（shellcheck / actionlint / 依存解決）
- [ ] 6.1 静的解析とスモークテスト
  - `shellcheck local-watcher/bin/issue-watcher.sh install.sh .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` 警告ゼロを目指す（環境により実行不可なら `bash -n` で syntax check にフォールバックし `impl-notes.md` に明記）
  - `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git timeout'` で cron-like PATH での依存解決を再確認
  - `PR_ITERATION_ENABLED=false` で `process_pr_iteration` 全パス skip を dry-run harness で確認（Phase A Test 1 と同形式）
  - `PR_ITERATION_ENABLED=true` で対象 PR 0 件の dry-run: サマリログが `success=0, fail=0, skip=0, escalated=0, overflow=0` で出ること
  - dirty working tree 検知で `pr-iteration: ERROR: dirty working tree` が出ること
  - 各 NFR（turn 上限・処理上限・timeout・force push 禁止・main push 禁止・dirty 中止・timestamp 書式・grep 用 prefix）を差分レビューで担保確認
  - 結果を `docs/specs/26-feat-pr-needs-iteration/impl-notes.md` に記録
  - _Requirements: 2.2, 2.3, 2.4, 2.6, 8.5, 9.1, 9.3, 9.5, NFR 1.1, NFR 1.2, NFR 1.3, NFR 2.1, NFR 2.2, NFR 2.3, NFR 3.1, NFR 3.2_

- [ ]* 7. E2E dogfooding（deferrable）
  - 本 repo 自身に対しテスト用 PR を立て `needs-iteration` を付与し、watcher 1 サイクルで: (a) hidden marker が PR body に付与される、(b) commit / push が head branch に積まれる、(c) 各 line コメントに返信が付く、(d) general `@claude` コメントに引用返信が付く、(e) ラベルが `needs-iteration` → `ready-for-review` に切り替わる、を観測する
  - 同一 PR で 2〜3 回目の iteration を実行し hidden marker の round カウンタ増加を確認
  - 4 回目で `claude-failed` 昇格とエスカレコメント投稿を観測
  - hidden marker 手動削除 + `claude-failed` 除去 + `needs-iteration` 再付与 → 次サイクルで round=0 から再開
  - `needs-iteration` + `needs-rebase` 併存 PR で本機能が skip、Phase A が rebase を試行することをログで確認
  - 観測結果を `impl-notes.md` に追記
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 7.1, 7.2, 7.3, 7.4, 8.1, 8.2, 8.3, 8.4_
