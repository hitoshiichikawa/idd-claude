# Implementation Notes

## 実装サマリ

Issue #263（per-task Implementer が rc=0 で進捗ゼロのまま終了し、次 tick 以降で同じ task を
無限再 pickup する無限リトライループ）の修正を以下の通り実装した。すべて
`local-watcher/bin/issue-watcher.sh` 単一ファイルへの変更で完結する。

### 追加した関数

1. **`pt_check_task_completed <tasks_md_path> <task_id>`** (新規 / `issue-watcher.sh` 内)
   - tasks.md 上で指定 task_id の checkbox 状態を判定し、戻り値で表現する
   - 戻り値: `0` = `- [x]` 完了 / `1` = `- [ ]` 未完了 / `2` = tasks.md 不在 or 該当行不在
   - `pt_extract_pending_tasks` の正規表現 `^- \[ \] [0-9]+(\.[0-9]+)*\.? ` と整合し、親
     （`- [ ] 1. <title>`）/ 子（`- [ ] 1.1 <title>`）両慣習をカバー
   - `set -euo pipefail` 配下で grep no-match を `2>/dev/null` で吸収し、関数全体を止めない
   - task_id を sed で正規表現リテラル化し、`1` が `1.1` / `1.10` の prefix に誤マッチしないことを保証
   - 配置場所: `pt_extract_pending_tasks` の直後（`issue-watcher.sh:2202` 付近）

2. **`pt_mark_no_progress_failed <task_id> <stage_phase> <check_rc>`** (新規 / `issue-watcher.sh` 内)
   - 進捗ゼロ検出時に `mark_issue_failed "per-task-implementer-no-progress" "<body>"` を流用して
     `claude-failed` 化する専用ヘルパー（Req 2.1, 2.2 / NFR 1.2 既存ハンドラ流用）
   - Issue コメント本文に task_id・検出フェーズ（`initial` / `blocked-redo` / `round2-redo` /
     `round3-redo`）・判定根拠（`pt_check_task_completed` rc）・watcher ログパス・人間向け
     復旧手順を含める（Req 4.1〜4.5）
   - watcher ログに grep 可能な 1 行 `pt_log "task=<id> implementer end rc=0 progress=zero
     phase=<phase> check_rc=<rc> → claude-failed (per-task-implementer-no-progress)"` を出力
     （Req 4.4, NFR 2.1, 2.2）
   - 配置場所: `run_per_task_loop` の直前（`issue-watcher.sh:2880` 付近）

### 修正箇所（`run_per_task_loop` 関数内 4 箇所の rc=0 分岐）

`run_per_task_loop()` 関数内の 4 つの `run_per_task_implementer "$task_id"` 呼出直後の
`impl_rc=0` ケースに、`pt_check_task_completed` を呼んで進捗を機械検証し、未完了なら
`pt_mark_no_progress_failed` を呼んで `return 1` する分岐を追加（Req 1.3 / 全 4 箇所適用）:

| 呼出位置 | 変数名 | 検出フェーズ識別子 | 旧挙動 | 新挙動 |
|---|---|---|---|---|
| round=1 初回実行 | `impl_rc` | `initial` | `0) ;;` で即続行 | rc=0 でも進捗ゼロなら停止 |
| BLOCKED 経路再実行 | `impl_bl_rc` | `blocked-redo` | `0) ;;` で即続行 | rc=0 でも進捗ゼロなら停止 |
| Reviewer reject 後再実行 | `impl2_rc` | `round2-redo` | `0) ;;` で即続行 | rc=0 でも進捗ゼロなら停止 |
| Debugger 経由 3 回目再実行 | `impl3_rc` | `round3-redo` | `0) ;;` で即続行 | rc=0 でも進捗ゼロなら停止 |

#### 後方互換性（NFR 1.1, 1.3 / Req 1.2）

- `PER_TASK_LOOP_ENABLED=true` の場合のみ `run_per_task_loop()` が起動する既存の dispatcher
  経路に変更はない（`run_impl_pipeline` 側の分岐は無修正）
- `PER_TASK_LOOP_ENABLED` 未設定 / `true` 以外 / `false` のケースでは、本機能の追加コードは
  1 行も実行されない（構造的 skip / Req 1.2）
- 既存 `mark_issue_failed` を流用しており、`claude-claimed` / `claude-picked-up` の除去順序・
  `claude-failed` 付与・末尾の `build_recovery_hint` 流用も既存挙動と完全一致（NFR 1.2）
