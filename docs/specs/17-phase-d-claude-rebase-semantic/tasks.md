# Implementation Plan

> 設計参照: [`design.md`](./design.md)
> 要件参照: [`requirements.md`](./requirements.md)
>
> 実装順序の原則: Config / logger / 候補抽出（1.x）→ rebase 試行（2.x）→ 分類 + 後処理（3.x）
> → orchestration 配線（4.x）→ template 配置（5.x）→ ドキュメント（6.x）→ dogfood（7.x）
> 各タスクは 1 commit 単位を目安。`(P)` を付けたタスクは `_Boundary:_` の異なる別ファイル
> 領域に閉じるため並列実装可能。同一関数本体や同一ファイルの隣接編集は直列とする。

## 1. Phase D 基盤（Config / Logger / 候補抽出）

- [x] 1.1 `AUTO_REBASE_*` env var 群と起動時 template 存在チェックを Config block に追加
  - `local-watcher/bin/issue-watcher.sh` の Phase A Re-check Config 直後に Phase D Config を新設
  - 追加 env var: `AUTO_REBASE_MODE` (既定 `off`) / `MECHANICAL_PATHS` (既定 空) / `AUTO_REBASE_MODEL` (既定 `claude-opus-4-7`) / `AUTO_REBASE_MAX_TURNS` (既定 `30`) / `AUTO_REBASE_MAX_TURNS_SEC` (既定 `600`) / `AUTO_REBASE_GIT_TIMEOUT` (既定 `60`) / `AUTO_REBASE_MAX_PRS` (既定 `3`) / `AUTO_REBASE_TEMPLATE` (既定 `$HOME/bin/auto-rebase-prompt.tmpl`)
  - `AUTO_REBASE_MODE` を `case` で正規化（`claude` のみ通し、他はすべて `off` に固定）
  - 既存「デフォルト有効化フラグの値正規化」ループには加えない（opt-in 制のため別扱い）
  - `AUTO_REBASE_MODE != off` のとき `auto-rebase-prompt.tmpl` の存在を必須化（既存 ITERATION_TEMPLATE と同 pattern）
  - サイクル開始時に有効値をログに出力する設定値（`base-branch=` ログ近傍）
  - 既存 env var（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `MERGE_QUEUE_*` / `BASE_BRANCH` 等）の意味・既定値・正規化方式は変更しない（NFR 1.2）
  - _Requirements: 1.1, 1.3, NFR 1.1, NFR 1.2, NFR 3.2_

- [x] 1.2 `auto-rebase:` prefix の logger 三点セットと `process_auto_rebase` スケルトンを追加
  - `process_merge_queue` 関数（既存 L1090 直後）の直後に Phase D セクションを新設
  - `ar_log` / `ar_warn` / `ar_error` を既存 `mq_*` と同じ書式（`[YYYY-MM-DD HH:MM:SS] [$REPO] auto-rebase:` の 3 段 prefix）で定義
  - `process_auto_rebase()` のエントリ関数を作成: opt-in gate / dirty working tree check / サイクル開始ログ / 空サマリ行出力までを実装（候補抽出と PR 処理は次タスク）
  - _Requirements: 1.1, 1.2, 1.4, 3.4, NFR 1.1, NFR 2.2, NFR 4.1_

- [x] 1.3 `ar_fetch_candidates` で `needs-rebase` + approved + 非 draft + 非 fork PR を抽出
  - `gh pr list --search "review:approved label:\"needs-rebase\" -label:\"claude-failed\" -draft:true"` を server filter として使用
  - jq client filter: `isDraft == false` / `reviewDecision == "APPROVED"` / `headRefName | test($MERGE_QUEUE_HEAD_PATTERN)` / `headRepositoryOwner.login == $owner`
  - `process_auto_rebase` 内から呼び出し、overflow（`AUTO_REBASE_MAX_PRS` 超過分）の集計とログ出力までを実装
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 8.4_

## 2. Claude rebase 試行と rollback

- [ ] 2.1 `ar_build_prompt` で auto-rebase-prompt.tmpl のプレースホルダ展開を実装
  - `auto-rebase-prompt.tmpl` のプレースホルダ（`{{REPO}}` / `{{PR_NUMBER}}` / `{{PR_TITLE}}` / `{{PR_URL}}` / `{{HEAD_REF}}` / `{{BASE_REF}}` / `{{BASE_BRANCH}}`）を awk 置換で展開する関数を実装（既存 `pi_build_iteration_prompt` を参考）
  - _Requirements: 4.1_

