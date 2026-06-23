# Implementation Notes (#397)

## 修正方針

`pr-iteration.sh` の `pi_run_iteration` 末尾（round 終了処理）で、`commit_pushed=false`（head branch に新規 commit が push されなかった round）でも `no-progress-streak < PR_ITERATION_NO_PROGRESS_LIMIT` であれば `pi_finalize_labels_design` / `pi_finalize_labels` を呼んで `needs-iteration` を外し、`awaiting-design-review` / `ready-for-review` に遷移して `action=success` で完了扱いしていた defect を修正する。

修正後の挙動:

- **commit_pushed=true**（新規 commit あり）→ 従来通り `pi_finalize_labels_design` / `pi_finalize_labels` を呼んで `awaiting-design-review` / `ready-for-review` に遷移し `action=success` ログを記録（Req 3.1〜3.3 / 4.3 / NFR 1.3）。
- **commit_pushed=false かつ streak < limit**（no-progress 過渡状態）→ `needs-iteration` を **据え置き** し、`action=no-progress` ログを記録して `return 1`。次サイクルでも `needs-iteration` を起点とする候補抽出に再び含まれる（Req 1.1〜1.3 / 2.1〜2.2 / 4.1〜4.2 / 5.1〜5.2）。
- **commit_pushed=false かつ streak >= limit**（no-progress 上限到達）→ 従来通り `pi_escalate_to_failed "no-progress"` で `claude-failed` に遷移し `return 2`。Req 5.3 を満たすため、escalate ログに `limit=<値>` を追加（従来は省略されていた）（Req 2.3〜2.4 / 5.3）。

判定ロジックは新規ヘルパー `pi_classify_round_outcome <commit_pushed> <new_streak> <limit>` に切り出し、純粋関数として隔離テスト可能にした（CLAUDE.md「機能追加ガイドライン」§1 / §2 / §7 と整合: `pi_` prefix namespace 維持、副作用なし、近接テスト追加）。

## 変更ファイル

- `local-watcher/bin/modules/pr-iteration.sh`
  - `pi_classify_round_outcome()` 新規追加（純粋関数 / 3 way 分類: `success` / `escalate` / `no-progress`）
  - `pi_run_iteration()` 内の round 終了処理（`if [ $rc -eq 0 ]; then` ブロック）を上記ヘルパーの結果で 3 way 分岐に再構成
  - escalate ログに `limit=<値>` を追記（Req 5.3）
  - 既存 env var（`PR_ITERATION_NO_PROGRESS_LIMIT` / `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_MAX_ROUNDS*`）の名称・既定値・意味は **不変**（NFR 1.1）
  - 既存ラベル（`needs-iteration` / `awaiting-design-review` / `ready-for-review` / `claude-failed`）の名称・付与責務・取り外し責務は **不変**（NFR 1.2）
  - 既存 return code（0=success / 1=fail / 2=escalated / 3=skip）の意味は **不変**

## 追加テスト

- `local-watcher/test/pi_classify_round_outcome_test.sh`（新規 24 ケース）
  - 正常系 success（4 ケース / Req 3.1〜3.3）: `commit_pushed=true` は streak 値に依らず success
  - 正常系 no-progress（3 ケース / Req 1.1〜1.3 / 2.1〜2.2 / 4.1〜4.2）: `commit_pushed=false` かつ `streak < limit` は no-progress
  - 正常系 escalate（3 ケース / Req 2.3〜2.4 / 5.3）: `streak >= limit` は escalate
  - 累積シナリオ（4 ケース / Req 2.1〜2.3）: 連続 no-progress round で最終的に escalate に到達する
  - 境界値（3 ケース）: `limit=1` で即時 escalate / `limit=0` で常時 escalate / 極端な大 limit で永続 no-progress
  - 異常系（6 ケース / NFR 2.1）: 不正値（空文字列 / 非数値 / typo）は安全側で no-progress に倒れる
  - kind 非依存性（1 ケース / Req 4.1〜4.3）: 同入力で同 outcome（design / impl 区別なし）

## 静的解析結果

- `bash -n local-watcher/bin/modules/pr-iteration.sh` → OK
- `shellcheck local-watcher/bin/modules/pr-iteration.sh` → 警告ゼロ
- `shellcheck local-watcher/bin/modules/*.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh` → 警告ゼロ
- `diff -r .claude/agents repo-template/.claude/agents` → 空（同期維持）
- `diff -r .claude/rules repo-template/.claude/rules` → 空（同期維持）
- `repo-template/` 配下に `pr-iteration.sh` は存在せず（`local-watcher/` 配下のみが正本、`install.sh` 経由で `$HOME/bin/modules/` に配布する設計）

## 既存テスト実行結果（リグレッション確認）

- `bash local-watcher/test/pi_classify_round_outcome_test.sh` → 24 PASS / 0 FAIL（新規）
- `bash local-watcher/test/pi_max_rounds_kind_test.sh` → 24 PASS / 0 FAIL
- `bash local-watcher/test/pi_detect_quota_soft_fail_test.sh` → 13 PASS / 0 FAIL
- `bash local-watcher/test/repo_prefix_log_test.sh` → 36 PASS / 0 FAIL

## AC Traceability

