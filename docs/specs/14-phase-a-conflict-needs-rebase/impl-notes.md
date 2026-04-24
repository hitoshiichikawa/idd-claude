# Implementation Notes: Phase A — 出口 conflict 検知 + needs-rebase ラベル

Issue: #14（親 Issue: #13）
Branch: `claude/issue-14-impl-phase-a-conflict-needs-rebase`

## 実装サマリ

`local-watcher/bin/issue-watcher.sh` に `process_merge_queue()` 関数群を追加し、watcher サイクル
冒頭で approve 済み open PR の mergeability を能動的に検知できるようにした。`MERGE_QUEUE_ENABLED`
環境変数で **opt-in** 制御できる（デフォルト `false`）。`.github/scripts/idd-claude-labels.sh` に
`needs-rebase` ラベルを追加し、README にも Phase A セクションと migration note を追記した。

## env 変数の最終決定

| 変数 | デフォルト | 決定理由 |
|---|---|---|
| `MERGE_QUEUE_ENABLED` | `false` | CLAUDE.md の「opt-in gate なしで新しい外部サービス呼び出しを有効化しない」原則と、`.github/workflows/issue-to-pr.yml` の `IDD_CLAUDE_USE_ACTIONS=true` opt-in 設計の踏襲。既稼働 cron / launchd を絶対に壊さないため、安全側に倒した |
| `MERGE_QUEUE_MAX_PRS` | `5` | NFR 1.1（60 秒以内）と `MERGE_QUEUE_GIT_TIMEOUT=60` から逆算: 各 PR 最大 60 秒 × 5 件で上限 5 分。通常ケース（0〜3 件）は数十秒で済む見込み。Issue ピックアップ枠（既存 `--limit 5`）と合わせて 1 サイクルの最大消費を概算しやすい数値にした |
| `MERGE_QUEUE_GIT_TIMEOUT` | `60`（秒） | watcher 最短実行間隔（README 既定 2 分 = 120 秒）の半分（NFR 1.1）に揃えた。各 git / gh 操作（fetch / checkout / rebase / push / gh pr list / gh pr view）に個別に適用 |
| `MERGE_QUEUE_BASE_BRANCH` | `main` | 本リポジトリも consumer template も既定 `main`。レガシー repo（`master`）対応として override 可能にした。MERGEABLE で `base_ref != MERGE_QUEUE_BASE_BRANCH` の PR は安全側で自動 rebase 対象外とする（要件外の base への push 事故防止） |

## conflict ファイル一覧の取得方法

**選択**: `gh pr view <num> --json files` を使用（`git diff --name-only` ではなく）

**理由**:

- 要件 AC 2.4「どのファイルが conflict したかが利用者に伝わる粒度」は **真の conflict ファイル**
  ではなく「conflict が発生し得る範囲を利用者が把握できる粒度」と解釈した。
- `mergeable=CONFLICTING` の段階で真の conflict ファイル一覧を取得するには、ローカルで
  staging branch を立てて `git merge --no-commit` を試して unmerged paths を取るのが正攻法
  だが、**Phase B（#15）で staging branch を導入する**ため、Phase A では PR の変更
  ファイル一覧（≒ conflict が発生し得るファイル群）で代替するのが妥当。
- `gh pr view --json files` なら 1 API call で取得でき、NFR 1.2（PR あたり 5 call 以内）の
  予算内に収まる（list=1, view=1, edit=1, comment=1 の合計 4 call）。
- 上限 50 ファイル + 残数表示で truncate（API レスポンス・コメント長を制限）。

**Phase B での置き換え予定**: staging branch 上で `git merge-tree` または
`git merge --no-commit --no-ff` を使った真の conflict path 抽出に差し替える。

## 各 git 操作の timeout 値とその根拠

