# Implementation Plan

> 本 tasks.md は `docs/specs/261-feat-pr-codex-antigravity/design.md` に従う実装単位を列挙する。
> 全タスクは bash モジュール `local-watcher/bin/modules/pr-reviewer.sh` 1 ファイル + 既存 3 ファイル
> （`issue-watcher.sh` / `core_utils.sh` / `README.md`）への追記で完結する。`(P)` 並列マークは
> 編集対象ファイルが分かれる箇所のみ付与し、`_Boundary:_` で衝突境界を明示する。

- [x] 1. core_utils.sh への logger 追加（pr_log / pr_warn / pr_error）
  - `local-watcher/bin/modules/core_utils.sh` の既存 `pi_log` / `drr_log` 群の末尾に、同形式
    （`[$(date '+%F %T')] [$REPO] pr-reviewer: ...`）で 3 関数を追加する
  - 既存関数・順序は変更しない（NFR 1.2）
  - `shellcheck` 警告ゼロ
  - _Requirements: NFR 1.2, NFR 2.1, NFR 3.1_

- [x] 2. pr-reviewer.sh モジュール骨格と opt-in gate の実装
- [x] 2.1 モジュールヘッダ / 入口関数 / opt-in 早期 return
  - 新規 `local-watcher/bin/modules/pr-reviewer.sh` を作成
  - ファイル冒頭コメントで「用途 / 配置先 / 依存 / セットアップ参照先」を既存モジュールと同形式で記述
  - `process_pr_reviewer()` を定義し、`[ "$PR_REVIEWER_ENABLED" != "true" ] && return 0` の早期 return
    （AC 1.1 の `=true` 厳密一致の正規化規則を踏襲）
  - サイクル開始の 1 行サマリログを `pr_log` で出力（解決済み tool / max_prs / timeout）
  - _Requirements: 1.1, 1.2, 1.3, NFR 1.1, NFR 3.1_

- [x] 2.2 tool 解決と排他検証 `pr_resolve_tool`
  - `PR_REVIEWER_TOOL` / `PR_REVIEWER_CODEX_ENABLED` / `PR_REVIEWER_ANTIGRAVITY_ENABLED` から
    Design Decision 1 の解決順序で `codex` / `antigravity` / `none` / `conflict` のいずれかを返す
  - 排他エラー / 両方無効化は `pr_log` / `pr_warn` で観測可能にする
  - _Requirements: 2.1, 2.2, 2.3, 2.5, NFR 3.1_

- [ ] 3. ツール健全性チェック（installed / authenticated）
- [x] 3.1 `pr_check_tool_installed` 実装
  - `command -v "$tool"` で PATH 上の実行ファイル存在を確認
  - 戻り値 0/1 を返す pure check
  - _Requirements: 3.1_

- [x] 3.2 `pr_check_tool_authenticated` 実装
  - `PR_REVIEWER_<TOOL>_AUTH_CMD` env を解決し、空文字なら skip（戻り値 2）
  - 非空ならコマンドを実行し、終了コード 0 で OK 判定
  - stdout/stderr は破棄（auth token 流出防止 / Security Considerations）
  - 既定値は実機ドキュメント整合: codex = `codex login status`、agy = `""`（既定 skip。
    Decision 3）
  - _Requirements: 3.2_

- [ ] 4. 重複防止 marker と候補 PR 列挙
- [ ] 4.1 `pr_build_marker` と `pr_already_processed` の実装
  - hidden HTML marker フォーマット `<!-- idd-claude:pr-reviewer sha=<oid> kind=<kind> tool=<tool> -->` を生成
  - `gh api /repos/$REPO/issues/<n>/comments` で marker 既存判定（`jq -e` でテスト）
  - 戻り値: 0 = 既存（skip）, 1 = 未存在（continue）
  - _Requirements: 3.3, 6.1, 6.2, 6.3, 6.4, NFR 4.1_

