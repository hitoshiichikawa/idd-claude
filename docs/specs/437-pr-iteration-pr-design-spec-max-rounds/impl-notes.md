# 実装ノート（#437 PR Iteration out-of-scope 第 3 判定）

## 概要

PR Iteration / Adjudicator が「正当だが当該 impl PR の権限では是正できない（要 design/spec 変更・
spec-stale）」指摘を **`out-of-scope`（第 3 判定）** に分類し、iteration round を消費させずに
人間判断（`needs-decisions`）へ還流する。Developer 構造化マーカーと内容ベース fingerprint による
no-progress 判定で、設計レベル指摘の堂々巡りによる `max_rounds` 消尽 → `claude-failed` を防ぐ。

## 導入した env gate（すべて opt-in / 既定は導入前と等価な no-op）

| env var | 既定 | 正規化 | 役割 |
|---|---|---|---|
| `PR_ITERATION_OOS_ENABLED` | `false` | `=true` 厳密一致のみ ON。それ以外（未設定 / 空 / `True` / `1` / `0` / `on` / typo）は OFF | 機能全体の opt-in gate |
| `PR_ITERATION_OOS_ROUTE` | `needs-decisions` | `needs-decisions` 以外（`design-reflow` / `spawn-issue` / 未知値）は `needs-decisions` に丸める | out-of-scope 還流先ルート（本 spec では needs-decisions のみ実装） |
| `PR_ITERATION_OOS_NO_PROGRESS_LIMIT` | `2` | 非数値 / `<1` は `2` に丸める | 内容ベース no-progress の早期打ち切り閾値 |

- 有効化条件: crontab / env ファイルに `PR_ITERATION_OOS_ENABLED=true` を設定（前提として
  `PR_REVIEWER_ADJUDICATOR_ENABLED=true`。out-of-scope verdict は adjudicator が生成するため）。
- 正規化は `local-watcher/bin/issue-watcher.sh` の Config ブロック（`PR_ITERATION_OOS_*`）で行い、
  不正値は必ず安全側（OFF / needs-decisions / 2）へ倒す。起動ログに `oos-enabled=...` を併記。

## gate OFF（既定）時の後方互換

- adjudicator の verdict は従来の 2 値（`legitimate` / `excessive`）厳密一致で validate され、
  3 値 decisions は schema 違反として fail-safe（全件 legitimate）に倒れる。
- `pi_general_filter_oos` は jq `.` で pass-through（コメント件数不変）。
- `pi_write_marker` は既存 4 フィールドのまま（`oos-no-progress-streak` / `oos-fingerprint` を
  追記しない）。
- `pi_route_out_of_scope_escalate` / `adj_route_out_of_scope` は早期 return（gh / ラベル操作ゼロ）。

## 主な関数と配置

- `adjudicator.sh`: `adj_oos_enabled` / `adj_oos_prompt_block`（{OOS_INSTRUCTIONS} 注入）/
  `adj_validate_decisions`（gate ON で 3 値許容 + 不変条件 `legitimate + excessive + out_of_scope == total`）/
  `adj_extract_out_of_scope_count` / `adj_route_out_of_scope`（委譲判定 → pi へ）。
- `pr-iteration.sh`: `pi_general_filter_oos` / `pi_route_out_of_scope_escalate`（還流本体・冪等
  marker `idd-claude:pr-iteration-oos-routed sha=<sha>`）/ `pi_detect_developer_oos_marker`
  （厳密書式 `^OUT-OF-SCOPE:[[:space:]]+(design|spec-stale)[[:space:]]*$`）/ `pi_oos_fingerprint`
  （内容ハッシュ・SHA 非依存・順序非依存）/ `pi_read_oos_no_progress_streak` /
  `pi_read_oos_fingerprint` / `pi_next_oos_no_progress_streak`。

## verdict 命名（design.md canonical 契約）

- JSON verdict 文字列: `out-of-scope`（ハイフン）
- summary キー: `out_of_scope`（スネークケース）
- 不変条件: `legitimate + excessive + out_of_scope == total`

## テスト（近接配置 / extract_function 隔離イディオム）

- `adj_out_of_scope_test.sh` — gate / schema 検証（2 値⇔3 値）/ 件数算出 / 委譲判定（20 ケース）
- `adj_oos_prompt_test.sh` — {OOS_INSTRUCTIONS} 注入 / gate OFF byte 等価（18 ケース）
- `pr_iteration_oos_routing_test.sh` — filter no-op / 還流 / 冪等 / 入力検証 / 失敗 WARN（21 ケース）
- `pr_iteration_oos_no_progress_test.sh` — marker 検出 / fingerprint / streak（23 ケース）

いずれも gate ON / OFF 両系統を同一スイート内で検証（gate OFF の後方互換を回帰対象に含む）。

## 確認事項

- `PR_ITERATION_OOS_ROUTE` の `design-reflow` / `spawn-issue` は env 値として将来予約するが、本 spec
  では未実装で `needs-decisions` に正規化する（design.md 確認事項 / Non-Goal）。
