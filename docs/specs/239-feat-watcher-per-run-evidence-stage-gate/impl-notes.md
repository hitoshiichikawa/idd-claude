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

### Task 6（Reviewer 起動・verdict・round と最終遷移の記録差し込み）

- **採用方針**: `run_reviewer_stage` の 6 return 直前に `rs_record_reviewer` を、最終遷移 5 箇所
  （claude-failed / hold / ready-for-review / needs-iteration）に `rs_set_result` を bare 呼び出しで差し込む。
- **重要な判断**:
  - `run_reviewer_stage` の return マッピングは design.md L293-298 通り: 0→`independent approve`、
    1→`independent reject`、99→`independent quota`、2（claude-exit-nonzero / parse-failed /
    unknown-result の 3 箇所）→`degraded "" "$round"`。`rs_record_reviewer` の degraded は verdict 引数を
    空文字 `""` で渡す（run-summary.sh L154-176 実装と design.md L427-429 fixture 例に厳密一致）。round は
    関数冒頭 `local round="$1"` をそのまま渡す。
  - **needs-iteration の上書き**: Reviewer reject 終端（reviewer-reject2 / reviewer-reject3）は
    `mark_issue_failed` 経由で claude-failed ラベルが付与される。`mark_issue_failed` 内に
    `rs_set_result claude-failed` を入れたため、reject 終端では `mark_issue_failed` の**直後**に
    `rs_set_result needs-iteration` を置いて上書きし、「Reviewer 判定起因の差し戻しループ打ち切り終端」を
    needs-iteration として区別する（tasks.md task 6 を正本に採用）。stage 失敗等その他の `mark_issue_failed`
    呼び出しは claude-failed のまま。
  - **既存 PR ガード成功には result を入れない**: `stage_c_existing_pr_guard` 成功（OPEN/MERGED/CLOSED いずれも
    return 0）は「PR 作成成功し ready-for-review へ向かう終端」に該当せず、CLOSED は needs-decisions 遷移のため、
    一律 ready-for-review 記録は誤り。result enum に「既存 PR 再利用」値がないため、ガード成功パスには
    `rs_set_result` を差し込まず既定 unknown を維持した（新規 PR 作成成功 L5481 のみ ready-for-review）。確認事項参照。
  - **hold = stage-a-verify round=1 defer**: design.md L59-60 の「round=1 defer（保留）」は stage-a-verify の
    `return 3`（`stage_a_verify_round1_defer`）終端を指す。Reviewer reject round=1 は同一サイクル内で Stage A'→round=2 へ
    進み「次サイクルへ defer する保留」は存在しないため、hold は stage-a-verify round=1 defer に対応づけた。確認事項参照。
- **残存課題（次 task=7/8 に影響する事項）**: なし（task 7=README / task 8=fixture は本 task の記録配線と独立。
  fixture は `rs_record_reviewer independent approve 1` / `degraded "" 1` / `rs_set_result needs-iteration` 等を
  source 直接呼びで検証する想定で、本 task の本体配線に依存しない）。

### Task 7（README 更新: grep 例 + オプション機能一覧）

- **採用方針**: README の既存記述は追記のみ（NFR 1.1）。「複数リポ運用時の cron.log grep 例」節に
  `run-summary:` 専用サブ節（出力例 / 全件 grep / degraded grep / 8 key の enum 表）を追加し、
  「オプション機能一覧」の「デフォルト有効」テーブル末尾に `RUN_SUMMARY_ENABLED` 行を 1 行追加。
- **重要な判断**:
  - `RUN_SUMMARY_ENABLED` の正規化規則は #112 系 8 種の「`=false` 厳密一致のみ無効」とは**異なり**、
    lowercase の `false`/`0`/`no`/`off` のいずれかで無効化される（それ以外 = 空文字 / `False` /
    `OFF` / typo はすべて有効）。この差異を「正規化規則」列に明記し、誤って「=false 厳密一致のみ」と
    書かないようにした（実装 `rs_emit` の `case ... in false|0|no|off) return 0` と一致）。
  - enum 表・grep 例は design.md L316-346 / L463 を正本として README 向けに転記。grep 例の cron.log
    パスは既存節の他例と同じ `$HOME/.issue-watcher/cron.log` 表記に揃えた。
  - L1206 の「上記 9 機能はすべて有効です」件数表現は、現状の「デフォルト有効」テーブル件数
    （本追加前から 11 行）と既に乖離した曖昧な件数言及であり、本追加で初めてズレるものではない
    ため触れていない（指示の「曖昧なら触れない」に従った）。
