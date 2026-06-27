# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-27T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-421-impl--bug-per-task-reviewer-diff-range-marker
- HEAD commit: f23d689810e0eda17f335608ad45b791e22e21f3
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/issue-watcher.sh`（`pt_resolve_diff_range` 関数のみ改修、+96/-33）
  - `local-watcher/test/pt_resolve_diff_range_test.sh`（新規 394 行）
  - `docs/specs/421--bug-per-task-reviewer-diff-range-marker/impl-notes.md`（新規）
- 注: tasks.md は本 spec では未生成（Triage が `needs_architect: false` 判定で
  Architect 経由しない単純改修と推定。Boundary は requirements.md と Issue 本文の
  明示範囲＝`pt_resolve_diff_range` 関数および近接テストに限定されているため、
  実装はその範囲内で完結している）

## Verified Requirements

- 1.1 — `pt_resolve_diff_range_test.sh` Section A "Req 1.1: suffix 付き 単記 marker のみ → 解決"（sha0006 解決 / range pair sha0005\tsha0006）および初回 task fixture で確認
- 1.2 — Section A "Req 1.2 順方向 / 逆方向" 双方向 fixture で時系列最終一致が一意に採用されることを確認
- 1.3 — Section D "Req 4.5" 非数字 / 数字混在（`(#abc)` / `(#12a)`）が拒否され `^[0-9]+$` 検証が機能している
- 1.4 — Section D "Req 4.1〜4.4" で canonical 表記（半角空白 1 + `(#<digits>)` + 行終端）が境界として実装側コード（`[[ "$subject" == "${single_canonical} (#"*")" ]]` + `${var#prefix}` / `${var%)}` + `^[0-9]+$`）で表現
- 1.5 — Section A の `assert_contains "via=single-id-marker-with-suffix"` で stderr 観測タグを確認。実装側は `case "$via"` 分岐で stderr 出力
- 2.1 — Section B "Req 2.1 suffix 付き 連記" の slash / comma 連記 fixture が解決成功
- 2.2 — Section B "Req 2.2 token 化規則同一"（`task_id=1` が `1.1 / 1.2` に誤マッチしないこと）で確認
- 2.3 — Section B `via=multi-id-marker-with-suffix` 観測タグ確認、かつ `single-id-marker-with-suffix` が出ないことの否定アサーションあり
- 3.1 — Section C "Req 3.1" で suffix 無し 単記のみ fixture が本変更前と同一 SHA pair（sha_a\tsha_b）を返す
- 3.2 — Section C "Req 3.2" で suffix 無し 連記 fixture が既存挙動を保持
- 3.3 — Section A の逆順 fixture / Section C で `-with-suffix` タグが既存ログタグ条件下では出ないことを否定アサーションで確認、既存 `via=multi-id-marker ` の文字列は維持
- 4.1 — Section D "Req 4.1" `mark 10 as done (#1)` 解決
- 4.2 — Section D "Req 4.2" 空白なし `done(#118)` rc=1
- 4.3 — Section D "Req 4.3" 括弧なし `done #118` rc=1
- 4.4 — Section D "Req 4.4" 閉じ括弧後追加文字列 `done (#118) extra` rc=1
- 4.5 — Section D "Req 4.5 / 4.5 (mixed)" 非数字・数字混在 rc=1
- 4.6 — Section D "Req 4.6 (multi) x2" 連記パスにも同一規則（空白なし / 閉じ括弧後追加文字列）が rc=1 で適用
- 5.1 — Section E "Req 5.1 x2" marker 0 件 / 該当 task_id 不在で rc=1
- 5.2 — 実装は `mark_issue_failed` 経由の既存失敗終端（呼び出し元）に影響を与えない（本関数は rc=1 のみ返却、失敗カテゴリ識別子・ラベル遷移を新規追加せず）
- NFR 1.1 — Section C で既存 `via=multi-id-marker` の文字列形式（trailing space を含む）と発火条件（suffix 無し連記）を維持。`diff-range-resolve-failed` 等の既存識別子は本 PR で touch していない（grep 確認）
- NFR 1.2 — `pt_resolve_diff_range` は呼び出し元（`PER_TASK_LOOP_ENABLED=true` で gate された経路）からのみ到達する。本関数自体は gate を持たないため、未設定経路では到達しない既存設計を温存
- NFR 2.1 — Section A / B で `via=*-with-suffix` の grep 可能性を `assert_contains` で確認
- NFR 2.2 — 解決失敗時のログは本関数で新規追加していない（呼び出し元 `pt_mark_diff_range_resolve_failed` の既存契約に委譲、impl-notes.md で明示）
- NFR 3.1 — Section D "Req 4.5" / 実装で `[[ "$suffix_num" =~ ^[0-9]+$ ]]` の事前検証を経てから採用
- NFR 3.2 — 実装の正規表現は `[0-9]+`（線形時間量指定子）・glob は末尾 `)` アンカー固定で ReDoS リスクなし（design 観点で確認）
- NFR 4.1 — Section D が許容 1 + 拒否 4 = 5 パターンを fixture として網羅
- NFR 4.2 — 既存 `pt_*_test.sh` 4 ファイル（`pt_check_fail_fast_test.sh:18` / `pt_extract_debugger_section_test.sh:24` / `pt_extract_findings_block_test.sh:20` / `pt_post_marker_classify_test.sh:39`）全て PASS（合計 101）を Reviewer 側でも再実行確認

## 追加検証

- 新規 `pt_resolve_diff_range_test.sh` を再実行: `PASS: 50, FAIL: 0`
- 既存 pt_* 系 4 テストを再実行: 全 PASS（合計 PASS: 101, FAIL: 0、回帰なし）
- `shellcheck local-watcher/bin/issue-watcher.sh` クリーン（出力 0 行）
- `shellcheck local-watcher/test/pt_resolve_diff_range_test.sh` クリーン（出力 0 行）
- Issue 本文の root example（`mark 6 as done (#118)`）が Section F で回帰固定されており、altpocket-server #118 の再発防止が観測可能

## Feature Flag Protocol 採否確認

CLAUDE.md に `## Feature Flag Protocol` 節は存在しない（参照テーブル行のみ）。
opt-out 扱いとし、flag 観点の細目（旧パス削除 / `if (flag)` 分岐 / flag-off path mutation /
flag 命名規約）は本判定に **適用しない**。通常の 3 カテゴリ判定のみ。

## Boundary 確認

- 変更スコープは `pt_resolve_diff_range` 関数本体 + 関数ヘッダ doc + 近接テスト新規追加のみ
- 既存 env var 名 / ラベル名 / 既存失敗カテゴリ識別子 (`diff-range-resolve-failed`) /
  既存ログタグ (`via=single-id-marker` 不出力 / `via=multi-id-marker`) の文字列・発火条件は
  変更なし（CLAUDE.md「後方互換性」規約を逸脱せず）
- `repo-template/` への二重管理対象（agents / rules）は本 PR では `diff -r` 空で同期維持
  （impl-notes 申告どおり）
- 関数の主出力は stdout の `<range_start>\t<range_end>`、観測タグは stderr に分離されており
  呼び出し元の SHA pair 受け取りに副作用を起こさない

## Findings

なし

## Summary

Issue #421 で要求された 5 要件群（trailing issue-ref suffix 許容拡大 / 既存挙動温存 /
許容拒否境界 / 失敗時挙動温存）と全 NFR が、`pt_resolve_diff_range` の局所改修 + 新規
近接テスト 50 アサーションで実装・検証されている。既存 pt_* 4 テスト計 101 件も回帰なく
通過しており、boundary 逸脱もない。

RESULT: approve
