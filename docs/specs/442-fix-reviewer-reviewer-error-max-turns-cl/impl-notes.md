# Implementation Notes — #442 Reviewer error_max_turns 拡張リトライ

## 概要

独立 Reviewer（per-task 経路 `run_per_task_reviewer` / 単発経路 `run_reviewer_stage`）が
claude 実行を turn 切れ（`error_max_turns`）で終了した場合に、即 `claude-failed` とせず
拡張 turn 予算で同一 round 内に 1 回だけリトライする救済を実装した。拡張リトライ後もなお
turn 切れで verdict 未到達なら、`reviewer-error` / `reviewer-missing-file` / code reject の
いずれとも区別される `reviewer-max-turns-exhausted`（per-task 経路は
`per-task-reviewer-max-turns-exhausted`）カテゴリで escalation する。

本 Issue は Architect ゲートを経ていない（Triage `needs_architect=false` で PM→Developer 直行）
ため `design.md` / `tasks.md` は存在せず、`requirements.md` を直接の根拠として実装した。

## 実装の要点（file:line 参照）

- 純粋ヘルパー 2 関数を Config ブロック直前（前方参照のため）に追加:
  - `reviewer_normalize_extended_max_turns`（`local-watcher/bin/issue-watcher.sh:1281` 付近）—
    拡張 turn 予算の決定的正規化（未設定/不正値→base×2、base 未満→base 引き上げ）
  - `reviewer_is_error_max_turns`（同 `:1320` 付近）— stream-json の最後の result イベント
    subtype で turn 切れ判定。`tu_*` 未ロード時は安全側で非検出
- 既定値変更: `REVIEWER_MAX_TURNS` `30→50`、新 env `REVIEWER_MAX_TURNS_EXTENDED`
  （既定 base×2 / 起動時に正規化）
- per-task 経路 `run_per_task_reviewer`: missing-file リトライ（`for attempt in 1 2`）と
  直交する turn 切れ拡張リトライ内側ループ（`for _mt_inner in 1 2`）を追加。枯渇時 return 6
- 単発経路 `run_reviewer_stage`: 上記と対称の内側ループ（`_mt_inner_rv`）。枯渇時 return 6 +
  `rs_record_reviewer degraded`
- caller（`run_per_task_loop` round 1/2/3、`run_impl_pipeline` round 1/2/3）に rc=6 ハンドラを
  追加し、区別された失敗カテゴリで `claude-failed` + Issue コメント

return code 6 は内部関数の戻り値であり、スクリプトの exit code 意味は変えない（NFR 1.2 保持）。

## AC ↔ 実装 / テストのトレーサビリティ

| AC | 実装 | 担保テスト |
|---|---|---|
| 1.1 turn 切れ→拡張 turn で 1 回リトライ | 両経路の内側ループ `_mt_inner(_rv)` | flow ケース1（return 0、base→EXTENDED 起動） |
| 1.2 リトライ後 verdict 取得で既存経路合流 | break 後 `case _qa_rc` 0 分岐 | flow ケース1 |
| 1.3 リトライは同一 round 1 回限定 | `_max_turns_retry_used(_rv)` フラグ + 内側ループ上限 2 | flow ケース2（base→EXTENDED の 2 回のみ） |
| 1.4 per-task 経路で同一挙動 | `run_per_task_reviewer` 内側ループ | retry テスト群（ヘルパー共有）/ flow（単発経路で挙動同型） |
| 1.5 単発経路で同一挙動 | `run_reviewer_stage` 内側ループ | flow ケース1〜4 |
| 2.1 turn 切れ以外は即 error | `reviewer_is_error_max_turns` false→break→`*)` 即 return 2 | flow ケース3（claude crash→return 2、base で 1 回のみ） |
| 2.2 ファイル不在は従来 attempt=2 経路 | 拡張リトライは rc≠0 のみ起動（rc=0 は既存 missing-file 経路） | flow ケース4（外形不変）/ 既存 #296 経路を温存 |
| 2.3 parse 失敗は従来どおり error | rc=0 で review-notes parse は既存経路、拡張リトライ非起動 | flow ケース4 + 既存挙動温存 |
| 2.4 判定は最後の result イベント subtype | `reviewer_is_error_max_turns`（`tu_extract_last_result_json`） | retry: `reviewer_is_error_max_turns` 8 ケース（subtype 別 / offset / 不在 / 空 / 未ロード） |
| 3.1 枯渇 escalation は区別された理由 | return 6 + `reviewer-max-turns-exhausted` カテゴリ | flow ケース2（return 6） |
| 3.2 Issue コメントに turn 切れ枯渇記録 | caller の `mark_issue_failed` / `publish_terminal_failure_artifacts` 文言 | flow ケース2（return 6 で caller 文言到達） |
| 3.3 run-summary に degraded 記録 | 単発経路 `rs_record_reviewer degraded` | flow ケース2（return 6 経路） |
| 3.4 grep 区別可能な文字列で発行 | reason `max-turns-exhausted` / カテゴリ識別子 | flow ケース2 |
| 3.5 / 3.6 両経路で同一 escalation | per-task / 単発双方に rc=6 ハンドラ | flow（単発）/ retry（ヘルパー）+ コード対称性 |
| 4.1 決定的に算出 | `reviewer_normalize_extended_max_turns` | retry: 正規化 10 ケース |
| 4.2 未設定なら既定（base×2） | `''` ケース→`default_ext` | retry「base 不正かつ raw 未設定なら 50×2=100」等 |
| 4.3 数値非解釈は破棄→既定 | `*[!0-9]*` ケース→`default_ext` | retry「不正値(abc/12x/負号)なら base×2」 |
| 4.4 base 以上に正規化 | `raw < base` なら base 出力 | retry「base 未満なら base に丸め」 |
| 4.5 override 尊重（既定値で上書きしない） | `REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-50}"` | flow（base=50 起動で観測）/ 既定 fallback 構文 |
| 4.6 拡張リトライ起動をログ記録 | `pt_log` / `rv_log` の `reason=max-turns-extended` 行 | flow ケース1（リトライ発火）|
| NFR 1.1 非適用時は導入前と同一 | rc=0/通常 reject/crash/missing-file 経路を温存 | flow ケース3・4（外形不変） |
| NFR 1.2 env 名/exit code 不変 | return 6 は内部戻り値のみ | コード（exit path 不変）|
| NFR 1.3 既定値引き上げの migration note | README migration note 追記 | 後述 README 同期 |
| NFR 2.1 / 2.2 可観測性（1 行ログ / grep 識別） | `reason=max-turns-extended` / `max-turns-exhausted` | flow / コード |
| NFR 3.1 README 同期 | README 4 箇所更新 | 後述 README 同期 |
| NFR 4.1 近接テスト | flow（8）/ retry（20） | 両テストファイル |