- [ ] 2.2 `ar_run_claude_rebase` で Claude CLI 起動 + rollback + `--force-with-lease` push を実装
  - `(subshell + trap)` で `git rebase --abort` + `git checkout "$BASE_BRANCH"` を保証（Phase A `mq_try_rebase_pr` 踏襲）
  - `git fetch origin "$head_ref" "$base_ref"` → `git checkout -B "$head_ref" "origin/$head_ref"` → before_sha 取得 → `timeout "$AUTO_REBASE_MAX_TURNS_SEC" claude --print "$prompt" --model "$AUTO_REBASE_MODEL" --permission-mode bypassPermissions --max-turns "$AUTO_REBASE_MAX_TURNS" --output-format stream-json --verbose` → claude 終了後 dirty check → after_sha 取得 → `git push --force-with-lease`
  - 戻り値仕様: `0`=成功、`1`=conflict 未解消（dirty 残置）、`2`=timeout（exit 124）、`3`=push 失敗、`4`=fetch/checkout 失敗、`5`=rebase 不要（skip）
  - 各 git/gh サブプロセスに `timeout "$AUTO_REBASE_GIT_TIMEOUT"` を必ず適用
  - ログファイルは `$LOG_DIR/auto-rebase-<pr_number>-<timestamp>.log`
  - _Requirements: 4.1, 4.2, 4.3, 4.5, 4.6, NFR 5.1, NFR 5.2, NFR 5.3_

## 3. 分類と後処理（mechanical / semantic / failed）

- [ ] 3.1 `ar_classify_diff` で `MECHANICAL_PATHS` allowlist と path 集合の照合を実装 (P)
  - `git diff --name-only "origin/${base_ref}".."${head_ref}"` で変更 path 一覧を取得
  - `MECHANICAL_PATHS` 空 → 全件 `semantic`（保守的判定）
  - カンマ区切り pattern 配列を bash `[[ $path == $pattern ]]` glob 照合で走査（`# shellcheck disable=SC2053` を必要箇所に付与）
  - 全 path 一致 → `mechanical`、1 件でも unmatch → `semantic`（最初の unmatched path をログに含める）
  - 戻り値仕様: stdout に `mechanical` / `semantic` の 1 語、戻り値 `0`=正常、`1`=`git diff` 失敗（呼び出し側は保守的に `semantic` 扱い）
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_
  - _Boundary: ar_classify_diff_

- [ ] 3.2 `ar_apply_mechanical` で `needs-rebase` 除去のみを実装 (P)
  - `gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE"` の単一 API 呼び出し（個別 timeout 付与）
  - approve 維持 / 追加コメント無し（Req 6.1 / 6.3 を構造的に保証）
  - 戻り値: `0`=成功、`1`=API 失敗（呼び出し側で WARN）
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
  - _Boundary: ar_apply_mechanical_

- [ ] 3.3 `ar_dismiss_all_approvals` で review dismissal API を実装 (P)
  - `gh api "/repos/${REPO}/pulls/${pr_number}/reviews"` で全 review を取得
  - jq で `state == "APPROVED"` の id のみ抽出
  - 各 id について `gh api -X PUT "/repos/${REPO}/pulls/${pr_number}/reviews/{id}/dismissals" -f message="Phase D semantic rebase: re-review required"` を順次実行
  - 422（既に dismissed 等）は当該 review skip、それ以外の non-zero は全体失敗扱い（戻り値 `1`）
  - `gh pr review --request-changes` は使用しない（Req 7.5）
  - _Requirements: 7.1, 7.5, 7.6_
  - _Boundary: ar_dismiss_all_approvals_

- [ ] 3.4 `ar_apply_semantic` で dismissal + label 遷移 + 説明コメント投稿を実装
  - 順序: `ar_dismiss_all_approvals` → `needs-rebase` 除去 → `ready-for-review` 付与 → 説明コメント投稿
  - heredoc コメント本文に before_sha / after_sha、最初の unmatched path、dismissal 実施の旨、再レビュー要求の理由、hidden marker `<!-- idd-claude:auto-rebase pr=${pr_number} -->` を含める
  - dismissal 失敗時は呼び出し側（`ar_handle_pr`）に戻り値で通知し escalate 経路に流す
  - _Requirements: 7.1, 7.2, 7.3, 7.4_
  - _Depends: 3.3_

