# Implementation Notes: #55 PR Iteration general comment filter relaxation

## 概要

PR Iteration Processor の一般コメント収集から `@claude` mention 必須の制約を撤廃し、
当該 PR の Conversation タブ一般コメントを原則すべて Claude prompt に積むよう変更した。
誤発火を防ぐため、watcher 自身の自動投稿（marker ベース）/ 過去 round 対応済み（`last-run`
TS ベース）/ GitHub system 由来 event-style コメントを除外する 3 段フィルタと、大量時の
件数 truncate を `pi_collect_general_comments` オーケストレーション関数に集約した。

## Feature Flag Protocol 採否

対象 repo (`/home/hitoshi/github/idd-claude-watcher`) の `CLAUDE.md` には
`## Feature Flag Protocol` 節が存在せず、Default の opt-out として解釈した。
このため通常の単一実装パスで実装し、flag による分岐や両系統テストは導入していない。

## 実装サマリ（タスクと commit の対応）

| Task | Commit | 概要 |
|------|--------|------|
| 1.1 | `34af1c1` | `pi_read_last_run` ヘルパ新設（PR body marker から `last-run` ISO8601 を抽出） |
| 1.2 | `caf6dab` | 4 種フィルタ関数（`pi_general_filter_self` / `_resolved` / `_event_style` / `_truncate`）新設 |
| 1.3 | `42fddd2` | `pi_collect_general_comments` オーケストレーション + `pi_build_iteration_prompt` の旧 `@claude` フィルタ撤去 |
| 2.1 | `2dd7d9f` | `iteration-prompt.tmpl`（impl 用）の一般コメント節改稿 |
| 2.2 | `77ffc10` | `iteration-prompt-design.tmpl`（design 用）の一般コメント節改稿 |
| 3.1 | `4f6b3f7` | README に「対象コメント」節新設 + Migration Note #55 項追加 |
| 3.2 | `99294f6` | `repo-template/.claude/agents/project-manager.md` の文言更新 |
| 3.3 | （no-op） | `repo-template/CLAUDE.md` は `@claude` 文言を含まないため変更不要（design.md の指示通り） |

## Requirements トレーサビリティ（AC → 検証）

requirements.md の numeric ID と、それを担保した実装 / 検証手段の対応:

