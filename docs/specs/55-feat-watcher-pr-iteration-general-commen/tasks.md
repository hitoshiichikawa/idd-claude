# Implementation Plan

- [ ] 1. watcher 関数層: 一般コメント収集ロジックの再構成
- [ ] 1.1 `pi_read_last_run` ヘルパ関数を新設 (P)
  - PR body 文字列から `idd-claude:pr-iteration round=N last-run=ISO8601` の `last-run` 値を抽出して stdout に出力（複数 marker 検出時は末尾を採用、既存 `pi_read_round_counter` と整合）
  - regex / `grep -oE` / `sed` を使用、新規依存追加なし
  - marker 不在時は空文字列を出力（呼び出し元で初回 round 扱い）
  - **読み取り専用**であり、既存 marker 形式・キー名・更新タイミングには一切手を加えない（後方互換性）
  - _Requirements: 2.3, 2.4, 4.1_
  - _Boundary: pi_read_last_run_

- [ ] 1.2 一般コメントフィルタ関数 4 種を新設 (P)
  - `pi_general_filter_self`: jq `select((.body // "") | contains("idd-claude:") | not)` で marker ベース自己投稿除外（着手表明 marker `idd-claude:pr-iteration-processing round=N` を含むコメントを除外、`@claude` 文字列には依存しない）
  - `pi_general_filter_resolved`: jq `--arg last_run "$last_run"` で `last_run == "" or .created_at > $last_run` を満たすコメントのみ採用（境界は採用側に倒し `>` を採用、`last_run` 空文字なら全件採用 = 初回 round）
  - `pi_general_filter_event_style`: `(.user.type // "") != "Bot" and (.body // "") != ""` で system / 空 body コメント除外
  - `pi_general_truncate`: 件数が `${PI_GENERAL_MAX_COMMENTS:-50}` 以下なら no-op、超過時は `created_at` 昇順ソート後に末尾上限件数を採用（古い順 drop）
  - 各関数は stdin から JSON 配列を受け取り stdout に JSON 配列を返す（pure・副作用なし）
  - 着手表明 marker 文字列 `idd-claude:pr-iteration-processing round=N` の **書き込み側**は本タスクで触らない（後方互換性、既存 `pi_post_processing_marker` をそのまま温存）
  - _Requirements: 2.1, 2.2, 2.6, 2.7, 3.1, 3.4, 4.5, NFR 1.1_
  - _Boundary: pi_general_filter_self, pi_general_filter_resolved, pi_general_filter_event_style, pi_general_truncate_

- [ ] 1.3 `pi_collect_general_comments` オーケストレーション関数を新設し `pi_build_iteration_prompt` から呼び出す
  - 入力: `$1=pr_number`, `$2=pr_body`
  - GitHub API `/repos/${REPO}/issues/${pr_number}/comments` を `gh api` で取得（既存と同じ `PR_ITERATION_GIT_TIMEOUT` / fall-back 方式）
  - 取得失敗時は `[]` で degraded、WARN ログを残す
  - 取得成功時は射影 jq で `{id, user, body, url, created_at}` の配列を作成し、1.2 のフィルタを `self → resolved → event_style → truncate` の順で適用
  - 各段の前後で `length` を計測し、最終的に 1 行サマリ `pr-iteration: PR #N general comments: fetched=F, filtered_self=A, filtered_resolved=B, filtered_event=C, truncated=D, final=E` を出力（truncate 発動時は `pi_warn`、それ以外は `pi_log`）
  - `pi_build_iteration_prompt` の既存 jq 式（`select(... test("@claude") ...)`）を撤去し、本関数の戻り値を `general_comments_json` に代入
  - kind（design / impl）に依存する分岐を入れない（impl PR / design PR で共通呼び出し）
  - 既存 env var（`REPO`, `PR_ITERATION_GIT_TIMEOUT` 等）名前・既定値・意味を変更せず、新規 env var として `@claude` mention を opt-out で復活させる種類のものを追加しない（`PI_GENERAL_MAX_COMMENTS` は内部定数として導入、README には載せない）
  - ラベル遷移契約（`pi_finalize_labels` / `pi_finalize_labels_design` / `pi_escalate_to_failed`）には触れない（後方互換性）
  - サマリ 1 行ログ format（`pr-iteration: サマリ: ...`）と watcher 全体の exit code は不変
  - _Requirements: 1.1, 1.2, 1.5, 2.5, 3.2, 4.2, 4.3, 4.4, 4.6, 6.2, NFR 1.1, NFR 1.2, NFR 2.1, NFR 2.2_
  - _Boundary: pi_collect_general_comments, pi_build_iteration_prompt_
  - _Depends: 1.1, 1.2_