- [ ] 3.5 `ar_escalate_to_failed` で `claude-failed` 付与と原因種別コメントを実装 (P)
  - 入力 `reason` ∈ `{conflict-unresolved, timeout, push-failed, dismissal-failed}` で heredoc を分岐
  - `needs-rebase` には触らない（Req 8.1）
  - `gh pr edit --add-label "$LABEL_FAILED"` + `gh pr comment` の順で実行（label 付与失敗時もコメントは試みる）
  - _Requirements: 4.4, 4.5, 7.6, 8.1, 8.2, 8.3_
  - _Boundary: ar_escalate_to_failed_

- [ ] 3.6 `ar_handle_pr` で 1 PR 分の処理フロー（rebase → 分類 → 後処理 / escalate）を統合
  - `ar_run_claude_rebase` の戻り値に応じて `ar_escalate_to_failed`（種別: conflict-unresolved / timeout / push-failed）に振り分け
  - 成功時は `ar_classify_diff` の結果で `ar_apply_mechanical` / `ar_apply_semantic` に分岐
  - `ar_apply_semantic` 内の dismissal 失敗時は `ar_escalate_to_failed dismissal-failed` を呼ぶ
  - 1 PR 1 行サマリログ（`PR #N: classification=... before_sha=... after_sha=... action=...`）を出力（NFR 2.1）
  - 戻り値: `0`=mechanical / `1`=semantic / `2`=failed / `10`=skip
  - _Requirements: 3.4, 4.4, 4.5, 5.5, 7.6, NFR 2.1_
  - _Depends: 2.2, 3.1, 3.2, 3.4, 3.5_

- [ ] 3.7 `process_auto_rebase` の本処理ループとサマリ集計を完成させる
  - 1.3 で取得した候補配列を順次 `ar_handle_pr` に渡す
  - 戻り値別カウンタ（mechanical / semantic / failed / skip / overflow）を集計
  - `ar_log "サマリ: mechanical=N, semantic=N, failed=N, skip=N, overflow=N"` を 1 件出力（Req 3.4 / NFR 2.2）
  - サイクル末尾で保険として `git checkout "$BASE_BRANCH"` に戻す
  - _Requirements: 3.4, NFR 2.2_
  - _Depends: 3.6_

## 4. Orchestration 配線（既存 Phase A 系列との競合排除）

- [ ] 4.1 `process_merge_queue` 呼び出し（L1233）の直後に `process_auto_rebase` を直列配置
  - 既存呼び出し行 `process_merge_queue || mq_warn "..."` の**直後**に 1 行追加: `process_auto_rebase || ar_warn "process_auto_rebase が想定外のエラーで終了しました（後続 Issue 処理は継続）"`
  - これにより Re-check（先行）→ Phase A 本体 → Phase D の順序が確定し、Req 3.1〜3.3 が直列順序により構造的に保証される
  - 既存ラベル名（`needs-rebase` / `claude-failed` / `ready-for-review` 等）の名前と意味は変更せず、Phase D は既存定数（`$LABEL_NEEDS_REBASE` / `$LABEL_FAILED` / `$LABEL_READY`）を再利用する（NFR 1.3）
  - _Requirements: 3.1, 3.2, 3.3, NFR 1.3_
  - _Depends: 3.7_

## 5. Prompt template 配置

- [ ] 5.1 `auto-rebase-prompt.tmpl` を新規作成し install.sh の自動配置経路で配布 (P)
  - 配置: `local-watcher/bin/auto-rebase-prompt.tmpl`
  - プレースホルダ: `{{REPO}}` / `{{PR_NUMBER}}` / `{{PR_TITLE}}` / `{{PR_URL}}` / `{{HEAD_REF}}` / `{{BASE_REF}}` / `{{BASE_BRANCH}}`
  - Claude への指示: 「base ref を head に rebase し conflict 解消後 working tree clean な状態で終了する。force push / dismissal / label 操作は watcher が行うため Claude 側では行わない」
  - 禁止事項節: `git push` 全般 / `gh pr review` / `gh pr edit --add-label` / `gh pr comment` / rebase 範囲外の不要 refactor を厳禁
  - install.sh は既存 `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.tmpl" "$HOME/bin"` で自動配置されるため install.sh 自体の変更は不要
  - _Requirements: 4.1_
  - _Boundary: auto-rebase-prompt.tmpl_

