# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-392-impl-fix-dr-dr-log-stdout-staged-for-release
- HEAD commit: dd0175800ed3fe158ce7e442ca9eb3797e187cdd
- Compared to: main..HEAD
- Changed files: `local-watcher/bin/issue-watcher.sh`（`dr_log` 1 行 + コメントブロック）、
  `local-watcher/test/dr_resolve_one_stdout_test.sh`（新規 509 行）、
  `docs/specs/392-.../impl-notes.md`（新規）
- Feature Flag Protocol: `CLAUDE.md` に `## Feature Flag Protocol` 節（`**採否**:` 行）
  なし → 通常の 3 カテゴリ判定のみを適用（opt-in 細目は適用せず）

## Verified Requirements

- 1.1 — `dr_log` を `echo ... >&2` に変更（issue-watcher.sh L9680）。
  `dr_resolve_one_stdout_test.sh` Case 8 で `dr_log` 単体の stdout が空であることを assert
- 1.2 — `dr_warn` は本修正前から `>&2`（L9683）。Case 7 / 8 で stdout 汚染ゼロを assert
- 1.3 — Case 1 (OPEN + staged-for-release + BASE_BRANCH=develop) で stdout 厳密 `resolved` を assert
- 1.4 — Case 2 (OPEN + ラベル無し) で stdout 厳密 `open` を assert
- 1.5 — Case 3 (CLOSED + merged≥1) で stdout 厳密 `resolved` を assert
- 1.6 — Case 4 (CLOSED + merged=0、CLOSED node 1 件 / 空配列 2 fixture) で
  stdout 厳密 `closed unmerged` を assert
- 1.7 — Case 5 (GraphQL errors) / Case 6 (不正 JSON, issue=null) / Case 7 (gh rc!=0) /
  Case 9 (REPO 不正) で stdout 厳密 `api error` を assert
- 1.8 — Case 1 で `verdict=$(dr_resolve_one ...)` 捕捉値が 4 値集合
  (`resolved` / `open` / `closed unmerged` / `api error`) と完全一致することを case 分岐 assert
- 2.1 — Case 1 で OPEN + staged-for-release が `resolved` 1 行を返すことを実証。
  既存 `dr_unblock_sweep_test.sh` AT-a シナリオ（56 件 PASS）で間接担保
- 2.2 — `dr_unblock_sweep_test.sh` 56 件 PASS で構造化ログ
  `verdict=unblock_cleared` および「`未知の verdict` 残らない」を間接担保
- 2.3 — `_dispatcher_run` 経路は無変更（impl-notes に明示）。既存 #346 動線を維持
- 3.1 — `dr_unblock_sweep_test.sh` AT-c の gate `=true` 以外を 56 件 PASS で維持
- 3.2 — Case 2b (OPEN + BASE_BRANCH=main + staged-for-release ラベル) で `open` を返す
  既存挙動を維持することを assert
- 3.3 — Case 3 / 4 / 5 / 6 / 7 で CLOSED / api error 経路の挙動を維持
- 3.4 — env var / ラベル / exit code / cron 文字列は変更なし（diff は `dr_log` 1 行 + コメントのみ）
- 3.5 — `dr_unblock_sweep` 本体・FIFO 順・上限・cycle 連携の変更なし
- 4.1 — Case 8 で `dr_log` の stderr フォーマット `[YYYY-MM-DD HH:MM:SS] dr: <message>`
  維持を assert（cron は `>>cron.log 2>&1` で stderr を集約する前提）
- 4.2 — Case 1 で `dr: issue=#117 verdict=resolved reason=staged-for-release base=develop`
  の語彙・キー順序・prefix `dr:` 維持を assert
- 4.3 — Case 8 で `dr_error` の stdout が空 / stderr に `dr: ERROR:` 維持を assert
- 5.1 — Case 1〜7 + Case 9 の 5 経路すべてで stdout = verdict 1 行のみを厳密一致 assert
- 5.2 — `dr_extract_deps` は `dr_log` / `dr_warn` を呼ばない純粋関数（コード review 確認 +
  impl-notes に明記）。既存 `dr_unblock_sweep_test.sh` の依存抽出シナリオで間接担保
- 5.3 — `dr_format_unresolved_comment` も `dr_log` / `dr_warn` を呼ばない（impl-notes 確認）
- 5.4 — `dr_gh_graphql_closed_by` も `dr_log` / `dr_warn` を呼ばない（impl-notes 確認 +
  本テストでは stub 化）
