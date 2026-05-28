# Implementation Notes — Issue #259

## 概要

Claude API の一時的な過負荷（HTTP 529 Overloaded）が原因で自動開発フロー（Issue Stage A〜C・
PR Iteration の round 反復）が中断した際、サーバーログだけでなく Issue / PR コメントとして
警告を可視化することで、運用者が GitHub 画面のみで「待つべき一時障害」と「恒常的な失敗」を
判別できるようにする。

## 設計判断

### 共通化方式: core_utils.sh に純粋関数として配置

検知ロジックは 2 箇所（`pr-iteration.sh` の `pi_run_iteration` / `issue-watcher.sh` の
`mark_issue_failed`）で使用するため、`local-watcher/bin/modules/core_utils.sh` に
`claude_log_detect_529` を新規追加した。

理由:
- すでに両モジュールが本ファイル経由でロガー（`pi_log` / `qa_log` 等）を共有しており、
  追加の依存読み込み不要。
- 関数本体が小さく（~60 行）独立モジュールに切り出す必要はないと判断。
- 純粋関数（副作用なし、戻り値で結果を返す）として実装し、テストしやすく既存挙動への
  影響を最小化。

### 検知パターン

要件・Issue 本文の例示を踏まえ、以下を OR 結合で検知する:

| パターン | 用途 |
|---|---|
| `"(api_error_status\|error_status\|status)"\s*:\s*529` | JSON key 隣接の 529（Anthropic API stream 内 / wrapper のエラー応答） |
| `\bstatus\s*:\s*529\b` | plain text の `status: 529` 表記 |
| `"type"\s*:\s*"overloaded_error"` | Anthropic API 標準のエラー type 文字列 |
| `\bOverloaded\b` | HTTP 529 の reason phrase（単語境界で false-positive を抑止） |

**false-positive 対策**:
- `529` の数値単独検出はしない（git hash・metric 値・ID 等で頻出するため）
- `Overloaded` は大文字始まりの単語境界限定（`overloaded_user` 等の混入を回避）

### 副作用の隔離

両 caller とも、検知ロジックが失敗・例外を起こしても **既存の失敗処理を妨げない** よう
defensive に実装:

- `pr-iteration.sh`: 検知後の PR コメント投稿失敗は `pi_warn` のみ。`needs-iteration`
  据え置き / `post-round-recover` / SHA 比較 / no-progress streak 加算等の既存フローは
  そのまま継続される。
- `issue-watcher.sh::mark_issue_failed`: 検知ロジック呼び出しは `|| _mif_529_rc=$?` で
  rc を吸収。検知成否にかかわらず `gh issue edit … --add-label claude-failed` と
  `gh issue comment …` は実行される。

### ログ可観測性 (NFR 2.1)

検知結果は `$LOG` および watcher のサーバーログから事後追跡できるよう、3 状態
（detected / not-detected / log-missing）を 1 行ずつ出力:

- PR Iteration: `pi_log` / `pi_warn` 経由で processor prefix 付き 1 行サマリ
- Issue Watcher: `$LOG` に 1 行追記（best-effort、書き込み失敗は無視）

### 後方互換性 (NFR 3.1 / Req 4.x)

- 既存 env var 名 / cron 文字列 / ラベル名 / exit code に **一切変更なし**
- 529 検知パターンが当てはまらない既存ログでは旧フローと完全に等価
- gh コメント投稿失敗時も既存処理（needs-iteration 据え置き / claude-failed 付与）は完遂

## 実装ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `local-watcher/bin/modules/core_utils.sh` | `claude_log_detect_529` 関数を追加（純粋検知関数 / 副作用なし） |
| `local-watcher/bin/modules/pr-iteration.sh` | `pi_run_iteration` の Claude 失敗分岐内で 529 検知 → PR コメント投稿 |
| `local-watcher/bin/issue-watcher.sh` | `mark_issue_failed` の本文組み立て時に 529 検知 → 警告ブロック挿入 |
| `README.md` | 「失敗時」節に 529 可視化機能の説明を追記 |
| `docs/specs/259-claude-api-529-issue-pr/test-fixtures/` | 8 件の fixture ログ + 検知関数のスモークテスト |

