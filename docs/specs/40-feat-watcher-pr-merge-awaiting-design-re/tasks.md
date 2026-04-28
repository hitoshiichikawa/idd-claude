# Implementation Plan

実装は `local-watcher/bin/issue-watcher.sh` の中核変更を 1 commit で完結させ、
ドキュメント更新（README / PjM template）と検証を並列タスクとして分割します。

- [ ] 1. Design Review Release Processor の実装と組み込み
- [ ] 1.1 Config ブロックに新規 env var を追加
  - `DESIGN_REVIEW_RELEASE_ENABLED="${DESIGN_REVIEW_RELEASE_ENABLED:-false}"` を既存 `PR_ITERATION_*` 群の直後に追加
  - `DESIGN_REVIEW_RELEASE_MAX_ISSUES="${DESIGN_REVIEW_RELEASE_MAX_ISSUES:-10}"` を追加
  - `DESIGN_REVIEW_RELEASE_HEAD_PATTERN="${DESIGN_REVIEW_RELEASE_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"` を追加
  - `DRR_GH_TIMEOUT="${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"` を追加（既存 timeout を流用）
  - 既存 env var / 既存 LABEL_* 定数 / 既存依存ツール check は変更しない
  - _Requirements: 1.2, 5.1, 5.4, 7.1, 7.5_

- [ ] 1.2 ロガー関数 3 セットを追加
  - `drr_log()` / `drr_warn()` / `drr_error()` を `process_pr_iteration` 関数定義の直後（既存 `pi_*` 関数群の閉じ位置の後）に配置
  - 書式は `[$(date '+%F %T')] design-review-release: $*`（既存 mq_log と完全同形）
  - `drr_warn` / `drr_error` は `>&2` リダイレクト
  - 出力は既存 `LOG_DIR` 配下に流れる stdout/stderr のみ（新規 mkdir / 新規ディレクトリ作成なし）
  - _Requirements: 6.4, 6.5, 6.6, 6.7, NFR 3.1, NFR 3.2_

- [ ] 1.3 既処理判定 `drr_already_processed(issue_number)` を追加
  - `gh issue view "$issue_number" --repo "$REPO" --json comments` を `timeout "$DRR_GH_TIMEOUT"` でラップ
  - jq で `idd-claude:design-review-release issue=<issue_number>` regex を検出 → "true"/"false" を stdout
  - API エラー時は return 1（呼び出し元で WARN + skip）
  - _Requirements: 4.2, 4.3, 4.4, 5.3, 5.4, 5.5_

- [ ] 1.4 リンク済 設計 PR 検出 `drr_find_merged_design_pr(issue_number)` を追加
  - `gh pr list --repo "$REPO" --state merged --search "is:pr is:merged claude/issue-<N>-design- in:head" --json number,headRefName,body,mergedAt --limit 20` を `timeout "$DRR_GH_TIMEOUT"` でラップ
  - jq で `headRefName | test($DESIGN_REVIEW_RELEASE_HEAD_PATTERN)` + body に `(Refs|refs|Ref|ref) #<issue_number>` regex match を確認
  - 複数件マッチ時は最大番号 = 最新を採用、無ければ空文字を stdout
  - API エラー時は return 1
  - _Requirements: 2.2, 2.3, 2.4, 2.5, 2.6, 5.3, 5.4, 5.5, NFR 2.2_

- [ ] 1.5 ラベル除去 + コメント投稿 `drr_remove_label_and_comment(issue_number, merged_pr_number)` を追加
  - `timeout "$DRR_GH_TIMEOUT" gh issue edit <N> --remove-label "$LABEL_AWAITING_DESIGN"`（失敗時 WARN + return 1、コメント投稿は呼ばない）
  - 成功時のみ `timeout "$DRR_GH_TIMEOUT" gh issue comment <N> --body "<template>"` を呼ぶ
  - コメント本文末尾に hidden marker `<!-- idd-claude:design-review-release issue=<N> pr=<P> -->` を含める
  - 本文に「設計 PR #<P> が merged」「次回 cron tick で Developer が impl-resume モードで自動起動」を含める
  - PR 側操作・push・close は一切呼ばない（grep で `git push` / `git commit` / `git checkout` / `gh pr edit` / `gh pr comment` の不在を確認）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 5.3, 5.4, 5.5, 6.7, 7.6, NFR 2.1, NFR 2.3_

- [ ] 1.6 エントリ関数 `process_design_review_release()` を追加
  - 先頭で `[ "$DESIGN_REVIEW_RELEASE_ENABLED" != "true" ] && return 0`
  - `gh issue list --repo "$REPO" --state open --search 'label:"awaiting-design-review" -label:"claude-failed" -label:"needs-decisions"' --json number,title,url,labels --limit 100` を timeout でラップ
  - server-side filter で `label:"awaiting-design-review"` を必須にすることで、人間が先に手動除去した Issue は候補に上がらない（ラベル除去 API 呼び出し / コメント投稿は走らない）
  - jq で client-side fail-safe filter（label 配列に `awaiting-design-review` あり、`claude-failed`/`needs-decisions` なし）
  - `DESIGN_REVIEW_RELEASE_MAX_ISSUES` で先頭 N 件 truncate、超過は `overflow=N` でサマリに記録
  - per-Issue ループ内で `drr_already_processed` → `drr_find_merged_design_pr` → `drr_remove_label_and_comment` の順に呼ぶ
  - 各 Issue について `drr_log "Issue #<N>: merged-design-pr=#<P>, action=..."` を出力
  - サイクル開始ログ・サマリログ（`removed=N, kept=N, skip=N, fail=N, overflow=N`）を出力
  - _Requirements: 1.1, 1.4, 2.1, 2.7, 4.1, 4.4, 4.5, 5.2, 5.5, 6.1, 6.2, 6.3, 7.5_

