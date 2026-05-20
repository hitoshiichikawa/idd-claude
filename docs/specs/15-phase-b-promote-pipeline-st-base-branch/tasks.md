# Implementation Plan

実装は **境界の独立性が高い順** に並べる。タスク 1（labels）→ タスク 2（config + gate）→
タスク 3〜5（Promote Pipeline 機能本体）→ タスク 6（docs）。タスク 1 と 6 は本体と独立した
ファイル群を触るため `(P)` で並列実行可能。タスク 3〜5 は `process_promote_pipeline()` の
内部状態（promote 集合 / Issue ループ）を共有するため直列にする。

- [x] 1. ラベルセットアップスクリプトに `st-failed` を追加
- [x] 1.1 `repo-template/.github/scripts/idd-claude-labels.sh` と `.github/scripts/idd-claude-labels.sh` の `LABELS=(...)` 配列に `st-failed` を追加する (P)
  - 両ファイルに同一行 `"st-failed|d73a4a|【Issue 用】 ST failure 検知後 revert 済み（Phase B Promote Pipeline が付与）"` を追記
  - 既存 12 ラベルの定義（名前・色・description）は変更しない（NFR 1.3 / Req 4.2）
  - `gh label create --force` 再実行で冪等になることを確認（既存ループに変更不要 / Req 4.1.4）
  - スクリプトを `--force` 付きでローカル実行し `st-failed` が created または created/updated になることを目視確認
  - _Requirements: 4.1, 4.2, NFR 1.3_
  - _Boundary: Labels Setup Script_

- [x] 2. `local-watcher/bin/issue-watcher.sh` Config ブロックに Phase B env var を追加
- [x] 2.1 6 つの新 env var を Config ブロックに宣言し、opt-in semantics で正規化する
  - 追加対象: `PROMOTE_PIPELINE_ENABLED`（既定 `false`）/ `PROMOTION_TARGET_BRANCH`（既定 `main`）/ `ST_CHECK_RUN_NAME`（既定空）/ `PROMOTE_MODE`（既定 `on-demand`）/ `PROMOTE_CRON`（既定空）/ `PROMOTE_FAIL_NOTIFY_ISSUE`（既定空）/ `PROMOTE_GIT_TIMEOUT`（既定は `${MERGE_QUEUE_GIT_TIMEOUT:-60}` を流用）
  - `LABEL_ST_FAILED="st-failed"` 定数を `LABEL_STAGED_FOR_RELEASE` の直後に宣言
  - `PROMOTE_PIPELINE_ENABLED` は `=true` を明示した場合のみ有効として正規化する（#112 で反転した既存「デフォルト有効化フラグ」ループには加えない）
  - 既存の `MERGE_QUEUE_*` / `BASE_BRANCH` / `LOG_DIR` 等の env var 名と既定値は変更しない（NFR 1.2）
  - 配置位置: 既存 `BASE_BRANCH` 設定ブロックの直後、Phase A `Merge Queue Processor` 設定の直前を推奨
  - _Requirements: 1.1, 1.2, NFR 1.1, NFR 1.2_

- [x] 3. Promote Pipeline Processor 本体と staged-for-release 自動付与（B1: gate + 自動付与）
- [x] 3.1 `process_promote_pipeline()` のエントリポイント、ロガー、3 重 gate（opt-in / 2-branch model / dirty tree）を実装する
  - 専用ロガー `pp_log` / `pp_warn` / `pp_error` を Phase A `mq_log` と同一書式（`[YYYY-MM-DD HH:MM:SS] [$REPO] promote-pipeline:` prefix）で定義
  - `pp_resolve_target_branch()` を実装し、`BASE_BRANCH == PROMOTION_TARGET_BRANCH` の no-op 終了（Req 1.1.3）と `git ls-remote --exit-code --heads origin "$PROMOTION_TARGET_BRANCH"` による存在検証（Req 1.2.2）を行う
  - `process_promote_pipeline()` の最初に `[ "$PROMOTE_PIPELINE_ENABLED" = "true" ] || return 0`、続けて dirty tree gate（NFR 2.3）を配置
  - Phase A 本体（`process_merge_queue`）の直後（issue-watcher.sh の `process_merge_queue || ...` の次の行）に `process_promote_pipeline || pp_warn "..."` を 1 行追加
  - _Requirements: 1.1, 1.2, NFR 1.1, NFR 2.3_
