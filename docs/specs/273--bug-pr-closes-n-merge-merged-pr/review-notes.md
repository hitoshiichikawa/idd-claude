# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-273-impl--bug-pr-closes-n-merge-merged-pr
- HEAD commit: 8ea81b6ce012cfbf40d09e3e53e58da672dc84d0
- Compared to: main..HEAD

CLAUDE.md には `## Feature Flag Protocol` 節が存在しないため、本レビューは通常の 3 カテゴリ
（AC 未カバー / missing test / boundary 逸脱）判定のみを適用する（flag 観点は適用外）。

## Verified Requirements

### Requirement 1（PR 本文の Refs/Closes 規約）

- 1.1 — `.claude/agents/project-manager.md` の新規サブ節「実装 PR 本文の `Refs` / `Closes`
  使い分け（auto-close 事故防止）」で「`tasks.md` の最上位未チェックタスク残存件数 > 0
  なら `Refs #N`」を判定ロジック（疑似コード + bash スニペット）として明文化。
- 1.2 — 同節で「remaining_after_this_pr <= 0 なら `Closes #N`」「design-less impl（tasks.md
  不在）なら `Closes #N`」を明示。
- 1.3 — 「確認事項への 1 行記載例」サブ節で `部分実装 PR: 残 X 件のため Refs を採用` /
  `最終 PR: tasks.md 全完了のため Closes を採用` / `design-less impl: 単一 PR で完了のため
  Closes を採用` の 3 例を明示。
- 1.4 — `diff -r .claude/agents repo-template/.claude/agents` を実行 → 無出力（byte 一致）を
  確認。
- 1.5 — `README.md` 「使い方 > 基本フロー」節 7 番目項目直後に新規 h4「部分実装 PR と最終 PR
  の `Refs` / `Closes` 使い分け（auto-close 事故防止）」を追加。Refs/Closes 使い分け規約と
  第 2 防御線、観測性 grep 例を明文化。

### Requirement 2（MERGED PR 非 terminal 化ガード）

- 2.1 — `stage_checkpoint_find_impl_pr()` の `elif [ -n "$merged_pr" ]` 分岐に再判定ガードを
  inject。`issue_state == "OPEN" && tasks_rc == 0 && tasks_unchecked >= 1` のときのみ
  `found=""` で非 terminal 化。
- 2.2 — `found=""` に倒すことで既存の `pr_rc=1`（既存 impl PR なし）経路に合流し、後段の
  impl-notes.md / review-notes.md 評価へ進む。
- 2.3 — `issue_state == "CLOSED"` 分岐で `found="$merged_pr"` を維持し
  `reason=closed-issue` をログ出力（従来通り terminal）。
- 2.4 — `tasks_rc == 2`（ファイル不在 = design-less impl 等価）/ `tasks_unchecked == 0`
  （全完了）のいずれも `found="$merged_pr"` で従来通り terminal を維持。
- 2.5 — 新規 inject は `elif [ -n "$merged_pr" ]` ブロック内に閉じ、OPEN PR 採用経路
  （`if [ -n "$open_pr" ]; then found="$open_pr"`）には 1 行も手を入れていない。追加
  `gh issue view` は OPEN PR 不在 + MERGED PR 存在時のみ発火。

### Requirement 3（取得失敗時の safe fallback）

- 3.1 — `issue_rc != 0`（gh API 失敗）→ `reason=issue-api-failure`、`found="$merged_pr"`
  で従来通り terminal。
- 3.2 — `tasks_rc == 1`（I/O 失敗、`[ -r "$path" ]` false）→ `reason=tasks-io-failure`、
  `found="$merged_pr"` で従来通り terminal。`tasks_rc == 2`（ファイル不在）も同様。さらに
  想定外 rc に対する `*) reason="tasks-unknown-rc"; found="$merged_pr"` の保険も実装。
- 3.3 — `sc_tasks_unchecked_count` 内で `local rel="$SPEC_DIR_REL/tasks.md"` /
  `local path="$REPO_DIR/$rel"` として既存 spec ディレクトリ規約を再利用。spec ディレクトリ
  不在は `[ -f "$path" ]` false → rc=2（design-less impl 等価）にフォールスルー。

### Requirement 4（観測可能性）

- 4.1 — 非 terminal 経路は `sc_log "find-impl-pr: merged-non-terminal pr=#... issue=#...
  issue_state=OPEN unchecked=... reason=open-issue-with-unchecked-tasks branch=..."` で
  既存 `stage-checkpoint:` prefix に揃えて 1 行出力。
- 4.2 — terminal 経路は `sc_log "find-impl-pr: merged-terminal pr=#... issue=#...
  issue_state=... unchecked=... reason=<closed-issue|no-tasks-file|tasks-io-failure|
  all-checked|issue-api-failure|tasks-unknown-rc> branch=..."` で出力。