- `rc=99`（quota）/ `rc=非 0`（claude 非 0 exit）の既存経路は変更せず、本検証は rc=0 分岐
  のみに挿入（Req 1.4）

### 既存 `pt_extract_pending_tasks` 正規表現との整合（Req 3.3）

`pt_check_task_completed` は `pt_extract_pending_tasks` と同じ判定パターン
（`^- \[[ x]\] <id>\.? `）に依拠する。`- [ ]*` deferrable は両者の判定パターンの「`\[ \]` 直後に
空白を要求」する仕様により自然に除外されるため、deferrable は per-task ループの dispatch 対象に
入らず、`pt_check_task_completed` の検証経路にも乗らない（Req 3.3 / Req 5.3 と整合）。

## 検証結果

### Mechanical check

- **`shellcheck local-watcher/bin/issue-watcher.sh`**: 警告ゼロ（exit code 0）。1 箇所
  `SC2016`（sed 単引用符内のリテラル `\\&`）は意図的な無展開のため `# shellcheck disable=SC2016`
  ディレクティブで個別抑止
- **`bash -n local-watcher/bin/issue-watcher.sh`**: syntax error なし（exit code 0）

### 手動スモークテスト

新規 fixture `docs/specs/263--bug-per-task-implementer-tasks-md/test-fixtures/test-pt-check-task-completed.sh`
を作成し、17 ケース全 pass を確認:

| ケース | 入力 | 期待 rc | 実 rc | 判定 |
|---|---|---|---|---|
| 親タスク `- [x] 1.` | task_id=1 | 0 | 0 | PASS |
| 親タスク `- [ ] 2.` | task_id=2 | 1 | 1 | PASS |
| 不在 task_id=9 | (該当行なし) | 2 | 2 | PASS |
| 子タスク `- [x] 1.1` | task_id=1.1 | 0 | 0 | PASS |
| 子タスク `- [ ] 1.2` | task_id=1.2 | 1 | 1 | PASS |
| 子タスク `- [ ] 1.10` | task_id=1.10 (2 桁) | 1 | 1 | PASS |
| 1.1 prefix の誤マッチ防止 | task_id=1.1, 1.10 が `- [x]` | 1 | 1 | PASS |
| tasks.md 不在 | (ファイルなし) | 2 | 2 | PASS |
| deferrable `- [ ]* 3.1` | task_id=3.1 | 2 | 2 | PASS |
| 空 tasks.md | (空ファイル) | 2 | 2 | PASS |
| 実際的な親 + 子 + deferrable mix | 6 task | 各期待値 | 一致 | 6/6 PASS |

実行: `bash docs/specs/263--bug-per-task-implementer-tasks-md/test-fixtures/test-pt-check-task-completed.sh`
→ `PASS=17 FAIL=0`

### 既存テストとの整合性

`pt_extract_pending_tasks` の regex 動作（`1`, `1.1`, `1.10` を抽出、`- [x]` 完了行 / `- [ ]*`
deferrable 行を除外）が変更されていないことを `/tmp/regex-cross-check.sh` で確認。本機能は
`pt_extract_pending_tasks` の出力を変更しないため、既存 per-task ループの dispatch 対象は
不変（Req 3.4 / NFR 1.1）。

## 受入基準のテスト割当

