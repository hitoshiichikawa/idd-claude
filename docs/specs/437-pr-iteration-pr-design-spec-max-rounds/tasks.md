# Implementation Plan

- [ ] 1. opt-in gate の Config ブロック追加と値正規化
  - `local-watcher/bin/issue-watcher.sh` の Config ブロックに 3 env を追加する
  - `PR_ITERATION_OOS_ENABLED`（既定 `false`、`case true) :;; *) false` で厳密 `=true` のみ ON / 安全側 OFF）
  - `PR_ITERATION_OOS_ROUTE`（既定 `needs-decisions`、`needs-decisions|design-reflow|spawn-issue` 以外は `needs-decisions` に正規化）
  - `PR_ITERATION_OOS_NO_PROGRESS_LIMIT`（既定 `2`、非数値 / `-lt 1` は `2` に正規化）
  - 起動ログ行（issue-watcher.sh:1564 付近）に `oos-enabled=${PR_ITERATION_OOS_ENABLED}` を追記
  - 既存 env var 名 / ラベル名 / commit status context / exit code / cron 文字列を一切変更しない
  - `local-watcher/test/pr_iteration_oos_routing_test.sh` に正規化マトリクステストを追加（未設定/空/`True`/`1`/typo → `false`、未知 route → `needs-decisions`、非数値 limit → `2`）。`pr_reviewer_adjudicator_default_on_test.sh` の正規化コピーイディオムを踏襲
  - _Requirements: NFR 1.1, NFR 1.2, NFR 1.3_

- [ ] 2. Adjudicator / Reviewer プロンプトの out-of-scope 判定指針を明文化
- [ ] 2.1 adjudicator-prompt.tmpl に第 3 判定 out-of-scope を追記
  - `local-watcher/bin/adjudicator-prompt.tmpl` の分類基準に out-of-scope シグナルを追加
  - 「requirements.md / design.md の確定事項と矛盾し当該 PR タイプでは対処不能な強化要件は `out-of-scope` に分類」を明記（Req 1.2 / 6.1）
  - 「確信が持てなければ legitimate」原則を out-of-scope にも適用（Req 1.3）
  - reason に矛盾する確定事項・AC・境界を明記する指示（Req 1.4）
  - 出力契約 JSON の `verdict` を 3 値 + `summary.out_of_scope` 追加（Data Models と byte 一致）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 6.1_
- [ ] 2.2 iteration-prompt.tmpl / iteration-prompt-design.tmpl に Developer 構造化マーカー出力指示を追記
  - `local-watcher/bin/iteration-prompt.tmpl` と `iteration-prompt-design.tmpl` の「設計と矛盾するレビュー指摘」節を構造化マーカー出力指示に拡張
  - マーカー厳密書式 `OUT-OF-SCOPE: design` / `OUT-OF-SCOPE: spec-stale`（許容語彙集合明示）を出力する条件と書式を記述（Req 4.1）
  - マーカー出力時にどの確定事項・どの AC と矛盾するかを同応答本文に併記する指示（Req 4.4）
  - _Requirements: 4.1, 4.4_

- [ ] 3. adjudicator.sh の 3 値分類対応（schema 検証 / label / comment）
  - `local-watcher/bin/modules/adjudicator.sh` の `adj_validate_decisions` を gate ON 時 3 値許容に拡張（gate OFF は既存 2 値厳密一致 / `legit+excess+oos==total` vs 既存 `legit+excess==total`）
  - `adj_run_for_pr` の summary 抽出に `out_of_scope` を追加し、`adj_apply_label_decision` には `summary.legitimate`（oos 除外値）を渡す（Req 2.1〜2.4。既存 `adj_apply_label_decision` シグネチャは不変）
  - `adj_post_decision_comment` の summary 本文に `out-of-scope` 件数行を追加し、out-of-scope finding 個別 marker `<!-- idd-claude:pr-adjudicator-out-of-scope id=<N> sha=<sha> -->` を投稿（Req 3.3。未信頼値は jq `--arg`/`--argjson`）
  - gate OFF 時は schema / summary / marker をすべて既存 byte 互換に保つ（NFR 1.3 / 1.4）
  - `local-watcher/test/adjudicator_out_of_scope_test.sh` を新規追加: gate ON で out-of-scope verdict + summary 整合を valid 判定、gate OFF で out-of-scope を invalid 判定（→ legitimate fallback / NFR 1.4）、legitimate 件数に oos を含めないこと、out-of-scope marker 投稿の gh 呼び出しトレース
  - _Requirements: 1.1, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 3.3, NFR 1.3, NFR 1.4, NFR 3.1, NFR 3.3_
  - _Boundary: adjudicator.sh, adj_validate_decisions, adj_run_for_pr, adj_apply_label_decision, adj_post_decision_comment_

