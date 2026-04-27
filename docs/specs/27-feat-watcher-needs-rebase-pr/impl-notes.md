# 実装ノート: feat(watcher) `needs-rebase` PR の自動再評価ループ (#27)

## 概要

`local-watcher/bin/issue-watcher.sh` に `process_merge_queue_recheck()` を新設し、
watcher サイクル冒頭（既存 `process_merge_queue` の **直前**）に 1 回起動する。
`needs-rebase` 付き approved PR を別レーンで再評価し、`mergeable=MERGEABLE` に
戻った PR からラベルを除去する。Phase A 本体（`MERGE_QUEUE_ENABLED`）とは独立
した env (`MERGE_QUEUE_RECHECK_ENABLED`) で opt-in 制御。

## 主要な実装判断

### 1. 共通化の方針

Phase A 本体（`process_merge_queue`）と Re-check で共通化できそうな箇所
（PR 検索 → クライアント側 jq フィルタ → head pattern / fork 判定）はあるが、
**今回は共通化を見送り、最小限の重複を許容**した。理由:

- Phase A 本体は **5 件**（`MERGE_QUEUE_MAX_PRS` default）まで処理する短時間ループ、
  Re-check は **20 件**（`MERGE_QUEUE_RECHECK_MAX_PRS` default）まで処理する別軸の
  ループで、`--limit` / 上限値 / 処理アクション（rebase vs label removal）が異なる
- 共通化で関数引数 / フラグが膨らむと、Phase A 既存挙動を壊すリスクが上がる
- 既存挙動の後方互換性最優先（CLAUDE.md 禁止事項）の観点から、Phase A 本体側は
  一切変更せず、Re-check は **独立した関数 + 独立したロガー (`mqr_*`)** で実装

将来 Phase B / Phase C で共通化が必要になれば、その時点で fetch + filter ロジックを
小さなヘルパー関数に切り出す前提（投機的抽象化を避ける）。

### 2. ログ prefix の分離

要件 5.5 / NFR 3.2 に従い、Re-check は `merge-queue-recheck:` prefix を使用
（Phase A 本体の `merge-queue:` と区別）。これにより operator は以下のように
独立に集計できる:

```bash
grep 'merge-queue-recheck:' $HOME/.issue-watcher/logs/<repo>/cron.log
```

ロガー関数も `mqr_log` / `mqr_warn` / `mqr_error` として独立定義。
タイムスタンプ書式 (`[YYYY-MM-DD HH:MM:SS]`) と stderr / stdout の方針は
既存 `mq_*` と完全に揃えた（要件 5.6 / 5.8）。

### 3. ラベル除去失敗時の扱い

要件 2.6 に従い、`gh pr edit --remove-label` がエラーを返した場合は
WARN ログを出して **後続 PR の処理を継続**。失敗カウンタ (`failed`) で
サマリにも反映。サブシェル境界は使わず、`if timeout ... gh pr edit ...` で
直接判定（Phase A 本体の `mq_handle_conflict` と同じパターン）。

### 4. mergeable 判定の網羅

要件 2.1〜2.4 / NFR 2.2 に従い、mergeable 値の case 分岐は以下:

| 値 | アクション | サマリ計上 |
|---|---|---|
| `MERGEABLE` | `--remove-label needs-rebase` | `label-removed` |
| `CONFLICTING` | 状態変更なし（再ラベル / コメントなし） | `conflicting` |
| `UNKNOWN` / `null` / `""` | 次回サイクルに委ねる | `unknown-skip` |
| その他（未知の値） | 安全側でラベル除去せず skip | `unknown-skip` |

NFR 2.2 を厳格に守るため、未知の値も `unknown-skip` として扱う（誤って
ラベルを外さないよう default は除去しない）。

### 5. server-side 検索クエリ

Phase A 本体が `-label:"needs-rebase"` で除外しているのに対し、Re-check では
**`label:"needs-rebase"`（include）** にする。それ以外（review:approved /
-label:"claude-failed" / -draft:true）は同一なので、approved + 非 draft +
非 claude-failed の安全フィルタは Phase A と同等（要件 1.4〜1.6）。

`--limit 100` は server-side 取得の上限。クライアント側で
`MERGE_QUEUE_RECHECK_MAX_PRS`（default 20）まで truncate するので、
20 件超を持つ大規模 repo でも overflow がログに残る形にしている。

### 6. opt-in gate と独立性

要件 3.1〜3.3 に従い、`MERGE_QUEUE_RECHECK_ENABLED != "true"` なら関数の
冒頭で即 return（Phase A 本体の有効化状態は参照しない）。これにより:

