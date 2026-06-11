# 要件定義: stage 別トークン使用量の計測ログ（Token Usage Report）

- Issue: [#325](https://github.com/hitoshiichikawa/idd-claude/issues/325) "watcher: stage 別トークン使用量を stream-json result から集計してログ出力する"
- 対象ファイル想定: `local-watcher/bin/modules/token-usage.sh`（新規）、`local-watcher/bin/modules/quota-aware.sh`（`qa_run_claude_stage` への配線）、`local-watcher/bin/issue-watcher.sh`（`REQUIRED_MODULES` 登録 / EXIT trap 連結）、`README.md`

## Introduction

watcher の各 stage（Stage A / A' / B / C / design 等）は `claude --print --output-format stream-json --verbose` の全イベントを `$LOG` に保存しているが、最終 `result` イベントに含まれる `usage`（input / output / cache トークン数）・`num_turns`・`total_cost_usd` を活用していない。トークン消費の最適化（モデル選定・固定オーバーヘッド削減）の効果測定には stage 別の実測値が不可欠である。

本機能は `qa_run_claude_stage`（全 12 call site が経由する Stage Wrapper）の完了時に、当該 stage が `$LOG` へ追記した範囲から最後の `result` イベントを抽出し、機械可読な `token-usage:` 1 行を追記する。Issue 処理終端では stage 横断の合計 1 行を出力する（`run-summary:`（#239）と同型の observability 機能）。

## Requirements

### Requirement 1: stage 別 token-usage 行の出力

**Objective:** As a watcher 運用者, I want stage ごとのトークン使用量を `$LOG` から grep で集計したい, so that モデル変更や固定オーバーヘッド削減の効果を実測で比較できる

#### Acceptance Criteria

1. When `qa_run_claude_stage` がラップした claude 実行が完了したとき（exit code を問わない）, the Token Usage Reporter shall `$LOG` に `token-usage: stage=<stage_label> in=<n> cache_read=<n> cache_write=<n> out=<n> turns=<n> cost_usd=<x> models=<ids>` 形式の 1 行を追記する
2. The Token Usage Reporter shall 出力行の時刻 prefix と repo 識別子を既存ログ規約（`[<ts>] [<REPO>]`、`run-summary:` 行と同形）に揃える
3. If 当該 stage の実行中に追記されたログ範囲に有効な `result` イベント行が存在しない場合（stream-json 非使用の Triage / claude crash 等）, the Token Usage Reporter shall 行を出力せず正常継続する
4. The Token Usage Reporter shall stage 実行前の `$LOG` 行数を offset として記録し、offset 以降の範囲のみから `result` 行を抽出する（直前 stage の `result` 行を誤って現 stage として集計しない）
5. If `result` イベントに `usage` の一部フィールドや `modelUsage` / `total_cost_usd` が欠落している場合, the Token Usage Reporter shall 欠落値を `0`（models は `-`）として行を出力する

### Requirement 2: Issue 単位サマリの出力

**Objective:** As a watcher 運用者, I want 1 Issue の処理全体で消費したトークンの合計を 1 行で知りたい, so that Issue 単位のコストを cron.log の grep だけで把握できる

#### Acceptance Criteria

1. When `_slot_run_issue` のサブシェルが終端したとき（正常 / 失敗 / 早期 return のいずれでも）, the Token Usage Reporter shall `$LOG` 中の全 `token-usage: stage=` 行を集計した `token-usage: issue=#<N> total in=<n> ... stages=<count>` 形式の 1 行を出力する
2. If `$LOG` に `token-usage: stage=` 行が 1 件も存在しない場合, the Token Usage Reporter shall サマリ行を出力しない
3. The Token Usage Reporter shall サマリ出力を既存 `rs_emit`（run-summary）と同じ EXIT trap 経路に連結し、`rs_emit` の発火を妨げない

### Requirement 3: 無効化スイッチ

**Objective:** As a watcher 運用者, I want ログノイズを env 1 つで抑止したい, so that 計測不要のリポジトリで出力を止められる

#### Acceptance Criteria

1. While `TOKEN_REPORT_ENABLED` が lowercase の `false` / `0` / `no` / `off` のいずれかであるとき, the Token Usage Reporter shall stage 行・サマリ行とも一切出力しない
2. The Token Usage Reporter shall 上記以外の値（未設定 / 空文字 / typo を含む）をすべて有効として扱う（`RUN_SUMMARY_ENABLED` と同一の正規化規則）

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher shall 既存の env var 名 / ラベル名 / exit code 意味 / cron 登録文字列 / 既存ログ行を変更しない（`token-usage:` 行の追記のみ）
2. The Token Usage Reporter shall `qa_run_claude_stage` の戻り値（claude exit code / 99 sentinel）を透過し、抽出・整形の失敗が stage の成否判定に影響しない（fail-open）
3. When `token-usage.sh` が読み込まれていない環境（`extract_function` による隔離抽出テスト等）で `qa_run_claude_stage` を実行したとき, the Stage Wrapper shall 従来と同一の挙動で完走する（`declare -F` ガード）

### NFR 2: 静的解析・テスト

1. When `shellcheck` を変更ファイルへ実行したとき, the build pipeline shall 本変更による新規警告を 0 件にする
2. The build pipeline shall 既存テストスイート（`local-watcher/test/*_test.sh`、特に `qa_run_claude_stage_test.sh`）を全 PASS のまま維持する
3. The Token Usage Reporter shall 純粋関数（抽出 / 整形 / 集計）に対する近接テスト `local-watcher/test/tu_token_usage_test.sh` を持つ

## Out of Scope

- Triage stage の stream-json 化（現状 stream-json 非使用のため Req 1.3 により silent skip。#332 とも独立）
- `qa_run_claude_stage` を経由しない claude 呼び出し（`pr-iteration.sh` の Iteration 実行・`auto-rebase.sh` の rebase 実行）の計測
- Issue コメント等 GitHub への出力（ログのみ。将来 opt-in で検討）
- cost_usd の課金請求額としての保証（Claude Max サブスクリプションでは参考値）
- 集計結果に基づく自動制御（モデル切替・abort 等）
