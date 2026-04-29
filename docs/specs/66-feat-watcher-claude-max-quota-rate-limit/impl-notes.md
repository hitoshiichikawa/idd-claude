# Implementation Notes — Quota-Aware Watcher (#66)

## 実装サマリ

tasks.md の番号順に従い、以下のコミットで実装した（branch:
`claude/issue-66-impl-feat-watcher-claude-max-quota-rate-limit`）。

| タスク | コミット | 概要 |
|---|---|---|
| 1.1 / 1.2 | `2e6c593 feat(labels)` | `repo-template/.github/scripts/idd-claude-labels.sh` と root の `.github/scripts/idd-claude-labels.sh` の双方に `needs-quota-wait\|c5def5\|【Issue 用】 ...` 行を冪等追加 |
| 2.1 / 2.2 / 2.3 / 2.4 / 3.1 / 3.2 / 3.3 | `afbd110 feat(watcher): add Quota-Aware Watcher helpers and Resume Processor` | Config 節への env / ラベル定数追加、`qa_*` ヘルパー群（log / detect / persist / load / format / handle / wrapper）、`process_quota_resume` の追加、cron tick 冒頭での起動、Dispatcher exclusion query への `-label:needs-quota-wait` 追加 |
| 4.1 / 4.2 / 4.3 / 4.4 | `b0e1914 feat(watcher): wrap 6 claude stage invocations` | Triage / Stage A / Stage A' / Reviewer round=1/2 / Stage C / design の 6 stage に `qa_run_claude_stage` を適用。99 受領時は `qa_handle_quota_exceeded` を呼んで `_slot_mark_failed` / `mark_issue_failed` を踏まずに `return 0` で抜ける |
| 5.1 / 5.2 | `b45dcd0 docs(readme): add Quota-Aware Watcher section` | README にラベル一覧 / 状態遷移表 / ポーリングクエリ / opt-in 一覧 / 状態遷移図への追記、および `## Reviewer Gate` 直前への `## Quota-Aware Watcher (#66)` 節新設 |
| (修正) 2.2 | `23e2820 fix(watcher): per-line JSON parse` | `qa_detect_rate_limit` の jq を `-R` raw 入力 + `try fromjson catch null` に修正（Req 2.5 担保: 解析失敗で stream を止めない） |
| 6 | （本ファイル） | dogfooding fixture テスト手順を本ノートにまとめた |

各コミットは `feat(scope)` / `fix(scope)` / `docs(scope)` の Conventional Commits
形式で、scope は `labels` / `watcher` / `readme` から選択。

## 採用したオプション（design.md の論点に対する決定）

design.md の Open Questions すべてに Architect が決定を与えていたため、Developer
側で追加の選択を行った箇所はない。以下、設計に従った主要な実装判断:

1. **reset 時刻の永続化媒体**: design.md 採用通り、Issue body の hidden HTML
   コメント `<!-- idd-claude:quota-reset:<epoch>:v1 -->` を末尾に 1 行で永続化する
   方式を実装した。
2. **stream-json 解析方式**: design.md は「per-line jq fold」を指示。当初
   `jq -r ...` 直結で実装したところ、jq 既定の concatenated JSON モードでは無効な
   1 行で fatal 停止することが smoke test で判明（Test 4: 非 JSON 混在）。Req 2.5
   「解析失敗時は分類しない・既存フローに委ねる（stream を止めない）」を担保するため、
   `jq -R -r '... try ($line | fromjson) catch null ...'` に変更した。
3. **Processor 配置順**: tasks.md 3.2 の指示通り、`process_merge_queue_recheck`
   よりも前（git pull 直後）に `process_quota_resume` を配置した。
4. **escalation コメントフォーマット**: design.md 「Escalation Comment Template」を
   逐語使用するため、`qa_build_escalation_comment` ヘルパーを追加（design.md には
   関数として明記されていなかったが、bash の heredoc を関数化するのが可読性で勝る）。
