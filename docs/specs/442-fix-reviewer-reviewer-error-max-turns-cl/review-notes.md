# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-8 timestamp=2026-06-29T14:40:00Z -->

## Reviewed Scope

- Branch: claude/issue-442-impl-fix-reviewer-reviewer-error-max-turns-cl
- HEAD commit: 32fbcc3687b78f4104e8a6b96601b9e2e3873b4b
- Compared to: main..HEAD

ROUND=1 は `main..HEAD` が空（実装未 commit）で AC を 1 件も verify できず reject だったため、
本 ROUND=2 は実質的な初回フルレビューとして全 numeric AC を突き合わせた。

## Verified Requirements

- 1.1 — turn 切れ拡張リトライ内側ループ（`run_reviewer_stage` の `for _mt_inner_rv in 1 2` /
  `run_per_task_reviewer` の `for _mt_inner in 1 2`）+ `reviewer_is_error_max_turns` 判定。flow ケース1（return 0、base→EXTENDED 起動）
- 1.2 — リトライ後 break → `case _qa_rc 0` 分岐で既存 verdict 経路に合流。flow ケース1
- 1.3 — `_max_turns_retry_used(_rv)` フラグ + 内側ループ上限 2 で 1 回限定。flow ケース2（base→EXTENDED の 2 回のみ起動）
- 1.4 — per-task 経路 `run_per_task_reviewer` に単発経路と対称の内側ループ。共有ヘルパー + 対称コード
- 1.5 — 単発経路 `run_reviewer_stage`。flow ケース1〜4
- 2.1 — `reviewer_is_error_max_turns` false → break → `*)` 即 return 2。flow ケース3（claude crash→return 2、base 1 回のみ）
- 2.2 — 拡張リトライは rc≠0 のみ起動。rc=0 ファイル不在は既存 `for attempt in 1 2` 経路を温存。flow ケース4
- 2.3 — rc=0 の review-notes parse 失敗は既存 error 経路、拡張リトライ非起動
- 2.4 — `reviewer_is_error_max_turns`（`tu_extract_last_result_json` の最後の result subtype + offset）。retry テスト 8 ケース（subtype 別 / offset / 不在 / 空 / 未ロード安全側）
- 3.1 — 拡張リトライ後 turn 切れ枯渇で return 6 → `reviewer-max-turns-exhausted` /
  `per-task-reviewer-max-turns-exhausted` カテゴリ。flow ケース2（return 6）
- 3.2 — caller の `mark_issue_failed` / `publish_terminal_failure_artifacts` 文言に「turn 切れ枯渇」起因を明記
- 3.3 — 単発経路は `rs_record_reviewer degraded "" "$round"` を return 6 直前に呼出（flow ケース2 経路）。
  per-task 経路は既存アーキテクチャ（`run_per_task_loop` は `rs_record_reviewer` を使わず、Stage A の
  `rs_scan_degraded_log` で degraded を反映する設計）に追従（後述 Summary 参照）
- 3.4 — reason 文字列 `max-turns-exhausted` / カテゴリ識別子が `reviewer-error` /
  `reviewer-missing-file` と grep 区別可能
- 3.5 / 3.6 — per-task（round 1/2/3）/ 単発（round 1/2/3）双方に rc=6 ハンドラ + 区別カテゴリ + Issue コメント
- 4.1 — `reviewer_normalize_extended_max_turns`（決定的正規化）。retry テスト正規化 10 ケース
- 4.2 — 未設定 → base×2。retry「未設定なら base×2＝100」「base 不正かつ raw 未設定なら 50×2＝100」
- 4.3 — 数値非解釈 → 既定にフォールバック。retry「不正値(abc/12x/負号)なら base×2」
- 4.4 — base 未満 → base に丸め。retry「base 未満なら base に丸め」
- 4.5 — `REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-50}"` で override 尊重（既定値更新で上書きしない）
- 4.6 — 起動時 `reason=max-turns-extended extended-max-turns=N` の 1 行ログ（`rv_log` / `pt_log`）。flow ケース1
- NFR 1.1 — turn 切れ以外（crash / missing-file / approve / reject）は外形不変。flow ケース3・4
- NFR 1.2 — return 6 は内部関数戻り値のみ。スクリプト exit code / env var 名は不変
- NFR 1.3 — README に既定値 30→50 引き上げの migration note 追記
- NFR 2.1 / 2.2 — round/attempt/拡張 turn 予算/reason を 1 行ログ、grep 識別可能な reason 文字列
- NFR 3.1 — README 4 箇所同期（env var テーブル / migration note / cron 例 / 「既定 50 turn」2 箇所）
- NFR 4.1 — 近接テスト `reviewer_max_turns_flow_test.sh`（8/8 PASS）/ `reviewer_max_turns_retry_test.sh`（20/20 PASS）。reviewer 環境で再実行し green 確認

## Findings

なし

## Summary

ROUND=1 の 2 つの reject 理由（実装未 commit で `main..HEAD` 空 / README 未同期）はいずれも解消済み
（4 commit が積まれ、README は env テーブル・migration note・cron 例・既定 turn 数記述の 4 箇所を同期）。
全 numeric AC（1.1〜4.6 / NFR 1.1〜4.1）に観測可能な実装と近接テストが対応し、`bash -n` OK・
flow 8/8・retry 20/20 を再実行確認。boundary も `issue-watcher.sh` + README + テスト + spec docs のみで
`.claude/{agents,rules}` / template 不変（Out of Scope 準拠）。AC 3.3 の run-summary degraded 記録は
単発経路で明示（`rs_record_reviewer degraded`）、per-task 経路は既存アーキテクチャ（per-task は
`rs_record_reviewer` を使わず `rs_scan_degraded_log` で degraded を反映）に追従しており、Req 3 の運用者
切り分け目的は per-task でも 3.1/3.2/3.4（区別カテゴリ + Issue コメント + grep 識別ログ）で達成される
ため、観測可能機構が存在し AC 未カバーには当たらないと判断。reject 対象 3 カテゴリの該当なし。

RESULT: approve
