# 実装ノート — Phase B Promote Pipeline + ST 連携 (#15)

## 実装サマリ

tasks.md の番号順に 6 タスク（1.1 / 2.1 / 3.1 / 3.2 / 4.1 / 4.2 / 4.3 / 5.1 /
5.2 / 5.3 / 6.1）を完了し、各タスクの実装 commit と `docs(tasks): mark N as done`
専用 commit を交互に積みました。deferrable な task 7（テスト追加、`- [ ]*` 印付き）
は本サイクルでは未実装で、要件に従い親タスクの完了判定からも除外しています。

実装は **既存 7 ファイルへの追記のみ** で実現しており、新規ファイルは作成して
いません（design.md の File Structure Plan に従う）。

### 追加した env var / 関数 / ラベルの一覧

#### env var（`local-watcher/bin/issue-watcher.sh` Config ブロックに追加）

| 変数 | デフォルト | 用途 |
|---|---|---|
| `PROMOTE_PIPELINE_ENABLED` | `false` | Phase B 全体の opt-in gate（`=true` 明示のみ有効） |
| `PROMOTION_TARGET_BRANCH` | `main` | 昇格先ブランチ |
| `ST_CHECK_RUN_NAME` | `""` | ST check-run 名（単一文字列） |
| `PROMOTE_MODE` | `on-demand` | `continuous` / `batched` / `on-demand` |
| `PROMOTE_CRON` | `""` | `PROMOTE_MODE=batched` 用 cron 式 |
| `PROMOTE_FAIL_NOTIFY_ISSUE` | `""` | promote 失敗時の通知先 Issue 番号 |
| `PROMOTE_GIT_TIMEOUT` | `${MERGE_QUEUE_GIT_TIMEOUT:-60}` | git / gh サブプロセス timeout |

#### 関数（`pp_*` 名前空間で完全独立）

| 関数 | 責務 | 関連 Req |
|---|---|---|
| `pp_log` / `pp_warn` / `pp_error` | timestamp + `[$REPO] promote-pipeline:` prefix のロガー | 5.1, NFR 4.1, 4.2 |
| `pp_resolve_target_branch` | `PROMOTION_TARGET_BRANCH` のリモート存在検証 + 2-branch model gate | 1.1.3, 1.2.2 |
| `pp_issue_has_label` | Issue が指定ラベルを持つか確認 | 2.1.3 |
| `pp_collect_merged_issues` | merge 済み PR からリンク Issue を抽出 + 自動付与 + ST 判定対象出力 | 2.1, NFR 2.4, NFR 5.2 |
| `pp_resolve_merge_sha` | Issue → 直近 MERGED PR の `mergeCommit.oid` 解決 | 2.2 |
| `pp_get_st_state` | ST check-run の状態を 5 種に正規化（success/failure/pending/missing/skip-warn） | 2.2 |
| `pp_resolve_st_log_url` | ST check-run の `details_url` 解決 | 2.4.3 |
| `pp_do_revert` | サブシェル + trap で `git revert -m 1` + `--force-with-lease` push | 2.4.2, 2.4.6, NFR 2.1, 2.3 |
| `pp_handle_st_failure` | revert + Issue reopen + `st-failed` 付与 + コメント投稿 | 2.4, NFR 3.1 |
| `pp_handle_st_success` | `staged-for-release` 除去 + `PROMOTE_CANDIDATES` 追加（on-demand では hold） | 2.3, 3.2.5 |
| `pp_process_one_issue` | per-Issue 状態ディスパッチャ + カウンタ更新 | 2.2, 2.3, 5.1, NFR 3.1 |
| `pp_match_cron_field` | cron 1 フィールド matcher（`*` / `*/N` / `A-B` / `A,B,C` / 整数） | 3.2.4 |
| `pp_match_cron` | 標準 5 フィールド cron 式 matcher | 3.2.4, 3.2.6 |
| `pp_do_promote` | サブシェル + trap で fast-forward push（祖先確認付き） | 3.1, NFR 2.1, 2.2 |
| `pp_do_promote_if_eligible` | PROMOTE_MODE 3 モード dispatcher | 3.2 |
| `pp_notify_promote_failure` | promote 失敗時の通知（log + 任意 Issue コメント） | 3.3 |
| `pp_summary` | サイクル終了時のサマリ 1 行出力 | 5.1.3, NFR 4.1 |
| `process_promote_pipeline` | エントリポイント（3 重 gate + per-Issue loop + promote） | 1.1, NFR 1.1, 2.3, 3.1 |