| Req ID | 検証手段 | 備考 |
|--------|----------|------|
| 1.1 | `pi_collect_general_comments` の jq pipeline で `test("@claude")` を撤去（`pi_general_filter_self/_resolved/_event_style/_truncate` のいずれも mention に依存しない）| 手動 fixture テスト Test A で「@claude を含まない普通のコメント (id=3) も残る」ことを確認 |
| 1.2 | 同上。`pi_collect_general_comments` の各段に mention 判定なし | コード grep: `grep -n '@claude' local-watcher/bin/issue-watcher.sh` で残存ヒットゼロを確認 |
| 1.3 | `iteration-prompt.tmpl` 改稿（見出し / 説明文 / 責務 5 番目から `@claude` 表記削除） | `grep '@claude' local-watcher/bin/iteration-prompt.tmpl` でヒットゼロを確認 |
| 1.4 | `iteration-prompt-design.tmpl` 改稿（impl 版と同様） | 同上 |
| 1.5 | `pi_collect_general_comments` の取得失敗時 / jq 失敗時の degraded path で `[]` を出力 | 手動 fixture テスト Test E で確認 |
| 1.6 | 両 template の説明文に「精読し、対応すべきと判断したものに対して修正 commit または返信を行ってください」を明記 | template diff |
| 2.1 | `pi_general_filter_self` で `body` に `idd-claude:` を含むコメントを除外 | 手動 fixture テスト Test 1 / Test A で確認（着手表明 marker 含むコメントが除外される） |
| 2.2 | `pi_general_filter_resolved` で `created_at > last_run` のみ採用 | 手動 fixture テスト Test 2 / Test B で確認 |
| 2.3 | `pi_read_last_run` で PR body の hidden marker から `last-run=ISO8601` を抽出 | fixture テスト Test 1〜4（pi_read_last_run 単独）で marker あり / なし / 複数 / 空文字列を確認 |
| 2.4 | `pi_general_filter_resolved` の jq 式 `$last_run == "" or .created_at > $last_run` で marker なし時は no-op | 手動 fixture テスト Test 3 / Test A で確認 |
| 2.5 | 既存 `pi_run_iteration` の round 1 回起動構造を維持。`pi_collect_general_comments` は round 内で 1 回だけ呼ばれる | 既存挙動温存（`pi_build_iteration_prompt` は 1 round 1 回呼び出し） |
| 2.6 | `pi_general_filter_event_style` で `user.type == "Bot"` または `body == ""` を除外 | 手動 fixture テスト Test 4 で確認 |
| 2.7 | 全フィルタ関数の jq 式から `test("@claude")` 完全撤去 | コード grep `grep -n '@claude' local-watcher/bin/issue-watcher.sh` でヒットゼロ |
| 3.1 | `pi_general_truncate` で件数超過時に古い順 drop | 手動 fixture テスト Test 5 / Test 7 / Test D で確認 |
| 3.2 | `pi_collect_general_comments` の最終サマリで truncate 発動時に `pi_warn` を呼ぶ | 手動 fixture テスト Test D の log で WARN 行確認 |
| 3.3 | 両 template に「未提示のコメントへの対応は次 round 以降または人間レビュワーに委ねられる」旨を含む | template diff |
| 3.4 | `pi_general_truncate` の `if length <= $limit then . else ... end` で no-op | 手動 fixture テスト Test 6 / Test C で確認 |
| 4.1 | `pi_post_processing_marker` の hidden marker 形式・更新タイミングは未変更（読み取り専用ヘルパ `pi_read_last_run` を新設しただけ） | コード diff |
| 4.2 | `pi_finalize_labels` / `pi_finalize_labels_design` / `pi_escalate_to_failed` には触っていない | コード diff |
| 4.3 | `process_pr_iteration` の opt-in gate `PR_ITERATION_ENABLED` 判定は未変更 | コード diff |
| 4.4 | 新規 env var を追加していない（`PI_GENERAL_MAX_COMMENTS` は内部定数として shell 内で導入、README には載せない） | コード grep: 環境変数として `${PR_ITERATION_*}` の追加なし |
| 4.5 | `pi_post_processing_marker` の着手表明 marker 文字列 `idd-claude:pr-iteration-processing round=N` は未変更 | コード diff |
| 4.6 | 既存 env var の名前・既定値・意味は未変更 | コード diff |
| 5.1 | README の (1) と「needs-iteration ラベル」付与契機表記から `@claude` 削除 | README diff |
| 5.2 | README に「対象コメント」サブ節を新設 | README diff |
| 5.3 | `repo-template/.claude/agents/project-manager.md` の 36 行目文言を更新 | diff |
| 5.4 | README Migration Note `#55` 項に env var / ラベル / cron / round marker / exit code / サマリ format / 着手表明 marker いずれも不変の旨を明記 | README diff |
| 5.5 | 本 PR で同時更新（PjM が PR 作成時に手動チェック） | PR 構成 |
| 6.1 | impl / design 両 template に同一規約の説明文 | template diff |
| 6.2 | `pi_collect_general_comments` を impl/design 共通呼び出し（`pi_build_iteration_prompt` の単一呼び出しから両 kind が経由する） | コード diff |
| 6.3 | design 用 template の `{{SPEC_DIR}}` 配下スコープ規約と返信先規約を温存 | template diff（責務 6 番目に「編集許容スコープは {{SPEC_DIR}} 配下のみ」を残す） |
| 6.4 | impl 用 template の commit / push / 返信規約を温存 | template diff（責務 1〜8 番目はほぼ既存どおり） |
| NFR 1.1 | 既存 env var / ラベル名・既定値・意味不変 | コード grep / Migration Note |
| NFR 1.2 | `process_pr_iteration` の exit code / サマリ 1 行 format は未変更 | コード diff |
| NFR 1.3 | cron / launchd 登録文字列は未変更 | コード diff |
| NFR 1.4 | `idd-claude-labels.sh` には触っていない | コード diff |
| NFR 2.1 | `pi_collect_general_comments` の最終サマリで `filtered_self`, `filtered_resolved`, `filtered_event`, `truncated` の 4 カテゴリを 1 行で出力 | 手動 fixture テスト Test A〜E の log で確認 |
| NFR 2.2 | サマリは truncate 発動時 `pi_warn` / 非発動時 `pi_log >&2` で必ず出力（NFR 2.1 と同じログ） | 同上 |
| NFR 3.1 | shellcheck warning ゼロ（既存ベースラインと同じ info のみ残存） | `shellcheck --severity=warning` で 0 件 |
| NFR 3.2 | dry run（処理対象なし）が正常終了 | 後述「手動スモーク手順」参照（本サンドボックスでは `gh` 認証依存のため未実施） |
| NFR 3.3 | PR #53 等価 fixture | 後述「手動スモーク手順」参照 |