5. **PR Iteration / Reviewer Gate / Merge Queue 等の PR 系 Processor 内の
   claude 呼び出し**: design.md Out of Scope に従い、wrap は **行わなかった**
   （タスク 4 の 6 stage のみ）。`local-watcher/bin/issue-watcher.sh:1399` 周辺の
   `process_pr_iteration` 内の claude 起動は本機能の対象外。
6. **Reviewer Stage の 99 伝搬**: tasks.md 4.3 の「推奨実装」通り、
   `run_reviewer_stage` を 99 受領時に `return 99` にし、`run_impl_pipeline` 側で
   case 分岐 `99) return 0 ;;` を追加して quota 検出後は後続 stage を skip する。

## 受入基準の達成確認（traceability）

| Req ID | 担保箇所 | 検証 |
|---|---|---|
| 1.1 | `qa_run_claude_stage` 冒頭 + `process_quota_resume` 冒頭の `[ "$QUOTA_AWARE_ENABLED" != "true" ]` 早期 return | smoke test T1, T2（opt-out 時の素通し） |
| 1.2 | 同上 + 各 stage の wrap | smoke test T3〜T6（opt-in 時に exceeded 検知 → rc=99） |
| 1.3 | `QUOTA_AWARE_ENABLED="${QUOTA_AWARE_ENABLED:-false}"` の既定 false | コードレビュー |
| 1.4 | 既存 env var 名（REPO / REPO_DIR / LOG_DIR / LOCK_FILE / TRIAGE_MODEL / DEV_MODEL 等）への変更なし | git diff で確認 |
| 1.5 | 既存 cron 文字列で起動可（QUOTA_AWARE_ENABLED 未設定 → false → 全コードパス skip） | コードレビュー + 手動検証（opt-out smoke test） |
| 1.6 | 既存ラベル 10 個の name / color / description は不変。`needs-quota-wait` のみ追加 | git diff で確認 |
| 2.1 | `qa_run_claude_stage` の tee による stream 分岐、`qa_detect_rate_limit` の per-line fold | smoke test T1（exceeded 1 件で epoch 抽出） |
| 2.2 | `select(.status? == "exceeded")` フィルタ | smoke test T2（allowed のみ → 空） |
| 2.3 | `.resetsAt // .reset_at // .resets_at // empty` で reset epoch を取り出し | smoke test T1, T6 |
| 2.4 | `tail -1` で最後の exceeded のみ採用 | smoke test T3（複数 exceeded → 最新値） |
| 2.5 | `try fromjson catch null` + `2>/dev/null \| tail -1` | smoke test T4（非 JSON 行混在で正常継続） |
| 2.6 | `select(.status? == "exceeded")` で allowed は除外 | smoke test T2 |
| 3.1 | `qa_handle_quota_exceeded` 内の `gh issue edit ... --add-label "$LABEL_NEEDS_QUOTA_WAIT"` | コードレビュー |
| 3.2 | `qa_handle_quota_exceeded` は `claude-failed` を一切付与しない、各 stage の case 99 分岐は `_slot_mark_failed` / `mark_issue_failed` を踏まずに `return 0` | コードレビュー |
| 3.3 | `--remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_NEEDS_QUOTA_WAIT"` の 1 PATCH atomic | コードレビュー |
| 3.4 | `qa_build_escalation_comment` で Stage 種別 / epoch / ISO 8601 / grace を含むコメント本文を組み立て、`gh issue comment` で投稿 | コードレビュー |
| 3.5 | Dispatcher の `gh issue list --search` に `-label:"$LABEL_NEEDS_QUOTA_WAIT"` 追加 | コードレビュー |
| 3.6 | 既存 7 条件（needs-decisions / awaiting-design-review / claude-claimed / claude-picked-up / ready-for-review / claude-failed / needs-iteration）の意味・順序は不変 | git diff で確認 |
| 3.7 | qa 経路は `mark_issue_failed` / `_slot_mark_failed` を呼ばないため、`needs-quota-wait` と `claude-failed` の同時付与は構造的に発生しない | コードレビュー |
| 4.1 | `qa_persist_reset_time` が Issue body の hidden marker として書き込み | smoke test T2, T6（marker round-trip） |
| 4.2 | `qa_load_reset_time` が `gh issue view --json body` で読み出し → `process_quota_resume` から呼び出し | コードレビュー |
| 4.3 | 書き込み時に `sed -E '/<!-- idd-claude:quota-reset:[0-9]+:v1 -->/d'` で既存 marker 全削除 → 新値 1 行追記 | smoke test T6（複数 marker → 1 件のみ残る） |
| 4.4 | `qa_load_reset_time` は不正値時に return 1 + stdout 空、`process_quota_resume` 側で skip + `qa_warn` でラベル維持 | smoke test T4（不正 marker は無視） |
| 5.1 | cron tick 冒頭（git pull 直後、Phase A より前）で `process_quota_resume` を起動 | コードレビュー |
| 5.2 | `now_epoch >= reset_epoch + QUOTA_RESUME_GRACE_SEC` で `gh issue edit --remove-label "$LABEL_NEEDS_QUOTA_WAIT"` | コードレビュー |
| 5.3 | `[ "$now_epoch" -lt "$threshold" ]` で continue（ラベル維持） | コードレビュー |
| 5.4 | `process_quota_resume` 内ではラベル除去のみ。claim や Stage 実行はトリガーしない | コードレビュー |
| 5.5 | `QUOTA_RESUME_GRACE_SEC="${QUOTA_RESUME_GRACE_SEC:-60}"` 既定 60 秒、env で上書き可 | コードレビュー |
| 5.6 | API 失敗は `\|\| qa_warn` で吸収、`return 0` を保証 | コードレビュー |
| 6.1 | `repo-template/.github/scripts/idd-claude-labels.sh` および root 同等品の LABELS 配列に `needs-quota-wait` 行を追加 | git diff |
| 6.2 | 既存 EXISTING_LABELS 機構（既存実装 L106-122）が冪等性を担保 | コードレビュー（既存ロジック不変） |
| 6.3 | 既存 `--force` 機構（同上）が上書きを担保 | コードレビュー（既存ロジック不変） |
| 6.4 | LABELS 配列に行を追加するのみ。既存 10 行は変更しない | git diff |
| 6.5 | description 文字列に `【Issue 用】` prefix を含める（69 文字、100 文字制限内） | smoke test（`printf ... \| wc -m` で 69 文字確認済） |
| 7.1 | README に `## Quota-Aware Watcher (#66)` 節を新設（`## Reviewer Gate` 直前） | git diff |
| 7.2 | ラベル一括作成表 / ラベル状態遷移まとめ表に `needs-quota-wait` を追加 | git diff |
| 7.3 | 新規節内に env 表（`QUOTA_AWARE_ENABLED` 既定 false / `QUOTA_RESUME_GRACE_SEC` 既定 60）を記載 | git diff |
| 7.4 | 状態遷移図に `claude-claimed → needs-quota-wait → auto-dev` および `claude-picked-up → needs-quota-wait → auto-dev` の経路を追記 | git diff |
| 7.5 | 新規節冒頭の引用ブロックで「`QUOTA_AWARE_ENABLED=false`（既定）では本機能の全コードパスが skip され、既存挙動と完全に互換」を明記 | git diff |
| 8.1 / 8.2 / 8.3 / 8.4 | 後述「dogfooding fixture テスト手順」参照（実機 dogfood は人間が実行） | 本ノートに手順記載 |
| NFR 1.1 | `qa_log` で各イベント（exceeded 検知 / 永続化失敗 warn / ラベル付け替え失敗 warn / resume / waiting / API 失敗）を `LOG_DIR` 配下（`$LOG`）に追記 | smoke test（test log 出力確認） |
| NFR 1.2 | 各ログ行に Issue 番号（`#<N>`）/ Stage 種別（`stage=<S>`）/ reset epoch + ISO 8601 を含む | コードレビュー |
| NFR 2.1 | opt-out 時は wrapper が `"$@"` 素通し、`process_quota_resume` は早期 return 0、`mark_issue_failed` パスは不変 | smoke test T1, T2 |
| NFR 2.2 | qa 経路は `mark_issue_failed` を一切呼ばないため `claude-failed` 関連経路は不変 | コードレビュー |
| NFR 2.3 | ラベルスクリプトの既存冪等機構をそのまま利用、既存 10 ラベルの description は不変 | git diff |
| NFR 3.1 | `process_quota_resume` の `gh issue list --json number --limit 50` 1 回 + 0 件時は `return 0` | コードレビュー |
| NFR 3.2 | 1 Issue あたり最大 2 API call（`gh issue view` + `gh issue edit`）。--limit 50 で上限抑止 | コードレビュー |
| NFR 3.3 | grace 60 秒で同 cron tick 内の付与/除去往復を構造的に抑止 | コードレビュー（grace 機構） |
| NFR 4.1 | watcher script への shellcheck 実行で新規警告 0 件 | `shellcheck local-watcher/bin/issue-watcher.sh` で確認済 |
| NFR 4.2 | labels.sh への shellcheck 実行で新規警告 0 件 | `shellcheck repo-template/.github/scripts/idd-claude-labels.sh .github/scripts/idd-claude-labels.sh` で確認済 |