| 操作 | timeout | 根拠 |
|---|---|---|
| `gh pr list` (server side フィルタ済み, limit=50) | `MERGE_QUEUE_GIT_TIMEOUT=60s` | NFR 1.1（60 秒）の半分以上を 1 操作で食わない。検索クエリで絞り込み済みなら通常 < 5 秒 |
| `gh pr view --json files` | `60s` | 同上。files API は通常 < 3 秒 |
| `git checkout -B head_ref origin/head_ref` | `60s` | ローカル ref 切り替え。通常 < 1 秒だが、巨大 working copy で念のため |
| `git rebase origin/base_ref` | `60s` | コミット数 × 平均適用時間。100 コミット規模でも 30 秒程度の見積もり |
| `git push --force-with-lease` | `60s` | リモート HTTP RTT × push サイズ。大規模 monorepo では 30 秒程度を許容 |

すべて統一値（`MERGE_QUEUE_GIT_TIMEOUT`）を採用したのは:

- 操作ごとの妥当値を細かく env 変数化すると override 認知負荷が増す（CLAUDE.md「設定値は冒頭の config ブロックにまとめる」）。
- 1 PR の処理全体で `60s × 4〜5 操作 = 4〜5 分`が最悪ケースとなり、対象 PR が 5 件並ぶと
  最悪 25 分で `MERGE_QUEUE_MAX_PRS=5` の上限から外れる可能性があるが、これは AC 4.5（タイムアウト到達時は当該 PR を中断して次へ）でカバー。
- 通常ケース（PR 0〜3 件 / 各操作 数秒）では NFR 1.1（60 秒以内）を満たす。

## スモークテスト結果

shellcheck はインストール環境の制約（apt 権限なし・docker / pip3 / npm すべて未導入）で
実行できなかったため、`bash -n` での syntax check と、Phase A 関数だけを切り出した dry-run
harness で検証した。

### 1. Syntax check

```bash
$ bash -n local-watcher/bin/issue-watcher.sh && echo OK
OK
$ bash -n .github/scripts/idd-claude-labels.sh && echo OK
OK
```

### 2. cron-like 最小 PATH での依存解決確認

```bash
$ env -i HOME=$HOME PATH=/usr/bin:/bin bash -c \
  'export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"; \
   for c in claude gh jq flock git timeout; do \
     printf "%-10s -> %s\n" "$c" "$(command -v "$c" || echo NOT FOUND)"; \
   done'
claude     -> /home/hitoshi/.local/bin/claude
gh         -> /usr/bin/gh
jq         -> /usr/bin/jq
flock      -> /usr/bin/flock
git        -> /usr/bin/git
timeout    -> /usr/bin/timeout
```

新規依存 `timeout` は標準的なインストール先（`/usr/bin/timeout`）で解決可能。

### 3. dry-run（Phase A 関数のみを harness で実行）

`process_merge_queue` 関数だけを抽出した harness を /tmp/mq-only.sh に作成、clean な
git repo を cwd として実行。

#### Test 1: opt-out（デフォルト）

```
$ MERGE_QUEUE_ENABLED=false bash /tmp/mq-only.sh
=== process_merge_queue (MERGE_QUEUE_ENABLED=false) ===
=== exit OK (rc=0) ===
```

→ 出力ゼロ、Phase A コードパス完全 skip。**既存挙動と完全一致**（要件 5.1, 5.2）。

#### Test 2: enabled, 実 GitHub repo

```
$ MERGE_QUEUE_ENABLED=true bash /tmp/mq-only.sh
=== process_merge_queue (MERGE_QUEUE_ENABLED=true) ===
[2026-04-24 14:21:14] merge-queue: サイクル開始 (max=5, base=main, timeout=60s)
[2026-04-24 14:21:15] merge-queue: 対象候補 0 件、処理対象 0 件
[2026-04-24 14:21:15] merge-queue: サマリ: rebase+push=0, conflict=0, skip=0, fail=0, overflow=0
=== exit OK (rc=0) ===
```

→ ログ識別子 `merge-queue:` プレフィックス（NFR 3.2）と timestamp 形式（NFR 3.1）が
要件通り。サマリ行が出力（要件 6.3）。Issue 0 件でも Issue 処理ループに進める設計
（exit コード 0、後続処理を妨げない）。