## テスト方法と結果

### 静的解析

```bash
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh \
  docs/specs/259-claude-api-529-issue-pr/test-fixtures/test-detect.sh
```

結果: **クリーン（警告 0）**

### スモークテスト

```bash
bash docs/specs/259-claude-api-529-issue-pr/test-fixtures/test-detect.sh
```

結果: **10/10 PASS**

```
PASS: log-529-api-error-status: api_error_status:529 (expected rc=0, got rc=0)
PASS: log-529-error-status: error_status:529 (expected rc=0, got rc=0)
PASS: log-529-status-numeric: 'status: 529' plain text (expected rc=0, got rc=0)
PASS: log-529-overloaded-error-type: type:overloaded_error (expected rc=0, got rc=0)
PASS: log-529-overloaded-word: Overloaded word boundary (expected rc=0, got rc=0)
PASS: log-normal-error: 通常の TypeError 等は誤検知しない (expected rc=1, got rc=1)
PASS: log-empty: 空ファイルは検知なし (expected rc=1, got rc=1)
PASS: log-false-positive-529: 単独 529 数値は誤検知しない (expected rc=1, got rc=1)
PASS: 存在しないパスは rc=2 (expected rc=2, got rc=2)
PASS: 空文字列パスは rc=2 (expected rc=2, got rc=2)
```

### 構文チェック

```bash
bash -n local-watcher/bin/issue-watcher.sh
bash -n local-watcher/bin/modules/core_utils.sh
bash -n local-watcher/bin/modules/pr-iteration.sh
```

結果: **3 ファイルとも syntax OK**

### E2E スモーク（本リポジトリ内での dogfooding）

本 PR が main に merge されると、idd-claude self-hosting 環境では次サイクル以降の
529 失敗時に新しい警告コメントが投稿されるようになる。実機での E2E は手動操作が
必要なため、本 PR では fixture スモークと shellcheck で代替する。

## 受入基準とテストの対応

