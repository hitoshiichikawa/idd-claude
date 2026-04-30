# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-04-30T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-68-impl-feat-watcher-stage-checkpoint-reviewer-p
- HEAD commit: 1fdb517 (`docs(specs): record #68 impl-notes (smoke test results + traceability)`)
- Compared to: merge-base(origin/main, HEAD) = `0f5d54f` ..HEAD
  （`origin/main..HEAD` だと origin/main 側が後続で進んだ #67 / #66 等の差分が「削除」として誤って混入するため、merge-base 起点で判定）
- Files changed in scope:
  - `local-watcher/bin/issue-watcher.sh`（+429 -57）
  - `README.md`（+114 -0）
  - `docs/specs/68-feat-watcher-stage-checkpoint-reviewer-p/impl-notes.md`（新規 +180）

## Verified Requirements

### Requirement 1: Stage 完了 checkpoint の確立

- 1.1 — Stage A 完了 = `impl-notes.md` の branch HEAD tracked 判定。`stage_checkpoint_has_impl_notes()` (`local-watcher/bin/issue-watcher.sh:1858`) が `git ls-tree --name-only HEAD -- "$rel"` で working tree only の未 commit を不採用化。impl-notes.md smoke テーブル R-A〜R-OK で確認。
- 1.2 — Stage B 完了 = `review-notes.md` の RESULT 行。`stage_checkpoint_read_review_result()` (`local-watcher/bin/issue-watcher.sh:1880`) が既存 `parse_review_result` を再利用しつつ branch HEAD tracked を先行確認、TSV 同形式で stdout、return 0/1/2。
- 1.3 — Stage C 完了 = 既存 impl PR の存在。`stage_checkpoint_find_impl_pr()` (`local-watcher/bin/issue-watcher.sh:1908`) が `gh pr list --head $BRANCH --state all` で OPEN/MERGED/CLOSED を検出。
- 1.4 — `git ls-tree HEAD` ベースなので「branch に commit & push 済」=「別 worktree から `git fetch` 後再現可能」。design D-1 / D-5 と整合。
- 1.5 — Stage 失敗時に成果物が無ければ次 tick の `has_impl_notes` / `read_review_result` が「不採用」を返す。既存 `mark_issue_failed` 経路は不変。

### Requirement 2: 再開地点の判定

- 2.1 — `stage_checkpoint_resolve_resume_point()` (`local-watcher/bin/issue-watcher.sh:1945`) が START_STAGE を 1 つに決定し、`run_impl_pipeline` 冒頭 (`:2531`) で読み取り。
- 2.2 — 何も無ければ `START_STAGE=A reason=no-checkpoint` (`:2030` 付近)。smoke test 1。
- 2.3 — impl-notes 有 / review-notes 無 → `START_STAGE=B reason=impl-notes-only-or-review-unparsed`。smoke test 2 / R-B。
- 2.4 — impl-notes + approve → `START_STAGE=C reason=approve+no-pr`。smoke test 3 / R-C。
- 2.5 — round=2 reject → `START_STAGE=TERMINAL_FAILED reason=round2-reject-residual` → `mark_issue_failed "stage-checkpoint-terminal-failed"` (`:2545`)。smoke test 4 / R-F。
- 2.6 — 既存 impl PR を最優先で検出して `TERMINAL_OK` → `run_impl_pipeline` が即 `return 0`（ラベル不変）。smoke R-OK。
- 2.7 — `--- begin resolve ---` 〜 `--- end resolve ---` の 1 ブロックで `input:` 行（spec_dir / impl-notes tracked / review-notes tracked + result + round / existing-impl-pr）と `decision:` 行を `sc_log` で出力。NFR 2.1 / 2.2 と一致。

### Requirement 3: opt-in 切替と後方互換性

- 3.1 — `STAGE_CHECKPOINT_ENABLED="${STAGE_CHECKPOINT_ENABLED:-false}"` (`local-watcher/bin/issue-watcher.sh:150`)。既存 PR Iteration / Design Review Release の近傍。
- 3.2 — `run_impl_pipeline` 冒頭 (`:2531`) は `[ "${STAGE_CHECKPOINT_ENABLED:-false}" = "true" ]` の bash 完全一致のみで分岐入。flag false 時は resolve を呼ばず、`local START_STAGE="A"` のまま既存 case で「A 経路」に到達 = 既存挙動と等価。smoke BC-1 / BC-2。
- 3.3 — `=False` / `=0` / 空文字 / typo はすべて `"true"` ≠ で opt-out。smoke BC-3 / BC-4。
- 3.4 — diff 上で既存 env var（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `PR_ITERATION_ENABLED`）の定義は touched なし。
- 3.5 — diff 上で既存ラベル定義（`LABEL_*`）は touched なし。`mark_issue_failed` も既存契約のまま新引数 `"stage-checkpoint-terminal-failed"` を渡すのみ。
- 3.6 — README cron 例 (`L1738` 付近) は `STAGE_CHECKPOINT_ENABLED=true` を 1 個追加するだけの形。既存例は書き換えなし。

### Requirement 4: checkpoint の信頼性と新鮮度判定

- 4.1 — `git ls-tree --name-only HEAD -- "$rel"` で当該 branch HEAD の commit に tracked かを判定。mtime / hash / 絶対時刻に依存しない。
- 4.2 — main 由来でも当該 branch HEAD で tracked であれば採用、untracked なら不採用。これは「過去 Issue の残骸を採用しない」主旨と整合（SPEC_DIR_REL に Issue 番号が含まれるため過去 Issue path は構造的に混入しない、design D-2）。
- 4.3 — `parse_review_result` が return 2 → `stage_checkpoint_read_review_result` も return 2 → resolve で `rev_rc=2` 経路 → `START_STAGE=B reason=impl-notes-only-or-review-unparsed`。smoke test 8。
- 4.4 — 同上、SPEC_DIR_REL 構造で担保。