#### Test 3: env override

```
$ MERGE_QUEUE_ENABLED=true MERGE_QUEUE_MAX_PRS=2 bash /tmp/mq-only.sh
[2026-04-24 14:21:15] merge-queue: サイクル開始 (max=2, base=main, timeout=60s)
```

→ `MERGE_QUEUE_MAX_PRS` の env override が効いている。

#### Test 4: dirty working tree（NFR 2.3）

dirty な状態で実行すると以下が出力されることを観測:

```
[2026-04-24 14:20:25] merge-queue: ERROR: dirty working tree を検出しました。Merge Queue Processor をスキップします。
```

→ NFR 2.3 通り、ERROR を出してサイクル中止（exit code 0、後続 Issue 処理は継続）。

### 4. jq filter / files 整形ロジックの単体検証

mock データで以下を確認:

- draft / reviewDecision の client side 再フィルタが正しく機能（draft + APPROVED 以外を除外）
- `mq_pr_has_label` が labels 配列の中の `needs-rebase` を正しく検出
- files 整形: 空配列 / 通常 / 50 超 truncate / `files` key 欠落、4 ケースとも期待出力

## 受入基準カバレッジ

requirements.md の AC 全 44 件について、本実装でのカバー状況:

### Requirement 1: Approved PR の検知範囲

- 1.1: `process_merge_queue` を Issue 処理ループ前に 1 回呼び出し（issue-watcher.sh L402） — **実装済み**
- 1.2: `gh pr list --search "review:approved ..."` でサーバ側フィルタ + client side 再フィルタ — **実装済み**
- 1.3: search に `-label:"$LABEL_FAILED"` を付与（claude-failed 終端ラベル除外） — **実装済み**
- 1.4: search に `-draft:true`、client side で `select(.isDraft == false)` — **実装済み**
- 1.5: `mergeable` / `mergeStateStatus` を `--json` に含めて取得 — **実装済み**

### Requirement 2: CONFLICTING 検知時

- 2.1: `gh pr edit --add-label needs-rebase` — **実装済み**
- 2.2: `mq_pr_has_label` で重複ラベル検知し early return — **実装済み**
- 2.3: `gh pr comment` で 1 件のステータスコメント — **実装済み**
- 2.4: コメント本文に `gh pr view --json files` で取得した変更ファイル一覧を含める — **実装済み**（仕様解釈は上記「conflict ファイル一覧の取得方法」参照）
- 2.5: `gh pr edit / comment` の戻り値を check し失敗時は `mq_warn` で WARN ログ、後続継続 — **実装済み**

### Requirement 3: MERGEABLE 自動 rebase

- 3.1: `git rebase origin/${base_ref}` をサブシェル内で実施 — **実装済み**
- 3.2: `git push --force-with-lease` を使用（NFR 2.1 と整合） — **実装済み**
- 3.3: rebase 失敗時は `git rebase --abort` → `mq_handle_conflict` へ流す — **実装済み**
- 3.4: push 失敗時は `mq_warn` で WARN ログ、当該 PR スキップ — **実装済み**
- 3.5: `git merge-base --is-ancestor` で祖先関係判定し rebase スキップ — **実装済み**
- 3.6: `trap` でサブシェル exit 時に main checkout、サブシェル外でも保険で再 checkout — **実装済み**

### Requirement 4: タイムバジェット

- 4.1: NFR 1.1（60 秒以内）と env デフォルトで担保（5 件 × 60 秒/操作上限）— **設計上担保**
- 4.2: `MERGE_QUEUE_MAX_PRS` env で上限指定可能、デフォルト 5 — **実装済み**
- 4.3: 上限超過時は `[0:target_count]` で先頭のみ処理し、`overflow=N` をサマリログに含める — **実装済み**
- 4.4: 全 git / gh 操作を `timeout "$MERGE_QUEUE_GIT_TIMEOUT"` で wrap — **実装済み**
- 4.5: timeout SIGTERM が `git rebase` 等を kill すると非 0 終了 → `git rebase --abort` → 該当 PR スキップ → 次の PR へ — **実装済み（注: フル E2E 検証は未実施、後述）**