- [x] 3.2 `pp_collect_merged_issues()` で `BASE_BRANCH` に merge 済みの PR からリンク Issue を抽出し、未付与の Issue に `staged-for-release` を自動付与する
  - `gh pr list --state merged --base "$BASE_BRANCH" --limit 50 --json number,body,closingIssuesReferences,headRepositoryOwner` で対象 PR を取得
  - fork PR を除外（`headRepositoryOwner.login != REPO owner` の PR は除外、NFR 2.4）
  - 各 PR の `closingIssuesReferences` から Issue 番号を抽出（`Closes #N` 形式を GitHub が解決済みの値を利用）
  - 既に `staged-for-release` が付いている Issue にはラベル再付与しない（Req 2.1.3、重複付与抑止）
  - 未付与 Issue には `gh issue edit --add-label "$LABEL_STAGED_FOR_RELEASE"` を実行
  - 自動付与と人間付与の source 区別はしない（同一ラベルを共有 / Req 2.1.2）
  - 関数 stdout に「現時点で `staged-for-release` を持つ全 open Issue の番号」を 1 行 1 件で出力（次のステップで ST 判定する対象集合になる）
  - _Requirements: 2.1, NFR 2.4, NFR 5.2_

- [x] 4. ST polling と revert-and-continue（B2）
- [x] 4.1 `pp_get_st_state()` を実装し、Issue 番号から merge SHA を解決して check-run 状態を取得する
  - `pp_resolve_merge_sha()` ヘルパで Issue にリンクされた直近の merge commit SHA を取得（GraphQL `issue.timelineItems` 経由 or `gh issue view --json closedByPullRequestsReferences`）
  - `gh api "repos/$REPO/commits/$merge_sha/check-runs" --jq` で check-run 一覧を取得
  - `ST_CHECK_RUN_NAME` と完全一致する check-run を抽出し、`completed_at` が最新のものを採用
  - 出力 5 状態に正規化: `success` / `failure` / `pending` / `missing` / `skip-warn`（`ST_CHECK_RUN_NAME` 未設定時）
  - `failure` には GitHub の conclusion `failure` / `cancelled` / `timed_out` / `action_required` を含める（neutral / skipped / stale は `missing` 扱い）
  - `ST_CHECK_RUN_NAME` 未設定なら `skip-warn` を返し、呼び出し元で WARN ログを出させる（Req 2.2.3）
  - すべての gh / git 操作を `timeout "$PROMOTE_GIT_TIMEOUT"` で wrap（NFR 3.2）
  - _Requirements: 2.2_
- [x] 4.2 `pp_handle_st_failure()` + `pp_do_revert()` を実装し、ST failure 時の revert + Issue 操作 + fail-continue を実現する
  - `pp_do_revert()`: サブシェル内で `trap` を仕掛けて `BASE_BRANCH` への safe checkout 復帰を保証、`git checkout "$BASE_BRANCH"` → `git pull --ff-only` → `git revert -m 1 --no-edit "$merge_sha"` → `git push --force-with-lease origin "$BASE_BRANCH"` の順で実行（NFR 2.1）
  - `git push --force-with-lease` 失敗（リモート先行）→ exit 1（呼び出し元で WARN + `st-failed` 付与保留 / Req 2.4.6）
  - `git revert` 自体の失敗 → exit 2（呼び出し元で WARN + 当該 Issue スキップ）
  - revert 成功時: `gh issue edit --add-label "$LABEL_ST_FAILED" --remove-label "$LABEL_STAGED_FOR_RELEASE"`（Req 2.4.1, 2.4.4 を 1 call にまとめる）
  - `gh issue reopen` で Issue を reopen（Req 2.4.3）
  - `gh issue comment` で ST log URL を含む 1 件のステータスコメント投稿（Req 2.4.3）。コメント body には revert 済みの merge SHA prefix（7 文字）と ST log URL（`gh run view` 経由 or check-run の `details_url`）を含める
  - 1 件失敗しても他 Issue 処理を継続するため、関数戻り値で集計用カウンタにのみ反映（NFR 3.1, Req 2.4.5）
  - _Requirements: 2.4, NFR 2.1, NFR 3.1_