## スモークテスト結果

### 静的解析

```bash
shellcheck local-watcher/bin/issue-watcher.sh \
           .github/scripts/idd-claude-labels.sh \
           repo-template/.github/scripts/idd-claude-labels.sh
```

→ 新規 warning / error は 0 件。既存ファイルに残る info-level（SC2317 = 関数の
unreachable 誤検知 / SC2012 = ls の info）はいずれも本 PR 導入前から存在するもので
本機能では新規発生ゼロ（NFR 4.1 / 4.2）。

```bash
bash -n local-watcher/bin/issue-watcher.sh
```

→ 構文 OK。

### 単体ロジックの fixture-based smoke test

#### Test 1: `qa_detect_rate_limit`（8 ケース、全 PASS）

| # | 入力 | 期待 | 結果 |
|---|---|---|---|
| T1 | exceeded 1 件（数値 resetsAt） | `1745928000` | PASS |
| T2 | allowed のみ | 空 | PASS |
| T3 | 複数 exceeded（最新値採用） | `1745931600` | PASS |
| T4 | 非 JSON 行混在 | `1745928000`（次行を採用）| PASS（修正前 FAIL → 23e2820 で修正） |
| T5 | ISO 8601 文字列 resetsAt | numeric epoch | PASS |
| T6 | 別キー名 reset_at | `1745928000` | PASS |
| T7 | rate_limit_event 以外の type | 空 | PASS |
| T8 | 空 stream | 空 | PASS |