## テスト結果（サマリ）

- `bash -n local-watcher/bin/issue-watcher.sh` — OK
- `shellcheck local-watcher/bin/issue-watcher.sh <2 テスト>` — 警告ゼロ（exit 0）
- `bash local-watcher/test/reviewer_max_turns_flow_test.sh` — **PASS=8 FAIL=0**
- `bash local-watcher/test/reviewer_max_turns_retry_test.sh` — **PASS=20 FAIL=0**

## README 同期箇所（NFR 1.3 / NFR 3.1）

- env var テーブル（`README.md:5631`）: `REVIEWER_MAX_TURNS` 既定 `30→50`、`REVIEWER_MAX_TURNS_EXTENDED` 行追加
- Migration note ブロック追加（`README.md:5651` 付近）: 既定値引き上げの事実・影響範囲・拡張リトライ挙動・`reviewer-max-turns-exhausted` 障害カテゴリを記述
- cron 例（`README.md:5673` 付近）: `REVIEWER_MAX_TURNS=30→50`（任意整合）
- 「+1 Reviewer turn 分（既定 50 turn 上限）」（`README.md:5744`）
- 「Reviewer Round 3 … 最大 `REVIEWER_MAX_TURNS` (既定 50) ターン」（`README.md:7265`）

## 是正内容（Reviewer round1 reject への対応）

round1 reject は「実装が未 commit で `main..HEAD` が空」「README 未同期」の 2 Finding。是正:

- (a) commit した成果物一覧:
  - `local-watcher/bin/issue-watcher.sh`（実装）
  - `local-watcher/test/reviewer_max_turns_flow_test.sh` / `reviewer_max_turns_retry_test.sh`（テスト。shellcheck SC2034 の per-line disable 追記のみ調整）
  - `README.md`（同期）
  - `docs/specs/442-.../{requirements.md, review-notes.md, impl-notes.md}`（成果物）
- (b) AC↔実装/テストの紐付け: 上記トレーサビリティ表
- (c) テスト結果: flow 8/8・retry 20/20
- (d) README 同期箇所: 上記「README 同期箇所」
- (e) 確認事項: 下記「確認事項」

## 確認事項

- 本 Issue は Architect 非経由（Triage `needs_architect=false`）のため `design.md` / `tasks.md`
  は存在せず、`requirements.md` を直接の根拠として実装した。Reviewer Finding 1 が要求した
  `tasks.md` は **Architect の領分**であり Developer は捏造しない方針のため作成していない。
  オーケストレーター / 次 Reviewer への申し送りとしてここに明記する。
- flow テストファイルの調整は shellcheck SC2034 false-positive 抑止のための per-line
  `# shellcheck disable=SC2034` 追記のみで、テストロジック・アサーションは未変更（8/8 PASS 維持）。

STATUS: complete