## 手動スモーク手順（PR merge 前に実施推奨）

本リポジトリには unit test framework が無いため、watcher 動作確認は以下の組み合わせで実施する。

### 1. 静的解析（必須）

```bash
shellcheck --severity=warning local-watcher/bin/issue-watcher.sh
# expect: 出力なし
```

`actionlint` は本変更で `.github/workflows/*.yml` を触らないため対象外。

### 2. dry run（処理対象なし、必須）

```bash
mkdir -p /tmp/test-repo-empty && cd /tmp/test-repo-empty && git init -q
REPO=owner/test REPO_DIR=/tmp/test-repo-empty $HOME/bin/issue-watcher.sh
# expect: "処理対象の Issue なし" 相当のログで正常終了 (exit 0)
#         pr-iteration セクションも 1 行サマリ "success=0, fail=0, ..." で完了
```

### 3. cron-like 最小 PATH 解決確認（依存解決の sanity check）

```bash
env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git timeout'
# expect: 全コマンドのパスが解決される
```

### 4. PR #53 等価 fixture（NFR 3.3、推奨）

idd-claude 自身（self-hosting）に test PR を立てて E2E 確認する。

1. `claude/issue-<N>-impl-test` 形式の test PR を作成
2. **mention 無し**の一般コメントを 2 件投稿（例: 「ここを修正してほしい」「もう一箇所」）
3. `needs-iteration` ラベルを付与
4. cron / launchd または手動で watcher を 1 サイクル実行（`PR_ITERATION_ENABLED=true` 必須）
5. prompt log（`$LOG_DIR/pr-iteration-impl-<n>-round<r>-*.log`）を `cat` し、
   `## PR の一般コメント (Conversation タブ、JSON 配列)` 節に当該 2 件が含まれることを目視確認
6. watcher 全体ログ（`$LOG_DIR/issue-watcher.log` 等）に
   `pr-iteration: PR #<n> general comments: fetched=N, filtered_self=A, filtered_resolved=B, filtered_event=C, truncated=0, final=N`
   が出ることを確認

### 5. 大量コメント truncate 確認

1. test PR に 60 件以上の一般コメントを投稿（GitHub UI から手動 / `gh pr comment` ループ）
2. watcher を 1 サイクル実行
3. watcher ログに
   `WARN: PR #<n> general comments: fetched=60, ..., truncated=10 (limit=50), final=50`
   が出ることを確認
4. prompt log の JSON 配列が 50 件であることを `jq 'length'` で確認

### 6. 設計 PR 経路（`PR_ITERATION_DESIGN_ENABLED=true`）

`claude/issue-<N>-design-test` 形式の test PR で同様の手順を実施し、design 用 template
（`iteration-prompt-design.tmpl`）が使われることをログで確認する。同じ
`pi_collect_general_comments` のサマリ 1 行が design / impl どちらでも出力されることを
確認。

## 実装上の判断 / トレードオフ

### 1. `pi_log` の stdout / stderr 分離

`pi_collect_general_comments` の **stdout は JSON 配列に予約**されているため、サマリログを
`pi_log` で出すと stdout に混入してしまう。`pi_log` のグローバル動作（stdout に出力）は
影響範囲が大きく変えたくないため、**呼び出し側で `pi_log "..." >&2` と明示的にリダイレクト**
する方針で対応した。`pi_warn` は元々 `>&2` 直行のため変更不要。

### 2. event-style フィルタの schema 復元