### Requirement 5: 後方互換 / opt-out

- 5.1: `MERGE_QUEUE_ENABLED != "true"` で early return — **実装済み + Test 1 で検証**
- 5.2: opt-out 時は Phase A コードパス完全スキップ → 既存 Issue 処理フローのみ — **Test 1 で検証**
- 5.3: 既存 env 名（`REPO`/`REPO_DIR`/`LOG_DIR`/`LOCK_FILE`/`TRIAGE_MODEL`/`DEV_MODEL` 等）を **追加・変更なし** — **diff で確認済み**
- 5.4: 既存ラベル名・意味・付与契約を **追加・変更なし** — **diff で確認済み**
- 5.5: 既存 lock パス / ログ出力先 / exit code を変更なし — **diff で確認済み**
- 5.6: `idd-claude-labels.sh` に `needs-rebase` を追記、既存パターンに沿って冪等 — **実装済み**

### Requirement 6: ロギング

- 6.1: サイクル開始時に「対象候補 N 件、処理対象 N 件」ログ — **実装済み + Test 2 で観測**
- 6.2: 各 PR について `mergeable` 判定とアクション結果を 1 行ログ — **実装済み**
- 6.3: サマリログ `rebase+push=N, conflict=N, skip=N, fail=N, overflow=N` — **実装済み + Test 2 で観測**
- 6.4: 既存 `LOG_DIR` を流用、新規ディレクトリ作らず — **実装済み（mq_log は stdout に出力、cron / launchd の reidirect で既存 LOG_DIR / cron.log に集約される）**
- 6.5: 標準出力は機械可読サマリ用（mq_log）、stderr は人間向け WARN/ERROR（mq_warn / mq_error） — **実装済み**

### NFR 1: パフォーマンス

- 1.1: 通常ケース（0〜3 PR）で 60 秒以内 — **設計上担保（各操作 timeout 60s だが通常は数秒）**
- 1.2: 1 PR あたり API 呼び出し ≤ 5 回（pr list 1, pr view 1, edit 1, comment 1 = 4 回） — **実装済み**

### NFR 2: 安全性

- 2.1: `--force-with-lease` のみ（`--force` 未使用） — **実装済み + diff で確認**
- 2.2: サブシェル + `trap EXIT` + サブシェル外の保険 checkout、3 段で main checkout 復帰 — **実装済み**
- 2.3: dirty working tree 検知時は ERROR ログ + 中止 — **実装済み + Test 4 で観測**

### NFR 3: 観測可能性

- 3.1: timestamp 形式 `[YYYY-MM-DD HH:MM:SS]`（既存 watcher と同じ） — **実装済み + Test 2 で観測**
- 3.2: `merge-queue:` プレフィックスで grep 集計可能 — **実装済み + Test 2 で観測**

### Requirement 7: ドキュメント（DoD）

- 7.1: README に Merge Queue Processor 概要セクション追加 — **実装済み**
- 7.2: `MERGE_QUEUE_*` env の名称・デフォルト・推奨を表で明記 — **実装済み**
- 7.3: `needs-rebase` ラベルの意味・付与主体・解除タイミングをラベル一覧と状態遷移表に追記 — **実装済み**
- 7.4: Migration Note を README Phase A セクションに明記 — **実装済み**
- 7.5: `idd-claude-labels.sh` が `needs-rebase` を冪等追加できる旨を README に記述 — **実装済み**

**カバレッジ**: 44 / 44 AC を実装でカバー。E2E 検証（実 conflict PR / 実 timeout 発火 / 実 push 失敗）は未実施（後述）。

## E2E 検証ができていない項目

