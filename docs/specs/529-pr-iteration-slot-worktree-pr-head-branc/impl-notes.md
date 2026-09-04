# 実装ノート (#529)

## 変更点サマリ

PR Iteration Processor（`local-watcher/bin/modules/pr-iteration*.sh`）が、slot worker の
worktree 残留により head branch の checkout に失敗し無限リトライ + コメントスパムに陥る問題を修正。

### Requirement 1: holding worktree の自動 detach
- 追加: `pi_detach_holding_worktrees`（`pr-iteration.sh`）。`git worktree list --porcelain` を awk で
  パースし `refs/heads/<head_ref>` を保持する **他** worktree を `git -C <wt> checkout --detach` で解放。
- 呼び出し: `pi_run_iteration` の subshell 内、`git fetch` 成功後・`git checkout -B` 直前（`pr-iteration.sh`）。
  この checkout コードパスは kind 非依存のため impl / design 両方をカバー（AC 1.3）。
- 現在の worktree（`git rev-parse --show-toplevel`）は除外（checkout -B が扱う / NFR 1.2）。detach 失敗は
  WARN のみで既存フロー継続（AC 1.5）。head_ref は awk `-v` / git は `--detach`（引数なし）のみで
  オプション注入不可（NFR 2.1 / 2.2）。全 git 操作に `PR_ITERATION_GIT_TIMEOUT` 適用（NFR 3.1）。

### Requirement 2: 着手表明コメントの dedupe
- 追加: `pi_processing_comment_posted`（`pr-iteration-state.sh`）。sentinel marker
  `<!-- idd-claude:pr-iteration-processing round=N -->` の完全一致で既投稿判定（rc 0=既投稿 / 1=未投稿 / 2=判定不能）。
- 変更: `pi_post_processing_comment`（`pr-iteration-state.sh`）冒頭で dedupe。rc 0 のみ再投稿を抑止（AC 2.1）。
  rc 1/2 は投稿へ進む（AC 2.2 / 2.3 fail-open）。常に return 0。

### Requirement 3: 着手前段失敗の no-progress 計上 + escalate
- 追加: tmpfile `pi_preclaim_file`。claude 起動直前に `reached-claude` を書き込み、subshell 非 0 終了時に
  本 file が空なら「着手前段失敗（claude 未起動）」と判定（`pr-iteration.sh`）。
- 変更: `pi_run_iteration` の最終 `else` 分岐。着手前段失敗のみ `pi_next_no_progress_streak`(commit なし=+1)
  → `pi_classify_round_outcome` → `escalate` なら `pi_escalate_to_failed`(reason=no-progress) で
  `needs-iteration` 除去 + `claude-failed` 付与（AC 3.1〜3.4）。claude 起動後失敗は既存挙動（marker 据え置き）維持。
  no-progress 上限は max_rounds 非依存のため design（無制限）でも打ち切る（AC 3.5）。

## gate の採否: 常時有効（新 env / gate なし）
- 本件は「壊れていたケースだけ正す」バグ修正。Req 1 の detach は正常系で完全 no-op（誰も branch を保持
  しなければ何もしない）であり外部挙動を新たに増やさないため、CLAUDE.md §3 の「既定は後方互換 no-op」を
  「detach 常時有効・ただし正常系 no-op」で満たす。既存 no-progress streak 機構（#122）へ相乗りするため
  新 env gate は不要と判断。新ラベル・新 env var・exit code 変更なし（NFR 1.1 / 1.3 / 1.4）。

## Req 3 の marker round / streak 更新方針の決定
- **streak は +1 して永続化、round は据え置く**（next_round へ進めない）。理由: 着手前段失敗では round が
  実質消費されておらず、かつ round を進めると next_round が毎サイクル変化して着手表明コメント dedupe（Req 2）が
  効かず再びスパム化するため。round 据え置き + streak 加算により、次サイクルは同一 round を dedupe しつつ
  streak のみ積み上がり、上限で escalate する。marker 書き込み失敗は WARN のみ（round を無限化させない）。