- [ ] 1.7 既存 Processor 直列ブロック末尾に呼び出しを追加
  - `process_pr_iteration || pi_warn ...` 行（issue-watcher.sh:1105 直後）に `process_design_review_release || drr_warn "process_design_review_release が想定外のエラーで終了しました（後続 Issue 処理は継続）"` を追加
  - Issue 処理ループ（`gh issue list` で `auto-dev` を検索する箇所）の直前に位置することを確認
  - 既存 flock / git fetch / checkout main の前後関係は不変
  - _Requirements: 1.3, 1.5, 7.3, 7.4_

- [ ] 2. ドキュメント更新
- [ ] 2.1 PjM agent template に自動除去注記を追加 (P)
  - `repo-template/.claude/agents/project-manager.md` の design-review モード（行 30〜36 付近の Issue コメントテンプレート）に注記行を追加
  - 注記文: `_注: watcher で DESIGN_REVIEW_RELEASE_ENABLED=true を有効化している場合、設計 PR merge 後数分以内に Issue から awaiting-design-review が自動除去され、ステータスコメントが投稿されます。手動でのラベル除去は不要です。_`
  - 既存の手動除去案内行は残す（自動除去未有効化のユーザにも対応するため）
  - _Requirements: 8.4_
  - _Boundary: PjM Agent Template_

- [ ] 2.2 README に Design Review Release Processor セクションを追加 (P)
  - 既存「PR Iteration Processor」節の後（または Phase A 系セクションと並列の位置）に新規節を追加
  - 節構成: 機能概要 / 対象 Issue 判定 / 挙動表 / 環境変数表（3 変数）/ 既存手動運用との並存 / Migration Note
  - 環境変数表に `DESIGN_REVIEW_RELEASE_ENABLED` (`false`) / `DESIGN_REVIEW_RELEASE_MAX_ISSUES` (`10`) / `DESIGN_REVIEW_RELEASE_HEAD_PATTERN` (`^claude/issue-[0-9]+-design-`) の 3 行
  - Migration Note: 既存 env / ラベル / lock / exit code 不変、`ENABLED=false` で完全無影響、cron 登録文字列の書き換え不要
  - 既存「設計 PR ゲート（2 PR フロー）」節（行 1089 付近）の状態遷移を更新: 「人間が手動でラベルを外す」→「自動除去 or 手動除去」両対応
  - ラベル一覧表の `awaiting-design-review` 説明欄に「watcher が自動除去対象」を追記（必要なら）
  - _Requirements: 8.1, 8.2, 8.3, 8.5_
  - _Boundary: README_

- [ ] 3. 静的解析と手動スモークテスト
- [ ] 3.1 shellcheck と bash 構文 check
  - `shellcheck local-watcher/bin/issue-watcher.sh` 警告ゼロ（既存と同レベル）
  - `bash -n local-watcher/bin/issue-watcher.sh` 構文エラーなし
  - 結果を `impl-notes.md` に貼付
  - _Requirements: 7.1, 7.2, 7.3_

- [ ] 3.2 cron-like 最小 PATH での dry run スモークテスト + 性能確認
  - `env -i HOME=$HOME PATH=/usr/bin:/bin DESIGN_REVIEW_RELEASE_ENABLED=false REPO=owner/test REPO_DIR=/tmp/test-repo bash $HOME/bin/issue-watcher.sh` で本機能 skip + 既存挙動を確認（処理対象 Issue なしで正常終了 / `design-review-release:` プレフィックスのログが出ない）
  - `DESIGN_REVIEW_RELEASE_ENABLED=true` で同条件（候補 0 件想定）の dry run: サマリログが `removed=0, kept=0, skip=0, fail=0, overflow=0` で出ること
  - 候補 1〜3 件の通常ケース実測で wall clock を計測し、30 秒以内に完了することを確認
  - 候補 10 件の上限ケース（dogfood で再現可能なら）実測で wall clock を計測し、60 秒以内に完了することを確認
  - 既存 watcher cron 登録文字列が書き換え不要であることを確認
  - 結果を `impl-notes.md` に貼付
  - _Requirements: 1.1, 1.4, 7.4, 7.5, NFR 1.1, NFR 1.2_

- [ ]* 3.3 dogfooding E2E（任意・人間判断）
  - self-hosting repo (`hitoshiichikawa/idd-claude-watcher`) で `awaiting-design-review` 付き既存 Issue + merged 設計 PR がある状態で watcher を 1 サイクル回す
  - 期待: ラベル除去 + ステータスコメント投稿 + 次サイクルで skip
  - 実機検証は dogfood 運用の判断に委ねる（CI 必須化はしない）
  - _Requirements: 2.1, 2.4, 3.1, 3.2, 4.2, 6.2_