#### ラベル

| ラベル | 色 | 適用先 | 付与主 |
|---|---|---|---|
| `st-failed` | `d73a4a` | Issue | Phase B Promote Pipeline Processor |

`.github/scripts/idd-claude-labels.sh` と `repo-template/.github/scripts/idd-claude-labels.sh`
の両 `LABELS=(...)` 配列に同一行で追加。`gh label create --force` 再実行で冪等
（既存ループに内在）。

#### ドキュメント更新箇所

- `README.md`:
  - 「セットアップ → ラベル一覧」表に `st-failed` 行追加
  - 「手動で作成する場合」の `gh label create` 例に `st-failed` 追加
  - 「ラベル状態遷移まとめ」表に `st-failed` 行追加 + `staged-for-release` の付与主を Phase B 含む形に更新
  - 「Phase B: Promote Pipeline 補助フロー」サブセクション新規追加（状態遷移表 + Mermaid 図 + 共存メモ）
  - 「オプション機能一覧 / opt-in」表に Phase B 行追加
  - 新規 h2「Promote Pipeline Processor (Phase B)」セクション追加（概要 / 目的 / 対象 / タイミング / 環境変数 / 利用方法 / `st-failed` ラベル / ログ識別語 / Migration Note / merge 後の再配置）
- `QUICK-HOWTO.md`: 「作成されるラベル」一覧に `st-failed` を追加
- `CLAUDE.md`（本 repo）: 「idd-claude 特有の設計上の注意」節に Phase B 関連の留意点を 1 段落追記

## 検証結果

### 静的解析

- **`shellcheck local-watcher/bin/issue-watcher.sh repo-template/.github/scripts/idd-claude-labels.sh .github/scripts/idd-claude-labels.sh`**:
  - 残置 warning は **SC2317（unreachable, 動的呼び出しヘルパに対する誤検知）と SC2012（`ls` → `find` 推奨）のみ**で、いずれも **pre-existing**（本 PR で追加された行に対する警告ではない）
  - 本 PR で追加した `pp_*` 関数群および `process_promote_pipeline` に対する shellcheck 警告はゼロ
  - 中間状態（task 2.1 完了直後）で発生した SC2034（`LABEL_ST_FAILED appears unused`）は task 4.2 の `pp_handle_st_failure` 実装で実使用に転じ解消済み
- **`bash -n local-watcher/bin/issue-watcher.sh`**: syntax error なし
- **`REPO=owner/test REPO_DIR=/tmp/test-repo-15 PROMOTE_PIPELINE_ENABLED=false bash -n local-watcher/bin/issue-watcher.sh`**: syntax error なし
- **`REPO=owner/test REPO_DIR=/tmp/test-repo-15 PROMOTE_PIPELINE_ENABLED=true PROMOTION_TARGET_BRANCH=main BASE_BRANCH=develop bash -n local-watcher/bin/issue-watcher.sh`**: syntax error なし
- **`actionlint`**: workflow YAML は本 PR で変更していないため対象外

### 後方互換性