## 検証
- `bash -n`: pr-iteration.sh / pr-iteration-state.sh とも OK。
- `shellcheck`: 変更 2 module + 新規 3 テスト、警告ゼロ。
- 新規テスト（近接配置 / `extract_function` + stub イディオム）:
  - `pi_detach_holding_worktrees_test.sh`: PASS 14 / FAIL 0
  - `pi_processing_comment_dedupe_test.sh`: PASS 12 / FAIL 0
  - `pi_preclaim_no_progress_test.sh`: PASS 14 / FAIL 0
- 既存回帰テスト全緑: `pi_no_progress_invariant_test`(21) / `pi_classify_round_outcome_test`(24) /
  `pi_max_rounds_kind_test`(24) / `pr_iteration_oos_no_progress_test` / `pr_iteration_oos_routing_test` /
  `pi_detect_quota_soft_fail_test`(13) 他。
- 全 suite（`local-watcher/test/*.sh`）: pr-iteration 関連は全て安定緑。`spec-html_test.sh` は本 PR と無関係の
  既存失敗（ambient env に `SPEC_HTML_ENABLED=true` が設定されており「未設定→OFF」assertion が落ちる。
  module 変更を stash した base 状態でも同様に失敗するため本 PR 起因ではない）。
  `publish_terminal_failure_artifacts_test.sh` も base で失敗する既存 flaky（pr-iteration 非依存）。

## AC トレーサビリティ
| AC | 担保テスト |
|---|---|
| 1.1 / 1.2 | `pi_detach_holding_worktrees_test.sh`（他 worktree 保持 → detach + checkout 継続） |
| 1.3 | 同上 + コード: 呼び出しが kind 非依存の checkout パス直前（`pr-iteration.sh`） |
| 1.4 | `pi_detach_holding_worktrees_test.sh`（別 branch の slot は detach されない） |
| 1.5 | `pi_detach_holding_worktrees_test.sh`（detach 失敗でも rc 0） |
| 2.1 | `pi_processing_comment_dedupe_test.sh`（既投稿 round は再投稿抑止） |
| 2.2 | `pi_processing_comment_dedupe_test.sh`（新 round は 1 回投稿 / 初回投稿） |
| 2.3 | `pi_processing_comment_dedupe_test.sh`（判定失敗でも return 0 / fail-open 投稿） |
| 3.1 | `pi_preclaim_no_progress_test.sh`（着手前段失敗で streak +1） |
| 3.2 | `pi_preclaim_no_progress_test.sh`（limit 未満は no-progress = 据え置き） |
| 3.3 | `pi_preclaim_no_progress_test.sh`（limit 到達で escalate + label 遷移） |
| 3.4 | `pi_preclaim_no_progress_test.sh`（escalate 本文が streak / limit を含む）+ コード: escalate ログ 1 行 |
| 3.5 | `pi_preclaim_no_progress_test.sh`（max_rounds 非依存で escalate 判定） |
| NFR 1.1〜1.4 | 新 env / gate / ラベル / exit code なし（コードレビュー）。正常系 no-op を各 detach テストで担保 |
| NFR 2.1 / 2.2 | `pi_detach_holding_worktrees_test.sh`（`-` 始まり head_ref を完全一致 detach / フラグ注入なし） |
| NFR 3.1 | コード: 全 git 操作に `PR_ITERATION_GIT_TIMEOUT` 適用（静的確認） |

## 確認事項
- **slot worker 側の終了時 detach（requirements Out of Scope / Open Question 3）**: 本 PR は pr-iteration 側の
  detach（提案1後者）で問題を解消済み。slot worker 終了時に worktree を detach する追加防御（提案1前者）は
  スコープ外とした。恒久対策として別 Issue で追跡することを提案（採否は運用者判断）。
- **NFR 3.1 のタイムアウト実挙動**: `PR_ITERATION_GIT_TIMEOUT` の適用はコード上確認したが、実 timeout 発火は
  単体テストで再現していない（stub で duration を strip）。既存 module の timeout 運用と同一イディオムのため
  リスクは低いと判断。
- **design.md / tasks.md 不在**: 本 Issue は requirements.md のみで design/tasks フェーズを経ていない。実装は
  requirements の AC と既存 no-progress 機構（#122）との整合で確定した。設計レビュー観点で追加確認が必要なら
  Architect への差し戻しを提案する。

STATUS: complete