| 要件 | テストケース（および inline 修正箇所） |
|---|---|
| Req 1.1 (no-progress で `awaiting-design-review` 付与なし) | `pi_classify_round_outcome false 1 3 → no-progress` + 修正後の `case "$outcome" in no-progress) return 1` 分岐（`pi_finalize_labels_design` を呼ばない経路） |
| Req 1.2 (no-progress を `action=success` で記録しない) | 修正後の `pi_log ... action=no-progress` 出力（`action=success` キーを含まない） |
| Req 1.3 (次サイクル候補に残る) | `needs-iteration` を据え置く（`pi_finalize_labels*` を呼ばないため `pi_fetch_candidate_prs` の `label:"$LABEL_NEEDS_ITERATION"` フィルタに次サイクルも合致） |
| Req 2.1 (no-progress streak 加算) | 修正前と同じく `prev_streak+1` を `pi_write_marker` で永続化 / 既存 `pi_max_rounds_kind_test.sh` の no-progress-streak 読み出しテストで読出側の互換性確認 |
| Req 2.2 (limit 未満なら次 round 進める) | `pi_classify_round_outcome false <streak<limit> <limit> → no-progress`（4 ケース + 累積シナリオ 2 ケース） |
| Req 2.3 (limit 到達で escalation 発火) | `pi_classify_round_outcome false <streak>=limit> <limit> → escalate`（3 ケース + 累積シナリオ 2 ケース + 境界値 2 ケース） |
| Req 2.4 (escalation ログに reason/streak/limit) | 修正後の `pi_log ... no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT} reason=no-progress escalate` 出力 |
| Req 3.1 (commit 有り round の通常 finalize) | `pi_classify_round_outcome true * * → success` + 既存 finalize case 分岐維持（4 ケース） |
| Req 3.2 (commit 有り round で streak リセット) | `new_streak=0` 既存ロジック維持（修正対象外） |
| Req 3.3 (commit 有り round の `action=success` ログ維持) | 既存 `pi_log ... action=success (needs-iteration -> awaiting-design-review/ready-for-review)` 維持 |
| Req 4.1 (impl 種別でも同等制御フロー) | `pi_classify_round_outcome` は kind を引数に取らない（純粋関数 / 1 ケース）+ `pi_run_iteration` 内の case 分岐は finalize 関数選択のみ kind 依存、outcome 判定は kind 非依存 |
| Req 4.2 (impl no-progress で `ready-for-review` 付与なし) | 修正後の `case "$outcome" in no-progress) return 1` 分岐は `pi_finalize_labels` も呼ばないため impl 側も同様に needs-iteration 据え置き |
| Req 4.3 (impl commit 有り round の通常 finalize) | 既存 `impl)` case ブロックは outcome=success のときのみ到達するため挙動不変 |
| Req 5.1 (no-progress 1 行ログに PR/kind/round/streak/limit) | 既存 L1387 ログを温存（design / impl 両 kind で出力 / `pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT}"`） |
| Req 5.2 (`action=success` を含まないログ) | 修正後の `pi_log ... action=no-progress` 出力で `action=success` を含まない |
| Req 5.3 (escalation 1 行ログに PR/kind/round/reason/streak/limit) | 修正後の escalate ログに `limit=${PR_ITERATION_NO_PROGRESS_LIMIT}` を追加（従来欠落していた） |
| NFR 1.1 (既存 env var 不変) | env var の参照のみで宣言・既定値は無変更 |
| NFR 1.2 (既存ラベル不変) | `LABEL_NEEDS_ITERATION` / `LABEL_AWAITING_DESIGN` / `LABEL_READY` / `LABEL_FAILED` の名称・責務は無変更 |
| NFR 1.3 (commit 有り round の挙動不変) | 既存 finalize case 分岐と success ログを温存（success cases 4 ケース + commit 有り round の return 0 を維持） |
| NFR 2.1 (判定情報不足時は success に倒さない) | `pi_classify_round_outcome` の不正値処理は no-progress に倒れる（6 ケース） |
| NFR 2.2 (marker 永続化失敗時の据え置き) | 既存 `pi_write_marker` 失敗時の `pi_error + return 1` ロジック維持（#122 既存挙動） |

## 確認事項

- **`return 1` の意味**: no-progress round 据え置きは `pi_run_iteration` の `return 1`（fail カウンタに加算される）で表現している。要件は「`action=success` として記録しない」のみを要求しているため要件は満たすが、運用観点では `process_pr_iteration` のサマリで「needs-iteration 据え置き = fail カウント増」となる。意図的な挙動だが、将来的に「needs-iteration retry」を独立 return code（例: `4=retry`）に分離してサマリでも区別する設計変更を検討する余地がある（本要件のスコープ外、別 Issue 検討推奨）。
- **escalate ログの `limit=` 追記**: Req 5.3 を満たすため escalate ログに `limit=` キーを新規追加した。既存運用で `grep 'reason=no-progress escalate'` 形式の集計をしている場合は不変だが、`limit=` を読み取る監視はこれまで存在しなかったため後方互換上の影響はない（ログ文字列に新キー追加のみ、既存キーの順序や名称は不変）。

## 派生タスク候補

- `process_pr_iteration` のサマリで「needs-iteration 据え置き retry round」を `fail` から分離するための return code 追加（運用観測性向上、本 Issue スコープ外）
- Out of Scope に挙がっている「reopen された PR に残る obsolete な人間コメントを現行指示として解釈する挙動の見直し」は別 Issue 検討事項

STATUS: complete