- `MERGE_QUEUE_ENABLED=true` + `MERGE_QUEUE_RECHECK_ENABLED=false` → 既存挙動（Phase A 本体のみ）
- `MERGE_QUEUE_ENABLED=false` + `MERGE_QUEUE_RECHECK_ENABLED=true` → Re-check のみ実行
- `MERGE_QUEUE_ENABLED=true` + `MERGE_QUEUE_RECHECK_ENABLED=true` → 両方実行
- 両方 `false` → 本機能導入前と完全に一致する挙動（要件 3.3）

## 検証

### 静的解析

- `bash -n local-watcher/bin/issue-watcher.sh` → OK（構文エラーなし）
- `shellcheck` → ローカル環境に未インストールのため未実行（`apt list --installed`
  および主要パスを探索したが存在せず）。CI 等で確認する想定で、新規追加分は
  既存 `mq_*` と同じパターン（クォート / `command -v` / `: "${VAR:=...}"`
  スタイル / `local` 宣言）を踏襲しており、既存 `mq_*` 関数で出ていない warning は
  追加していないはず。

### 手動 dry-run

両ケースとも scratch repo `/tmp/idd-recheck-test`（hitoshiichikawa/idd-claude を clone）で実施。

**Case 1: recheck 無効時の回帰確認**
```
MERGE_QUEUE_ENABLED=false MERGE_QUEUE_RECHECK_ENABLED=false bash issue-watcher.sh
→ "[2026-04-27 10:07:51] 処理対象の Issue なし"
→ merge-queue / merge-queue-recheck どちらのログも出ない（既存挙動と一致）
```

**Case 2: recheck 有効時のクエリ・サマリ確認**
```
MERGE_QUEUE_ENABLED=false MERGE_QUEUE_RECHECK_ENABLED=true bash issue-watcher.sh
→ "[...] merge-queue-recheck: サイクル開始 (max=20, timeout=60s)"
→ "[...] merge-queue-recheck: 対象候補 0 件、処理対象 0 件"
→ "[...] merge-queue-recheck: サマリ: label-removed=0, conflicting=0, unknown-skip=0, fail=0, overflow=0"
```

`bash -x` で実際の `gh pr list` 引数を確認:
```
gh pr list --repo hitoshiichikawa/idd-claude --state open
  --search 'review:approved label:"needs-rebase" -label:"claude-failed" -draft:true'
  --json number,headRefName,baseRefName,mergeable,labels,url,isDraft,reviewDecision,headRepositoryOwner
  --limit 100
```
→ 要件 1.4〜1.7 のフィルタが server-side で正しく構築されている。

## 要件 → 実装トレーサビリティ

