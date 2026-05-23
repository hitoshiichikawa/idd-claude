# 実装ノート（Issue #166）

## 概要

`PER_TASK_LOOP_ENABLED=true` 下で `tasks.md` を持たない Issue（Architect 不要 triage を通過した
Issue 等）が、ログ上は「Stage A にフォールバックする」と表示しながら実際は `claude-failed` を
付与して即停止していた不整合を修正した。`tasks.md` 不在時は Issue を失敗扱いせず従来 Stage A
（single-shot Implementer + Reviewer round=1 + PR 作成）へ正しくフォールバックする。

## 採用した設計（Option C: 上位層の事前分岐）

requirements.md の Open Questions で提示された Option A / B / C のうち、Issue 指示の推奨かつ
NFR 2.1（per-task ループ dispatcher 本体アルゴリズムを変えず fallback 判定のみ追加）を最も
素直に満たす **Option C（上位層 `run_impl_pipeline()` の Stage A 分岐で事前判定）** を採用した。

### 採用理由

- **NFR 2.1 の責務境界保全**: `run_per_task_loop()` 本体（タスク逐次消化・round 制御・Debugger
  Gate）には一切手を入れず、起動判定（gate）のみを上位の `case "$START_STAGE" in A)` 分岐に
  追加した。dispatcher 本体アルゴリズムは無変更。
- **コード重複の回避**: 従来 Stage A は独立関数ではなく `else` ブランチ（`build_dev_prompt_a` +
  `qa_run_claude_stage "StageA"` + `verify_pushed_or_retry` + `handle_partial_status` の
  インライン展開）である。Option C は per-task ループ起動条件を `if` に畳むことで、`_pt_loop_enabled`
  が false のとき自然に既存 `else` ブランチへフォールスルーする。Stage A ブロックを複製せずに
  到達させられるため、Option B（`run_per_task_loop` 内から Stage A を直接呼ぶ）で必要になる
  関数抽出やコード複製を回避できた。

### Option A / B を採らなかった理由

- **Option A（fallback signal code を返し呼び出し側が Stage A 起動）**: `run_per_task_loop` が
  新たな signal（例 return 2）を返し呼び出し側で分岐する形。判定ロジックが関数内外に分散し、
  「tasks.md の有無」という単一判定を 2 箇所に持つことになる。Option C の方が判定が 1 箇所に
  集約され明快。
- **Option B（`run_per_task_loop` 内で従来 Stage A を直接呼ぶ）**: 従来 Stage A が独立関数で
  ないため、関数抽出（`run_stage_a`）を新設するか Stage A コードを複製する必要があり、NFR 2.1
  の「dispatcher 本体を変えない」制約と相性が悪い。

## 変更箇所

### 1. `local-watcher/bin/issue-watcher.sh`

#### `run_impl_pipeline()` の Stage A 分岐（`case "$START_STAGE" in A)`、9140 行付近）

- per-task ループ起動判定を `if [ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ] && [ -f tasks.md ]`
  相当に変更（`_pt_loop_enabled` フラグ変数 + フォールスルー）。
- `PER_TASK_LOOP_ENABLED=true` かつ `tasks.md` 不在のときは、AC5 の判別可能なログ行
  `--- per-task: tasks.md 不在 → Stage A fallback（<path>）---` を `tee -a "$LOG"` で出力してから
  従来 Stage A の `else` ブランチへフォールスルーする（`claude-failed` は付けない）。
- 既存 Stage A `else` ブロック（`build_dev_prompt_a` 以降）は無変更。

#### `run_per_task_loop()` の tasks.md 不在ブランチ（7132 行付近）

- 上位で事前分岐するため通常経路からは到達しなくなるが、防御ガードとして残置。
- ただし旧実装の `mark_issue_failed "per-task-tasks-missing"` + `return 1`（新挙動と矛盾する
  失敗扱い）を撤去し、`pt_warn` + `return 0`（no-op）に変更。万一直接呼び出し等で到達しても
  Issue を失敗扱いせず、メッセージ（「フォールバック相当」）と実装（実際は failed 化）の乖離を
  解消した（Issue の主訴）。
- 関数 docstring の戻り値説明も `return 0` の防御ガードケースを追記して同期。

### 2. `README.md`（per-task ループ節「新挙動（opt-in 時）」）