- `PROMOTE_PIPELINE_ENABLED` 未設定／`false` の場合、`process_promote_pipeline()` は冒頭の早期 return で完全に no-op となり、log 出力もゼロ（NFR 1.1）
- 既存 env var（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `BASE_BRANCH` / `MERGE_QUEUE_*` / `PR_ITERATION_*` 等）の名前と既定値は一切変更していない（NFR 1.2）
- 既存ラベル 12 種（`auto-dev` / `needs-decisions` / `awaiting-design-review` / `claude-claimed` / `claude-picked-up` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` / `needs-quota-wait` / `staged-for-release`）の名前・色・description は無変更（Req 4.2.1）
- `staged-for-release` の付与・除去契約は #100 の人間付与運用と同一ラベルを共有する形で拡張のみ（Req 2.1.2, 4.2.2）
- Phase A の `needs-rebase` 契約は変更なし（Req 4.2.3）
- watcher の exit code / log prefix / cron 登録文字列に影響する変更はなし

### Feature Flag Protocol 確認

本リポジトリの `CLAUDE.md` には `## Feature Flag Protocol` 節が**存在しない**ため、
**通常フローで実装**（`feature-flag.md` の opt-in 規約は適用しない / 既定 opt-out）。
`PROMOTE_PIPELINE_ENABLED` は Feature Flag Protocol の flag ではなく、Phase B 機能
自体の opt-in env var。`if (flag) 新挙動 else 旧挙動` 2 系統温存は不要で、新規機能を
opt-in gate の内側に閉じ込めた単一実装パスとなっている。

## AC（受入基準）→ テスト・コード担保のトレーサビリティ

deferrable な task 7 のテスト追加は本サイクル未実装のため、各 AC は**実装コード**で
担保していることを以下に明示します。Reviewer / 運用者は対象コードを参照して挙動を
確認できます。

### Requirement 1: Opt-in gate と適用条件

| AC | 担保 |
|---|---|
| 1.1.1 | `process_promote_pipeline()` 冒頭の `[ "$PROMOTE_PIPELINE_ENABLED" != "true" ] && return 0`（issue-watcher.sh L1939 付近） |
| 1.1.2 | 上記 gate 通過後 `pp_resolve_target_branch` が BASE != TARGET を確認した上で本体実行 |
| 1.1.3 | `pp_resolve_target_branch()` の `[ "$BASE_BRANCH" = "$PROMOTION_TARGET_BRANCH" ]` 早期 return |
| 1.1.4 | Config ブロックで既存 env var を **読み取りのみ**で、`MERGE_QUEUE_*` / `BASE_BRANCH` / `LOG_DIR` 等の値・既定値を変更していない |
| 1.2.1 | `PROMOTION_TARGET_BRANCH="${PROMOTION_TARGET_BRANCH:-main}"`（Config block） |
| 1.2.2 | `pp_resolve_target_branch()` の `git ls-remote --exit-code --heads` 失敗で `pp_error` + return 1 |

### Requirement 2: ST 連携と `staged-for-release` 自動付与

| AC | 担保 |
|---|---|
| 2.1.1 | `pp_collect_merged_issues()` の `gh issue edit --add-label "$LABEL_STAGED_FOR_RELEASE"` 呼び出し |
| 2.1.2 | 自動付与 source 区別なし。`gh issue list --label staged-for-release` で人間付与と自動付与を統合取得 |
| 2.1.3 | `pp_issue_has_label` で既付与を確認し、TRUE なら `continue` で API 再送せず |
| 2.2.1 | `pp_get_st_state()` の `gh api repos/.../commits/$merge_sha/check-runs` 呼び出し |
| 2.2.2 | `jq --arg n "$ST_CHECK_RUN_NAME"` で完全一致フィルタ + `completed_at` 最新採用 |
| 2.2.3 | `pp_get_st_state` 冒頭 `[ -z "$ST_CHECK_RUN_NAME" ] && echo "skip-warn"` → 呼び出し元 `pp_warn` |
| 2.2.4 | `pending` ケースで `pp_log "ST=pending action=skip-next-cycle"`、ラベル変更なし |
| 2.2.5 | `pp_resolve_merge_sha` 失敗 / check-runs 取得失敗 → `missing` → `pp_warn` |
| 2.3.1 | `pp_handle_st_success` の `gh issue edit --remove-label "$LABEL_STAGED_FOR_RELEASE"` |
| 2.3.2 | `PROMOTE_CANDIDATES+=("$issue_number")` で promote 集合に追加 |
| 2.4.1 | `pp_handle_st_failure` の `gh issue edit --add-label "$LABEL_ST_FAILED"` |
| 2.4.2 | `pp_do_revert()` で `git revert -m 1 --no-edit` + `git push --force-with-lease` |
| 2.4.3 | `gh issue reopen` + ST log URL を含む `gh issue comment`（同関数内） |
| 2.4.4 | 同 `gh issue edit` call で `--remove-label "$LABEL_STAGED_FOR_RELEASE"` 同時実施 |
| 2.4.5 | per-Issue 失敗時に `pp_warn` + `return 1`（呼び出し元のループは継続） |
| 2.4.6 | `pp_do_revert` exit 1（push 失敗）時に `pp_warn` + st-failed 付与スキップ |