| Req ID | 内容 | テスト割当 |
|---|---|---|
| 1.1 | rc=0 直後の `- [ ] → - [x]` 機械検証 | `test-pt-check-task-completed.sh` 全 17 ケース |
| 1.2 | `PER_TASK_LOOP_ENABLED` 未設定 / false 時 1 行も実行しない | 構造的 skip。`run_per_task_loop()` が呼ばれない経路で本機能のコードは到達不能（コードレビューで担保） |
| 1.3 | 全 4 箇所（initial / blocked-redo / round2-redo / round3-redo）に適用 | コードレビューで担保（4 箇所の `case "$impl*_rc"` 0) 分岐に `pt_check_task_completed` 呼出を挿入したことを diff で確認可能） |
| 1.4 | rc=99 / 非 0 終了時は本検証を skip | コードレビューで担保（既存 `99)` / `*)` 分岐は無修正） |
| 2.1 | 進捗ゼロ検出時に `claude-failed` 化 | `pt_mark_no_progress_failed` が `mark_issue_failed` を流用（実装ロジック） |
| 2.2 | ラベル付け替え（picked-up / claimed 除去 + failed 付与） | `mark_issue_failed` 流用で既存挙動と等価（NFR 1.2） |
| 2.3 | 進捗ゼロ検出時に per-task ループ即時打ち切り | 4 箇所すべてで `return 1` |
| 2.4 | Reviewer / PR / ready-for-review / Stage A 完了ゲートを起動しない | `return 1` により後続経路に到達しない（構造的） |
| 2.5 | 同一実行に対し二重発火しない | 1 回の `case` 0) 分岐内で 1 度だけ判定 + 1 度だけ `mark_issue_failed`、`return 1` で即離脱 |
| 3.1 | 進捗ありの正常系（`- [x]` 遷移済み）は本機能導入前と同一経路 | `pt_check_task_completed` rc=0 時の処理: 旧来通り続行（diff 範囲外） |
| 3.2 | 後段 Reviewer / Debugger Gate / Stage A 完了ゲートの起動タイミングを変更しない | コードレビューで担保（rc=0 分岐に検証を追加したのみで rc=99 / 非 0 / Reviewer 経路に変更なし） |
| 3.3 | `- [ ]*` deferrable は検証対象外 | `pt_extract_pending_tasks` regex で除外されているため per-task ループの dispatch 対象に入らない（fixture でも検証） |
| 3.4 | 判定単位は当該 round の task_id 1 件 | `pt_check_task_completed` は単一 task_id を引数に取り他 task に依存しない |
| 4.1 | Issue コメント本文に task_id 識別文字列 | `pt_mark_no_progress_failed` 本文に `対象 task ID: \`${task_id}\`` |
| 4.2 | Issue コメント本文に進捗ゼロ説明文 | `pt_mark_no_progress_failed` 本文に「rc=0 で終了したが `- [ ] → - [x]` 遷移が確認できなかった」旨を記載 |
| 4.3 | Issue コメント本文に自動再開停止旨 + watcher ログパス参照 | `pt_mark_no_progress_failed` 本文に `ログ: \`$LOG\`` および無限ループ防止旨を記載 |
| 4.4 | watcher ログに grep 可能な 1 行 | `pt_log "task=<id> implementer end rc=0 progress=zero phase=<phase> check_rc=<rc>"` を出力 |
| 4.5 | Issue コメントに人間向け復旧手順 | `pt_mark_no_progress_failed` 本文に「次の手順」セクション + 既存 `build_recovery_hint` 流用 |
| 4.6 | 新規 stage 識別子 `per-task-implementer-no-progress` | `mark_issue_failed "per-task-implementer-no-progress" ...` で既存 stage 識別子と区別可能 |
| 5.1 | 1 回の Implementer 呼出に対し 1 回判定 | `case "$impl*_rc"` 0) 分岐内で 1 回だけ呼出（4 箇所すべて） |
| 5.2 | `claude-failed` 既付与 Issue は再 pickup しない | 既存ラベル除外条件（変更なし） |
| 5.3 | tasks.md 読取失敗時は claude-failed で停止 | `pt_check_task_completed` rc=2 (tasks.md 不在 / 該当行不在) → `pt_mark_no_progress_failed` 呼出 |
| NFR 1.1 | `PER_TASK_LOOP_ENABLED` 無効時に既存挙動を維持 | 構造的 skip（`run_per_task_loop` が呼ばれない） |
| NFR 1.2 | 既存失敗ハンドラを流用 | `mark_issue_failed` を引数違いで呼ぶのみ |
| NFR 1.3 | 既存 Reviewer reject / Debugger Gate / Stage A 完了ゲートの判定ロジックを変更しない | 変更なし（rc=0 分岐に新検証を追加したのみ） |
| NFR 2.1 | 新規 stage 識別子 `per-task-implementer-no-progress` で区別可能 | 既存識別子 (`per-task-implementer-failed` 等) と異なる文字列 |
| NFR 2.2 | per-task ロガー既存書式 (`task=<id> implementer end ...`) と整合 | `pt_log "task=${task_id} implementer end rc=0 progress=zero phase=..."` で整合 |
| NFR 3.1 | grep / read 高々 2 回 | 実際は 1 回の Implementer 呼出に対し `pt_check_task_completed` 内 grep 高々 2 回（完了 → 未完了の順序）+ 実行前 grep は呼ばない設計（実行後のみで判定可能） |