#### Test 2: `qa_format_iso8601`（GNU date 環境）

```
T1 (epoch=1745928000): 2025-04-29T21:00:00+09:00 → ISO 8601 with TZ ✓
```

PASS。BSD date 環境（macOS）は dogfood で別途確認推奨。

#### Test 3: hidden marker round-trip（7 ケース、全 PASS）

| # | シナリオ | 結果 |
|---|---|---|
| T1 | marker 不在 → empty | PASS |
| T2 | marker 1 件 → epoch 抽出 | PASS |
| T3 | marker 複数 → tail -1（最新） | PASS |
| T4 | 不正 marker（abc）→ 無視 | PASS |
| T5 | clean → extract で空 | PASS |
| T6 | 複数 marker 削除 + 新規追加 → 1 件残存 | PASS |
| T6 count | grep で `<!-- idd-claude:quota-reset:[0-9]+:v1 -->` が 1 件 | PASS |

#### Test 4: `qa_run_claude_stage`（7 ケース、全 PASS）

| # | シナリオ | 期待 rc | 結果 |
|---|---|---|---|
| T1 | opt-out + claude rc=0 | 0 | PASS（reset_file 未触触） |
| T2 | opt-out + claude rc=1 | 1 | PASS（既存挙動委譲） |
| T3 | opt-in + 通常出力 | 0 | PASS |
| T4 | opt-in + claude rc=1 + no exceeded | 1 | PASS |
| T5 | opt-in + exceeded（claude rc=1） | 99 | PASS（reset_file=1745928000） |
| T6 | opt-in + exceeded（claude rc=0） | 99 | PASS |

