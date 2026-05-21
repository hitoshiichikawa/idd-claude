# Implementation Notes — #17 Phase D Claude rebase + semantic 判定

> 関連: [`requirements.md`](./requirements.md) / [`design.md`](./design.md) / [`tasks.md`](./tasks.md)

## 実装サマリ

`local-watcher/bin/issue-watcher.sh` に **新規 opt-in Processor `process_auto_rebase`**
（`AUTO_REBASE_MODE=claude` 明示時のみ起動）を Phase A 系列の直後に追加した。
`needs-rebase` + approved な open PR を Claude による rebase で機械的に救済し、
変更ファイルが運用者宣言の `MECHANICAL_PATHS` allowlist に閉じている場合のみ
approve を維持して auto-merge に到達させる。それ以外は approving review を
review dismissal API で剥がして `ready-for-review` に戻し、人間レビューを誘導する。

`AUTO_REBASE_MODE` 未設定 / `off` / 不正値（`on` / `true` / `CLAUDE` 等の typo を
含む）はすべて `off` に正規化され、本機能導入前と完全に同一の挙動を保つ（NFR 1.1）。

## ファイル変更

- 新規追加:
  - `local-watcher/bin/auto-rebase-prompt.tmpl` — Claude rebase 用 prompt template
- 既存ファイル変更:
  - `local-watcher/bin/issue-watcher.sh` — Config block / logger / 関数群 /
    orchestration 配線
  - `README.md` — オプション機能一覧表に Phase D 行 + 新規節「Auto Rebase
    Processor (Phase D)」を追加
  - `repo-template/CLAUDE.md` — エージェント連携節に Phase D の存在を 1 項目追記
  - `docs/specs/17-phase-d-claude-rebase-semantic/tasks.md` — 進捗マーカー更新
    （`- [ ]` → `- [x]`、deferrable な 7.3 は据え置き）

`install.sh` は既存の `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.tmpl"
"$HOME/bin"` で `auto-rebase-prompt.tmpl` を自動配置するため、install.sh 自体の
変更は不要（File Structure Plan 通り）。

## AC Traceability

各 numeric requirement ID と、それを担保した実装箇所 / 検証手段の対応を以下に
記載する。requirements.md の AC は **本実装の `bash` 関数の境界 + grep 観測可能な
log 行** によって担保される性質のものが大半（unit test framework は本リポジトリに
存在しない / CLAUDE.md「テスト・検証」節）。

