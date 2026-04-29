# Implementation Plan

- [ ] 1. Config + flag normalization（opt-in 受け口の構築）
- [ ] 1.1 `local-watcher/bin/issue-watcher.sh` の Config block に `IMPL_RESUME_PRESERVE_COMMITS` と `IMPL_RESUME_PROGRESS_TRACKING` の env 既定値（それぞれ `false` / `true`）を追加し、コメントで用途と既定値の根拠を明記
  - 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `MERGE_QUEUE_*` 等）を一切変更しない
  - cron / launchd 登録文字列を変えなくても既定 OFF で動くことを bash 構文レベルで保つ
  - _Requirements: 1.1, 1.4, 1.5, 3.6_
- [ ] 1.2 `_resume_normalize_flag` ヘルパ関数を新規追加（`preserve_default_off` / `tracking_default_on` の 2 モード対応）
  - whitelist 厳格比較（`true` 完全一致のみ true 化、それ以外は既定値）
  - 純粋関数として副作用なし、shellcheck クリーン
  - _Requirements: 1.3, 3.6_

- [ ] 2. Branch detection と branch 初期化戦略の実装
- [ ] 2.1 `_resume_detect_existing_branch` 関数を新規追加し、`git ls-remote --exit-code origin refs/heads/<branch>` で origin branch 存在を判定
  - ネットワーク失敗 / タイムアウト時は「不在扱い」+ `slot_warn` ログで fail-safe
  - `gh pr list` には依存しない（設計論点 1 の決定）
  - _Requirements: 2.1, 2.2_
- [ ] 2.2 `_resume_branch_init` 関数を新規追加し、既存 line 2944-2953 のシーケンスを内包したうえで Strategy 分岐を実装
  - PRESERVE=false（既定）: 既存 `git checkout -B BRANCH origin/main` + `git push -u origin --force-with-lease` を温存
  - PRESERVE=true + branch 存在: `git checkout -B BRANCH origin/BRANCH` + `_resume_push` 委譲
  - PRESERVE=true + branch 不在: `git checkout -B BRANCH origin/main` + `_resume_push` 委譲
  - 各分岐で `slot_log "resume-mode=<...>"` を発射（NFR 2.1）
  - 既存の `_worktree_reset` で行われる `git clean -fdx` を変更しない（untracked / 一時ファイルは保護対象外、AC 2.5）
  - 失敗時は既存 `_slot_mark_failed "branch-checkout"` パスに合流
  - _Requirements: 1.1, 1.2, 2.1, 2.2, 2.3, 2.5, 4.4, NFR 1.3, NFR 2.1_

- [ ] 3. fast-forward push と non-ff 安全停止
- [ ] 3.1 `_resume_push` 関数を新規追加し、force 系オプション無しの `git push -u origin <branch>` を実行
  - stderr を一時ファイルに捕捉し、`non-fast-forward` / `rejected` パターンを ERE で判定
  - non-ff 検出時は `_resume_mark_nonff_failed` を呼んで戻り値 1 を返す
  - リトライしない（AC 4.2）/ reset / rebase を行わない（AC 4.5）
  - _Requirements: 4.1, 4.2, 4.5_
- [ ] 3.2 `_resume_mark_nonff_failed` 関数を新規追加し、既存 `_slot_mark_failed` を薄く wrap して non-ff 専用 Issue コメントを投稿
  - コメント本文に「自動 force-push を抑制」「人間が衝突解消後に `claude-failed` を除去すれば再 pickup される」「対象 branch / Issue 番号」を含める
  - 既存 stage 識別子セット（`branch-checkout` / `branch-push` 等）に `branch-nonff` を追加
  - _Requirements: 4.2, 4.3, NFR 2.2_

- [ ] 4. Slot Runner と Developer prompt への組み込み
- [ ] 4.1 `_slot_run_issue` 内の line 2944-2953 を `_resume_branch_init` 1 行呼び出しに置き換え、`MODE` が `design` / `impl` の場合は既存挙動を完全温存（`if MODE = impl-resume then _resume_branch_init else 既存ブロック`）
  - `RESUME_PRESERVE` 変数を export し、後段の prompt builder が参照できるようにする
  - 既存の return 1 ハンドリングを維持（`_slot_mark_failed` が claude-failed 遷移）
  - _Requirements: 1.1, 1.2, 2.1, 2.2, NFR 1.1, NFR 1.2_