| Req ID | 内容 | テスト / 実装担保 |
|---|---|---|
| 1.1 | PR Iteration 失敗時の 529 検知 → PR コメント投稿 | `pi_run_iteration` の 529 検知分岐 / `gh pr comment` 呼び出し |
| 1.2 | round カウンタ等の進捗据え置き | 検知分岐は既存の `recover_status` / marker 据え置きロジックを **変更せず**、警告コメント投稿のみ追加（NFR 1.1 等価） |
| 1.3 | 529 未検知時は警告コメントなし | `case "$_pi_529_rc" in 0)` 分岐のみがコメント投稿、`1` / `2` 分岐は log のみ |
| 1.4 | 正常終了時は警告コメントなし | 529 検知は `claude_rc -ne 0` 内でのみ呼び出される |
| 1.5 | ログ不在時は既存処理を継続 | `claude_log_detect_529` が `rc=2` を返し PR コメント投稿せず WARN ログのみ。`pi_run_iteration` の後続フロー（post-round-recover / marker 据え置き）は通常通り進む |
| 2.1 | Issue 失敗コメントに 529 警告を含める | `mark_issue_failed` の `case "$_mif_529_rc" in 0)` で body に警告ブロック追加 |
| 2.2 | 529 未検知時は警告文を含めない | `case` の `1` / `2` 分岐は body 改変なし |
| 2.3 | 正常進行中は警告投稿なし | `mark_issue_failed` は失敗経路でしか呼ばれない（既存の Stage 失敗 / Reviewer error / reject2 / 等） |
| 2.4 | ログ不在時も `claude-failed` 遷移とコメント投稿は完遂 | `claude_log_detect_529` の rc=2 分岐は警告ブロック付加をスキップするのみ。既存の `gh issue edit … --add-label claude-failed` / `gh issue comment …` は変更なく実行される |
| 3.1 | 日本語で 529 を明示 | 警告本文に「Claude API 一時混雑エラー (529 Overloaded)」を含む |
| 3.2 | 一時混雑である旨を明示 | 「一時的な混雑によるエラーの可能性」「混雑のため一時処理を中断しました」と明文化 |
| 3.3 | PR の場合は再試行と進捗据え置きを明示 | PR コメント文言: 「進捗（Round数等）は据え置かれ、次のポーリングサイクルで自動再試行します」 |
| 3.4 | Issue の場合は時間をおいた再試行を促す | Issue コメント文言: 「時間をおいて再試行してください」 |
| 4.1 | API 呼び出し回数を増やさない | 検知は **既存ログのファイル読み取りのみ**、Claude API 再呼び出しなし |
| 4.2 | ラベル遷移タイミングを変更しない | `claude-failed` / `needs-iteration` / `claude-picked-up` 関連の `gh issue edit` / `gh pr edit` には触れていない |
| 4.3 | ログフォーマットを破壊しない | 既存ログ行に変更なし。529 関連の新規ログは `pi_log` / `echo …>>$LOG` の独立行のみ |
| 4.4 | 529 検知処理失敗時も既存責務を完遂 | `claude_log_detect_529` の grep は `\|\| true` 不要（rc=1 を関数戻り値として返すため呼び出し元で吸収）。`gh` 呼び出し失敗は `pi_warn` のみで投稿スキップ |
| NFR 1.1 | 例外発生でも既存処理を継続 | 検知ロジックは set -euo pipefail 配下でも grep/test の rc を `\|\| _rc=$?` で握っており致命化しない |
| NFR 1.2 | 重複コメント抑止 | PR Iteration 側は HTML hidden marker `<!-- idd-claude:pr-iteration-529-warning round=N -->` を入れ、同一 round 内では 1 件のみ（`pi_run_iteration` は round あたり 1 回呼ばれる）。Issue 側は失敗通知コメントに **内包** するため 1 失敗イベント = 1 コメント |
| NFR 2.1 | サーバーログでの追跡 | detected / not-detected / log-missing の 3 状態それぞれが `$LOG` または stdout（processor prefix 付き）に 1 行記録される |
| NFR 3.1 | 既存 env / ラベル / cron の互換性 | 新規 env 変数なし、既存名称への変更なし |

## 確認事項（PR レビュワー判断ポイント）

- **検知パターンの網羅性**: Anthropic API の実応答 JSON 構造はサーバ側の実装で変わる
  可能性があるため、現状の 5 パターンで取りこぼしが出る場合は将来追加する余地を残している。
  運用ログを蓄積した上で必要なら拡張する。
- **PR コメント / Issue コメントの文言**: Issue #259 本文の例示と一致させたが、運用上
  もっと簡潔・もっと詳細にしたい等のフィードバックは PR レビューで提案歓迎。
- **重複抑止の hidden marker**: `<!-- idd-claude:pr-iteration-529-warning round=N -->` を
  入れているが、現状 watcher 側でこの marker を再走査するロジックは追加していない
  （`pi_run_iteration` が round あたり 1 回しか呼ばれない構造により自然に 1-per-round
  になるため）。将来 round 内で 2 回呼ばれる経路が増えた場合は marker 走査で重複抑止する。
- **dogfooding 観点**: idd-claude self-hosting 自体が 529 を踏んで本機能を発火させる
  ケースの観測は cron 実機運用上で確認することになる。本 PR の時点では fixture スモーク
  でのカバーに留まる。

## 補足: 検知パターンを追加したい場合

`local-watcher/bin/modules/core_utils.sh` の `claude_log_detect_529` 内に `grep -qE` の
1 行を追加し、対応する fixture を `docs/specs/259-claude-api-529-issue-pr/test-fixtures/`
に追加して `test-detect.sh` に assertion を増やすだけで拡張できる。

STATUS: complete