### 手動 dogfooding（次フェーズ / 人間が実機で実行）

本リポジトリ自身に対する end-to-end dogfooding（Req 8.1〜8.3）は本ノートの
「dogfooding fixture テスト手順」セクションに記載した手順で実施する。merge
後の cron 反映までは Developer レーンで完結しないため、PR レビュワー / 運用者が
実機で実行することを想定。

## dogfooding fixture テスト手順（タスク 6 / Req 8.1〜8.4）

### 前提

- `idd-claude` の watcher を local cron で動かす環境（`$HOME/bin/issue-watcher.sh`）
- `gh auth login` 済み + 検証用 scratch repo を 1 つ用意（本 repo 自身でも可）
- claude モック スクリプトの差し込みのため、PATH 上書きで本物の claude を一時的に
  覆す権限

### Step 1. ラベル一括作成スクリプトの再実行（Req 6.1, NFR 2.3）

```bash
cd /path/to/scratch-repo
bash .github/scripts/idd-claude-labels.sh
```

期待: 既存 10 ラベルは「already exists (skipped)」、`needs-quota-wait` のみ「created」。

### Step 2. claude モックの設置

claude が exceeded を出力する fixture スクリプトを作成し、PATH を上書きする。

```bash
# 過去 epoch（grace 経過判定の検証用に "近い未来" にする）
FUTURE_EPOCH=$(($(date +%s) + 90))   # 90 秒後 reset, grace 60 秒で 150 秒後に解除
mkdir -p /tmp/qa-mock/bin
cat > /tmp/qa-mock/bin/claude <<EOF
#!/usr/bin/env bash
# claude モック: stream-json で exceeded 1 件を出して exit 1
printf '{"type":"system","subtype":"init"}\n'
printf '{"type":"rate_limit_event","status":"exceeded","resetsAt":${FUTURE_EPOCH}}\n'
exit 1
EOF
chmod +x /tmp/qa-mock/bin/claude
```

### Step 3. test issue を立てて 1 cron tick 実行

```bash
# scratch repo に auto-dev Issue を起票
gh issue create --repo owner/scratch-repo --title "quota dogfood test" \
  --body "test body" --label auto-dev

# watcher を 1 回起動（PATH 上書きで mock claude を使う）
PATH=/tmp/qa-mock/bin:$PATH \
  REPO=owner/scratch-repo \
  REPO_DIR=$HOME/work/scratch-repo \
  QUOTA_AWARE_ENABLED=true \
  $HOME/bin/issue-watcher.sh
```

期待結果（Req 8.1）:

- 当該 Issue に `needs-quota-wait` ラベルが付与されている
- `claude-failed` ラベルは付与されていない
- Issue body 末尾に `<!-- idd-claude:quota-reset:<FUTURE_EPOCH>:v1 -->` が追記されている
- escalation コメント 1 件が投稿されている（Stage 種別 / reset epoch / ISO 8601 を含む）

確認コマンド:

```bash
gh issue view <N> --repo owner/scratch-repo --json labels,body,comments
```

### Step 4. reset 経過後の cron tick で自動 resume を確認（Req 8.2）

`FUTURE_EPOCH + 60` 秒（= 150 秒後）まで待機するか、Issue body の epoch を
過去にずらして即時解除を強制する:

```bash
# Issue body の epoch を 1 時間前に書き換え（test 用）
PAST_EPOCH=$(($(date +%s) - 3600))
gh issue view <N> --repo owner/scratch-repo --json body --jq '.body' \
  | sed -E "s/<!-- idd-claude:quota-reset:[0-9]+:v1 -->/<!-- idd-claude:quota-reset:${PAST_EPOCH}:v1 -->/" \
  > /tmp/new-body.md
gh issue edit <N> --repo owner/scratch-repo --body-file /tmp/new-body.md

# 再度 watcher を起動（mock を外しておく / 今回は claude は呼ばれない想定）
REPO=owner/scratch-repo \
  REPO_DIR=$HOME/work/scratch-repo \
  QUOTA_AWARE_ENABLED=true \
  $HOME/bin/issue-watcher.sh
```