- [ ] 4. pi_general_filter_oos による out-of-scope コメント除外 (P)
  - `local-watcher/bin/modules/pr-iteration.sh` に `pi_general_filter_oos` を新規追加（`pi_general_filter_excessive`:293 と同パターン。gate ON で `idd-claude:pr-adjudicator-out-of-scope` 含むコメント除外、OFF で jq `.` pass-through）
  - `pi_collect_general_comments` の filter chain を `self → resolved → excessive → out-of-scope → event_style → truncate` の 6 段に拡張し、サマリログに `filtered_oos=<N>` を追加（NFR 4.1）
  - gate OFF 時は filter chain が既存件数挙動と完全一致することを保証（NFR 1.1）
  - `local-watcher/test/pr_iteration_oos_routing_test.sh` に追加: gate ON で oos marker コメント除外、gate OFF で pass-through（件数不変）、`filtered_oos` ログ出力の検証
  - _Requirements: 2.1, NFR 1.1, NFR 3.1_
  - _Boundary: pr-iteration.sh, pi_general_filter_oos, pi_collect_general_comments_
  - _Depends: 1_

- [ ] 5. out-of-scope ルーティング共通ヘルパ pi_route_out_of_scope_escalate
  - `local-watcher/bin/modules/pr-iteration.sh` に `pi_route_out_of_scope_escalate` を新規追加
  - `PR_ITERATION_OOS_ROUTE` 解決（`needs-decisions` 既定、`design-reflow`/`spawn-issue` は本 spec では `needs-decisions` に丸める / Req 3.1, 3.2）
  - `needs-iteration` 除去 + `needs-decisions` 付与 + 追跡コメント（内容・分類根拠を含む）投稿（Req 3.2, 3.3）
  - 冪等 marker `<!-- idd-claude:pr-iteration-oos-routed sha=<sha> -->` を付与し、同一 PR・同一 SHA で既存検出時は再ルーティング skip（Req 3.5）
  - PR 番号 `^[0-9]+$` / SHA `^[0-9a-f]{7,40}$` を使用直前検証、gh へ `--` 付与（NFR 3.3）
  - ラベル / コメント投稿失敗時は WARN 1 行 + silent fail なし（Req 3.4）
  - 1 行機械抽出可能ログ `reason=out-of-scope route=needs-decisions` を出力（NFR 4.1）
  - `local-watcher/bin/modules/adjudicator.sh` に `adj_route_out_of_scope` を新規追加し本ヘルパへ委譲（gate OFF / oos ゼロで no-op）
  - `pr_iteration_oos_routing_test.sh` に追加: 同一 sha 2 回呼び出しで 2 回目 skip（冪等 / Req 3.5）、gh コメント失敗で WARN 非 silent（Req 3.4 failure path）、ルートログ出力、未知 route が needs-decisions に丸まる safety fallback
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, NFR 3.1, NFR 3.3, NFR 4.1_
  - _Boundary: pr-iteration.sh, pi_route_out_of_scope_escalate, adjudicator.sh, adj_route_out_of_scope_
  - _Depends: 1_

- [ ] 6. Developer 構造化マーカー検出 pi_detect_developer_oos_marker (P)
  - `local-watcher/bin/modules/pr-iteration.sh` に `pi_detect_developer_oos_marker` を新規追加
  - 厳密書式 `^OUT-OF-SCOPE:[[:space:]]+(design|spec-stale)[[:space:]]*$` を `grep -E` で検出、語彙集合外 / 不在は空返し（安全側 / Req 4.2, 4.5）
  - 入力（Developer 応答ログ）は変数 quote + `grep --` でオプション打ち切り（NFR 3.2）。read-only / fail-safe（ログ不在・不能は空返し）
  - `local-watcher/test/pr_iteration_oos_no_progress_test.sh` を新規追加: `design` / `spec-stale` 検出、`OUT-OF-SCOPE: foo`（語彙外）は空、マーカー不在は空、未信頼入力（`-` 始まり等）の安全処理を `extract_function` 隔離で検証
  - _Requirements: 4.2, 4.5, NFR 3.1, NFR 3.2_
  - _Boundary: pr-iteration.sh, pi_detect_developer_oos_marker_
  - _Depends: 1_

- [ ] 7. 内容ベース no-progress 判定（fingerprint / streak / marker 永続化）(P)
  - `local-watcher/bin/modules/pr-iteration.sh` に純粋関数 `pi_oos_fingerprint`（severity/file/message 連結ハッシュ。SHA 非依存 / Req 5.3）を追加
  - `pi_read_oos_no_progress_streak`（PR body marker `oos-no-progress-streak=K` / `oos-fingerprint=<H>` 読み取り。既存 `pi_read_no_progress_streak`:182 と独立）を追加
  - `pi_next_oos_no_progress_streak`（fingerprint 同一で +1、変化で 0 リセット / Req 5.1, 5.5。純粋関数）を追加
  - `pi_write_marker`:486 を gate ON 時のみ `oos-no-progress-streak` / `oos-fingerprint` 追記に拡張（既存 sed `[^>]*` 方式で旧 marker 吸収 / gate OFF は byte 互換 / NFR 1.3）
  - `pr_iteration_oos_no_progress_test.sh` に追加: 同一 severity/file/message で同一 fingerprint、message 変化で別 fingerprint、fingerprint 同一で streak +1、変化で 0 リセット（Req 5.3 / 5.5 regression）、gate OFF で marker が既存 4 フィールドのまま（NFR 1.3）
  - _Requirements: 5.1, 5.3, 5.5, NFR 1.3, NFR 3.1_
  - _Boundary: pr-iteration.sh, pi_oos_fingerprint, pi_read_oos_no_progress_streak, pi_next_oos_no_progress_streak, pi_write_marker_
  - _Depends: 1_