| Req ID | 担保箇所 / 検証手段 |
|---|---|
| 1.1 | `process_auto_rebase` 冒頭の `[ "$AUTO_REBASE_MODE" = "off" ] && return 0` 早期 return。`task 7.2` のスモークテストで未設定時に Phase D ログが 0 件であることを確認 |
| 1.2 | `process_auto_rebase || ar_warn ...` を orchestration に 1 行配置。`AUTO_REBASE_MODE=claude` 設定下で起動ログ `auto-rebase: サイクル開始 ...` が観測される |
| 1.3 | Config block の `case` 正規化（`claude` 以外を `off` に固定）。`task 7.2` のインライン正規化テストで `unset / "" / on / true / CLAUDE / 不正値` がすべて `off` に倒れることを確認 |
| 1.4 | 起動時 `[$(date '+%F %T')] base-branch=... merge-queue-base=... auto-rebase=${AUTO_REBASE_MODE}` 行に現在値を含めて出力 + `process_auto_rebase` 冒頭の `ar_log "サイクル開始 (mode=..., ...)"` で 2 段の観測点を確保 |
| 2.1 | `ar_fetch_candidates` の server-side filter `review:approved label:"needs-rebase"` |
| 2.2 | 同 filter の `-label:"$LABEL_FAILED"` |
| 2.3 | 同 filter の `-draft:true` + jq client filter `select(.isDraft == false)` |
| 2.4 | jq client filter `select((.headRepositoryOwner.login // "") == $owner)` |
| 2.5 | jq client filter `select(.headRefName \| test($pattern))`（既存 `MERGE_QUEUE_HEAD_PATTERN` 再利用） |
| 3.1 | Re-check → Phase A 本体 → Phase D の orchestration 直列順序による構造的排他（design.md「順序根拠」参照） |
| 3.2 | Re-check が Phase D より前に走り、MERGEABLE な PR の `needs-rebase` を除去するため、Phase D の `gh pr list --search` で当該 PR が候補に上がらない |
| 3.3 | Re-check は Phase D より前に 1 回だけ走るため、Phase D 後に Re-check は起動しない（同サイクル内での触れ直しが構造的に発生しない） |
| 3.4 | `process_auto_rebase` 末尾の `ar_log "サマリ: mechanical=N, semantic=N, failed=N, skip=N, overflow=N"` 1 行 |
| 4.1 | `ar_run_claude_rebase` の `claude --print "$prompt" --model --max-turns ... ` 起動（1 回） |
| 4.2 | `ar_run_claude_rebase` の `before_sha=$(git rev-parse HEAD)` と `after_sha=$(git rev-parse HEAD)` ログ記録 + `ar_handle_pr` の 1 行サマリログに `before=... after=...` を含める |
| 4.3 | `ar_classify_diff` の `git diff --name-only "origin/${base_ref}..origin/${head_ref}"` で base 比較の累積 diff を取得 |
| 4.4 | `ar_handle_pr` の `case` で `rebase_rc=1` を `conflict-unresolved` 種別で `ar_escalate_to_failed` に渡す + 1 件コメント投稿 |
| 4.5 | `ar_run_claude_rebase` の `timeout "$AUTO_REBASE_MAX_TURNS_SEC" claude ...` で exit 124 を `2` に変換 + `ar_handle_pr` で `timeout` 種別で escalate |
| 4.6 | `ar_run_claude_rebase` 内で `git push --force-with-lease` のみ使用（`--force` 単独は実装に登場しない） |
| 5.1 | `ar_classify_diff` で `git diff --name-only` の出力を `MECHANICAL_PATHS` 配列と照合 |
| 5.2 | 全 path 一致時のみ `echo "mechanical"`（match_count をログに含める） |
| 5.3 | 1 件 unmatch で即 break + `echo "semantic"` + 2 行目に最初の unmatched path |
| 5.4 | `ar_classify_diff` 冒頭の `[ -z "$MECHANICAL_PATHS" ]` で全件 `semantic` 早期 return |
| 5.5 | `ar_log "PR #${pr_number}: classification=mechanical paths=N"` / `ar_log "PR #${pr_number}: classification=semantic unmatch=<path>"` で出力 |
| 6.1 | `ar_apply_mechanical` は dismissal API を呼ばない（label 除去のみ） |
| 6.2 | `gh pr edit --remove-label "$LABEL_NEEDS_REBASE"` |
| 6.3 | `ar_apply_mechanical` はコメント API を呼ばない |
| 6.4 | label 除去後、次サイクルで Re-check / Phase A 本体が当該 PR を再評価可能（既存 candidate 抽出が `-label:needs-rebase` を含むため自動的に candidate から外れる） |
| 7.1 | `ar_dismiss_all_approvals` が `gh api -X PUT .../reviews/{id}/dismissals` を全 APPROVED review に対し loop |
| 7.2 | `ar_apply_semantic` 内の `gh pr edit --remove-label "$LABEL_NEEDS_REBASE"` |
| 7.3 | `ar_apply_semantic` 内の `gh pr edit --add-label "$LABEL_READY"` |
| 7.4 | `ar_apply_semantic` 内の heredoc `gh pr comment --body "..."` でコメント 1 件投稿（rebase 実施 / semantic 判定 / dismissal / 再レビュー誘導の理由を含む） |
| 7.5 | dismissal は `gh api -X PUT ...` 経由のみ。`gh pr review --request-changes` の呼出は実装に存在しない |
| 7.6 | `ar_dismiss_all_approvals` の戻り値 1 → `ar_handle_pr` の semantic 経路で `ar_escalate_to_failed "$pr_number" "dismissal-failed"` を呼出 |
| 8.1 | `ar_escalate_to_failed` は `needs-rebase` ラベルに触らない（remove-label を呼ばない） |
| 8.2 | `ar_escalate_to_failed` の `gh pr edit --add-label "$LABEL_FAILED"` |
| 8.3 | `case "$reason"` で原因種別ごとに heredoc コメントを 1 件投稿（`conflict-unresolved` / `timeout` / `push-failed` / `dismissal-failed` / `fetch-failed`） |
| 8.4 | `ar_fetch_candidates` の server-side filter `-label:"$LABEL_FAILED"` で `claude-failed` 付与済み PR を機械的に除外 |
| 9.1 | README「オプション機能一覧（opt-in）」表に Phase D 行 + 新規節「Auto Rebase Processor (Phase D)」で AUTO_REBASE_MODE 仕様を記載 |
| 9.2 | README 新規節「`MECHANICAL_PATHS` 構文」+「環境変数」表に既定 空 / 空時挙動を記載 |
| 9.3 | README 新規節「言語別設定例」で JavaScript / Python / Go / Rust の典型 lockfile pattern を表形式で列挙 + モノレポ向け `**/...` 例も追加 |
| 9.4 | dogfood 検証は task 7.3 (deferrable) として人間運用フェーズで実施予定。実装段階では `task 7.2` のスモークテストで「未設定時に Phase D ログが出ない」「`auto-rebase=off` 起動ログが出る」を観測した |
| NFR 1.1 | `AUTO_REBASE_MODE` 既定 `off` + `process_auto_rebase` 冒頭の早期 return。`task 7.2` で確認 |
| NFR 1.2 | 既存 env var（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `MERGE_QUEUE_*` / `BASE_BRANCH` 等）の既定値・正規化方式は改変せず、Phase D は新 env var のみを追加した |
| NFR 1.3 | 既存ラベル名（`needs-rebase` / `claude-failed` / `ready-for-review` 等）はそのまま既存定数 `$LABEL_NEEDS_REBASE` / `$LABEL_FAILED` / `$LABEL_READY` を再利用 |
| NFR 1.4 | cron / launchd 登録文字列は変更不要（Phase D は env var で opt-in、コマンド構造は不変） |
| NFR 1.5 | `process_auto_rebase` は失敗時も常に 0 を返し、watcher 全体の exit code には反映しない |
| NFR 2.1 | `ar_handle_pr` の 1 PR 1 行サマリログ `PR #N: classification=... before_sha=... after_sha=... action=... url=...` |
| NFR 2.2 | `process_auto_rebase` 末尾の `ar_log "サマリ: ..."` 1 行 |
| NFR 3.1 | `bash` / `gh` / `jq` / `git` / `claude` / `timeout` のみで構成。Node.js / Python は導入しない |
| NFR 3.2 | `MECHANICAL_PATHS=` 既定空（特定言語の lockfile 名を内蔵しない） |
| NFR 4.1 | `shellcheck --severity=warning local-watcher/bin/issue-watcher.sh` が CLEAN（task 7.1 で確認） |
| NFR 5.1 | `timeout "$AUTO_REBASE_MAX_TURNS_SEC"` で Claude 呼出を wrap（既定 600 秒） |
| NFR 5.2 | `(subshell + trap)` で `git rebase --abort` + `git checkout "$BASE_BRANCH"` を rollback として保証（Phase A `mq_try_rebase_pr` パターン踏襲） |
| NFR 5.3 | `git push --force-with-lease` のみ使用（実装に `--force` 単独は登場しない） |