> 注: 実装では「実行前 / 実行後」の 2 回 grep ではなく **実行後 1 回のみ** の grep で
> 判定している。これは「実行前に `- [ ]` 行が存在し、実行後に `- [x]` で同じ行が出ていれば
> 完了」という素朴な diff 比較ではなく、「実行後の最終状態が `- [x]` か `- [ ]` か」を
> 直接判定するアプローチに簡素化したため。Implementer 実行前後で tasks.md 上の当該行が
> 完全に消える / 別 ID に置換されるケースは spec 外であり、本実装の判定で十分（NFR 3.1
> の「高々 2 回」要件を 1 回に圧縮）。

## 後方互換性の確認

- **`PER_TASK_LOOP_ENABLED=false` / 未設定**: `run_per_task_loop()` 自体が呼ばれず、Stage A は
  既存の単一 Developer 経路で動作する。本機能のコードは 1 行も実行されない（Req 1.2 / NFR 1.1）
- **既存 `mark_issue_failed` の挙動**: 変更なし。本機能は同関数を新しい stage 識別子で呼ぶだけ
- **既存 `pt_log` の書式**: 変更なし。本機能は同関数を `task=<id> implementer end ...` 書式で呼ぶ
- **`pt_extract_pending_tasks` の出力**: 変更なし。同関数は本機能で参照しない
- **ラベル遷移契約**: `claude-claimed` / `claude-picked-up` 除去 + `claude-failed` 付与の順序は
  既存 `mark_issue_failed` の挙動そのまま
- **env var 名 / cron 登録文字列 / exit code 意味**: 一切変更なし

## 確認事項（PR レビュワーへ）

- 進捗検証の判定タイミングを「実行後 1 回のみ」に簡素化した（NFR 3.1 の「高々 2 回」を満たす）。
  仕様上は「実行前 + 実行後」の 2 回判定でも構わないが、実行後の最終状態だけで未完了 / 完了
  が判定できるため、実行前の grep は冗長と判断した。問題があれば指摘されたい
- `pt_check_task_completed` の戻り値 `2`（該当行不在）は要件 5.3「tasks.md 読取失敗時の fail-safe」
  と「該当 task_id 行不在の防御」を両方含む。tasks.md 自体が存在しないケースは
  `run_per_task_loop()` 冒頭で防御済みのため、戻り値 2 が実発火するのは spec 不整合（tasks.md
  に該当 task_id 行が無いのに per-task ループに dispatch されたケース）に限られる。この場合も
  「fail-safe で claude-failed 化」する方針で実装した（Req 5.3）
- Issue コメント本文に含めた「検出フェーズ」（`initial` / `blocked-redo` / `round2-redo` /
  `round3-redo`）は要件で明示されていないが、運用者がどの round で進捗ゼロが発生したかを
  把握しやすくする観測性向上のため追加した（NFR 2.1 / 2.2 の趣旨に沿うと判断）

## Reviewer への引き継ぎメモ

- 変更箇所の意図: per-task ループの **rc=0 分岐に限定** して進捗検証フックを挿入したため、
  既存の rc=99（quota）/ rc=非 0（claude 非 0 exit）経路には一切手を加えていない。Reviewer は
  diff の 4 箇所 (`case "$impl_rc"` / `case "$impl_bl_rc"` / `case "$impl2_rc"` / `case "$impl3_rc"`)
  すべてで `0)` ブロック内に `pt_check_task_completed` + `pt_mark_no_progress_failed` 呼出が
  挿入されていることを確認してほしい
- 新規ヘルパー 2 関数 (`pt_check_task_completed` / `pt_mark_no_progress_failed`) は既存の
  `pt_log` / `mark_issue_failed` を流用しており、独自に副作用を持たない
- 既存の `pt_mark_diff_range_resolve_failed`（Issue #164 由来）は重複コメント抑制機能を持つが、
  本機能の `pt_mark_no_progress_failed` は「進捗ゼロ検出は 1 回の rc=0 分岐に対し 1 回しか
  発火しない」（Req 2.5 / 5.1）ため重複コメント抑制ロジックを持たない。同一 Issue が複数 tick に
  またがって持ち越されるケースは `claude-failed` ラベル除外条件で既存仕組みが捕捉する（Req 5.2）
- fixture テスト `test-pt-check-task-completed.sh` は `awk` で関数本体だけを抽出して `eval` で
  局所評価する方式。`source` で `issue-watcher.sh` 全体を読み込むと main 実行ロジックが走って
  しまうため避けた。本 fixture は POSIX-bash 4+ 環境で完全動作する

STATUS: complete
