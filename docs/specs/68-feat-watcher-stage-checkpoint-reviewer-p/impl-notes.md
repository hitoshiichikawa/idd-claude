# Implementation Notes (#68)

Developer 補足メモ。`requirements.md` / `design.md` / `tasks.md` は人間レビュー済みの
ため書き換えず、実装上の判断・確認事項のみ本ファイルに記録する。

## 実装サマリ

| Task | コミット | 概要 |
|---|---|---|
| 1.1 | `feat(watcher): add STAGE_CHECKPOINT_ENABLED env var (#68 task 1)` | env 既定 false を Config に追加 + ヘッダコメントに resume 経路を追記 |
| 2.1〜2.4 | `feat(watcher): add Stage Checkpoint Module observation helpers (#68 task 2)` | sc_log/warn/error + has_impl_notes / read_review_result / find_impl_pr |
| 3.1 | `feat(watcher): add stage_checkpoint_resolve_resume_point (#68 task 3)` | decision table をコード化、START_STAGE 決定 + 1 ブロックログ |
| 4.1 | `feat(watcher): wire Stage Checkpoint resume into run_impl_pipeline (#68 task 4)` | 関数冒頭 gate + Stage A/B 起動ブロックを case で skip 制御 |
| 5.1, 5.2 | `docs(readme): document Stage Checkpoint Resume (#68 task 5)` | opt-in 表に行追加 + 「Stage Checkpoint (#68)」セクション新設 |

タスク 6 は `- [ ]*`（deferrable）で、本ファイルに smoke test 結果を記録することで完了とする。

## Requirements 受入基準カバレッジ

各 numeric requirement ID に対するテスト / 検証手段の対応:

| Req ID | 検証手段 |
|---|---|
| 1.1 | smoke test BC-1〜BC-4 / R-A〜R-OK で impl-notes.md tracked が START_STAGE 判定の入力として使われていることをログで確認 |
| 1.2 | smoke test resolve R-C / R-F / R-1 で review-notes.md の RESULT 行を解釈し START_STAGE が分岐 |
| 1.3 | smoke test R-OK で `gh pr list --head $BRANCH --state all` のスタブ出力に応じて TERMINAL_OK 判定 |
| 1.4 | `git ls-tree --name-only HEAD -- <path>` ベース判定 = 当該 branch HEAD に commit 済 = 別 worktree から `git fetch` 後再現可能（D-1, D-5）|
| 1.5 | 既存 mark_issue_failed 経路は不変。Stage 失敗時に成果物が無ければ次 tick の has_impl_notes/read_review_result が unparseable を返す（同じ smoke test 経路で間接的に確認）|
| 2.1 | smoke test R-A〜R-F で resolve_resume_point が START_STAGE を 1 つに決定、ログに記録 |
| 2.2 | smoke resolve test 1: 何も無ければ `START_STAGE=A reason=no-checkpoint` |
| 2.3 | smoke resolve test 2: impl-notes 有 / review-notes 無 → `START_STAGE=B reason=impl-notes-only-or-review-unparsed` |
| 2.4 | smoke resolve test 3: impl-notes + approve → `START_STAGE=C reason=approve+no-pr` |
| 2.5 | smoke resolve test 4: round=2 reject → `START_STAGE=TERMINAL_FAILED reason=round2-reject-residual` |
| 2.6 | smoke resolve test 6 / pipe test R-OK: 既存 PR 検出 → `START_STAGE=TERMINAL_OK` で run_impl_pipeline 即 return 0 |
| 2.7 | smoke ログに `--- begin resolve ---` から `--- end resolve ---` の 1 ブロック内に input / decision が出力されることを確認 |
| 3.1 | `STAGE_CHECKPOINT_ENABLED="${STAGE_CHECKPOINT_ENABLED:-false}"` を Config に配置 |
| 3.2 | smoke test BC-1 (env unset) / BC-2 (=false): stage-checkpoint ログ出力ゼロ、Stage A/B/C すべて従来通り実行 |
| 3.3 | smoke test BC-3 (=False, typo) / BC-4 (=0): どちらも opt-out として解釈され、stage-checkpoint ログゼロで Stage A から実行 |
| 3.4 | 追加 env のみで既存 env var 名は touch していない（`grep -n "REPO=\|REPO_DIR=\|LOG_DIR=\|LOCK_FILE=" issue-watcher.sh` で既存定義不変を目視確認）|
| 3.5 | 既存ラベル名（`LABEL_CLAIMED` 等）の定義を変更していない、`mark_issue_failed` の挙動も既存契約のまま |
| 3.6 | README に env を 1 個追加するだけの cron 例を提示。既存 cron 起動文字列はそのまま |
| 4.1 | `git ls-tree --name-only HEAD -- <path>` を使用（D-5, D-1）。smoke test では git commit ベースの判定が機能していることを観測 |
| 4.2 | smoke test 5: working tree のみに変更 / 未 commit のファイルが「不採用」になる経路は has_impl_notes が `[ -n "$out" ]` で空判定する仕組みで担保（コードレビューで確認済） |
| 4.3 | smoke test 8: review-notes.md の RESULT 行欠落 → `result=(missing-or-unparsed)` → Stage B から再実行 |
| 4.4 | SPEC_DIR_REL に Issue 番号が含まれるため、過去 Issue の path は構造的に混入しない（D-2）|
| 5.1 | smoke test 7: review-notes 有 / impl-notes 無 → INCONSISTENT 検出で `reason=inconsistent-review-notes-without-impl-notes` |
| 5.2 | run_impl_pipeline の TERMINAL_FAILED 経路は既存 mark_issue_failed を呼び出す（claude-failed 付与の既存契約を再利用）|
| 5.3 | sc_error / sc_warn が stderr に ERROR/WARN 行を出す。観測関数の git/gh 失敗時は `\|\| return N` で silent fail を回避 |
| 5.4 | resolve_resume_point の冒頭 `START_STAGE="A"` 初期化 + 内部エラー時 `\|\| true` ガードで safe fallback |
| 6.1 | README opt-in 表（L612 付近）に行追加。既定値 / 期待効果を記載 |
| 6.2 | README に新セクション「Stage Checkpoint (#68)」を Reviewer Gate と Feature Flag Protocol の間に追加 |
| 6.3 | README セクション内「影響範囲と既存挙動との互換性」「Migration Note」「期待される効果（token 効率）」を明記 |
| NFR 1.1 | smoke test BC-1〜BC-4: env 未設定 / opt-out 系で stage-checkpoint ログゼロ、外形挙動 100% 一致 |
| NFR 1.2 | `repo-template/**` 配下を一切変更していない（`git diff main..HEAD --stat` で確認） |
| NFR 2.1 | resolve のログは `--- begin resolve ---` から `--- end resolve ---` の 1 ブロック内に input + decision を出力 |
| NFR 2.2 | すべてのログ行が `stage-checkpoint:` prefix で始まる（grep `'stage-checkpoint:'` で機械抽出可能）|
| NFR 3.1 | smoke test R-B: impl-notes only → Stage A の claude 呼び出し 0 回（pipe-test の log で `[stub claude --print stub-prompt-a` 不在を確認）|
| NFR 3.2 | smoke test R-C: approve → Stage A / Stage B の claude / Reviewer 呼び出し 0 回（pipe-test の log で `stub-prompt-a` / `stub run_reviewer_stage` 不在を確認）|
| NFR 4.1 | `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` で warning / error ゼロ（info の SC2317 / SC2012 は既存と同形式で許容）|

## 手動スモークテスト結果（task 6 = deferrable）

### 1. resolve_resume_point 単体テスト 8 シナリオ

`/tmp/sc-resolve-test/run.sh`（ハーネスは別途破棄）で以下を実施:

| # | 入力 | 期待 START_STAGE | 結果 |
|---|---|---|---|
| 1 | 空 branch（impl-notes/review-notes/PR なし）| `A` (no-checkpoint) | OK |
| 2 | impl-notes のみ commit | `B` (impl-notes-only-or-review-unparsed) | OK |
| 3 | impl-notes + review-notes (round=1, RESULT: approve) | `C` (approve+no-pr) | OK |
| 4 | impl-notes + review-notes (round=2, RESULT: reject) | `TERMINAL_FAILED` | OK |
| 5 | impl-notes + review-notes (round=1, RESULT: reject) | `A` (round1-reject-mid-tick-fallback) | OK |
| 6 | gh pr list が `[{"number":99,"state":"OPEN"}]` を返す | `TERMINAL_OK` | OK |
| 7 | review-notes のみ（impl-notes 削除済）| `A` (inconsistent-review-notes-without-impl-notes) | OK |
| 8 | impl-notes + review-notes（RESULT 行欠落）| `B` (impl-notes-only-or-review-unparsed) | OK |

### 2. run_impl_pipeline 統合テスト

`/tmp/sc-pipe-test/run.sh` で `claude` / `gh` / `run_reviewer_stage` を stub 化して
pipeline 全体の挙動を観測:

| # | 設定 | 期待 | 結果 |
|---|---|---|---|
| BC-1 | `STAGE_CHECKPOINT_ENABLED` unset、空 branch | Stage A + B + C 全実行、`stage-checkpoint:` ログ 0 件 | OK |
| BC-2 | `=false` | 同上 | OK |
| BC-3 | `=False`（typo） | 同上（opt-out 扱い） | OK |
| BC-4 | `=0` | 同上 | OK |
| R-A | `=true`、空 branch | Stage A から実行（resolve 後 START_STAGE=A） | OK |
| R-B | `=true`、impl-notes commit 済 | Stage A スキップ、Stage B + C 実行（NFR 3.1）| OK |
| R-C | `=true`、impl-notes + review-notes(approve) commit 済 | Stage A + B スキップ、Stage C のみ実行（NFR 3.2）| OK |
| R-OK | `=true`、gh pr list が PR を返す | run_impl_pipeline 即 return 0、Stage 一切実行されず | OK |
| R-F | `=true`、round=2 reject 残骸 | TERMINAL_FAILED 経路で claude-failed 化（mark_issue_failed 呼び出し）| OK（実装到達確認、test 環境では LABEL_CLAIMED 未設定で gh stub 内で停止） |

### 3. 静的解析

```bash
shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh
# warning / error: 0 件（info: SC2317, SC2012 は既存と同形式で許容）
bash -n local-watcher/bin/issue-watcher.sh
# 構文 OK
```

### 4. 後方互換 dry-run

`env -i HOME=$HOME PATH=/usr/bin:/bin` でも `bash -n` が syntax OK を返すこと、
script 冒頭の PATH prepend で claude / gh / jq / flock / git / timeout の依存解決が
通ることを確認。

## 実装上の判断・解釈

### D-1〜D-5（design.md と同じ）

design.md の Decisions セクションをそのまま採用。実装上の追加判断:

1. **`stage_checkpoint_read_review_result` の戻り値分離**: design.md では「approve=0 /
   reject=1 / 不在=2」としていたが、parse_review_result が return 2 のときの stdout は
   空となる。`stage_checkpoint_read_review_result` は parse 結果を `echo` してから
   case 分岐する形にしたため、戻り値 2 のときは何も出力しない仕様で確定（design.md の
   契約と整合）。

2. **resolve 内での `tracked=yes/no` 判定の独立化**: 当初は `rev_rc=2` のときに
   `tracked=no` と表示していたが、不在と「tracked だが parse 失敗」が区別できないため、
   `git ls-tree` を直接呼んでログ用の tracked フラグを別途観測する実装に変更
   （ログの可読性向上）。

3. **`START_STAGE` を `local` 宣言**: design.md では「グローバル変数 START_STAGE」と
   していたが、`run_impl_pipeline` の関数内ローカル変数としても resolve_resume_point
   から `START_STAGE="X"` の代入を観測できる（bash の `local` は dynamic scope）。
   これにより run_impl_pipeline 外への汚染を避けつつ resolve から書き戻せる。

4. **shellcheck SC2034 への対処**: round=1 reject の `START_STAGE="A"` 行が
   shellcheck で「unused」と誤検出されたため、当該行に `# shellcheck disable=SC2034`
   を追加。task 4 で run_impl_pipeline が START_STAGE を読むようになるため将来的には
   不要になる可能性があるが、機能変更時の保険として残す。

### round 判別の robustness

design.md D-3 で「`<!-- idd-claude:review round=N -->` を grep」と決めたが、Reviewer
agent が確実にこのコメントを出力するかは agent 定義依存のため、`^round=N$` 形式の
代替パターンも grep するように実装（より緩い判定）。両方とも見つからなければ
INCONSISTENT 扱いで Stage A 再実行（safe fallback）。

## 確認事項（Reviewer / PjM へ）

設計書（design.md）と実装の間で疑義は無し。以下は PR レビュー時の確認候補:

1. **round=N コメントの安定性**: Reviewer agent（`.claude/agents/reviewer.md`）が
   `<!-- idd-claude:review round=N -->` を確実に出力する保証は agent prompt 設計に
   依存する。本実装は「見つからなければ INCONSISTENT 扱いで Stage A から再実行」
   という safe fallback を持つため壊れたら気づける（=「壊れた watcher が静かに
   sub-optimal な resume をする」事故は起きない）が、agent 定義側で round マーカーを
   出力契約として明示しておくと、token 効率の最適化が安定する。**本機能の範囲外
   として PR 後に reviewer.md を点検することを推奨**。

2. **`impl-notes.md` の commit & push 責務**: Stage A 完了 = impl-notes.md の存在で
   観測する設計上、Developer が `impl-notes.md` を commit & push しないまま Stage A
   が終わると（PjM Stage C で初めて push される現契約のもとでは）、Stage B 直前で
   watcher が落ちたケースの checkpoint が成立しない。本機能は「checkpoint 不採用 →
   Stage A 再実行」で safe に倒れるため不整合は起きないが、Developer agent
   （`.claude/agents/developer.md`）が `impl-notes.md` を最終コミットに含めるよう
   契約を明示しておくと NFR 3.1 の token 削減効果が安定する。**本機能の範囲外として
   PR 後に developer.md を点検することを推奨**（design.md 確認事項 2 と同じ指摘）。

3. **PARALLEL_SLOTS との共存**: PARALLEL_SLOTS=2 + STAGE_CHECKPOINT_ENABLED=true で
   別 Issue と同 Issue resume が同時走行しても、既存 slot lock + worktree 隔離設計に
   守られる前提（design.md Testing シナリオ 9）。本実装は per-Issue branch HEAD と
   per-Issue spec_dir のみを参照するため slot 間干渉は構造的に発生しないが、E2E は
   未実施（dogfooding 段階で検証）。

## 派生 Issue（候補）

- Reviewer agent / Developer agent の出力フォーマット契約（round マーカー、impl-notes
  最終 commit）を明文化する Issue を別途切る案（上記確認事項 1, 2）
- `STAGE_CHECKPOINT_ENABLED=true` 時の dogfooding E2E 観察用 Issue（Stage B 単独失敗を
  人為的に作って Developer 0 回を実測する）

## 追加した依存

なし。既存の `gh` / `jq` / `git` / `flock` / `timeout` / `claude` のみで動作。