- [ ] 4.2 `pr_fetch_candidate_prs` の実装
  - `gh pr list --repo $REPO --state open --search "-draft:true" --json number,headRefName,headRefOid,baseRefName,isDraft,url,headRepositoryOwner --limit 50`
  - クライアント側 fail-safe filter: `select(.isDraft == false)` + head pattern (`PR_REVIEWER_HEAD_PATTERN`) +
    fork 除外（`headRepositoryOwner.login == $owner`、既存 `pi_fetch_candidate_prs` 踏襲）
  - `PR_REVIEWER_MAX_PRS` で先頭から truncate
  - 取得失敗 / timeout 時は `pr_warn` + 空配列を返す（NFR 3.1 の観測性）
  - _Requirements: 7.1, 7.2, 7.3_

- [ ] 5. レビュー prompt 解決とレビュー実行とコメント投稿
- [ ] 5.1 `pr_build_prompt_file` と `pr_substitute_placeholders` の実装
  - `pr_build_prompt_file`: `PR_REVIEWER_<TOOL>_PROMPT` → `PR_REVIEWER_PROMPT` → 内蔵 default の順で
    prompt 本体を解決し、`{BASE}` / `{HEAD}` / `{PR}` を文字列置換した結果を `mktemp -t
    idd-claude-pr-reviewer.XXXXXX` で得た一時ファイルに書き出し、stdout にそのパスを返す
  - `pr_substitute_placeholders`: cmd template の `{BASE}` / `{HEAD}` / `{PR}` / `{PROMPT_FILE}` を
    文字列置換
  - 置換結果に shell metacharacter（`;` `|` `&` `` ` `` `$(` 等）が混入していたら当該 PR を skip + WARN
  - 内蔵 default prompt は design.md 「Default Review Prompt」節の本文と byte 一致させる
  - _Requirements: 4.3_

- [ ] 5.2 `pr_execute_review_command` の実装
  - サブシェル + trap で BASE_BRANCH 復帰と prompt tempfile 削除を保証
  - `git fetch origin <head_ref>` → `git checkout -B <head_ref> origin/<head_ref>`
  - 解決済みコマンドを `PR_REVIEWER_EXEC_TIMEOUT` 秒の `timeout` で実行（`bash -c "$resolved_cmd"`
    で subshell に閉じ込め、**`eval` は使わない** — Decision 9）
  - stdout を変数キャプチャ。`agy --output-format json` の場合は `jq -r '.message // .'` 等で
    最終 message を抽出（実装時に `agy --help` 出力を確認して JSON schema を確定）
  - 実行直後に `git status --porcelain` 検査でワークツリー変更を検出した場合は
    `git checkout -- .` で破棄しつつ `kind=workspace-modified` のエラーコメントを投稿
    （read-only 安全性 invariant、Decision 8）
  - stderr は 1KB に truncate して呼び出し元へ渡す
  - 終了コードと stdout を分離して返す
  - _Requirements: 4.1, 4.2, 4.5_

- [ ] 5.3 `pr_post_review_comment` / `pr_post_error_comment` の実装
  - `pr_post_review_comment`: レビュー結果テキスト末尾に hidden marker `kind=review` を付与し
    `gh pr comment` で投稿
  - `pr_post_error_comment`: 本文冒頭に `## 自動レビューエラー` 見出し + `kind=<conflict-tool|not-installed|not-authenticated|exec-failed|workspace-modified>` の marker
  - 投稿失敗時は `pr_warn`（後続 processor 阻害なし）
  - _Requirements: 2.4, 3.1, 3.2, 3.4, 4.4, 6.1, 6.4_

- [ ] 6. 構造化 VERDICT 検出と needs-iteration ラベル付与
  - `pr_detect_iteration_keyword` を実装: `grep -E -i -c "$PR_REVIEWER_ITERATION_PATTERN"` で
    マッチ件数取得。既定 pattern は内蔵 prompt が最終行に出力する
    `^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$` を line-anchored で検出
    （Decision 4）。env override で旧来の自由文 grep にも切替可
  - マッチ件数とパターンを `pr_log` で記録（NFR 3.1）
  - マッチ件数 > 0 のとき `gh pr edit <n> --repo $REPO --add-label "$LABEL_NEEDS_ITERATION"`
    （`gh` 側で冪等のため再付与は no-op）
  - _Requirements: 5.1, 5.2, 5.3, 5.4_

- [ ] 7. issue-watcher.sh への配線（env / source / dispatcher）
  - **Config ブロック追記**: 既存「PR Iteration Processor 設定」節の **後** に「PR Reviewer Processor 設定 (#261)」節を追加し、design.md の Environment Variable Catalog にある env 群を `${VAR:-default}` で解決
    - `PR_REVIEWER_ENABLED` / `PR_REVIEWER_TOOL` / `PR_REVIEWER_CODEX_ENABLED` /
      `PR_REVIEWER_ANTIGRAVITY_ENABLED`
    - `PR_REVIEWER_CODEX_CMD`（既定: `codex exec --sandbox read-only "$(cat '{PROMPT_FILE}')"`）
    - `PR_REVIEWER_ANTIGRAVITY_CMD`（既定: `agy -p "$(cat '{PROMPT_FILE}')" --output-format json`）
    - `PR_REVIEWER_PROMPT`（既定: 内蔵 default。design.md 「Default Review Prompt」節）
    - `PR_REVIEWER_CODEX_AUTH_CMD`（既定: `codex login status`）
    - `PR_REVIEWER_ANTIGRAVITY_AUTH_CMD`（既定: `""`）
    - `PR_REVIEWER_ITERATION_PATTERN`（既定: 構造化 VERDICT token の line-anchored ERE）
    - `PR_REVIEWER_HEAD_PATTERN` / `PR_REVIEWER_MAX_PRS` / `PR_REVIEWER_GIT_TIMEOUT` /
      `PR_REVIEWER_EXEC_TIMEOUT`
  - **REQUIRED_MODULES 追記**: 既存配列に `"pr-reviewer.sh"` を追加（`"pr-iteration.sh"` の隣）
  - **dispatcher call site 追加**: `process_pr_iteration` 呼び出しの **直前**（既存 line 994〜995 付近）に
    `process_pr_reviewer || pr_warn "process_pr_reviewer が想定外のエラーで終了しました（後続 Issue 処理は継続）"` を 1 行追加
  - 既存 env / 既存 dispatcher 順序 / 既存 source 群を変更しないこと（NFR 1.1, 1.2）
  - _Requirements: 1.1, 1.2, 1.3, NFR 1.1, NFR 1.2_

- [ ] 8. README への追記（opt-in 機能一覧 + 詳細セクション）
  - 「オプション機能一覧 / opt-in（既定 OFF、明示的に有効化が必要）」表に 1 行追加
    （制御変数: `PR_REVIEWER_ENABLED` / 既定 `false` / 正規化規則 / 追加 env: `PR_REVIEWER_TOOL` 等 / 詳細リンク / 関連 #261）
  - 新規 h2 セクション「PR Reviewer Processor (#261)」を追加: 概要 / env 一覧表（既定値・正規化規則）/ tool 排他制御 / hidden marker / cron 例 / トラブルシュート FAQ
  - `repo-template/README.md` は存在しないため二重管理対応は不要（design.md File Structure Plan で明記）
  - _Requirements: 1.2, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 4.4, 4.5, 5.1, 5.2, 5.3, 5.4, 6.1, 6.2, 6.3, 6.4, 7.1, 7.2, 7.3, NFR 1.1_

- [ ] 9. 静的解析クリーン化と手動スモーク
  - `shellcheck` を新規 / 編集ファイルに実行し警告ゼロを確認（NFR 2.1）
  - `PR_REVIEWER_ENABLED=false`（既定）の dry-run で `process_pr_reviewer` が早期 return することを log 観察
  - `PR_REVIEWER_ENABLED=true` + ツール未インストールで `kind=not-installed` コメント 1 回投稿を確認
  - 2 サイクル連続実行で同一 SHA / 同一 kind のコメント重複が発生しないことを確認（NFR 4.1）
  - tool 排他エラー条件（`PR_REVIEWER_TOOL=codex` + `PR_REVIEWER_ANTIGRAVITY_ENABLED=true`）で `kind=conflict-tool` 投稿を確認
  - _Requirements: NFR 1.1, NFR 2.1, NFR 3.1, NFR 4.1_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下の構造化
ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/pr-reviewer.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh
```