## 6. ドキュメント更新

- [ ] 6.1 README に Phase D 節を追加し言語別 `MECHANICAL_PATHS` 設定例を記載 (P)
  - 「オプション機能一覧」節の「opt-in（既定 OFF）」表に Phase D 行を追加（`AUTO_REBASE_MODE` / 既定 `off`）
  - 新規節「Auto Rebase Processor (Phase D)」を Phase B / Phase C と同階層で作成し、以下を含める:
    - 対象 PR の判定条件
    - 動作フロー（mechanical / semantic / failed の挙動表）
    - 環境変数仕様（`AUTO_REBASE_MODE` / `MECHANICAL_PATHS` / `AUTO_REBASE_MODEL` / `AUTO_REBASE_MAX_TURNS` / `AUTO_REBASE_MAX_TURNS_SEC` / `AUTO_REBASE_GIT_TIMEOUT` / `AUTO_REBASE_MAX_PRS`）
    - 言語別 `MECHANICAL_PATHS` 設定例: JavaScript (`package-lock.json,yarn.lock,pnpm-lock.yaml`) / Python (`poetry.lock,Pipfile.lock,uv.lock`) / Go (`go.sum`) / Rust (`Cargo.lock`)
    - Branch protection "Dismiss stale pull request approvals when new commits are pushed" との相互作用に関する注記（Phase A 既存注記と同トーン）
    - watcher token に必要な権限（admin / maintain 相当）
    - ログ観測コマンド例（`grep 'auto-rebase:' $HOME/.issue-watcher/logs/...`）
  - _Requirements: 9.1, 9.2, 9.3_
  - _Boundary: README.md_

- [ ] 6.2 `repo-template/CLAUDE.md` の禁止事項 / agent 連携節に Phase D の存在を補足（任意、影響軽微） (P)
  - 「idd-claude 特有の設計上の注意」節に Phase D Processor の opt-in 制と既存 cron 互換性を 1〜2 行で追記
  - PR Iteration の `claude-failed` 説明と同形式で、Phase D 起点の `claude-failed` 復旧手順への参照を追加
  - _Requirements: 9.1_
  - _Boundary: repo-template/CLAUDE.md_

## 7. 検証 / Dogfood

- [ ] 7.1 `shellcheck` を `issue-watcher.sh` に対して通し警告ゼロを確認
  - `shellcheck local-watcher/bin/issue-watcher.sh` を実行
  - 必要な `# shellcheck disable=SC2053` を `ar_classify_diff` の glob 一致行にのみ局所付与
  - PR 本文の Test plan に shellcheck 出力を記載
  - _Requirements: NFR 4.1_

- [ ] 7.2 cron-like 最小 PATH での起動確認と従来挙動の不変性スモークテスト
  - `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git timeout'`
  - `AUTO_REBASE_MODE` 未設定で `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を流し、Phase D 関連の起動ログが一切出ないこと、既存 Phase A / Re-check / PR Iteration のサマリ行が従来通り出力されることを確認
  - PR 本文の Test plan に観測ログ抜粋を記載
  - _Requirements: 1.1, NFR 1.1, NFR 1.4, NFR 1.5_

- [ ]* 7.3 idd-claude self repo での dogfood（`MECHANICAL_PATHS=package-lock.json` 設定下）
  - 自分の cron / launchd に `AUTO_REBASE_MODE=claude` / `MECHANICAL_PATHS=package-lock.json` を追加（既存 env はそのまま）
  - lockfile-only conflict の test PR で `mechanical` 判定 → `needs-rebase` 除去 → auto-merge 到達のフルパスをログから確認
  - lockfile + source 混在 conflict の test PR で `semantic` 判定 → approve dismissal → `ready-for-review` 付与 → 説明コメント投稿の各 API 呼び出しが成功することを確認
  - 観測コマンド: `grep 'auto-rebase: PR #' $HOME/.issue-watcher/logs/<repo-slug>/*.log`
  - _Requirements: 9.4, NFR 2.1, NFR 2.2_