- **残存課題（次 task=8 fixture への影響）**: なし。ただし README に転記した enum value
  （`reviewer=independent:approve:r<n>` / `degraded:r<n>` / `stage-a-verify=success|round1|round2|skip|disabled|n/a`
  / `result=ready-for-review|needs-iteration|claude-failed|hold|unknown` 等）と、task 8 で作成する
  `test-summary.sh` の `rs_emit` 出力 assert 期待値が一致していることを task 8 側で確認すると整合性が担保される。

## 確認事項

- **Debugger 経路の Stage A''/B''（round=3）の run サマリ扱い**: design.md の `stages` enum
  （`A / Ap / B / Bp / C`）と tasks.md task 5 のスコープに A''/B''（round=3 / Debugger 経由）が
  含まれないため、本 task では Stage A''/B'' に `rs_record_stage` を差し込んでいない。
  `DEBUGGER_ENABLED=true` で round=3 まで進んだ稀ケースでは、stages 列に A''/B'' が現れず
  Ap/Bp までの記録に留まる（degraded スキャンは各 stage 完了時に累積実行されるため errors は
  反映される）。これが許容範囲か、stages enum に A''/B'' 相当を追加すべきかは PM/Architect の
  判断事項。本 task では spec を書き換えず現状の enum に従った。

- **（task 6）Reviewer reject 終端の result が claude-failed か needs-iteration か**: tasks.md task 6 は
  「Reviewer reject 終端（差し戻しループ打ち切りで needs-iteration になる終端）→ `rs_set_result needs-iteration`」と
  指示する一方、実装上 reviewer-reject2 / reviewer-reject3 終端は `mark_issue_failed` 経由で
  `claude-failed` ラベルが付与される（Req 7.2「claude-failed で終了した場合は claude-failed として記録」と表面上
  競合）。本 task では tasks.md を正本とし、`mark_issue_failed`（claude-failed 記録）の直後に
  `rs_set_result needs-iteration` を置いて上書きし、reject 起因の終端を needs-iteration、その他 stage 失敗を
  claude-failed として区別した（design.md result enum が両値を別途定義していることと整合）。この区別が
  運用意図と一致するか（ラベルは claude-failed だが run サマリ result は needs-iteration という乖離が許容されるか）は
  PM/Architect の判断事項。spec は書き換えていない。

- **（task 6）既存 PR ガード成功（`stage_c_existing_pr_guard`）の result**: 同ガードは OPEN/MERGED/CLOSED いずれも
  return 0 を返し、CLOSED は needs-decisions に遷移する。tasks.md task 6 の「Stage C 成功（PR 作成成功し
  ready-for-review へ向かう終端）」に既存 PR 検出抑止は厳密には該当せず、CLOSED ケースを一律 ready-for-review に
  するのは誤りのため、ガード成功パスには `rs_set_result` を差し込まず既定 unknown を維持した（新規 PR 作成成功のみ
  ready-for-review）。result enum に「既存 PR 再利用」「needs-decisions」値がないため OPEN/MERGED 検出抑止時は
  result=unknown のまま emit される。enum 拡張要否は PM/Architect の判断事項。

- **（task 6）hold（保留）の対応箇所**: design.md L59-60 は「round=1 defer（保留）」を hold の対象とするが、
  これが stage-a-verify round=1 defer か Reviewer reject round=1 かが文面では曖昧。実装を精査した結果、
  「claude-failed を付けず次 tick で再 pickup する保留（return 3）」は stage-a-verify round=1 defer のみであり、
  Reviewer reject round=1 は同一サイクル内で round=2 へ前進するため保留ではない。よって hold は
  stage-a-verify round=1 defer（`stage_a_verify_round1_defer` → `return 3`）に対応づけた。

## 受入基準カバレッジ（task 4 範囲）

- **Req 5.1 / 5.2（scaffolding 有無の記録）**: `_worktree_record_scaffolding` が `$wt/.claude/agents`
  `$wt/.claude/rules` 両 dir 実体を判定し `rs_set_scaffolding ok|missing` を記録。一時 worktree で
  両 dir あり→ok / 片方のみ→missing / `.claude` 不在→missing を smoke test で確認済み。
- **Req 5.3（既存 scaffolding 検査結果の流用）**: 4 return パス共通の dir 実体判定で流用。
- **NFR 1.2（既存挙動非変更）**: 記録は変数代入のみで slot_log / slot_warn / cp / rm の挙動・戻り値不変。
- **NFR 4.1（fail-open）**: `command -v` ガードで run-summary.sh 未 source 時も rc=0 を smoke test で確認済み。

STATUS: complete
