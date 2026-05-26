# 実装ノート（Issue #251）

## 概要

Stage Checkpoint resume (#68) の `stage_checkpoint_resolve_resume_point()` が、per-task
ループ (#21) の途中で `impl-notes.md` が tracked になると、残必須タスクがあっても
`START_STAGE=B`（Stage A skip）を選び per-task ループが二度と起動しないバグを修正した。

修正は **impl-notes 有 / review-notes 無（`rev_rc=2`）の B 分岐に限定**し、`tasks.md` の
残必須タスク（deferrable `- [ ]*` を除く `- [ ]`）を read-only で確認して、残っていれば
`START_STAGE=A`（per-task ループ再開）を選ぶ。`approve`（C）/ `reject`（round 分岐）系の
判定には一切介入しない（Req 3）。

## 修正内容

### `local-watcher/bin/issue-watcher.sh`

- 関数冒頭の Decision Table コメント（1105-1117 行付近）を tasks.md 残必須タスク有無で
  分岐する記述へ更新。
- `case "$rev_rc" in 2)` 分岐（従来 `START_STAGE=B` 固定）を以下のロジックに置換:
  1. `$REPO_DIR/$SPEC_DIR_REL/tasks.md` が **存在しない**（design-less impl）→ 残タスク判定を
     スキップし従来どおり `START_STAGE=B`（reason 据え置き `impl-notes-only-or-review-unparsed`）。
  2. tasks.md が存在する → 既存 `pt_extract_pending_tasks "$sc_tasks_md"` を再利用して残必須
     タスクを抽出。
     - 抽出が **内部エラー（rc≠0）** → 安全側で `START_STAGE=A`（reason `pending-extract-error`、
       `sc_warn` で警告）。`[ -f ]` チェックを先行させているため tasks.md 不在の return 1 とは
       自然に分離される（NFR 3.1）。
     - 残必須タスク **1 件以上** → `START_STAGE=A`、`sc_log` で
       `reason=pending-tasks-remain count=N` を出力（Req 1, Req 5）。
     - 残必須タスク **0 件** → 従来どおり `START_STAGE=B`（reason 据え置き、Req 2）。
- 新規 env var は追加していない（既存 `REPO_DIR` / `SPEC_DIR_REL` のみ使用 / NFR 1.2）。
- read-only 判定のみで tasks.md / impl-notes.md / branch を編集・commit・push しない（NFR 2.2）。

### `README.md`

- 「Stage Checkpoint (#68)」節の Decision Table（impl-notes 有 / review-notes 無の行）を
  tasks.md 残必須タスク有無で 2 行に分割し、`#251` の残タスク再開挙動を 1 段落で追記。
- 残必須タスクによる Stage A 再開時のログ書式 `reason=pending-tasks-remain count=N` を明記。

## Migration note の要否判断

本修正は **既定挙動のバグ修正**であり、新規 opt-in / 新規外部サービス呼び出しの追加では
ない。判定が変わるのは「impl-notes 有 / review-notes 無 / tasks.md に残必須タスクあり」の
ケースに限定され、従来 `B`（Stage A skip → 残タスク永久未消化）だったものが `A`（per-task
ループ再開）に正される方向のみ。全タスク完了済み per-task impl / design-less impl（tasks.md
不在）/ `STAGE_CHECKPOINT_ENABLED=false` 経路は従来と完全に同一の `START_STAGE` を返す
（NFR 1.1, 1.4）。したがって独立した migration note セクションは不要と判断し、README の
Decision Table と説明段落で「判定が変わる旨」を明記する形にとどめた（CLAUDE.md「README との
二重管理」規約に従い同一 PR で README を更新）。

## Test plan

本リポジトリに unit test フレームワークは無いため、静的解析 + スモークテストで検証した。

### 静的解析

- `shellcheck local-watcher/bin/issue-watcher.sh` → 警告ゼロ（SHELLCHECK_CLEAN）
- `shellcheck docs/specs/251-bug-watcher-stage-checkpoint-resume-impl/test-stage-checkpoint-resume.sh`
  → 警告ゼロ（subshell env 隔離の SC2030/SC2031 は意図的なため局所 disable）

### スモークテスト

`docs/specs/251-bug-watcher-stage-checkpoint-resume-impl/test-stage-checkpoint-resume.sh` を
新規作成。再実装ドリフトを避けるため、`issue-watcher.sh` から実関数定義
（`stage_checkpoint_*` / `pt_extract_pending_tasks` / `parse_review_result` /
`extract_review_result_token` / `sc_log` 等）を `sed` で抽出して `source` し、**実関数を直接
実行**する。git tracked 判定は一時 git repo で実体を作り、`gh pr list` は PATH スタブで
「PR なし（rc=1）」に固定する。実 repo・branch には一切触れない。

実行結果（全 11 アサーション pass / `SMOKE_RESULT: pass`）:

| ケース | 入力 | 期待 START_STAGE | 結果 |
|---|---|---|---|
| 本バグ修正 | impl有 / review無 / 残必須2件 | A | OK |
| Req5 可観測性 | 同上のログに `reason=pending-tasks-remain count=2` | （ログ一致） | OK |
| Req2 従来維持 | impl有 / review無 / 全タスク完了 | B | OK |
| Req2 reason維持 | 全完了時 `reason=impl-notes-only-or-review-unparsed` | （ログ一致） | OK |
| Req4 design-less | impl有 / review無 / tasks.md不在 | B | OK |
| NFR3.2 deferrable | `- [ ]*` のみ残（必須0件） | B | OK |
| Req3.1 approve | approve + 残必須あり | C（介入しない） | OK |
| Req3.2 reject r2 | reject round=2 + 残必須あり | TERMINAL_FAILED（介入しない） | OK |
| Req3.3 reject r1 | reject round=1 + 残必須あり | A（既存どおり） | OK |
| NFR2.1 冪等性 | 同一 HEAD で 3 回呼ぶ | A（毎回同一） | OK |
| NFR2.2 副作用ゼロ | resolve 前後で HEAD / ファイル / status 不変 | （不変） | OK |

実行コマンド: `./docs/specs/251-bug-watcher-stage-checkpoint-resume-impl/test-stage-checkpoint-resume.sh`

### 動作確認（定義順）

`pt_extract_pending_tasks`（2192 行付近）は `stage_checkpoint_resolve_resume_point`（1129 行付近）
より後方で定義されているが、bash は関数呼び出しを実行時に解決するため定義順は問題ない。
スモークテストでも実際に呼び出して pass することを確認済み。

## 受入基準とテストの対応

| Req ID | 担保テスト |
|---|---|
| Req 1.1 / 1.2 / 1.3 | Case1（impl有/review無/残必須あり → START_STAGE=A）+ run_impl_pipeline の START_STAGE=A 経路で per-task ループ再開（既存 4759-4778 行の分岐に制御を渡す） |
| Req 2.1 | Case2（全タスク完了 → B）+ reason 維持ログ確認 |
| Req 2.2 | Case5（approve → C、既存ロジック不変） |
| Req 3.1 | Case5（approve は残必須あっても C） |
| Req 3.2 | Case6（reject round=2 は残必須あっても TERMINAL_FAILED） |
| Req 3.3 | Case7（reject round=1 は既存どおり A） |
| Req 3.4 | rev_rc=2 分岐のみに介入を限定（実装上、他分岐のコードは未変更）。Case5/6/7 で他分岐不変を確認 |
| Req 4.1 / 4.2 | Case3（tasks.md 不在 → B） |
| Req 5.1 / 5.2 | Case1 のログアサート（`stage-checkpoint:` prefix + `count=2` 抽出） |
| NFR 1.1 | run_impl_pipeline 4730 行の `STAGE_CHECKPOINT_ENABLED=false` gate を確認（本関数を呼ばない経路は不変） |
| NFR 1.2 | 新規 env var を追加せず実装（コードレビューで担保） |
| NFR 1.4 | Case2 / Case3（全完了 per-task impl / design-less impl で従来同一 START_STAGE） |
| NFR 2.1 | Case8（複数回呼び出しで同一 START_STAGE） |
| NFR 2.2 | Case9（HEAD / ファイル / git status 不変） |
| NFR 3.1 | 実装の `pending-extract-error → START_STAGE=A` フォールバック（コードレビューで担保）。`[ -f ]` 先行分離により tasks.md 不在の return 1 は Case3 で別途 B に分岐 |
| NFR 3.2 | Case4（deferrable `- [ ]*` を必須として数えない → 必須0件 → B） |

## 確認事項

- 本 Issue は design-less impl（design.md / tasks.md は本 spec dir に存在しない）。要件の
  scope（rev_rc=2 分岐限定、Req 3）を厳守した。曖昧点・矛盾は発見していない。
- `NFR 3.1` の内部エラーフォールバックは、実装上 `pt_extract_pending_tasks` が tasks.md
  存在時に通常 rc=0 を返すため、スモークテストで自然発火させるのは難しい。`[ -f ]` 先行
  チェックで tasks.md 不在の return 1 は別経路（Case3=B）に分離済みであり、残る「想定外の
  内部エラー」は防御的フォールバックとしてコードに明示（`sc_extract_rc != 0 → START_STAGE=A`）。
  実害のある false negative を避ける安全側設計として、専用 fixture でのエラー注入テストは
  追加していない（実関数を改変せず注入する手段が無いため）。これは仕様逸脱ではなく
  防御コードの位置付け。

STATUS: complete