- 4.3 — `sc_log` ヘルパは既存実装を流用しており `[YYYY-MM-DD HH:MM:SS] stage-checkpoint:`
  3 段書式が維持される（既存挙動）。

### Requirement 5（既存挙動の後方互換）

- 5.1 — CLOSED 除外ログ（`excluded-closed`、Issue #265 由来）の発火条件
  `[ -z "$open_pr" ] && [ -z "$merged_pr" ] && [ -n "$closed_pr" ]` は MERGED 不在を要求
  するため、本 inject ブロック（MERGED 存在時のみ実行）と物理的に排他。1 行も手を入れて
  いない。
- 5.2 — 越境観測ヘルパ（`stage_a_crossing_probe` 等）には変更なし。本 inject は
  `stage_checkpoint_find_impl_pr` 内に閉じている。
- 5.3 — spec 完全性ガードへの変更なし。
- 5.4 — `STAGE_CHECKPOINT_ENABLED=false` 時の既存 gate は本関数より上位にあり、本 inject に
  到達しない。1 行も発火しない後方互換は維持。

### Non-Functional Requirements

- NFR 1.1 — 新規 env var なし（差分上 `STAGE_CHECKPOINT_ENABLED` 以外の新規 env 追加なし）。
- NFR 1.2 — ラベル名・Issue フィルタ規則への変更なし。
- NFR 1.3 — `issue_state == "CLOSED"` 分岐で従来挙動を維持。
- NFR 1.4 — PR テンプレートのセクション順・必須項目は本サブ節追加と `Closes` 行のプレース
  ホルダ化（`<Refs|Closes #<issue-number>>`）以外不変。
- NFR 2.1 — ログ書式が既存 `stage-checkpoint:` prefix と同一。
- NFR 3.1 / 3.2 — `sc_issue_state` / `sc_tasks_unchecked_count` ともに read-only。`gh
  issue view --json state` / `grep -cE` のみで書き込み副作用なし。
- NFR 4.1 — `diff -r .claude/agents repo-template/.claude/agents` 無出力を実行確認済み。

### テスト（test-fixtures）

- task 1 で追加された `docs/specs/273--bug-pr-closes-n-merge-merged-pr/test-fixtures/` 配下
  に `tasks-with-unchecked.md` / `tasks-all-checked.md` / `tasks-empty.md` の 3 fixture と
  `test-merged-guard.sh` 回帰スクリプトを追加。
- 実行確認: `bash test-merged-guard.sh` → PASS=3 FAIL=0（unchecked=2 / all-checked=0 /
  empty=0 すべて期待値一致）。
- 判定 regex `^- \[ \]\*? [0-9]+\. ` が `.claude/rules/tasks-generation.md` の Budget
  overflow count 抽出 regex と完全一致していることを `sc_tasks_unchecked_count` 関数冒頭
  コメントで明示。

### 静的解析 / verify

- `shellcheck local-watcher/bin/issue-watcher.sh` → 警告ゼロ（exit 0）。
- `diff -r .claude/agents repo-template/.claude/agents` → 無出力。
- `diff -r .claude/rules repo-template/.claude/rules` → 無出力。
- tasks.md `## Verify` 構造化ブロックの 4 コマンドすべて green を実行確認。

### Boundary 確認

差分対象ファイル:
- `local-watcher/bin/issue-watcher.sh`（Stage Checkpoint Module 内、tasks 2/3/4 `_Boundary:
  Stage Checkpoint Module_` 準拠）
- `.claude/agents/project-manager.md` / `repo-template/.claude/agents/project-manager.md`
  （tasks 5/6 `_Boundary: PjM Agent (impl)_` / `リポジトリ二重管理規約` 準拠）
- `README.md`（task 7 `_Boundary: README ワークフロー節_` 準拠）
- `docs/specs/273-*/test-fixtures/*` / `tasks.md` / `impl-notes.md`（task 1 補助物と
  Developer の自己記録）

いずれも tasks.md の `_Boundary:_` アノテーションで許可された範囲内。boundary 逸脱なし。

## Findings

なし

## Summary

要件 1〜5 / NFR 1〜4 のすべての numeric ID が実装または test-fixtures / 設定ファイル
（`.claude/agents/project-manager.md` / `README.md`）でカバーされており、tasks.md の
`_Boundary:_` 逸脱・missing test も検出されなかった。`shellcheck` / `diff -r` / 回帰
スクリプト（PASS=3 FAIL=0）も green。任意タスク 8（統合スモーク）は deferrable のため
未実施でも reject 対象外。

RESULT: approve