- [x] 4.3 `pp_handle_st_success()` を実装し、success Issue から `staged-for-release` を除去して promote 集合に追加する
  - `PROMOTE_MODE=on-demand` のときはラベルを除去せず、`PROMOTE_CANDIDATES` 集合にも入れない（Req 3.2.5、人間トリガー待ち）
  - それ以外（continuous / batched）は `gh issue edit --remove-label "$LABEL_STAGED_FOR_RELEASE"` 実行 + bash 配列 `PROMOTE_CANDIDATES+=("$issue_number")` に追加（Req 2.3.1, 2.3.2）
  - `pending` / `missing` / `skip-warn` 状態の Issue は何もせず次サイクルに持ち越す（Req 2.2.4, 2.2.5, 2.2.3）
  - すべての分岐で「Issue 番号 / ST 状態 / 実施アクション」を 1 行ログに出力（Req 5.1.2）
  - _Requirements: 2.2, 2.3, 3.2, 5.1_

- [ ] 5. Promote 実行（B3: fast-forward push + PROMOTE_MODE 分岐 + 失敗通知）
- [x] 5.1 `pp_do_promote_if_eligible()` と `pp_match_cron()` を実装し、PROMOTE_MODE 3 モードを分岐する
  - `PROMOTE_MODE=continuous`: promote 集合が 1 件以上なら即時 `pp_do_promote` 呼び出し（Req 3.2.3）
  - `PROMOTE_MODE=batched`: `pp_match_cron "$PROMOTE_CRON"` が真のときだけ `pp_do_promote`、`PROMOTE_CRON` 未設定 / 不正なら WARN + 当該サイクル no-op（Req 3.2.4, 3.2.6）
  - `PROMOTE_MODE=on-demand` / 未設定 / 不正値: 何もしない + log 出力（Req 3.2.2, 3.2.5）
  - `pp_match_cron()`: 標準 5 フィールド cron 式（`分 時 日 月 曜日`）を `date '+%M %H %d %m %u'` の現在時刻と比較。`*` / `*/N` / `A,B,C` / `A-B` / 整数の各サブパターンを bash で実装、不正値は `return 1`
  - _Requirements: 3.2, 5.1_
- [x] 5.2 `pp_do_promote()` で `BASE_BRANCH` → `PROMOTION_TARGET_BRANCH` の fast-forward push を実行する
  - サブシェル内で `trap` を仕掛けて `BASE_BRANCH` checkout 復帰を保証（NFR 2.3 / Req 3.1.4）
  - `git fetch origin "$PROMOTION_TARGET_BRANCH"` 実行
  - `git merge-base --is-ancestor "origin/$PROMOTION_TARGET_BRANCH" "origin/$BASE_BRANCH"` で fast-forward 可否を確認（祖先関係でなければ中止 / Req 3.1.2）
  - fast-forward 可能なら `git push origin "refs/remotes/origin/$BASE_BRANCH:refs/heads/$PROMOTION_TARGET_BRANCH"` で push（`--force` 系オプションを付けない＝自然な ff push、NFR 2.1, 2.2）
  - 成功時: `pp_log "promote-success: '$BASE_BRANCH' -> '$PROMOTION_TARGET_BRANCH' fast-forward OK"`
  - 失敗時: `pp_warn` に `promote-failed` 識別語を含めて出力（NFR 4.1）、ラベル状態は変更しない（Req 3.1.3）
  - すべての git 操作を `timeout "$PROMOTE_GIT_TIMEOUT"` で wrap（NFR 3.2 / NFR 5.1）
  - _Requirements: 3.1, NFR 2.1, NFR 2.2, NFR 3.2, NFR 4.1, NFR 5.1_