- [ ] 8. pi_run_iteration への配線（Developer marker 打ち切り / 内容ベース早期打ち切り）
  - `local-watcher/bin/modules/pr-iteration.sh` の `pi_run_iteration`:1231 に gate ON 時のみの分岐を配線
  - claude 実行後 `pi_detect_developer_oos_marker "$pi_log_file"` 検出時、当該 round を finalize せず `pi_route_out_of_scope_escalate` へ引き渡し（Req 4.3）
  - 同一 fingerprint の out-of-scope 連続を `pi_next_oos_no_progress_streak` で加算し、`>= PR_ITERATION_OOS_NO_PROGRESS_LIMIT`（既定 2）で `max_rounds` 到達前に早期打ち切り + ルーティング（Req 5.2）
  - 打ち切り理由（指摘内容ベース no-progress / 連続回数 / 閾値）を 1 行機械抽出可能ログに記録（Req 5.4 / NFR 4.1）
  - gate OFF 時は本分岐を完全 skip（既存 round フロー byte 互換 / NFR 1.1）
  - `pr_iteration_oos_no_progress_test.sh` に追加: Developer marker 検出 → round finalize せずルーティング呼び出し（Req 4.3）、streak 閾値到達で max_rounds 前に打ち切り + ルートログ（Req 5.2 / 5.4 failure path）、gate OFF で既存フロー不変（NFR 1.1 regression）。gh / git は stub して呼び出しトレースで検証
  - _Requirements: 4.3, 5.2, 5.4, NFR 1.1, NFR 4.1_
  - _Boundary: pr-iteration.sh, pi_run_iteration_
  - _Depends: 5, 6, 7_

- [ ] 9. impl Reviewer プロンプト明文化 + root↔repo-template 同期
  - `.claude/agents/reviewer.md` の「reject しない条件」節に「design.md の確定事項と矛盾する設計レベル指摘を impl PR の reject 理由にしない（設計 iteration / 別 Issue へ回す）」を明記（Req 6.2）
  - 設計レベル指摘を AC 未カバー / missing test / boundary 逸脱の 3 カテゴリのいずれにも該当しないものとして reject しないことを明記（Req 6.3）
  - `repo-template/.claude/agents/reviewer.md` に byte 一致で同一内容を反映（Req 6.4 / NFR 2.1）
  - 反映後に `diff -r .claude/agents repo-template/.claude/agents` が空であることを確認
  - _Requirements: 6.2, 6.3, 6.4, NFR 2.1, NFR 2.2_
  - _Boundary: reviewer.md_

- [ ] 10. Developer プロンプト明文化 + README 反映 + 全体検証
  - `.claude/agents/developer.md` の「PR Iteration」関連節に out-of-scope 構造化マーカー宣言規約（`OUT-OF-SCOPE: design` / `OUT-OF-SCOPE: spec-stale` の書式・出力条件・矛盾根拠併記）を追記（Req 4.1, 4.4）
  - `repo-template/.claude/agents/developer.md` に byte 一致で反映し `diff -r .claude/agents repo-template/.claude/agents` が空であることを確認（NFR 2.1）
  - `README.md` のオプション機能一覧 / PR Iteration 節に `PR_ITERATION_OOS_ENABLED`（既定 OFF / opt-in）と 3 env、out-of-scope ルーティング挙動を追記（CLAUDE.md 二重管理鉄則）
  - `shellcheck local-watcher/bin/modules/*.sh local-watcher/bin/issue-watcher.sh` / `bash -n` でクリーンを確認
  - _Requirements: 4.1, 4.4, NFR 2.1, NFR 2.2_
  - _Boundary: developer.md_
  - _Depends: 9_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを宣言する。
`local-watcher/` は repo-template にミラーされないため、同期 diff は `.claude/{agents,rules}`
のみを対象とする（tasks-generation.md「idd-claude 特有の注意」準拠）。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/adjudicator.sh local-watcher/bin/modules/pr-iteration.sh local-watcher/bin/issue-watcher.sh &&
  bash -n local-watcher/bin/modules/adjudicator.sh &&
  bash -n local-watcher/bin/modules/pr-iteration.sh &&
  bash local-watcher/test/adjudicator_out_of_scope_test.sh &&
  bash local-watcher/test/pr_iteration_oos_routing_test.sh &&
  bash local-watcher/test/pr_iteration_oos_no_progress_test.sh &&
  diff -r .claude/agents repo-template/.claude/agents
```