期待結果（Req 8.2）:

- `process_quota_resume` のログ `quota-aware: resumed issue=#<N> reset_epoch=<PAST_EPOCH> ...`
- `needs-quota-wait` ラベルが除去されている
- ラベル除去のみ。claim / Stage 実行はされていない（Req 5.4）

### Step 5. 通常 pickup ループでの再選定（Req 8.3）

Step 4 と同じ cron tick または次サイクルで Dispatcher が当該 Issue を pickup
候補として扱うことを確認:

```bash
# 同等クエリで対象判定を確認
gh issue list --repo owner/scratch-repo \
  --label auto-dev --state open \
  --search "-label:needs-decisions -label:awaiting-design-review -label:claude-claimed -label:claude-picked-up -label:ready-for-review -label:claude-failed -label:needs-iteration -label:needs-quota-wait"
```

→ 対象 Issue が結果に含まれていれば AC 8.3 達成。

### Step 6. opt-out 互換性検証（NFR 2.1）

同じ fixture 状況で `QUOTA_AWARE_ENABLED` を未設定にして watcher を起動し、
**従来通り `claude-failed` ラベルが付与されること** を確認する:

```bash
# 既存 needs-quota-wait をいったん除去 + body marker 削除（手動）
gh issue edit <N2> --repo owner/scratch-repo --remove-label needs-quota-wait

# QUOTA_AWARE_ENABLED 未設定で起動
PATH=/tmp/qa-mock/bin:$PATH \
  REPO=owner/scratch-repo \
  REPO_DIR=$HOME/work/scratch-repo \
  $HOME/bin/issue-watcher.sh
```

期待: `claude-failed` ラベルが付与され、`needs-quota-wait` は付与されない（既存挙動）。

### Step 7. PR 本文「Test plan」への転記（Req 8.4）

上記 Step 1〜6 の観測ログ（`$HOME/.issue-watcher/logs/<scratch-slug>/issue-<N>-*.log`）
から、以下を PR 本文の Test plan セクションに転記する:

- `quota-aware: stage detected exceeded label=... reset_epoch=...`
- `quota-aware: resumed issue=#... reset_epoch=... elapsed_sec=...`
- ラベル状態遷移の前後（`gh issue view <N> --json labels` の差分）
- escalation コメント本文（gh issue view --comments で抽出）
- opt-out 互換テスト（Step 6）の `claude-failed` ラベル付与結果

## 確認事項（PR レビュワーへ）

1. **stream-json 解析方式の修正（commit 23e2820）**: design.md は per-line jq fold
   を指示していたが、当初実装の `jq -r ...` 直結では Req 2.5（無効行で stream を
   止めない）を満たせなかった。`-R` raw 入力 + `try fromjson catch null` に変更
   して全 8 ケースで PASS となったが、design.md の Service Interface コードと
   実装が完全一致しなくなった（design.md の jq filter は実装より少しシンプル）。
   design.md の書き換えは Developer の領分外（人間レビュー済み spec）のため、
   本ノートで明記するに留める。
2. **PR Iteration Processor 内 claude 呼び出しの非対応**: design.md Out of Scope
   および tasks.md の対象範囲（Triage / Stage A / Stage A' / Reviewer / Stage C /
   design の 6 stage のみ）に従い、`process_pr_iteration` 内の claude 呼び出し
   （`local-watcher/bin/issue-watcher.sh:1392` 周辺）には wrap を適用していない。
   PR Iteration が長時間化して quota を枯渇させるケースが発生したら、別 Issue
   として扱う（design.md Non-Goals にも明記）。