- 6.1 — impl-notes に全 14 ロガー prefix の grep 結果を明示
  （`pr_detect_iteration_keyword` は既に `pr_log ... >&2` 対策済、
  `pr_build_prompt_file` はコメントで `pr_log` 不使用を明示）
- 6.2 — 横展開チェックで 0 件のため対象外（要件文の condition false）
- 6.3 — impl-notes に「`*_log` 横展開チェック: 同型バグ無し」と確認モジュール集合を明示
- 6.4 — 他モジュール `*_log` の一括書き換えなし（diff は `dr_log` 1 行のみ）
- 7.1 — `dr_resolve_one_stdout_test.sh` で `extract_function` イディオムにより
  `dr_resolve_one` / `dr_log` / `dr_warn` / `dr_error` の実体を抽出、`dr_gh_graphql_closed_by`
  のみを stub
- 7.2 — Case 1 で OPEN + staged-for-release + BASE_BRANCH=develop の捕捉 `verdict` が
  `resolved` と完全一致することを assert
- 7.3 — Case 1 で `dr_log` 行が stderr 経由のみで観測され、stdout に紛れ込まないことを
  両方向 assert（含む / 含まない）
- 7.4 — Case 2 / 3 / 4 / 5 / 6 の 5 経路で stdout 厳密一致を assert
- 7.5 — 既存 `dr_unblock_sweep_test.sh` stub を維持しつつ新規テストで実 stdout 純度を担保
- 8.1 — `local-watcher/bin/issue-watcher.sh` 単体修正で完結
- 8.2 — README 反映なし（ユーザー可視仕様の変更なし、要件文「必要時のみ追記」を尊重）
- 8.3 — `diff -r .claude/agents repo-template/.claude/agents` / `.claude/rules` ともに空
  （impl-notes 検証ログで確認）
- NFR 1.1 — `bash -n` OK、`shellcheck` baseline 維持（impl-notes 検証ログ）
- NFR 1.2 — 追加テストも `bash -n` / `shellcheck` クリーン（impl-notes 検証ログ）
- NFR 2.1 — ラベル名 `blocked` / `staged-for-release` / `claude-failed` / `needs-decisions` 改名なし
- NFR 2.2 — `DEP_AUTO_UNBLOCK_ENABLED` 未設定 / false 経路は本修正のコードパス対象外
- NFR 2.3 — 戻り値語彙 4 値集合を維持（Case 1〜9 で各値が出ることを assert）
- NFR 3.1 — Case 8 で `dr_log` / `dr_warn` の 1 行フォーマット維持を assert
- NFR 3.2 — Case 1 で `staged-for-release` 解決時の語彙・キー順序維持を assert
- NFR 4.1 — `>&2` 追加のみで変数展開クォート構造を破壊していない（diff 1 行）

## Boundary 確認

- 変更ファイル: `local-watcher/bin/issue-watcher.sh`（dr 系セクション L9666-9686）、
  `local-watcher/test/dr_resolve_one_stdout_test.sh`（新規）、impl-notes.md（仕様配下）
- 要件 Introduction の修正範囲（`dr_log` の `>&2` 化 + 棚卸し + 横展開チェック + 近接テスト追加）
  と diff が一致。`dr_resolve_one` / `dr_unblock_sweep` 本体・他モジュールの `*_log`
  には触れていない（Out of Scope を尊重）
- `tasks.md` は本 spec には存在せず（Triage 経路で Architect スキップ）、
  `_Boundary:_` アノテーションによる境界制約は提示されていない。要件文の Introduction /
  Out of Scope に従い境界違反なしと判定

## 検証実行（Reviewer による再実行）

| 検証項目 | 結果 |
|---------|------|
| `bash local-watcher/test/dr_resolve_one_stdout_test.sh` | 22 PASS / 0 FAIL |
| `bash local-watcher/test/dr_unblock_sweep_test.sh` | 56 PASS / 0 FAIL |
| `bash local-watcher/test/dc_cycle_sweep_test.sh` | 74 PASS / 0 FAIL |

## Findings

なし

## Summary

`dr_log` の 1 行修正 (`echo ... >&2`) + 詳細なコメントブロックで根因を解消し、
新規 22 assert 回帰テストで全 5 終端パスの stdout 純度と staged-for-release 解決パスの
verdict 捕捉非汚染を実証。Req 1〜8 / NFR 1〜4 をカバー、既存テスト（dr_unblock_sweep 56 件 /
dc_cycle_sweep 74 件）も全 PASS で後方互換を維持。Out of Scope の他モジュール `*_log`
一括書き換えにも踏み込んでいない。境界違反・AC 未カバー・missing test いずれも検出されず。

RESULT: approve