### Requirement 5: 失敗・異常系の取り扱い

- 5.1 — `has_impl="no"` / `rev_rc≠2`（review-notes 有）→ `START_STAGE=A reason=inconsistent-review-notes-without-impl-notes` (`:2026` 付近)。smoke test 7。
- 5.2 — TERMINAL_FAILED は `mark_issue_failed` 既存契約を再利用 (`:2545`)。
- 5.3 — `sc_error` / `sc_warn` が stderr に prefix 付き ERROR/WARN 行を出力 (`:1843-1849`)。`gh pr list` 失敗時は `sc_warn "gh pr list failed (rc=$pr_rc) → safe fallback"` (`:1996` 付近)。silent fail なし。
- 5.4 — `stage_checkpoint_resolve_resume_point` が return 1 を返した場合は `run_impl_pipeline` (`:2533`) が `START_STAGE="A"` に safe fallback。冒頭で `START_STAGE="A"` 初期化しているため部分代入の事故も発生しない。

### Requirement 6: ドキュメント整合性

- 6.1 — README opt-in 一覧表 (`README.md:612` 付近) に `STAGE_CHECKPOINT_ENABLED` 行追加（既定 false / リンク `#stage-checkpoint-68`）。
- 6.2 — 新セクション `## Stage Checkpoint (#68)` 追加（`README.md:1677` 付近）。Stage と checkpoint 対応表 / decision table / 環境変数 / 影響範囲 / 期待される効果 / 失敗・異常系 / 既知の制約 / Migration Note を網羅。
- 6.3 — 「影響範囲と既存挙動との互換性」節に既存 cron 起動文字列との互換性、Stage 失敗時の再実行範囲を明示。

### Non-Functional Requirements

- NFR 1.1 — flag 未設定時は `run_impl_pipeline:2531` の if 内に入らず resolve を呼ばない。`local START_STAGE="A"` 固定のまま既存 Stage A 経路に到達。smoke BC-1〜BC-4 で `stage-checkpoint:` ログ 0 件を確認。
- NFR 1.2 — `git diff 0f5d54f..HEAD --stat` で `repo-template/**` が touched 0 ファイル。consumer repo への影響なし。
- NFR 2.1 — `--- begin resolve ---` から `--- end resolve ---` までの sc_log 群が 1 ブロック内に input + decision を出力（`local-watcher/bin/issue-watcher.sh:1976` 付近〜）。
- NFR 2.2 — 全 sc_log / sc_warn / sc_error 行が `stage-checkpoint:` prefix で始まる (`:1843-1849`)。grep 抽出可能。
- NFR 3.1 — Stage A 起動ブロックが `case "$START_STAGE" in A) ... ;; B|C) sc_log "Stage A をスキップ" ;; esac` で skip 制御 (`:2552-2580`)。START_STAGE=B のとき claude (Developer) 呼び出し 0 回。impl-notes.md 8.R-B で確認。
- NFR 3.2 — 同様に Stage B 起動ブロックが `A|B) ... ;; C) sc_log "Stage B をスキップ" ;; esac` (`:2583-2654`) で skip。START_STAGE=C のとき Stage A の claude / Stage B の Reviewer 呼び出し 0 回。impl-notes.md 8.R-C で確認。
- NFR 4.1 — Reviewer 自身で `shellcheck local-watcher/bin/issue-watcher.sh` 再実行 → warning / error 0 件、info は SC2317（unreachable warning、既存 mq_warn / pi_log と同形式）と SC2012（既存）のみで impl-notes.md の主張と一致。

## Boundary 適合性

tasks.md の `_Boundary:_` 制約と diff の照合:

- Task 2.1〜2.4 / 3.1: `_Boundary: Stage Checkpoint Module_` → Stage Checkpoint Module は `local-watcher/bin/issue-watcher.sh:1820-2067` の新規 section に独立配置。Reviewer Gate (`:2068`) の直前で、design.md File Structure Plan と一致。
- Task 4.1: `_Boundary: Reviewer Stage Pipeline (run_impl_pipeline)_` → `run_impl_pipeline` (`:2524-2674`) のみ改修。冒頭の opt-in ガード追加 + 既存 Stage A / Stage B(round=1)+A'+round=2 ブロックの `case "$START_STAGE"` 化。Stage C は unconditional のまま。
- Task 5.1, 5.2: `_Boundary: README.md_` → `README.md` のみ改修（opt-in 表 1 行追加 + 新セクション）。
- 不要なファイル変更なし。`repo-template/**` / `.claude/agents/**` / 既存ラベルスクリプト等への変更なし。

## Findings

なし（findings なし、approve 候補）。

## Summary

Stage Checkpoint Resume の実装は、tasks.md の各 Boundary に閉じており、requirements.md 全 numeric ID（1.1〜6.3 / NFR 1.1〜4.1）が実装またはテスト（impl-notes.md の 8 シナリオ smoke + 9 統合 + shellcheck）でカバーされています。`STAGE_CHECKPOINT_ENABLED=false` 既定での後方互換性は flag の bash 完全一致ガードと resolve 呼び出し回避で構造的に保証され、opt-in の Feature Flag 設計（CLAUDE.md 採否は opt-in 宣言なし → 通常 3 カテゴリ判定のみ）にも整合します。Findings なし。

RESULT: approve