- 「tasks.md 不在時のフォールバック (#166)」の引用ブロックを追記。`tasks.md` 不在時は
  `claude-failed` 扱いせず従来 Stage A 経路へフォールバックし、slot ログに
  `per-task: tasks.md 不在 → Stage A fallback` が出る旨を明記（README との二重管理規約）。

### 3. スモークスクリプト（新規）

- `docs/specs/166-bug-watcher-per-task-loop-enabled-impl-m/test-pt-fallback.sh` を追加。
  起動判定ロジックを参照実装として抽出し、`tasks.md` あり/なし × `PER_TASK_LOOP_ENABLED`
  true/false/typo の組合せで分岐（per-task-loop / stage-a-fallback / stage-a-traditional）と
  AC5 フォールバックログの有無を機械検証する。

## テスト・検証結果

| 検証 | コマンド | 結果 |
|---|---|---|
| bash 構文 | `bash -n local-watcher/bin/issue-watcher.sh` | OK（`SYNTAX_OK`） |
| shellcheck（本体） | `shellcheck local-watcher/bin/issue-watcher.sh` | 新規警告ゼロ。残存は既存 SC2317（info, 関数 indirection 由来。編集行 9140-9230 / 7132 周辺に新規 finding なし） |
| shellcheck（スモーク） | `shellcheck docs/specs/166-.../test-pt-fallback.sh` | クリーン（`SMOKE_SHELLCHECK_CLEAN`） |
| スモークテスト | `./docs/specs/166-.../test-pt-fallback.sh` | 12 ケース全 `[OK]` / `SMOKE_RESULT: pass` |
| cron-like 最小 PATH | `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git'` | gh / jq / flock / git は解決。`claude` は script の PATH-prepend（line 37 `export PATH="$HOME/.local/bin:..."`）経由で解決（`command -v claude` → `$HOME/.local/bin/claude`）。本修正は PATH 処理に無関係 |
| dry-run（対象なし正常終了） | — | 未実施。理由: 本検証は `REPO` / `gh` 認証 / 実 Issue 状態に依存し worktree 環境で安全に再現困難。判定分岐はスモークスクリプトで機械検証済み |

## AC トレーサビリティ

| AC / NFR | 内容 | 担保 |
|---|---|---|
| AC 1.1 | flag=true + tasks.md 不在 → `claude-failed` を付けず従来 Stage A へフォールバック | impl: 9148-9155 行の事前分岐（`_pt_loop_enabled=false` のまま `else` フォールスルー）。smoke: `AC1: flag=true + tasks.md 不在 → stage-a-fallback` |
| AC 1.2 | フォールバック開始時に `claude-failed` 起因の失敗通知コメントを投稿しない | impl: 事前分岐は `mark_issue_failed` / `gh issue comment` を呼ばずログ行のみ出力。`run_per_task_loop` の不在ブランチからも `mark_issue_failed` を撤去 |
| AC 1.3 | フォールバック実行中、Implementer → Reviewer round=1 → PR 作成の順で従来同等の成果物を生成 | impl: 従来 Stage A `else` ブランチ（`build_dev_prompt_a` + `qa_run_claude_stage` + 後続 Stage B/C）に無変更で合流するため従来 Stage A と同一フロー |
| AC 1.4 | フォールバック中に Implementer/Reviewer が失敗したら従来同一の `claude-failed` ハンドリング | impl: 従来 Stage A `else` ブランチの失敗ハンドリング（`mark_issue_failed "stageA"`）を無変更で流用 |
| AC 2.1 | flag=true + tasks.md あり + pending≥1 → 従来 per-task ループで逐次処理 | impl: `_pt_loop_enabled=true` で `run_per_task_loop` 呼び出し（本体無変更）。smoke: `AC3: flag=true + tasks.md あり → per-task loop` |
| AC 2.2 | flag=true + tasks.md あり + pending 0 → Stage A 完了相当で正常終了 | impl: `run_per_task_loop` 内 `pending=0 → return 0`（無変更）。本ケースは tasks.md 存在のため上位判定で per-task ループへ入る |
| AC 2.3 | flag 未指定/true 以外 → per-task 分岐に入らず従来 Stage A | impl: `PER_TASK_LOOP_ENABLED:-false` の厳密一致判定（無変更）。smoke: NFR1.1 各ケース（空/false/True/1） |
| AC 3.1 | フォールバック発生をログで判別可能 | impl: 9153 行 `--- per-task: tasks.md 不在 → Stage A fallback（<path>）---`。smoke: `AC5: フォールバック発生時に判別可能ログ行` |
| NFR 1.1 | flag 未指定/true 以外で Stage A 外形挙動（ログ/ラベル遷移/exit code）が導入前と同一 | impl: flag off 時は `_pt_loop_enabled=false` でフォールバックログも出さず（`if PER_TASK_LOOP_ENABLED=true` の内側でのみ判定）従来 `else` へ直行。smoke: NFR1.1 各ケースで `stage-a-traditional` かつ fallback ログなし |
| NFR 1.2 | flag=true + tasks.md あり時の per-task 結果が導入前と同一 | impl: `run_per_task_loop` 本体無変更。tasks.md 存在時の起動条件も従来と等価 |
| NFR 2.1 | dispatcher 本体（逐次消化/round/Debugger Gate）を変えず fallback 判定のみ追加 | impl: `run_per_task_loop` 本体ループ（7160 行以降）に変更なし。追加したのは上位 gate と不在ブランチの失敗→no-op 化のみ |

## 確認事項（Reviewer / 人間判断ポイント）

- **`run_per_task_loop()` 不在ブランチの残置 vs 撤去**: 上位事前分岐により通常経路からは到達
  しないため撤去も可能だが、防御ガードとして残置し失敗扱い（`mark_issue_failed` + `return 1`）
  を no-op（`return 0`）に変更する方針を採った。これは「メッセージと実装の乖離を解消」という
  Issue 主訴と、万一の直接呼び出し時にも Issue を失敗扱いしないという AC1.1 の精神に沿わせる
  ためである。完全撤去を望む場合は要レビュー判断。
- **dry-run スモーク未実施**: 上記テスト表のとおり実 Issue / gh 認証依存のため未実施。分岐判定は
  `test-pt-fallback.sh` で機械検証済み。E2E は dogfooding（本 repo に test issue を立てる）で
  別途確認するのが望ましいが、本 PR スコープ外とした。
- **要件・設計の曖昧点**: なし。Open Questions の Option 選択は Developer 領分（Architect 不要
  triage）として Option C を確定した。requirements.md の AC 解釈に追加の発明・変更は加えていない。

STATUS: complete