## 主要な実装判断

### 1. `ar_classify_diff` の戻り出力を 2 行構成にした

設計時点では「`mechanical` / `semantic` の 1 語を stdout に返す」想定だったが、
`ar_apply_semantic` のコメントに「最初の allowlist 外パス」を含めたい（Req 7.4 の
理由明示）ため、戻り出力を:

- 1 行目: `mechanical` or `semantic`
- 2 行目: semantic の場合のみ最初の unmatched path（取得できれば）

の 2 行構成とした。`ar_handle_pr` は `sed -n '1p'` / `sed -n '2p'` で受け取る。
hidden marker や別ファイル経由ではなく **stdout 単一チャネル** で完結させ、関数
境界を維持した。

### 2. `before == after && base が祖先` を skip 扱い (exit 5) にした

`ar_run_claude_rebase` は Claude が rebase を完了しても before == after に
なるケース（既に base が head の祖先で rebase が no-op になる）を考慮し、exit 5
を「rebase 不要 = skip」用 sentinel として導入した。これにより:

- Phase D が Re-check の前に走ってしまった場合の重複処理を回避できる
- 次サイクルで Re-check が当該 PR を MERGEABLE 判定して `needs-rebase` を除去する
  自然な経路に委ねられる

### 3. `MECHANICAL_PATHS` の構文をカンマ区切り bash glob で確定