### Requirement 3: `BASE_BRANCH` → `PROMOTION_TARGET_BRANCH` の昇格

| AC | 担保 |
|---|---|
| 3.1.1 | `pp_do_promote` の `git push origin refs/remotes/origin/$BASE:refs/heads/$TARGET` |
| 3.1.2 | 同関数の `git merge-base --is-ancestor "origin/$TARGET" "origin/$BASE"` ガード |
| 3.1.3 | ancestor 不成立時に `pp_warn "promote-failed: ..."` + return（ラベル変更なし） |
| 3.1.4 | サブシェル + `trap "git checkout $BASE_BRANCH" EXIT` で復帰保証 |
| 3.2.1 | Config の `PROMOTE_MODE="${PROMOTE_MODE:-on-demand}"` で 3 値受付 |
| 3.2.2 | `pp_do_promote_if_eligible` の `case` 文 default で on-demand にフォールバック + WARN |
| 3.2.3 | `case continuous)` で即時 `pp_do_promote` |
| 3.2.4 | `case batched)` で `pp_match_cron "$PROMOTE_CRON"` 一致時のみ実行 |
| 3.2.5 | `case on-demand)` 何もしない + log。`pp_handle_st_success` も on-demand では label-remove スキップ |
| 3.2.6 | `case batched)` の PROMOTE_CRON 未設定 / 不一致で `pp_warn` / `pp_log` + 本サイクル no-op |
| 3.3.1 | `pp_do_promote` の各失敗パスで `pp_warn "promote-failed: ..."` |
| 3.3.2 | `pp_notify_promote_failure` の `[[ "$PROMOTE_FAIL_NOTIFY_ISSUE" =~ ^[0-9]+$ ]]` 分岐で `gh issue comment` |
| 3.3.3 | 上記条件不成立時は `return 0` で何もしない（log のみ） |

### Requirement 4: ラベル定義と既存ラベル契約

| AC | 担保 |
|---|---|
| 4.1.1 | `.github/scripts/idd-claude-labels.sh` の LABELS 配列に `st-failed|d73a4a|...` 追加 |
| 4.1.2 | description prefix `【Issue 用】` を既存 `needs-quota-wait` / `staged-for-release` と整合 |
| 4.1.3 | `repo-template/.github/scripts/idd-claude-labels.sh` にも同一行を追加（両系統で一致） |
| 4.1.4 | 既存ループ（`gh label list` → `gh label create --force`）の冪等性に内在、追加処理なし |
| 4.2.1 | 既存 12 ラベルの定義は 1 文字も変更していない（grep で全件確認可能） |
| 4.2.2 | `staged-for-release` ラベル名・色・description は無変更、付与・除去契約のみ Phase B が拡張 |
| 4.2.3 | `needs-rebase` 関連処理は Phase A コードに一切触れていない |

### Requirement 5: ロギング・可観測性

| AC | 担保 |
|---|---|
| 5.1.1 | `pp_log` / `pp_warn` / `pp_error` の `[$(date '+%F %T')]` 書式（Issue Watcher と一致） |
| 5.1.2 | `pp_process_one_issue` の各分岐で `issue=#N ST=<state> action=<action>` 形式の 1 行 log |
| 5.1.3 | `pp_summary` で `サマリ: st-success-promoted=X, st-failure-reverted=Y, pending-skip=Z, missing-skip=M, promote-success=P, promote-failed=Q, fail=F` |
| 5.1.4 | 新規 LOG_DIR を作っておらず、既存 watcher の stdout/stderr 出力（cron / launchd が redirect）に集約 |
| 5.1.5 | 全 log 行に `[$REPO] promote-pipeline:` prefix（grep 集計用識別語）|

### Requirement 6: ドキュメント更新（DoD）