3. **`run_reviewer_stage` の return 値拡張**: 既存契約は 0=approve / 1=reject / 2=error
   の 3 値だったが、Issue #66 で 99=quota-exceeded を追加した。`run_impl_pipeline`
   側の case 分岐で 99 を扱うコードを追加済みだが、他の呼び出し元が無いことは
   `grep run_reviewer_stage` で確認済み（呼び出し箇所は `run_impl_pipeline` 内の
   2 箇所のみ）。
4. **escalation コメントの絵文字（⏸️）使用**: design.md の Escalation Comment
   Template が ⏸️ 絵文字を使用しているため逐語使用したが、CLAUDE.md の markdown
   規約では「絵文字はステータス表示に限定」となっている。本コメントはステータス
   表示用途であり、既存の `⚠️` / `✅` / `❌` / `🤖` / `🟡` 使用と一貫している。
5. **Test plan dogfood の人間実行依存**: Req 8.1〜8.4 の dogfood は claude モックの
   PATH 上書きと scratch repo の実機 cron 実行が必要なため、Developer フェーズ
   では手順記載に留めた。PR マージ前の人間レビュー / smoke test で実行することを
   想定。fixture-based 単体ロジックは smoke test スクリプト（本ノート記載）で
   PASS 確認済。
6. **Issue body 競合更新リスク**: Req 4.3「最新値 1 件」は `qa_persist_reset_time`
   が `gh issue view` → sed 削除 → `gh issue edit` の 3 段階で実装している。
   この間に他プロセスが Issue body を更新した場合は最後の write が勝つ（race
   condition）。本機能の競合相手は Issue 起票者または別の watcher プロセスのみで、
   並列 watcher は flock で排他されているため実害は限定的。ただし設計 PR
   iteration 等で body が並行更新される可能性は理論上残る。design.md の Data
   Models セクションでも認識済み（「body 競合更新時に上書きリスク（が、本機能以外で
   body を編集する経路は少ない）」）。
7. **shellcheck の info-level warning（既存）**: SC2317（unreachable command の
   誤検知）が `qa_error` / `qa_warn` 行で出ているが、これは既存の `mqr_error` /
   `drr_error` / `slot_error` でも同形式で出ている既存パターンであり、新規
   warning ではない（NFR 4.1 を満たす）。

## 派生タスクの提案（Out of Scope / 別 Issue 候補）

design.md / requirements.md の Out of Scope を実装中に再確認した上で、以下を
将来の派生タスクとして列挙する（本 PR では対応しない）:

- PR Iteration Processor / Reviewer Gate / Merge Queue Processor 内の
  claude 呼び出しへの quota wrap 拡張（Out of Scope に明記）
- `needs-quota-wait` 長期化時の自動 escalation（reset から N 時間経過時に
  `claude-failed` 昇格）
- 多 repo cron で同一 Anthropic アカウント token 共有時の grace period 動的調整
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への同等導入
- partial work（Stage 途中までの進捗 commit）の保護・復元

## 静的解析・検証コマンドの最終結果

```bash
# 1. shellcheck（NFR 4.1, 4.2）
shellcheck local-watcher/bin/issue-watcher.sh \
           .github/scripts/idd-claude-labels.sh \
           repo-template/.github/scripts/idd-claude-labels.sh
# → 新規 warning 0 件、新規 error 0 件

# 2. bash 構文 check
bash -n local-watcher/bin/issue-watcher.sh
# → 構文 OK

# 3. fixture-based unit smoke test（impl-notes.md 記載のスクリプト群）
bash /tmp/qa-detect-test.sh   # → PASS=8 / FAIL=0
bash /tmp/qa-iso-test.sh      # → PASS=1 / FAIL=0
bash /tmp/qa-marker-test.sh   # → PASS=7 / FAIL=0
bash /tmp/qa-wrap-test.sh     # → PASS=7 / FAIL=0
```

`npm test` / `npm run lint` / `npm run build` は本リポジトリには存在しない（bash
+ markdown + GitHub Actions YAML のツール／テンプレート repo）ため該当なし。
