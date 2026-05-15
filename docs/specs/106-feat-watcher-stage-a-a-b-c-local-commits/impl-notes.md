# 実装ノート — Issue #106

## 実装した変更箇所

### `local-watcher/bin/issue-watcher.sh`

- **追加**: `verify_pushed_or_retry <stage_id> <branch> <stage_label>` ヘルパー関数
  （`mark_issue_failed` の直前、約 3201 行目に配置）
  - ローカル HEAD が upstream より進んでいないかを `git rev-list --count @{u}..HEAD` で測定
  - ahead == 0 → return 0、副作用なし（Req 1.3 / 2.3 / 3.3 / 5.1）
  - ahead > 0 または判定不能 → WARN ログ + 自動 `git push origin <branch>` リトライ 1 回
    - 成功 → WARN ログ + Issue コメント投稿 + return 0（Req 4.2 / 4.3 / NFR 2.2）
    - 失敗 → `mark_issue_failed "$stage_id" "$fail_body"` + return 1（Req 4.4 / 4.5 / NFR 2.3）
  - `git rev-list` / `git push` には GNU coreutils `timeout` が利用可能なら 30 秒上限を付与（NFR 1.2）
  - 判定不能（空文字 / 非数値）も「未 push と同等扱い」で安全側に倒す（Req 1.4）
  - `--force-with-lease` 等の force 系オプションは **使わない**（Open Question 3 の design 確定）

- **追加**: Stage A 完了成功路に verify 呼び出しを挿入（stage_id=`stageA-push-missing`）
- **追加**: Stage A' 完了成功路に verify 呼び出しを挿入（stage_id=`stageA-prime-push-missing`）
- **追加**: Stage B (Reviewer round=1 approve / round=1 reject / round=2 approve / round=2 reject) に verify 呼び出しを挿入
  - round=1 approve / round=1 reject / round=2 approve: 失敗時 `return 1` で claude-failed 経路
  - round=2 reject: best-effort 実行（`|| true`）、より情報量の多い `reviewer-reject2` 経路を優先

### `local-watcher/test/verify_pushed_or_retry_test.sh`（新規追加）

ローカル bare repo を fake origin として用いる擬似環境で 4 ケース 17 アサーションを検証。
外部ネットワーク呼び出し（GitHub API / 実 origin への push）を一切しない（Req 6.4）。

- **Case 1**: ahead == 0 → return 0、`$LOG` 行数 0（Req 1.3 / 2.3 / 3.3 / 5.1）
- **Case 2**: ahead > 0 + push 成功 → return 0、gh issue comment 投稿、bare 側に commit 到達（Req 4.1 / 4.2 / 4.3 / NFR 2.1 / 2.2）
- **Case 3**: ahead > 0 + push 失敗（bare の refs に chmod 000）→ return 1、`mark_issue_failed` 呼出（stage=`stageA-prime-push-missing`）、虚偽の成功メッセージなし（Req 4.4 / 4.5 / 4.6 / NFR 2.3）
- **Case 4**: stage 識別子 `stageB-push-missing` + stage_label "Stage B (round=1 approve)" が log に出力されることを確認（Req 3.4 / Open Question 4）

実行方法: `bash local-watcher/test/verify_pushed_or_retry_test.sh`

## スモークテスト結果

### shellcheck

```
shellcheck local-watcher/bin/issue-watcher.sh
→ 新規追加分は警告ゼロ。pre-existing SC2317 / SC2012 (info) のみ残存（既存と同パターン）

shellcheck local-watcher/test/verify_pushed_or_retry_test.sh
→ 警告ゼロ（既存 test と同じ SC2317 info パターンのみ）
```

### 全テスト結果

```
=== parse_review_result_test.sh ===       PASS: 19, FAIL: 0
=== qa_detect_rate_limit_test.sh ===      PASS: 10, FAIL: 0
=== qa_run_claude_stage_test.sh ===       PASS: 23, FAIL: 0
=== stagec_pr_verify_test.sh ===          PASS:  8, FAIL: 0
=== verify_pushed_or_retry_test.sh ===    PASS: 17, FAIL: 0 (新規)
                                          ───────────────────
合計                                       PASS: 77, FAIL: 0
```

## 実装上の判断

### Open Questions の確定（要件定義より引き継ぎ）