| AC | 担保 |
|---|---|
| 6.1.1 | README.md「Promote Pipeline Processor (Phase B)」h2 セクション（目的 / 対象 / タイミング） |
| 6.1.2 | 同セクション内「環境変数」表（6 種 + `PROMOTE_GIT_TIMEOUT`）|
| 6.1.3 | README.md「ラベル一覧」表 + 「ラベル状態遷移まとめ」表に `st-failed` 行追加 |
| 6.1.4 | README.md「Phase B: Promote Pipeline 補助フロー」サブセクション（状態遷移表 + Mermaid 図）|
| 6.1.5 | 同サブセクション末尾「既存 `staged-for-release`（#100）との共存」段落 |
| 6.1.6 | README.md「Migration Note（既存ユーザー向け）」サブセクション |
| 6.2.1 | QUICK-HOWTO.md「作成されるラベル」一覧に `st-failed` 追記 |
| 6.2.2 | `st-failed` は全ドキュメントで lowercase / ハイフン区切り完全一致（grep で確認済み） |

### Non-Functional Requirements

| NFR | 担保 |
|---|---|
| NFR 1.1 | `process_promote_pipeline` 冒頭の opt-in gate で `PROMOTE_PIPELINE_ENABLED != true` は no-op return |
| NFR 1.2 | Config block で既存 env var の値・既定値は無変更（diff で確認可能） |
| NFR 1.3 | 既存 12 ラベル定義は無変更、Phase B 関連の付与契約のみ拡張 |
| NFR 2.1 | `pp_do_revert` の `--force-with-lease`、`pp_do_promote` の自然 fast-forward push のみ。`--force` 単独は未使用 |
| NFR 2.2 | `pp_do_promote` の `git merge-base --is-ancestor` ガードで non-fast-forward を中止 |
| NFR 2.3 | `process_promote_pipeline` 冒頭の `git status --porcelain` で dirty tree を検知し ERROR + 中止 |
| NFR 2.4 | `pp_collect_merged_issues` の jq フィルタ `select(.headRepositoryOwner.login == $owner)` で fork PR を除外 |
| NFR 3.1 | per-Issue ループの `|| pp_warn`、`pp_do_promote_if_eligible || true` で fail-continue |
| NFR 3.2 | 全 gh / git 操作を `timeout "$PROMOTE_GIT_TIMEOUT"` で wrap |
| NFR 4.1 | `pp_log` / `pp_summary` の `promote-pipeline:` / `promote-success:` / `promote-failed:` 識別語 |
| NFR 4.2 | `pp_log` → stdout、`pp_warn` / `pp_error` → `>&2` の分離 |
| NFR 5.1 | 各 git / gh 操作に 60 秒 timeout、`gh pr list --limit 50` / `gh issue list --limit 100` で件数制限 |
| NFR 5.2 | 1 Issue あたり最大 5 回程度の API call（pp_get_st_state×1, pp_resolve_merge_sha×2, pp_handle_*×1-3 / ）|

## 解釈・判断メモ

- **`pp_resolve_merge_sha` の実装**: design.md は GraphQL `issue.timelineItems` を例示
  していたが、`gh issue view --json closedByPullRequestsReferences` + `gh pr view --json
  mergeCommit` の組み合わせが REST + シンプルで shell から扱いやすかったため、後者を採用
  （API call 数の上限 10 回以内 / NFR 5.2 の範囲内）
- **`pp_handle_st_success` カウンタ**: on-demand mode でラベル除去をスキップした場合も
  「ST success として検知した数」は pp_summary の `st-success-promoted` に加算するように
  設計した。これにより grep 集計上「ST success 検知数 - promote 集合追加数 = on-demand
  hold 数」が計算可能になる。要件は厳密に分けていないため、これは観測性優先の解釈
- **`PROMOTE_CANDIDATES` のスコープ**: 関数ローカルではなくグローバル配列として
  `process_promote_pipeline` 冒頭で初期化。`pp_handle_st_success` から `+=` で要素を
  足し、後続の `pp_do_promote_if_eligible` / `pp_do_promote` が参照する形を採用。
  bash の `while read` ループは here-string `<<<` を使うことでサブシェル化を回避