- [ ] 2. iteration prompt template の文言改稿
- [ ] 2.1 `iteration-prompt.tmpl`（impl 用）の一般コメント節を改稿 (P)
  - 見出し `## @claude mention 付き general コメント (JSON 配列)` を `## PR の一般コメント (Conversation タブ、JSON 配列)` に変更
  - スキーマ説明を `{ id, user, body, url, created_at }` に更新（`created_at` を新たに含める）
  - 説明文に「watcher が事前に自己投稿 / 過去 round 対応済み / system コメント / 大量時 truncate を除外しています」「精読し対応すべきと判断したものに修正 commit または返信を行ってください」「未提示分は次 round 以降または人間レビュワーに委ねられます」を含める
  - 「責務」5 番目の `@claude mention 付き general コメントへの返信は ...` を `general コメントへの返信は ...` に書き換え（mention 表記の特別扱いを削除）
  - placeholder `{{GENERAL_COMMENTS_JSON}}` の展開機構（行単独置換）は変更しない
  - _Requirements: 1.2, 1.3, 1.6, 3.3, 6.4_
  - _Boundary: iteration-prompt.tmpl_

- [ ] 2.2 `iteration-prompt-design.tmpl`（design 用）の一般コメント節を impl 版と同一規約で改稿 (P)
  - 2.1 と同じ見出し / 説明文 / スキーマ更新を適用
  - 「責務」6 番目 (`@claude mention 付き general コメントへの返信は ...`) を mention 表記なしの形に書き換え
  - design 用に固有の編集許容スコープ（`{{SPEC_DIR}}` 配下のみ）と返信先（同一 PR の一般コメント）規約は **温存**する（design PR の既存規約を維持）
  - _Requirements: 1.2, 1.4, 1.6, 3.3, 6.1, 6.3_
  - _Boundary: iteration-prompt-design.tmpl_

- [ ] 3. ドキュメント更新
- [ ] 3.1 README.md の PR Iteration Processor 節を改稿
  - 冒頭の (1) (4) と「`needs-iteration` ラベル」節の「付与契機」行から `@claude` mention 表記を削除
  - 「対象 PR の判定」の直前に **「対象コメント」サブ節**を新設し、(a) 行コメント = 既存どおり、(b) 一般コメント = mention 不要・watcher 自己投稿除外（marker ベース）・PR body の `last-run` TS より前に作成されたものを除外・GitHub system コメント除外・上限超過時は古い順に truncate を整理
  - Migration Note に「一般コメントフィルタの緩和」項目を追加し、env var / ラベル / cron / round marker / exit code を壊さない後方互換性を明記
  - 「設計 PR 拡張」節にも対象範囲が impl と同一規約である旨を 1 文で言及（kind による条件分岐なし）
  - ラベル `needs-iteration` / `ready-for-review` / `awaiting-design-review` / `claude-failed` / `needs-rebase` の名前・色・意味は不変であることを Migration Note に明示
  - _Requirements: 5.1, 5.2, 5.4, NFR 1.3, NFR 1.4_
  - _Boundary: README.md_

- [ ] 3.2 `repo-template/.claude/agents/project-manager.md` の設計 PR ガイダンスを改稿 (P)
  - 第 36 行の「`line コメント / @claude mention general コメント`」を「line コメント / mention 不要の一般コメント」に書き換え
  - Req 1 / 2 と整合する説明（自動除外対象 = watcher 自己投稿 / 過去 round 対応済み）を 1 文補足
  - _Requirements: 5.3, 5.5_
  - _Boundary: project-manager.md_

- [ ] 3.3 `repo-template/CLAUDE.md` を必要に応じて整合更新 (P)
  - 132〜136 行の「PR Iteration の責務境界」節に `@claude` 文言が含まれていないことを diff で確認
  - 必要なら「対象コメント」表現を README に揃えるための 1〜2 行の追記を行う（不要なら no-op）
  - 既存ラベル遷移契約・kind 判定規約の文言は変更しない
  - _Requirements: 5.5_
  - _Boundary: repo-template/CLAUDE.md_

- [ ] 4. 静的解析 + dogfood スモーク手順の整備
- [ ]* 4.1 手動スモーク手順を impl-notes.md に整理
  - `shellcheck local-watcher/bin/issue-watcher.sh` 警告ゼロ
  - `actionlint` は本変更で workflow を触らないため対象外
  - dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` が「処理対象の Issue なし」で正常終了
  - PR #53 等価 fixture: 当 repo に test PR を立て、mention なし general コメント 2 件 + `needs-iteration` を付与し、watcher 1 サイクル実行で当該コメントが prompt log（`$LOG_DIR/pr-iteration-impl-<n>-round<r>-*.log`）に含まれることを目視確認
  - 大量コメント fixture: 60 件投稿で truncate 発動 + WARN ログ 1 行（`fetched=60 ... truncated=10 (limit=50) final=50`）が出ることを確認
  - 設計 PR 経路（`PR_ITERATION_DESIGN_ENABLED=true`）でも同一 builder が呼ばれることをログで確認（kind=design / kind=impl 両方で `pi_collect_general_comments` のサマリ 1 行が出る）
  - 内部定数 `PI_GENERAL_MAX_COMMENTS`（既定 50）の存在を impl-notes.md に明記
  - _Requirements: NFR 3.1, NFR 3.2, NFR 3.3_
  - _Boundary: impl-notes.md_
