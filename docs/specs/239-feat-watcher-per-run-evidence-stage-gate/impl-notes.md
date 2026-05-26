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

### Task 2（本体への source 追加と EXIT trap による終端 emit 配線）

- **採用方針**: `REQUIRED_MODULES` 配列末尾に `run-summary.sh` を明示追加し、`_slot_run_issue`
  冒頭に `rs_init` → `rs_set_issue "$NUMBER"` → `trap 'rs_emit || true' EXIT` を仕込む配線のみ。
- **重要な判断**:
  - trap 設置位置は NUMBER / LOG 確定後（L6774 の `slot_log "Worker 起動..."` 直後）で、
    最初の早期 return（L6781 worktree-ensure 失敗）より前。これにより worktree 初期化失敗の
    ような早期終端でも run-summary 行が 1 行出る（Req 1.5）。
  - source は glob ではなく明示 `REQUIRED_MODULES` 配列なので追加が必須。install.sh は
    `modules/*.sh` glob でコピーするため install.sh は変更不要（self-hosting watcher でも
    必須モジュールチェックが通る）。
  - trap 本体は `rs_emit || true` の fail-open。`_slot_run_issue` サブシェル内に既存 EXIT trap が
    無い（dispatcher の INT/TERM trap のみ）ことを grep 確認済みのため chain 不要で単純設置。
- **残存課題（次 task に影響する事項）**:
  - task 3（mode 記録）/ task 4（scaffolding）/ task 5（stage・sav）/ task 6（reviewer・result）の
    各観測点で `rs_*` 記録呼び出しを差し込む際、本 task で EXIT trap は既に張られている前提を
    使える（記録呼び出しは変数代入のみで、emit は終端で自動発火）。trap 自体の再設置は不要。

### Task 3（mode 確定箇所への `rs_set_mode` 記録差し込み）

- **採用方針**: `_slot_run_issue` の MODE 確定 4 分岐（impl-resume / skip-triage→impl /
  design / impl）の `MODE="..."` 代入直後に `rs_set_mode <mode>` を 1 行ずつ追加するのみ。
- **重要な判断**:
  - 差し込み位置は `MODE=` 代入の直後（既存ログ `echo ... | tee -a "$LOG"` より前後どちらでも
    挙動は同じだが、design 分岐は代入直後・他 3 分岐も代入直後に統一して可読性を確保）。
    `MODE=""`（L6909 初期化）には差し込まない（4 分岐の確定値のみ記録 / mode=unknown 既定は
    全分岐をすり抜けた場合のフェイルセーフとして温存）。
  - design モードは `rs_set_mode design` のみ記録し reviewer 系は一切触れない。これにより
    `rs_init` の既定 `reviewer=n/a` が維持される（Req 3.5）。
  - 変数代入のみの副作用で戻り値常に 0。既存のラベル遷移 / exit code / 既存ログ行に影響なし
    （NFR 1.2）。shellcheck クリーン（新規警告ゼロ）を確認。
- **残存課題（次 task に影響する事項）**: なし（task 4 以降の scaffolding / stage / reviewer /
  result の記録差し込みは本 task と独立。`rs_set_mode` の配線完了により mode value は全 4 分岐で
  確定する）。