- [ ] 5.3 `pp_notify_promote_failure()` と `pp_summary()` を実装し、ログ識別語と Issue コメント通知を仕上げる
  - `pp_notify_promote_failure`: `PROMOTE_FAIL_NOTIFY_ISSUE` が `^[0-9]+$` にマッチする数値のとき `gh issue comment "$PROMOTE_FAIL_NOTIFY_ISSUE" --repo "$REPO" --body "..."` で 1 件投稿（Req 3.3.2）、それ以外は log のみ（Req 3.3.3）
  - `pp_summary`: サイクル終了時に `[$REPO] promote-pipeline: サマリ: st-success-promoted=X, st-failure-reverted=Y, pending-skip=Z, promote-failed=W, fail=V` を 1 行で出力（Req 5.1.3）
  - 各 git / gh 操作の stderr / stdout 分離を NFR 4.2 に合わせて維持（`pp_log` → stdout、`pp_warn` / `pp_error` → `>&2`）
  - _Requirements: 3.3, 5.1, NFR 4.1, NFR 4.2_

- [ ] 6. ドキュメント更新（DoD）
- [ ] 6.1 README.md / QUICK-HOWTO.md / CLAUDE.md に Phase B の概要・env var 表・ラベル一覧・状態遷移・migration note を追記する (P)
  - **具体的な挿入位置・見出し階層・内容スケルトンは `design.md` の「Documentation Set / README 編集ブループリント」節に従う**（Architect が利用方法と状態遷移の README 反映方法を確定済み）
  - README に Phase B Promote Pipeline **利用方法**セクション（目的・対象・タイミング）を新規 h2 として追加（Req 6.1.1、ブループリント 1）
  - README の環境変数表に `PROMOTE_PIPELINE_ENABLED` / `PROMOTION_TARGET_BRANCH` / `ST_CHECK_RUN_NAME` / `PROMOTE_MODE` / `PROMOTE_CRON` / `PROMOTE_FAIL_NOTIFY_ISSUE` を追加（Req 6.1.2、ブループリント 2）
  - README のラベル一覧に `st-failed` の「適用先 = Issue」「付与主 = Phase B Promote Pipeline」「意味 = ST failure 検知後に revert 済み」を追加（Req 6.1.3、ブループリント 3）
  - README の**ラベル状態遷移節**に Phase B 補助フロー（`staged-for-release` 自動付与 → ST polling → success/failure 分岐）を、**状態遷移表 + Mermaid 図** の両形式で追加（Req 6.1.4、ブループリント 4）
  - #100 で定義された人間付与の `staged-for-release` 運用と Phase B 自動付与が同一ラベルを共有する旨を README に明記（Req 6.1.5、ブループリント 5）
  - Migration Note: `PROMOTE_PIPELINE_ENABLED` 未設定で既存挙動完全保持、既存 env / ラベル / lock / exit code 不変、`BASE_BRANCH` Branch Protection 設定確認の推奨を記載（Req 6.1.6、ブループリント 6）
  - QUICK-HOWTO.md の「作成されるラベル」一覧に `st-failed` を追加（Req 6.2.1、ブループリント 7）
  - 全ドキュメントで `st-failed` を lowercase / ハイフン区切りで完全一致表記（Req 6.2.2、ブループリント 7）
  - CLAUDE.md（本 repo）の「idd-claude 特有の設計上の注意」節に Phase B 機能の留意点（opt-in gate / 2-branch model 前提 / 既存 staged-for-release 共存）を 1 段落追記（ブループリント 7）
  - 完了基準: `design.md` のブループリント「Acceptance Criteria → README 追記箇所のトレーサビリティ」表の Req 6.1.1〜6.2.2 がすべて README / QUICK-HOWTO / CLAUDE.md のいずれかに反映されていること
  - _Requirements: 6.1, 6.2_
  - _Boundary: Documentation Set_

- [ ]* 7. テスト追加（optional / deferrable）
  - `process_promote_pipeline` の opt-in OFF dry-run（exit 0 / 出力空）を harness で再現
  - `pp_get_st_state` の jq フィルタを mock JSON で 5 状態（success / failure / pending / missing / skip-warn）網羅
  - `pp_match_cron` の cron 式 matcher を unit test 化（`*` / `*/15` / `1,15` / `0-30` / 不正値の 5 パターン）
  - `idd-claude-labels.sh` 再実行で `st-failed` が冪等に処理される dry-run（既存ラベル + 新ラベル混在）
  - cron-like 最小 PATH での依存解決（`env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v gh jq git flock timeout claude'`）
  - _Requirements: 1.1, 1.2, 2.2, 3.2, 4.1_
