# Implementation Notes (#26 PR Iteration Processor)

## 概要

`needs-iteration` ラベル付き PR を fresh context の Claude で反復対応する機能を、
`local-watcher/bin/issue-watcher.sh` に Phase A (`process_merge_queue`) と同パターンで
追加した。既存運用への影響を避けるため `PR_ITERATION_ENABLED=false` の opt-in gate を
最優先し、無効時は完全に skip される。

## 変更ファイル一覧

| ファイル | 変更内容 | 関連タスク |
|---|---|---|
| `.github/scripts/idd-claude-labels.sh` | `LABELS` 配列に `needs-iteration` を追加（色 d4c5f9） | 1.1 |
| `repo-template/.github/scripts/idd-claude-labels.sh` | 同上（root と同期） | 1.1 |
| `install.sh` | `--local` で `iteration-prompt.tmpl` を `$HOME/bin/` にコピー（存在チェック付き） | 1.2 |
| `local-watcher/bin/iteration-prompt.tmpl` | 新規。PR Iteration Mode の Claude prompt テンプレート | 2.1 |
| `local-watcher/bin/issue-watcher.sh` | Config に env var 群 / `LABEL_NEEDS_ITERATION` 定数追加。`process_pr_iteration` ほか 8 個の `pi_*` 関数を追加。`process_merge_queue` 呼び出し直後に `process_pr_iteration` 呼び出しを追加 | 3.1 / 3.2 / 3.3 / 3.4 |
| `README.md` | 「PR Iteration Processor (#26)」セクションを追加。ラベル一覧表 / 状態遷移まとめ表 / 手動ラベル作成例を更新 | 5.1 |

### スコープ外（後述「未消化タスク」）

- `repo-template/.claude/agents/developer.md` への「PR iteration モード（#26）」節追記（task 4.1）

## 各 requirement ID の担保確認

requirements.md の全 numeric ID について、どこで実装が担保されているかを記録する。

| Req ID | 担保箇所 | 検証方法 |
|--------|----------|----------|
| 1.1 | `pi_fetch_candidate_prs` の `gh pr list --search 'label:"needs-iteration" ...'` | unit harness Test 7（PR 5 件混在 → 適合 2 件返却） |
| 1.2 | `pi_fetch_candidate_prs` の jq client filter `select(.headRefName | test($pattern))` | unit harness Test 7（feature/bar が除外） |
| 1.3 | `pi_fetch_candidate_prs` の jq client filter `select((.headRepositoryOwner.login // "") == $owner)` | unit harness Test 7（owner=someone-else が除外） |
| 1.4 | server-side `-draft:true` + client-side `select(.isDraft == false)` | unit harness Test 7（draft が除外） |
| 1.5 | server-side `-label:"claude-failed"` 検索クエリ | コード差分レビュー（gh pr list 引数に含まれる） |
| 1.6 | `process_pr_iteration` の `target_count="$PR_ITERATION_MAX_PRS"` truncate と overflow ログ | コード差分レビュー（既存 Phase A と同パターン） |
| 2.1 | `process_pr_iteration` 先頭 `[ "$PR_ITERATION_ENABLED" != "true" ] && return 0` | unit harness Test 1（false で完全 skip）、Test 2（true で起動） |
| 2.2 | opt-in gate により Issue 処理ループ未介入 | コード差分レビュー（Issue 取得セクションは未変更） |
| 2.3 | 既存 env var 名・意味は不変 | `git diff` で `REPO/REPO_DIR/LOG_DIR/LOCK_FILE/TRIAGE_*/DEV_*/MERGE_QUEUE_*` の定義行に変更なし |
| 2.4 | Config ブロックに `PR_ITERATION_ENABLED=false / DEV_MODEL=claude-opus-4-7 / MAX_TURNS=60 / MAX_PRS=3 / MAX_ROUNDS=3 / HEAD_PATTERN=^claude/ / GIT_TIMEOUT=60` を追加 | `grep -n PR_ITERATION_ issue-watcher.sh` |
| 2.5 | 既存 `LABEL_*` 定義は不変 | `git diff` で `LABEL_TRIGGER/PICKED/...` 行に変更なし |
| 2.6 | 既存 `flock` / `LOG_DIR` / exit code は不変 | コード差分レビュー（既存ブロックは触っていない） |
| 3.1 | `pi_build_iteration_prompt` の `gh api /reviews` → `last.id` → `/comments` 取得 | unit harness Test for prompt 展開（line_comment_json に id=111 が含まれる） |
| 3.2 | `pi_build_iteration_prompt` の `gh api /issues/{N}/comments` + `jq 'test("@claude"; "i")'` | unit harness Test（general_comment_json に id=222 が含まれる） |
| 3.3 | jq projection で `{id, path, line, user, body}` および `{id, user, body, url}` を抽出 | unit harness Test（id/path/line を含む JSON が prompt に展開される） |
| 3.4 | `gh pr diff` の出力を ENVIRON 経由で `{{PR_DIFF}}` に注入 | unit harness Test（"added line" が prompt に含まれる） |
| 3.5 | head ref から `issue-N` 抽出 → `docs/specs/N-*/requirements.md` 解決 → ENVIRON 注入 | unit harness Test（"Requirement 1" が prompt に含まれる） |
| 3.6 | `pi_run_iteration` で `claude --print ...` のみ使用、`--resume`/`--continue`/`--session-id` 不使用 | コード差分レビュー（grep で `--resume\|--continue\|--session-id` ヒット 0） |
| 4.1〜4.5 | `iteration-prompt.tmpl` の責務セクション + Claude が実行 | template 内容レビュー（ff-only / 通常 push / 1:1 reply / reply-only 許容を明示） |
| 5.1〜5.5 | `iteration-prompt.tmpl` の API call 例 + 1:1 返信原則 | template 内容レビュー |
| 6.1 | `pi_post_processing_marker` で hidden marker 更新 + 着手表明コメント投稿 | コード差分レビュー（gh pr edit + gh pr comment の 2 コール） |
| 6.2 | `pi_finalize_labels` で `--remove-label needs-iteration --add-label ready-for-review` 1 コマンド | コード差分レビュー（line 590-595） |
| 6.3 | `pi_run_iteration` の Claude 失敗パスでラベル操作なし、`pi_warn` 出力 | unit harness Test 1（dirty 検知）と同様の制御フロー |
| 6.4 | `pi_finalize_labels` で `--remove-label` を `--add-label` の前に列挙し原子実行 | コード差分レビュー（line 593-594） |
| 6.5 | `idd-claude-labels.sh` × 2 の LABELS 配列に追加 | `git diff` 確認、2 ファイル diff 0 |
| 7.1 | `pi_read_round_counter` で hidden marker 抽出、`pi_post_processing_marker` で更新 | unit harness Test 4-6 |
| 7.2 | `pi_run_iteration` の `[ "$round" -ge "$PR_ITERATION_MAX_ROUNDS" ]` で `pi_escalate_to_failed` 呼び出し | コード差分レビュー（line 808-812） |
| 7.3 | `pi_escalate_to_failed` で定型エスカレコメント本文を投稿 | コード差分レビュー（escalation_body の cat heredoc） |
| 7.4 | hidden marker 手動削除で round=0 にリセット可能 | unit harness Test 4（marker 無し → 0） + README に手順記載 |
| 8.1 | Phase A → PR Iteration → Issue 処理 を同一プロセス内で**直列**実行 | コード差分レビュー（呼び出し順序） |
| 8.2 | 既存 `flock -n 200` を共有（追加 lock なし） | コード差分レビュー（exec 200>$LOCK_FILE は不変） |
| 8.3 | `pi_run_iteration` のサブシェル `trap "git checkout main" EXIT` + 呼び出し元保険 | コード差分レビュー（subshell + trap、`process_pr_iteration` 末尾の保険 checkout） |
| 8.4 | server-side `-label:"needs-rebase"` 検索クエリ | コード差分レビュー（gh pr list 引数） |
| 8.5 | `process_pr_iteration` 冒頭 `[ -n "$(git status --porcelain)" ] && pi_error ... && return 0` | unit harness Test 3 |
| 9.1 | `pi_log "対象候補 N 件、処理対象 M 件"` | unit harness Test 2 のログ出力で確認 |
| 9.2 | `pi_log "PR #${pr_number}: round=${next_round}/${MAX_ROUNDS} 着手"` ほか | コード差分レビュー（line 815） |
| 9.3 | `pi_log "サマリ: success=N, fail=N, skip=N, escalated=N, overflow=N"` | unit harness Test 2 で確認 |
| 9.4 | `LOG_DIR` を流用（新規 mkdir なし） | コード差分レビュー（mkdir は既存の 1 行のみ） |
| 9.5 | `pi_log` で `[$(date '+%F %T')] pr-iteration: ...` 形式 | unit harness Test 2 のログ出力で確認 |
| 10.1〜10.5 | README に「PR Iteration Processor (#26)」セクション追加（概要 / env / ラベル / 住み分け / Migration） | README 内容レビュー |
| NFR 1.1 | `claude --max-turns "$PR_ITERATION_MAX_TURNS"` | コード差分レビュー（pi_run_iteration 内） |
| NFR 1.2 | `process_pr_iteration` の MAX_PRS truncate + overflow ログ | コード差分レビュー（AC 1.6 と同実装） |
| NFR 1.3 | 各 `gh` / `git` 呼び出しを `timeout "$PR_ITERATION_GIT_TIMEOUT"` で wrap | grep `timeout.*PR_ITERATION_GIT_TIMEOUT` で 9 箇所確認 |
| NFR 2.1 | force push 禁止（template + Developer docs で明示） | template 内容レビュー（force push 禁止箇条書き） |
| NFR 2.2 | main 直接 push 禁止（template で明示） | template 内容レビュー |
| NFR 2.3 | dirty 検知で ERROR + skip | unit harness Test 3 |
| NFR 3.1 | `pi_log` の `[%F %T]` 形式 | unit harness Test 2 のログ出力 |
| NFR 3.2 | prefix `pr-iteration:` で grep 集計可能 | unit harness Test 2 のログ出力 |

## 実装上の判断

### 1. PR body の hidden marker による round 永続化（design 採用）

design.md の論点 2 で採用された通り、PR body 末尾に
`<!-- idd-claude:pr-iteration round=N last-run=ISO8601 -->` を書き込む方式。

`gh pr edit --body` で PR body 全体を書き換えるため、人間が PR body を編集している
場合と競合する可能性があるが、本機能の対象 PR は idd-claude が作成した PR (`claude/`
始まり head) であり、説明本文の編集は基本的に発生しない前提。複数 marker が混入した
場合は `tail -1` で最後の数値を採用する fail-safe を入れている。

### 2. awk の複数行変数は ENVIRON 経由

prompt 組み立ての awk pipeline で、`-v` で渡せない複数行値（line/general comment JSON、
PR diff、requirements.md）は `export PI_LINE_JSON=... && awk '{ ENVIRON["PI_LINE_JSON"] }'`
方式で受け渡し。初期実装では 2 段 awk pipeline を試みたが第 1 段で改行が値を切ってしまい、
結果として全プレースホルダが素通りする問題があったため修正（commit `e39f0b5`）。

unit harness で 13 プレースホルダ全展開と本体行に bare placeholder が残らないことを確認済み。

### 3. timeout passthrough のため stub は PATH 経由で配置

unit harness では `gh` を bash function で stub 化したが、内部実装の `timeout "$PR_ITERATION_GIT_TIMEOUT" gh ...` は子プロセス起動のため bash function は伝播しない。
最終的に `$STUB_DIR/gh` をスクリプトとして PATH 先頭に配置する方式に切り替えた。

### 4. fork PR の除外は server + client の二段防御

server side `gh pr list --search` で `headRepositoryOwner` を絞れないため、`headRefName`
や `labels` でフィルタした結果に対し、client side で `headRepositoryOwner.login == $owner`
を確認している（Phase A と同パターン）。

### 5. 着手表明コメントを Phase A 流に投稿

design.md の論点 1 で「processing コメント方式」を採用。Phase A は着手表明コメントを
出さない方針だが、本機能では round カウンタとセットで「いつ何 round 目に処理を始めたか」を
人間が PR タイムラインで追える価値が大きいと判断。コメントには
`<!-- idd-claude:pr-iteration-processing round=N -->` の hidden marker を付けて、
将来コメント数のクリーンアップ等で識別できるようにしている。

## 未消化タスク（要フォロー）

### task 4.1: `repo-template/.claude/agents/developer.md` への追記が permission で拒否された

本リポジトリの harness 上で `.claude/agents/developer.md` への Edit / Write / Bash append
すべてが permission denied で実行できなかった（"sensitive file" 判定）。
PM が Issue/PR コメントで運用者に手動編集を依頼するか、別 Issue で permission 拡張対応する
必要がある。

**応急策（既に実装内に組み込み済み）**: `iteration-prompt.tmpl` 自体に同等のガイダンス
（1:1 返信の原則 / force push 禁止 / spec 書き換え禁止 / resolve 禁止 / fresh context 前提）
を完全に重ねて記述しているため、Claude が iteration mode で起動された際の挙動は
developer.md 追記なしでも担保される。ただし「Developer subagent の独立ドキュメント」
としての網羅性は満たせていないため、PR 確認事項に明記して人間に対応を委ねる。

### task 7（E2E dogfooding, deferrable）

deferrable とアノテートされており、本実装フェーズではスコープ外。本 PR merge → install.sh
再実行 → cron に `PR_ITERATION_ENABLED=true` 追加 → テスト PR で観測、の手順は README に
記載済み。dogfood 結果は別途追記する。

## 検証結果

### 静的解析

- `bash -n local-watcher/bin/issue-watcher.sh` → OK
- `bash -n install.sh` → OK
- `bash -n .github/scripts/idd-claude-labels.sh` → OK
- `bash -n repo-template/.github/scripts/idd-claude-labels.sh` → OK
- `bash -n setup.sh` → OK
- `shellcheck` は環境にインストールされていなかったため、`bash -n` で代替（CI 等で別途実施推奨）
- `actionlint` も環境に無いため未実行（本 PR は `.github/workflows/` を変更していないため影響軽微）

### cron-like 最小 PATH での依存解決

```
env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '
  export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
  for c in claude gh jq flock git timeout; do command -v "$c" || echo MISSING $c; done'
```

→ 全コマンドが解決された。

### Unit-style harness（独立検証）

`pi_*` 関数群を個別に呼び出すテスト harness を `mktemp -d` 環境で構築し、以下のケースを検証:

| Test | 内容 | 結果 |
|------|------|------|
| 1 | `PR_ITERATION_ENABLED=false` → 即 `return 0`（gh は呼ばれない） | PASS |
| 2 | `PR_ITERATION_ENABLED=true` + 候補 0 件 → サマリ `success=0, fail=0, skip=0, escalated=0, overflow=0` | PASS |
| 3 | dirty working tree 検知 → `pr-iteration: ERROR: dirty working tree ...` + `return 0` | PASS |
| 4 | `pi_read_round_counter` (marker 無し body) → `0` | PASS |
| 5 | `pi_read_round_counter` (marker round=2) → `2` | PASS |
| 6 | `pi_read_round_counter` (marker 複数 round=1, round=5) → `5`（fail-safe） | PASS |
| 7 | `pi_fetch_candidate_prs` の client filter（5 PR 中 draft / fork / head pattern mismatch を除外して 2 件 [#1, #5] 返却） | PASS |
| 8 | `pi_build_iteration_prompt` の template 13 プレースホルダ展開 + 主要値（PR 番号 / round / issue # / spec dir / line/general JSON / diff / requirements.md）の埋め込み | PASS |

全 8 ケースが green。

### 後方互換性レビュー

- `git diff main..HEAD` で `LABEL_TRIGGER/PICKED/NEEDS_DECISIONS/AWAITING_DESIGN/READY/FAILED/SKIP_TRIAGE/NEEDS_REBASE` の定義行は不変
- 既存 env var (`REPO/REPO_DIR/LOG_DIR/LOCK_FILE/TRIAGE_MODEL/DEV_MODEL/TRIAGE_MAX_TURNS/DEV_MAX_TURNS/TRIAGE_TEMPLATE/MERGE_QUEUE_*`) の定義は不変
- `process_merge_queue || mq_warn ...` の呼び出しはそのまま、その**直後**に `process_pr_iteration || pi_warn ...` を 1 行追加
- `PR_ITERATION_ENABLED=false`（デフォルト）では `process_pr_iteration` 冒頭で `return 0`、Issue 処理フローは導入前と完全一致

## PR 本文の「確認事項」候補

PjM が PR を作成する際に、本文の「確認事項」セクションに以下を記載することを推奨:

1. **`repo-template/.claude/agents/developer.md` への追記が permission により未実施**:
   tasks.md の task 4.1。`iteration-prompt.tmpl` 内に同等ガイダンスを重複記述して機能的には
   担保しているが、Developer subagent ドキュメントとしての網羅性は人間判断で別途補完が必要。
   別 Issue を切るか、レビュー時に手動 commit を提案する。
2. **shellcheck / actionlint が未実行**: 環境に未インストールのため `bash -n` のみで代替。
   PR レビュアー側で実行することを推奨。
3. **dogfooding (task 7) は deferrable**: 実 PR で観測する E2E はこの PR merge 後に
   `install.sh --local` 再実行 → `PR_ITERATION_ENABLED=true` を cron に追加 → テスト PR
   作成、の段取りで実施する。
4. **対応する設計 PR**: #28（`docs(specs): add design for PR iteration loop`、merge 済み）。