- [ ] 4.2 `build_dev_prompt_a "impl-resume"` の heredoc 末尾に resume 指示節と tasks.md 進捗追跡指示節を inline で追加
  - `RESUME_PRESERVE=true` 時のみ「既存 branch から resume 中・既存 commit を温存・未完了マーカー先頭から続行」を inline 追記
  - `IMPL_RESUME_PROGRESS_TRACKING` の値に応じて「`- [ ]` → `- [x]` に書き換えて `docs(tasks): mark <id> as done` で commit する」または「マーカー更新を行わない」を分岐記述
  - 既存 prompt の Step 1 / 制約節は変更しない
  - _Requirements: 2.4, 3.1, 3.2, 3.3, 3.4, 3.5_

- [ ] 5. Developer 行動規約への規約追記
- [ ] 5.1 `.claude/agents/developer.md` と `repo-template/.claude/agents/developer.md` に「impl-resume / tasks.md 進捗追跡規約」節を追記
  - tasks.md の `- [ ]` → `- [x]` 行内編集が許可される唯一の書き換え範囲であること
  - タスク本文 / `_Requirements:_` / `_Boundary:_` / `_Depends:_` / 順序を改変しない（AC 3.5）
  - 進捗 commit は `docs(tasks): mark <id> as done` で別 commit として積む
  - 全完了時は追加実装をせず impl-notes.md に記録
  - 設計論点 2 の決定（hidden marker は使わない）に整合
  - _Requirements: 3.3, 3.4, 3.5_

- [ ] 6. ドキュメント更新
- [ ] 6.1 `README.md` の Phase C / impl-resume 節に opt-in 手順 / 新挙動 / Migration Note を追記
  - opt-in 手順: cron / launchd で `IMPL_RESUME_PRESERVE_COMMITS=true` / `IMPL_RESUME_PROGRESS_TRACKING=false` を渡す方法
  - 新挙動の運用者視点記述: 既存 origin branch resume / tasks.md 進捗マーカー / force-push 抑制 + claude-failed 遷移
  - Migration Note: 「既定で従来挙動維持」「新規 branch は従来通り origin/main から初期化」「進行中 Issue は無影響」
  - 強制 fresh が必要な場合の手順（branch 手動削除 or `IMPL_RESUME_PRESERVE_COMMITS=false` に戻す）
  - _Requirements: 5.1, 5.2, 5.3_
- [ ] 6.2 `repo-template/CLAUDE.md` の impl-resume 関連記述（branch policy / 進捗追跡）に 1 段落追記し、consumer repo 配布時に opt-in 規約が伝わるようにする
  - _Requirements: 5.1, 5.2, 5.3_

- [ ] 7. 検証（静的解析 + dogfood E2E）
- [ ] 7.1 `shellcheck local-watcher/bin/issue-watcher.sh` で新規警告 0 件、`actionlint .github/workflows/*.yml`（workflow 変更が無いことの再確認）で新規警告 0 件を確認
  - cron-like 最小 PATH 起動 (`env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '$HOME/bin/issue-watcher.sh'`) でも `処理対象の Issue なし` で正常終了することを確認
  - `_resume_normalize_flag` を bash inline で 6 ケース（`true` / `false` / 空 / `True` / `1` / `yes`）テスト
  - 必要なら shellcheck disable コメントを最小範囲で追加
  - _Requirements: NFR 1.3, NFR 3.1, NFR 3.2_
- [ ] 7.2 dogfood シナリオ A（途中 commit 保護）を本リポジトリの test issue で実行し、`resume-mode=existing-branch` ログと既存 commit 保持を impl-notes.md に記録
  - _Requirements: 6.1_
- [ ] 7.3 dogfood シナリオ B（人間 commit + non-ff 検出）を本リポジトリで実行し、`resume-failure=non-ff` ログと `claude-failed` 遷移 + Issue コメント投稿を impl-notes.md に記録
  - _Requirements: 6.2_
- [ ] 7.4 dogfood シナリオ C（既定 OFF 等価性）を `IMPL_RESUME_PRESERVE_COMMITS=false` で実行し、`resume-mode=legacy-force-push` ログと既存 force-with-lease 経路の動作を impl-notes.md に記録
  - _Requirements: 1.1, 4.4, 6.3, NFR 1.1_

- [ ]* 7.5 追加スモーク: `IMPL_RESUME_PROGRESS_TRACKING=false` を渡したケースで Developer prompt の進捗追跡指示節が含まれないことを目視確認
  - 対応する受入基準のうち、現時点でログ単独カバレッジが薄い項目を補完
  - _Requirements: 3.2, 3.6_