| Open Question | 確定内容 | 理由 |
|---|---|---|
| 1. Issue コメント粒度 | stage 単位で 1 件投稿 | 観測性優先。stage 識別子・branch・commit 数をコメント本文に明記し、運用者が事後追跡しやすくする |
| 2. Stage B での扱い | Reviewer の reject / approve 両方で verify 経路を走らせる | Req 3.1 の "reject / approve いずれも含む" に厳密準拠。round=2 reject のみは reviewer-reject2 を優先するため best-effort |
| 3. push オプション | plain `git push origin <branch>` (fast-forward のみ) | 既稼働 cron 環境で意図せぬ history 書き換えを起こさないため。`_resume_push` (#67) と同じ非破壊ポリシー |
| 4. stage 識別子命名 | `stageA-push-missing` / `stageA-prime-push-missing` / `stageB-push-missing` | 既存 `stageC-pr-missing` (#104) との一貫性を取った命名 |

### Stage B (round=2 reject) の特殊扱い

要件 3.1 は "reject / approve いずれも含む" と明記しているが、round=2 reject の出力経路は
既に `reviewer-reject2` で claude-failed 化が確定している。verify 失敗時に
`mark_issue_failed "stageB-push-missing"` を呼ぶと、より情報量の多い reject 理由（target ID /
category / review-notes.md 参照）が失われる。そのため round=2 reject だけは
`verify_pushed_or_retry ... || true` の best-effort 実行とし、reject 経路を優先する。

- ahead == 0 / 自動 push 成功時: WARN ログ / Issue コメントは投稿される（観測性は維持）
- 自動 push 失敗時: stageB-push-missing コメントと reviewer-reject2 コメントが両方残る
  （想定としては稀。運用者は両方の情報を見られる）

### Feature Flag Protocol の不採用

`CLAUDE.md` には `## Feature Flag Protocol` 節が存在しない（idd-claude 自体は opt-out）。
本実装は単一実装パスで Stage 完了直後に verify を実行する。既存挙動との後方互換性は
「ahead == 0 ケースの副作用なし return 0」で担保する（Req 5.1, NFR 1.1）。

### 既存 stage 終了コード / ラベル契約の保全

- 終了コード `0`（成功）・`99`（quota 検出）・それ以外（既存失敗）の意味を変えない（Req 5.2）
- `claude-picked-up` / `claude-failed` / `needs-quota-wait` 等のラベル遷移契約を変えない（Req 5.3）
- 既存 env var 名（`REPO` / `REPO_DIR` / `BRANCH` 等）を変えない（Req 5.2）

### timeout コマンドの可搬性

GNU coreutils の `timeout` が利用可能（Linux / cron 環境）であれば 30 秒上限を付与する。
BSD / macOS 標準環境では `command -v timeout` が空配列を返し、timeout なしで実行する。
これにより既存 cron / launchd 環境で互換性を維持しつつ、Linux 主流環境ではハング防止
を効かせる。

## AC とテスト・実装のマッピング

| AC ID | 内容 | 担保したテスト / 実装 |
|---|---|---|
| 1.1 | Stage A 完了前に verify | 実装: Stage A `case "$_qa_rc_a" in 0)` ブロック内 `verify_pushed_or_retry "stageA-push-missing"` 呼出 |
| 1.2 | ahead > 0 検出時 WARN ログ | 実装: `qa_warn` 呼出（Stage A）。Test: Case 2 / Case 4（`$LOG` に "auto-push retry" / stage_label 行） |
| 1.3 | ahead == 0 時 従来挙動 | Test: Case 1（rc=0 / `$LOG` 行数 0） |
| 1.4 | git 判定不能時 安全側に倒す | 実装: `[[ "$ahead_count" =~ ^[0-9]+$ ]]` で非数値→"unknown"扱いで push リトライへ進行 |
| 2.1 | Stage A' 完了前に verify | 実装: Stage A' `case "$_qa_rc_aredo" in 0)` 内 `verify_pushed_or_retry "stageA-prime-push-missing"` |
| 2.2 | Stage A' ahead > 0 WARN | 実装: 同上（Stage A' label） |
| 2.3 | Stage A' ahead == 0 従来挙動 | Test: Case 1（共通 helper） |
| 3.1 | Stage B 完了前に verify (reject/approve) | 実装: Reviewer round=1 approve / reject、round=2 approve / reject 各分岐で `verify_pushed_or_retry "stageB-push-missing"` |
| 3.2 | Stage B ahead > 0 WARN | 実装: 同上（Stage B label） |
| 3.3 | Stage B ahead == 0 従来挙動 | Test: Case 1（共通 helper） |
| 3.4 | review-notes.md 識別ログ粒度 | 実装: stage_label に "Stage B (round=1 approve)" 等を含める。Test: Case 4 |
| 4.1 | ahead > 0 → push リトライ 1 回 | 実装: `verify_pushed_or_retry` 内 1 回のみ実行（無ループ）。Test: Case 2 / Case 3 |
| 4.2 | リトライ成功 → 継続 + WARN | 実装: success ブロック。Test: Case 2 (rc=0 / mark_issue_failed 未呼出) |
| 4.3 | リトライ成功 → Issue コメント | 実装: gh issue comment 呼出。Test: Case 2（gh args / body 検証） |
| 4.4 | リトライ失敗 → mark_issue_failed | 実装: fail ブロック。Test: Case 3 (stage=stageA-prime-push-missing) / Case 4 (stage=stageB-push-missing) |
| 4.5 | リトライ失敗 → 成功メッセージ出力なし | 実装: 呼出側が return 1 で抜けるため `echo "✅ ... 完了"` に到達しない。Test: Case 3（`$LOG` に "完了" 文言なし） |
| 4.6 | リトライ 1 回上限 | 実装: `verify_pushed_or_retry` 内に loop なし。Test: Case 3（失敗時に再試行しない、mark_issue_failed が即発火） |
| 5.1 | ahead == 0 時 出力同一 | Test: Case 1（`$LOG` 行数 0、副作用なし） |
| 5.2 | env var / 終了コード意味不変 | 実装: 既存 env var 名（`REPO` / `BRANCH` / `LOG` 等）と終了コード（0 / 99 / その他）の意味を変更していない |
| 5.3 | ラベル遷移契約不変 | 実装: 失敗時は既存 `mark_issue_failed` 経由で `claude-failed` を付与（新ラベル不導入） |
| 6.1 | push 成功経路テスト | Test: Case 2 |
| 6.2 | push 失敗 → claude-failed テスト | Test: Case 3 |
| 6.3 | ahead == 0 通常成功テスト | Test: Case 1 |
| 6.4 | 外部ネットワーク不要 | Test: ローカル bare repo + fake gh / mark_issue_failed |
| 6.5 | 既存テスト不破壊 | 確認済: parse_review_result / qa_detect_rate_limit / qa_run_claude_stage / stagec_pr_verify 全 60 ケース PASS |
| NFR 1.1 | ahead == 0 で +1 秒以内 | 実装: 単一 `git rev-list` で完結（典型 ~10ms）。Test: Case 1 で実行時間 1 秒未満 |
| NFR 1.2 | git クエリに 30 秒 timeout | 実装: `command -v timeout >/dev/null` で `timeout 30` prepend |
| NFR 2.1 | 検出/リトライ単一行 log | 実装: `qa_warn` 1 行 + `echo` 1 行で複数行可。Test: Case 2 / Case 4 で `$LOG` 検査 |
| NFR 2.2 | Issue コメント本文に Issue 番号 / stage / branch / commit 数 | 実装: comment_body に全項目を含める。Test: Case 2 で gh args / body grep |
| NFR 2.3 | 失敗時 ログ粒度 | 実装: `qa_warn` で stage_id / branch / push_rc / stderr_tail 出力。`mark_issue_failed` body にも明示 |
| NFR 3.1 | cron / 配置先 / 依存 CLI 不変 | 実装: 追加依存なし（`timeout` は optional） |
| NFR 3.2 | self-hosting 環境で有効 | 実装: 既存 watcher (idd-claude 自体) に対しても同等動作 |

## 確認事項

なし。要件定義の Open Questions はすべて Developer 判断で確定済み（上記表参照）。
仕様の追加・解釈変更はしていない。

### Reviewer / PjM 向けレビューポイント

1. **Stage B (round=2 reject) の best-effort 扱い** が要件 3.1 の "reject / approve いずれも含む" の解釈として
   許容範囲か。verify 失敗時に reviewer-reject2 経路を優先する判断（情報量の多い失敗カテゴリを残す目的）が
   妥当か Reviewer に確認願いたい。
2. **push オプション**: 既稼働 cron 環境保護のため plain `git push origin <branch>` のみ採用。
   `--force-with-lease` が必要なケース（rebase 後の検出など）は本 Issue のスコープ外として扱った。
3. **timeout コマンド可搬性**: GNU coreutils 不在の BSD / macOS 環境では timeout なしで実行する。
   Linux 主流の cron 環境では 30 秒上限が効く。idd-claude self-hosting 環境（Linux）でも問題なく動作する想定。