`pi_general_filter_event_style` は `user.type == "Bot"` を判定するが、
`pi_collect_general_comments` の射影段では `{id, user, body, url, created_at}` の user は
**login 文字列のみ** を保持する設計（template 互換）。そのため event_style フィルタの
直前で `_meta_user_type` を `user.type` 相当に詰め直し、フィルタ後に `user` を再び login
文字列に戻す **schema 往復**を実装した。

代替案として「最初から `user: {type, login}` のオブジェクトで持つ」も検討したが、prompt
template 既存スキーマ（`{ id, user, body, url }` の user は文字列）との互換性を優先した。
今後 template 側で user object を扱うように変更するなら、本実装の往復は単純化可能。

### 3. `last-run` 比較は `>` （境界は除外側に倒す）

`pi_general_filter_resolved` の境界判定は `created_at > last_run`（`>=` ではない）。
理由: `last_run` 時点で **既に存在していた**コメントは「過去 round で提示済み」とみなす方が
fail-safe（同 round 内で次の watcher サイクルが回ったときの再取り込みを防ぐ）。
GitHub `created_at` の TS 精度は秒単位なので、`==` のレースは実害が極めて小さい。

design.md「論点 1」採用案 A をそのまま実装。

### 4. `PI_GENERAL_MAX_COMMENTS` 内部定数の扱い

design.md の決定に従い `PI_GENERAL_MAX_COMMENTS`（既定 50、env override 可）として導入。
README の env var 表には載せない（運用上 default で十分）。Migration Note にのみ「内部定数で
`<整数>` で override 可能」と一言記載した。Req 4.4 が禁ずるのは「`@claude` mention 必須を
opt-out で復活させる env var」であり、本変数は別目的（コンテキスト保護）。

### 5. `repo-template/CLAUDE.md` no-op 判断

design.md tasks.md 3.3 で「`@claude` 文言が無いことを diff で確認、必要なら 1〜2 行追記」と
されていた。`grep -n '@claude' repo-template/CLAUDE.md` でヒットゼロを確認したため、
当初の「不要なら no-op」方針通り **本ファイルは変更しない**。一般コメント対象範囲の表現は
README / `repo-template/.claude/agents/project-manager.md` 側で完結している。

## 確認事項（PR レビュワー判断ポイント、PR 本文に転記推奨）

1. **`pi_collect_general_comments` の schema 往復**（実装上の判断 #2）が冗長と判断される場合、
   prompt template 既存スキーマを `{ id, user: { login, type }, body, url, created_at }` に
   拡張して往復を省く方針もある。本 PR では template 互換性を優先したが、フォローアップ
   Issue で扱うか判断してください
2. **`PI_GENERAL_MAX_COMMENTS=50` の妥当性**: 現実 PR で頻繁に超過するなら README に env var
   として昇格させる必要がある。watcher ログの WARN 行で観測可能なので、実運用で発火頻度を
   見て次 PR で判断する想定
3. **dogfood E2E 未実施**: 本サンドボックスでは `gh` 認証依存のため PR #53 等価 fixture の
   E2E スモークは未実施。merge 前に運用者が「手動スモーク手順 4」を実施することを推奨
4. **`repo-template/CLAUDE.md` no-op**（実装上の判断 #5）: design.md の指示「不要なら no-op
   で良い」に従ったが、Reviewer / 運用者の感覚で 1 文追記が望ましければ別 PR で対応可能
5. **`pi_log >&2` リダイレクト**（実装上の判断 #1）: 設計上、サマリログを stderr に流しても
   既存 watcher ログ（`>> $LOG_DIR/...`）に正しく合流するため問題なし。`pi_log` の
   グローバル仕様変更は将来検討する場合別 Issue で扱う

## 残課題 / フォローアップ候補

- **active feature flag の棚卸し**: 本リポジトリは Feature Flag Protocol opt-out のため
  該当なし
- **`PI_GENERAL_MAX_COMMENTS` のチューニング**: 上記「確認事項 2」を参照
- **CI での shellcheck 自動化**: 本 PR で警告ゼロを維持したが、CI で shellcheck を回す仕組みは
  未導入（手動チェック前提）。別 Issue で扱う候補