| Req ID | 担保箇所 |
|---|---|
| 1.1 | `process_merge_queue_recheck` を `process_merge_queue` の直前で呼び出し（issue-watcher.sh L451） |
| 1.2 / 1.3 | 関数冒頭の `[ "$MERGE_QUEUE_RECHECK_ENABLED" != "true" ] && return 0` + Config の `${MERGE_QUEUE_RECHECK_ENABLED:-false}` |
| 1.4 | `--search "review:approved label:\"$LABEL_NEEDS_REBASE\" ..."` の include クエリ |
| 1.5 | クエリの `-draft:true` + jq filter `select(.isDraft == false)` |
| 1.6 | クエリの `-label:"$LABEL_FAILED"` |
| 1.7 | jq filter `select(.headRefName \| test($pattern))`（既存 `MERGE_QUEUE_HEAD_PATTERN`） |
| 1.8 | jq filter `select((.headRepositoryOwner.login // "") == $owner)` |
| 1.9 | gh pr list の `--json mergeable` で取得 |
| 2.1 | case `MERGEABLE` で `gh pr edit --remove-label "$LABEL_NEEDS_REBASE"` |
| 2.2 | 成功時の `mqr_log "PR #N: mergeable=MERGEABLE -> label removed (conflict resolved, re-evaluating next cycle)"` |
| 2.3 | case `CONFLICTING` で状態変更なし（ラベル付与・コメントなし） |
| 2.4 | case `UNKNOWN\|null\|""` で skip（state 変更なし） |
| 2.5 | re-merge / 自動 rebase / コメント投稿コードなし。`gh pr edit --remove-label` のみが副作用 |
| 2.6 | `gh pr edit` 失敗時の `mqr_warn` + `failed=$((failed + 1))` + 後続継続 |
| 3.1 / 3.2 / 3.3 | env gate を `MERGE_QUEUE_ENABLED` から完全独立で判定（return 0 で完全 skip） |
| 3.4 | 既存 env var の名前・default を一切変更していない |
| 3.5 | 既存ラベル定数 `LABEL_NEEDS_REBASE` / `LABEL_FAILED` を再利用、新ラベルは追加していない |
| 3.6 | `LOCK_FILE` / `LOG_DIR` / exit code に手を入れていない |
| 3.7 | 副作用はラベル除去のみ。付与経路は持たない |
| 4.1 | `MERGE_QUEUE_RECHECK_MAX_PRS` で上書き可、default `20` |
| 4.2 | 上限超過時 `skipped_overflow` をサマリに含めて持ち越し |
| 4.3 | API 呼び出しは PR 一覧取得（1）+ ラベル除去（1）= 2 回（取得時点で mergeable も同梱、≤3 回） |
| 4.4 | `timeout "$MERGE_QUEUE_GIT_TIMEOUT"` を `gh pr list` / `gh pr edit` 双方に適用 |
| 4.5 | `gh pr list` 失敗時 WARN + return 0、`gh pr edit` 失敗時 WARN + 次 PR 継続 |
| 5.1 | サイクル開始ログ「対象候補 N 件、処理対象 M 件 / overflow K 件」 |
| 5.2 | 各 PR ごとに mergeable / 実施アクションを 1 行ログ |
| 5.3 | MERGEABLE 成功時の文言「conflict resolved, re-evaluating next cycle」 |
| 5.4 | サマリ「label-removed=N, conflicting=N, unknown-skip=N, fail=N, overflow=N」 |
| 5.5 | 全ログ行に `merge-queue-recheck:` prefix |
| 5.6 | timestamp 書式 `[YYYY-MM-DD HH:MM:SS]`（既存 `mq_*` と一致） |
| 5.7 | 出力先は既存 stdout / stderr 経由（LOG_DIR は cron リダイレクトで保存される既存運用） |
| 5.8 | `mqr_warn` / `mqr_error` のみ stderr、`mqr_log` は stdout |
| 6.1〜6.4 | README.md「`needs-rebase` ラベルの自動解除（Re-check Processor, opt-in）」節および環境変数表 / Migration Note を更新 |
| NFR 1.1 / 1.2 | 1 PR あたり API 1〜2 call、20 件処理でも数秒〜十数秒オーダーで収まる想定（NFR 検証は本番運用での観測に委ねる） |
| NFR 2.1 / 2.2 | 副作用は label removal のみ、MERGEABLE 以外は除去しない |
| NFR 3.1 / 3.2 | `merge-queue-recheck:` prefix で grep 集計可能、Phase A 本体の `merge-queue:` と区別 |

## 確認事項（PM / Architect / レビュワー向け）

1. **`MERGE_QUEUE_RECHECK_MAX_PRS` の default `20`** は要件 4.1 そのままだが、本リポジトリの
   現状 (open PR 数十件規模) では適切と判断。大規模 repo で運用する operator は
   cron 環境変数で上書き可能。
2. **server-side `--limit 100`** は固定値。要件 4.1 の `MAX_PRS` を超える case
   （20 件 default → 超過は overflow ログ）に備え、`MAX_PRS=100` まで上書きしても
   server fetch でカバーできるよう余裕を持たせた。これを env で公開していないのは、
   要件で言及がなく、必要になった時点で追加する想定（投機的抽象化を避ける）。
3. **`MERGE_QUEUE_RECHECK_MAX_PRS=0` の挙動**: 要件には明記されていないが、`0`
   を指定すると常に `target_count=0` でゼロ件 summary だけ出して return する。
   実質「機能を有効化したまま処理だけ止める」運用になる（明示的な無効化は
   `MERGE_QUEUE_RECHECK_ENABLED=false` 推奨）。
4. **shellcheck がローカル未インストール**のため、CI / レビュワー側で
   `shellcheck local-watcher/bin/issue-watcher.sh` を実行して確認してほしい。
   既存 `mq_*` パターンに完全準拠しているため新規 warning は出ないはずだが、
   念のため確認を依頼する。
5. **dogfooding 検証**: 本 PR が merge された後、本リポジトリ自身の watcher で
   `MERGE_QUEUE_RECHECK_ENABLED=true` を試す場合は、対象 `needs-rebase` 付き PR が
   存在する状態で 1 サイクル走らせ、`merge-queue-recheck:` ログとラベル除去
   結果を観測する想定（`install.sh --local` で `~/bin/issue-watcher.sh` を更新後）。

## 派生タスク候補（次の Issue として切り出し検討）

- Re-check Processor のメトリクスを cron.log から集計する補助スクリプト
  （`merge-queue-recheck:` summary 行を 1 日単位で aggregate）
- `MERGE_QUEUE_RECHECK_MAX_PRS` 超過時の優先度付け（Out of Scope に明記済み）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への組み込み
  （Out of Scope に明記済み）
