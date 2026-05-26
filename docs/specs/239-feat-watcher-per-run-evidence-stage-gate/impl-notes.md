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

### Task 4（scaffolding 記録差し込み: core_utils.sh）

- **採用方針**: `core_utils.sh` に薄いヘルパ `_worktree_record_scaffolding(wt)` を追加し、
  `_worktree_inject_claude` の 4 つの return パス直前に 1 行ずつ差し込んで `rs_set_scaffolding ok|missing`
  を記録する。
- **重要な判断**:
  - 注入元 `.claude/` 不在 / cp 失敗の rm 後はいずれも両 dir 不在 → missing、tracked 運用 / cp 成功は
    実体を見て判定するため、worktree の `$wt/.claude/{agents,rules}` 両 dir 実体判定を 4 パス共通で
    使う（既存 scaffolding 検査結果の流用 / Req 5.3）。これで 4 return パスすべてで正しい結果になる。
  - `command -v rs_set_scaffolding` の fail-open ガードで run-summary.sh 未 source の文脈でも注入処理を
    倒さない（NFR 4.1）。`set -e` 下でも `rs_set_scaffolding ... || true` と常時 `return 0` で吸収。
  - `rs_set_scaffolding` は run サマリ用の状態変数代入のみで標準出力に何も足さないため、既存
    slot_log / slot_warn の文言・cp / rm の挙動・順序・戻り値・exit code は不変（NFR 1.1, 1.2）。
- **残存課題（次 task=5/6 に影響する事項）**: なし（scaffolding 記録は stage / sav / reviewer / result の
  記録差し込みと独立。本 task で `RUN_SUMMARY_SCAFFOLDING` は全注入経路で ok/missing に確定する）。

### Task 5（stage 実行と stage-a-verify 結果の記録差し込み: run_impl_pipeline）

- **採用方針**: `run_impl_pipeline` の Stage A / A'(Ap) / B / B'(Bp) / C 各実行直後に
  `rs_record_stage` + `rs_scan_degraded_log "$LOG"` を差し込み、stage-a-verify call site の
  outcome を `rs_record_sav` で記録する。
- **重要な判断**:
  - **stage-a-verify の success/skip/disabled 区別**: `stage_a_verify_run` の戻り値は
    0(success/skip/disabled)/1(round1)/2(round2) で、0 の 3 状態を戻り値だけで区別できない
    （Req 4.2 が skip/disabled 明示を要求）。そこで `sav_log` 出力フォーマットを一切変えず
    （NFR 1.1）、stage-a-verify.sh にモジュールスコープ変数 `_SAV_LAST_OUTCOME`（既存
    `_SAV_RESOLVED_SOURCE` と同じ流儀）を追加し各 return 直前で outcome を露出。call site は
    `stage_a_verify_run` と同一プロセス呼び出し（command substitution でない）なので変数を直接
    読め、`rs_record_sav "${_SAV_LAST_OUTCOME:-}"` でマップする。`_sav_handle_failure` 戻り値
    1→round1 / 2→round2 を `stage_a_verify_run` 内で受けて outcome を確定。
  - **「実際に走った stage のみ記録」(Req 2.1)**: START_STAGE skip された B/C 分岐
    （`sc_log "Stage A をスキップ..."` 経路）には記録を入れず、claude が実際に起動された箇所に
    記録。Stage C は既存 PR ガード early return では PjM 起動前なので記録されない。
  - **記録ポイント**: claude 起動失敗 / quota でも stage は走ったため case 分岐の前（claude
    起動直後）に記録。per-task loop は `run_per_task_loop` 成功/失敗の両終端で Stage A を記録。
  - **本体内 rs_* 呼び出しは bare**: REQUIRED_MODULES で run-summary.sh が source 済みのため
    task 3（`rs_set_mode`）と同じく bare 呼び出し。rs_* は全て変数代入のみ戻り値 0 で `set -e`
    で倒れない。`rs_record_sav` 空入力時は no-op（既定 n/a 維持）。
  - **既存挙動非変更（NFR 1.1, 1.2）**: 記録は変数代入のみで `sav_log` 出力 / ラベル遷移 /
    exit code / 既存ログ行を一切変えない。`_sav_handle_failure` 呼び出しを bare→`|| _hf_rc=$?`
    に変えたが、戻り値は元の `return $?` と厳密に等価（round1→1 / round2→2）で `set -e` 安全性が
    向上するのみ。shellcheck 4 ファイル警告ゼロを確認。
- **残存課題（次 task=6 に影響する事項）**:
  - Reviewer verdict / round の記録（`rs_record_reviewer`）と最終遷移（`rs_set_result`）は
    task 6 の責務。本 task は stage 記録のみで Reviewer 起動箇所では verdict を触らない。
  - **Debugger 経路の Stage A''/B''（round=3）は記録対象外**: design.md フォーマット表
    （L334）と tasks.md task 5（「A / A'(Ap) / B / B'(Bp) / C」）に A''/B'' enum がないため
    勝手に増やさず未記録とした。round=3 は Debugger 経路の稀ケースで、stages enum 拡張が
    必要なら別途 PM/Architect 判断（確認事項参照）。

## 確認事項

- **Debugger 経路の Stage A''/B''（round=3）の run サマリ扱い**: design.md の `stages` enum
  （`A / Ap / B / Bp / C`）と tasks.md task 5 のスコープに A''/B''（round=3 / Debugger 経由）が
  含まれないため、本 task では Stage A''/B'' に `rs_record_stage` を差し込んでいない。
  `DEBUGGER_ENABLED=true` で round=3 まで進んだ稀ケースでは、stages 列に A''/B'' が現れず
  Ap/Bp までの記録に留まる（degraded スキャンは各 stage 完了時に累積実行されるため errors は
  反映される）。これが許容範囲か、stages enum に A''/B'' 相当を追加すべきかは PM/Architect の
  判断事項。本 task では spec を書き換えず現状の enum に従った。

## 受入基準カバレッジ（task 4 範囲）

- **Req 5.1 / 5.2（scaffolding 有無の記録）**: `_worktree_record_scaffolding` が `$wt/.claude/agents`
  `$wt/.claude/rules` 両 dir 実体を判定し `rs_set_scaffolding ok|missing` を記録。一時 worktree で
  両 dir あり→ok / 片方のみ→missing / `.claude` 不在→missing を smoke test で確認済み。
- **Req 5.3（既存 scaffolding 検査結果の流用）**: 4 return パス共通の dir 実体判定で流用。
- **NFR 1.2（既存挙動非変更）**: 記録は変数代入のみで slot_log / slot_warn / cp / rm の挙動・戻り値不変。
- **NFR 4.1（fail-open）**: `command -v` ガードで run-summary.sh 未 source 時も rc=0 を smoke test で確認済み。

STATUS: complete