design.md の Open Questions Q3 通り、改行区切りは cron / launchd の env 渡しで
扱いにくいためカンマ区切りを採用。正規表現ではなく bash の `[[ $path ==
$pattern ]]` glob を使い、`*` / `?` / `[abc]` / `**` の標準構文に従う。
`shellcheck` の `SC2053`（変数を含む glob 比較）は意図的なので局所無効化した。

### 4. dismissal 422 を skip 扱いにした

`ar_dismiss_all_approvals` で 1 件の review が既に dismissed の場合、API は
HTTP 422 を返す。これを「全体失敗」扱いにすると後続の review が dismiss されない
ため、422 のみ skip 扱い（log 出力 + 次の review へ進む）として **冪等性** を
担保した。422 以外の non-zero は全体失敗扱いで `dismissal-failed` 経路に流れる。

### 5. ar_apply_semantic の戻り値 2（部分失敗）を semantic 扱いで継続

dismissal は成功したが、その後の `gh pr edit --remove-label` / `--add-label` /
`gh pr comment` が失敗した場合、approve は既に dismiss されており「semantic
判定として approve 剥がしが達成された」状態。これを `claude-failed` 扱いにすると
PR が `needs-rebase` + `claude-failed` で人間にエスカレートされるが、人間視点では
「semantic として処理されたが部分的に label 更新が漏れただけ」という状態の方が
正確。よって、戻り値 2 は WARN を出した上で **semantic として集計する**（再 reviewer
通知が漏れる程度の影響に留める）方針とした。

## 確認事項（design.md / requirements.md 矛盾は無し）

- requirements.md / design.md / tasks.md と矛盾する記述は実装中に発見しなかった。
  設計通りの実装で全 AC をカバー
- design.md の Open Questions（Q1〜Q4）はすべて design.md 内で確定済みのため、
  本実装は確定回答に従う（順序 = Re-check → Phase A → Phase D / Claude 自己判定
  方式 = Non-Goals / 構文 = カンマ区切り bash glob / Branch protection との
  相互作用 = README 注記のみ）

## 派生タスク候補（次の Issue として切り出すべきもの）

実装中に気づいた小さな改善余地。本 Issue では実装しない:

- **dismissal の事前可能性チェック**: `gh api .../collaborators/{user}/permission`
  で watcher token の権限を起動時に確認し、admin / maintain 権限が無い場合に
  Phase D を起動時から no-op として WARN を出す。現状は dismissal 失敗時に初めて
  検知する（事前検知の方が dogfood で運用ミスを早期発見できる）
- **mechanical 判定後の auto-merge 観測**: Phase D が `needs-rebase` を除去した
  後、当該 PR が auto-merge に到達したかどうかを観測する nice-to-have ログ追加
  （別 Processor として実装するか、Merge Queue Re-check 経由で観測する）
- **Phase D の dry-run モード**: `AUTO_REBASE_MODE=dry-run` で実 API 呼出をせず
  classification ログのみ出す機能。新規環境への試験導入に便利

## 検証コマンド

本リポジトリには unit test framework が無いため、検証は以下の組み合わせ:

```bash
# 静的解析（NFR 4.1）
shellcheck --severity=warning local-watcher/bin/issue-watcher.sh

# 全 severity（info 含む。pre-existing な SC2317 / SC2012 は本機能由来ではない）
shellcheck local-watcher/bin/issue-watcher.sh

# bash 構文チェック
bash -n local-watcher/bin/issue-watcher.sh

# cron-like 最小 PATH での依存解決（task 7.2）
env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"; for c in claude gh jq flock git timeout; do command -v "$c"; done'

# AUTO_REBASE_MODE 未設定での後方互換スモークテスト（task 7.2）
# → 起動ログに `auto-rebase=off` が出ること、Phase D ログ（`auto-rebase: サイクル開始 ...`）が出ないこと
```

## 7.3 dogfood（deferrable / 人間運用フェーズに委ねる）

`tasks.md` の 7.3（`- [ ]*` deferrable）は idd-claude self repo に
`AUTO_REBASE_MODE=claude` / `MECHANICAL_PATHS=package-lock.json` を設定した
本番 cron / launchd での E2E 観測を要求する。これは本リポジトリの実際の PR ライフ
サイクル（lockfile-only conflict / コード conflict 混在）に依存するため、merge
後の人間運用フェーズで実施し、結果を本 impl-notes.md にフォローアップ追記するか、
別 Issue（観測結果 + 微調整）を起票する想定。