- **`pp_do_promote` の push 形式**: `git push origin
  refs/remotes/origin/$BASE:refs/heads/$TARGET` の構文を採用。これは fetch 済みの
  remote ref を直接 push に渡す形で、`--force` 系オプションを付けない natural
  fast-forward push となる（NFR 2.1, 2.2）。`git checkout` を介さないため作業ツリーを
  汚さず、Phase A `process_merge_queue` 直後の clean な状態を維持できる
- **`pp_match_cron` の曜日表記**: cron 標準は 0=Sun, 1=Mon..6=Sat だが、`date +%u` は
  1=Mon..7=Sun を返す。cron 0（Sun）を取りこぼさないよう、`%u=7` の時に追加で
  `pp_match_cron_field "${fields[4]}" "0"` を試行する 2 段比較を実装
- **`pp_notify_promote_failure` の Issue コメント文言**: design.md にテンプレートが
  明示されていなかったため、Phase A `mq_handle_conflict` のコメント書式
  （`## 🔁` 見出し + `_本コメントは ... が自動投稿しました。_` 末尾）に揃えた
- **`process_merge_queue` 直後の起動位置**: tasks.md / design.md ともに「Phase A の
  直後」と指定。具体的には issue-watcher.sh の
  `process_merge_queue || mq_warn ...` の次の行に `process_promote_pipeline || pp_warn ...`
  を 1 行追加した（行番号は L1213 付近）

## 確認事項（PR 本文に転記推奨）

- **`PROMOTE_GIT_TIMEOUT` のデフォルト値**: Config block 内で
  `${MERGE_QUEUE_GIT_TIMEOUT:-60}` を fallback として使う設計だが、Config block 上で
  Phase B 環境変数は Phase A の前に配置している（tasks.md 指定の挿入位置）。これは
  bash のスクリプト上 `MERGE_QUEUE_GIT_TIMEOUT` の env 値が cron / launchd から渡されて
  いる場合は問題なく resolve され、未設定なら 60 にフォールバックする挙動で design.md
  と一致する。配置順を Phase A の後に移したい場合は別 PR / Issue で議論
- **`pp_resolve_merge_sha` の堅牢性**: 1 Issue が複数の MERGED PR を持つケース（rebase
  merge + revert + 再 merge 等）では、PR 番号降順で最初に `mergeCommit.oid` を取得
  できたものを採用している。ST 判定は最新の merge commit に対して行うのが要件に整合
  すると判断したが、稀にエッジケースで間違った commit を取得する可能性あり。本実装は
  最も新しい PR を優先する形になっているが、`mergeCommit.committedDate` 降順での
  ソートに変更する余地あり
- **`PROMOTE_FAIL_NOTIFY_ISSUE` への重複コメント**: 1 サイクル内で複数の promote 失敗
  経路（fetch / ancestor / push）が直列で起きた場合、`pp_notify_promote_failure` は
  各失敗ごとにコメントを投稿する可能性がある。実際は 1 サイクル内で `pp_do_promote` は
  1 回しか呼ばれないため、最大 1 件で済む設計だが、将来 promote を分割する場合は
  抑止策（per-cycle 1 件まで）が必要になるかも

## 残置 task と次の Issue 候補

- **Deferrable task 7**: テスト追加（本サイクル未実装）。`pp_match_cron` の cron 式
  matcher / `pp_get_st_state` の jq フィルタ / `idd-claude-labels.sh` の冪等性
  dry-run / cron-like 最小 PATH での依存解決確認の 4 系統を unit/E2E harness 化
  する次 Issue を切るのが望ましい
- **E2E dogfooding**: 本リポジトリ自身に対し `PROMOTE_PIPELINE_ENABLED=true`
  `BASE_BRANCH=develop` `PROMOTION_TARGET_BRANCH=main` で 1 サイクル動かして
  サマリログが期待値で出るかを確認する E2E が未実施。`docs(test): e2e Phase B
  dogfood` のような Issue を切って実機検証する
- **`PROMOTE_FAIL_NOTIFY_ISSUE` の per-cycle 重複抑止**: 上記「確認事項」参照
- **`pp_resolve_merge_sha` の commit 順ソート改善**: 上記「確認事項」参照
