# 実装ノート — Issue #325 / stage 別トークン使用量の計測ログ（Token Usage Report）

## 概要

`qa_run_claude_stage`（全 stage の claude 実行が経由する Stage Wrapper）の完了時に、stream-json の
最終 `result` イベントから usage を抽出して `token-usage: stage=<label> ...` 1 行を `$LOG` に追記する
モジュール `token-usage.sh`（prefix `tu_`）を新設した。Issue 終端では `rs_emit`（#239）と同じ
EXIT trap に連結した `tu_emit_issue_summary` が合計 1 行を slot 出力（cron.log）へ吐く。

## 変更ファイル

1. `local-watcher/bin/modules/token-usage.sh`（新規、prefix `tu_`）
   - `tu_enabled` / `tu_mark_log_offset` / `tu_extract_last_result_json` / `tu_format_usage_kv` /
     `tu_report_stage_usage` / `tu_emit_issue_summary` の 6 関数（全 fail-open）
2. `local-watcher/bin/modules/quota-aware.sh`
   - `qa_run_claude_stage` 冒頭で実行前 `$LOG` 行数を `_tu_offset` として記録
   - opt-out / opt-in 両分岐の claude 完了後に `tu_report_stage_usage` を呼ぶ
     （`declare -F` ガード + `|| true` で未ロード環境・失敗時も従来挙動）
3. `local-watcher/bin/issue-watcher.sh`
   - `REQUIRED_MODULES` に `token-usage.sh` を登録（install.sh は modules/ glob 配布のため変更不要）
   - `_slot_run_issue` の EXIT trap を `rs_emit || true; tu_emit_issue_summary || true` に連結
4. `local-watcher/test/tu_token_usage_test.sh`（新規、22 ケース）
5. `README.md`
   - 「`token-usage:` 行（Token Usage Report, #325）」節を run-summary 節の直後に追加
   - 「オプション機能一覧」既定 ON 表に `TOKEN_REPORT_ENABLED` 行を追加

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| Req 1.1 | `tu_report_stage_usage` + `qa_run_claude_stage` 両分岐からの呼び出し | E2E スモーク（opt-out / opt-in / 失敗 rc=7 の 3 経路で行出力を確認） |
| Req 1.2 | 出力 prefix `[<ts>] [<REPO>] token-usage:`（rs_emit と同形） | テスト「stage 行に固定 prefix と repo を含む」 |
| Req 1.3 | result 行不在 → `tu_extract_last_result_json` 空 → silent skip | テスト「result 行不在なら何も出力しない」 |
| Req 1.4 | `tu_mark_log_offset` で実行前行数を記録し `tail -n +offset+1` で範囲限定 | テスト「offset 指定で範囲前の result 行(A)を無視する」 |
| Req 1.5 | jq の `// 0` / models `-` 補完 | テスト「欠落フィールドは 0 / models は - に補完」 |
| Req 2.1 | EXIT trap 連結（`_slot_run_issue`） + `tu_emit_issue_summary` | テスト「サマリ行の合計値が正しい」+ E2E スモーク |
| Req 2.2 | stage 行ゼロ → return 0（出力なし） | テスト「stage 行ゼロならサマリを出力しない」 |
| Req 2.3 | `rs_emit || true; tu_emit_issue_summary || true` の順で連結（rs_emit 不変） | 文面確認 + 既存スイート green |
| Req 3.1/3.2 | `tu_enabled`（`false|0|no|off` のみ無効、RUN_SUMMARY と同一規則） | テスト 5 ケース（typo `False` は有効側） |
| NFR 1.1 | 追記のみ。env / ラベル / exit code / cron 文字列に変更なし | grep + 既存スイート green |
| NFR 1.2 | claude rc / 99 sentinel 透過（opt-out 分岐は set +e で rc 捕捉 → tu 呼び出し → return rc） | E2E スモーク case3（rc=7 透過） |
| NFR 1.3 | 全呼び出しを `declare -F` ガード | `qa_run_claude_stage_test.sh`（隔離抽出）green |
| NFR 2.1 | shellcheck クリーン（変更 3 ファイル + 新テスト） | 後述 |
| NFR 2.2 | 既存スイート全 PASS | 後述 |
| NFR 2.3 | `tu_token_usage_test.sh` 22 ケース | 後述 |

## 検証結果

- `shellcheck local-watcher/bin/modules/token-usage.sh local-watcher/bin/modules/quota-aware.sh local-watcher/test/tu_token_usage_test.sh` → 警告ゼロ。
  `issue-watcher.sh` は main 由来の既存 SC2329 info 6 件のみ（本変更による新規警告ゼロ）
- テストスイート `local-watcher/test/*_test.sh` → **23/23 PASS**（新規 1 件含む）
- E2E スモーク（stub claude）:
  - opt-out 経路（`QUOTA_AWARE_ENABLED=false`）→ `token-usage: stage=StageA ...` が $LOG に追記、rc=0
  - opt-in 経路（tee + 検出 pipe）→ 同様に追記
  - 失敗経路（stub rc=7）→ 行追記 + **rc=7 を透過**
  - サマリ → `token-usage: issue=#325 total ... stages=1`

## 設計上の判断

- **offset 方式（Req 1.4）**: claude が crash して result 行を出さなかった場合、`$LOG` 末尾grep だけだと
  直前 stage の result を誤って現 stage として報告する。実行前の行数を offset として渡し、抽出範囲を
  当該 stage の追記分に限定した
- **quota 検出（exit 99）より先に report**: 99 経路でも実行済み分の usage は観測価値があるため、
  detect 解釈の前に report を呼ぶ
- **config ブロックに env を追加しない**: `RUN_SUMMARY_ENABLED`（#239）の先例に従い、モジュール側で
  env を直接評価（本体 config ブロックの diff を増やさない）。ドキュメントは README の機能一覧表が正本
- **既定 ON の妥当性**: 出力は既存ログへの行追記のみで、exit code / ラベル / 既存行に影響しない
  （#239 と同じ判断）。`false|0|no|off` で抑止可能

## 確認事項（PR レビュワー向け）

- `qa_run_claude_stage` opt-out 分岐の `"$@"; return $?` を `set +e` + rc 捕捉に書き換えたが、
  既存 call site は全て `|| rc=$?` ガード付きのため挙動は等価（opt-in 分岐が従来から同じパターン）。
  `qa_run_claude_stage_test.sh` が green であることで担保
- Claude Max サブスクリプション運用では `cost_usd` は参考値（README に明記済み）
- PR Iteration / auto-rebase の claude 直接呼び出しは対象外（Out of Scope。必要になったら
  `tu_report_stage_usage` を同パターンで配線できる）

## 派生タスク候補

- Triage の stream-json 化（#332 の `--bare` 化とあわせて検討すれば Triage も計測対象にできる）
- `token-usage:` 行を集計して Issue コメントへ投稿する opt-in（運用での要望が出たら）
