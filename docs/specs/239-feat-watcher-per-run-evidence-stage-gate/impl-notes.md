# 実装ノート（#239 per-run ゲート evidence サマリ）

## Implementation Notes

### Task 1（run-summary.sh モジュール新規作成: 1.1 / 1.2 / 1.3）

- **採用方針**: Collector + Terminal Emitter。`RUN_SUMMARY_*` サブシェルスコープ scalar 変数群に
  状態を蓄積する `rs_*` 記録関数群と、終端 1 行 emitter `rs_emit` を `run-summary.sh` 1 ファイルに集約
  （本体配線は task 2 以降の責務なので未着手）。
- **重要な判断**:
  - `RUN_SUMMARY_ENABLED` は `rs_init` でスナップショットせず `rs_emit` 冒頭で都度評価する
    （ログノイズ off スイッチとして env を尊重 / NFR 1.3）。`false|0|no|off` を無効値として受理。
  - degraded 兆候パターンはモジュール内配列 `RUN_SUMMARY_DEGRADED_PATTERNS` で SSoT 化し、
    `rs_scan_degraded_log` の grep は `if grep -qE ...; then` で `set -e` を吸収。LOG 不在/読めない
    時は errors を変更せず fail-open。
  - `rs_record_stage` は `A'`→`Ap` / `B'`→`Bp` に正規化し、カンマ区切り集合で重複排除（実行順保持）。
  - 変数は export しない（`claude --print` 子プロセス汚染防止）。value は ASCII 固定・空白なし。
- **残存課題（次 task=2 の配線に影響）**:
  - 状態は同一サブシェル内のグローバル変数なので、task 2 で `_slot_run_issue` 冒頭に
    `rs_init` + `trap 'rs_emit || true' EXIT` をサブシェル内に仕込む（export 禁止 / dispatcher の
    INT/TERM trap と非干渉）。
  - `rs_emit` は `$REPO` / `$LOG` を遅延束縛参照するため、配線時点で本体 Config ブロックに両者が
    定義済みである前提を満たすこと。