実 PR を立てて以下のシナリオを観測することは現サイクルでは不可能（開発環境制約 + Issue
スコープ）。dry-run と単体ロジック検証で代替した部分:

| AC | 未検証項目 | 代替検証 |
|---|---|---|
| 2.1〜2.4 | 実 CONFLICTING PR でラベル付与 + コメント投稿 | jq による labels 重複チェック・files 整形ロジックの単体検証で関数挙動は確認済み。実 GitHub への副作用検証は本番運用の最初のサイクルで観測する必要あり |
| 3.1〜3.4 | 実 stale base PR で rebase + force-with-lease push 成功／失敗 | git コマンド列の syntax 検証と、サブシェル exit code → 集計分岐ロジックの目視レビューのみ |
| 4.4 / 4.5 | 実 timeout 発火時の `git rebase --abort` → 次 PR 移行 | timeout 60s 設定を確認、bash の `||` chain の挙動でカバー |
| NFR 1.1 | 実 PR 3 件で 60 秒以内に完了 | 各操作 timeout 60s × 通常 PR 数 = 数十秒の見積もり |

**推奨**: PR merge 後、本リポジトリ自身に対して `MERGE_QUEUE_ENABLED=true` で 1 サイクル
動かし、サマリログが `rebase+push=0, conflict=0, skip=0, fail=0, overflow=0` で出ることを
確認する（dogfooding スモーク）。

## 確認事項（PR 本文への転記候補）

requirements.md と乖離する判断や、レビュワーに最終確認してほしい点:

1. **`MERGE_QUEUE_ENABLED` のデフォルトを `false`（opt-in）にした**
   - 要件は「opt-out」とも「opt-in」とも書かれていないが、CLAUDE.md「opt-in gate なしで新しい
     外部サービス呼び出しを有効化しない」原則に従って opt-in を選択。
   - 本番投入時は `MERGE_QUEUE_ENABLED=true` を cron / plist に明示的に追加する必要あり
     （README に記載済み）。
2. **conflict ファイル一覧は「PR の変更ファイル」を表示している（真の conflict 範囲ではない）**
   - 上記「conflict ファイル一覧の取得方法」参照。Phase A の取り急ぎ実装で、Phase B
     （staging branch 導入）で `git merge-tree` ベースに置き換える前提。
   - 利用者にはコメント本文で「実際の conflict 範囲は `git merge-tree` 等で確認してください」と
     注記している。
3. **`base_ref != MERGE_QUEUE_BASE_BRANCH` の MERGEABLE PR は自動 rebase 対象外**
   - 例えば `develop` ブランチ向けの PR が approved になっている場合、Phase A は
     何もせず skip ログのみ出す。要件 3.1 は「main HEAD よりも進んでいる場合」と限定して
     書かれているため、安全側の解釈。レビュワーで OK か確認。
4. **shellcheck 未実行**
   - 環境制約（apt sudo 不可・docker / pip / npm なし）で shellcheck をインストールできず、
     `bash -n` syntax check のみ実施。CI / 別環境で shellcheck をかけて警告ゼロを確認したい。
5. **`gh pr list --json mergeable` は `gh` CLI が返してくれない場合がある**
   - GitHub の mergeability 計算は非同期。`UNKNOWN` / `null` のケースは「次回サイクルに委ねる」
     skip 扱いにした。実運用で `UNKNOWN` 連発が起きるなら、明示的に `gh api graphql` で
     再計算 trigger する仕組みを Phase B 以降で検討。

## 次の Issue 候補

- staging branch 経由で真の conflict ファイル一覧を取得するように mq_handle_conflict を改修（Phase B = #15 の範囲）
- mergeable=UNKNOWN 連発時の再計算 trigger（Phase B 以降）
- needs-rebase ラベル付き PR が指定期間（例: 7 日）放置されたら Issue 起点者に reminder（運用改善）
- `gh pr list` の `review:approved` フィルタは「ある時点で approve」されたものを返すが、
  approve 後に新規 commit が積まれた場合の挙動を E2E で確認
