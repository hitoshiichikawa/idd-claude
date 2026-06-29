# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-06-29T13:55:00Z -->

## Reviewed Scope

- Branch: claude/issue-442-impl-fix-reviewer-reviewer-error-max-turns-cl
- HEAD commit: 21c72d8b2b77aadf7ac6e334910262c92b0ce488
- Compared to: main..HEAD

## Verified Requirements

committed 差分（`main..HEAD`）が **空** のため、commit 状態でカバレッジが確認できた AC は
**ゼロ件** です。HEAD（`21c72d8`）は base ブランチ `main` と同一 SHA であり、ブランチ上に
実装 / テスト commit が 1 つも存在しません（`git log --oneline main..HEAD` も空）。

参考までに、未 commit の working tree には実装の実体が存在し、内容自体は各 AC に対応する形に
見えます（情報提供。**commit されていないため verify 対象にはなりません**）:

- 1.1〜1.5 / 2.1〜2.4 / 3.1〜3.6 / 4.1〜4.6 — `local-watcher/bin/issue-watcher.sh`（working
  tree 上 +239/-33）に `reviewer_normalize_extended_max_turns` / `reviewer_is_error_max_turns`
  ヘルパー、per-task 経路（`run_per_task_reviewer`）と単発経路（`run_reviewer_stage`）双方の
  拡張リトライ内側ループ、return code 6（`reviewer-max-turns-exhausted`）escalation を実装。
- NFR 4.1 — `local-watcher/test/reviewer_max_turns_flow_test.sh`（8/8 PASS）/
  `reviewer_max_turns_retry_test.sh`（20/20 PASS）が untracked で存在。reviewer 環境で再実行し
  green を確認済み。
- NFR 1.3 / NFR 3.1（README 同期）— **working tree でも未対応**（後述 Finding 2）。

## Findings

### Finding 1
- **Target**: 1.1〜4.6 / NFR 全件（committed 状態での全 numeric AC）
- **Category**: AC 未カバー
- **Detail**: ブランチ HEAD（`21c72d8b2b77aadf7ac6e334910262c92b0ce488`）が base ブランチ
  `main` と完全同一 SHA で、`git diff main..HEAD` および `git log --oneline main..HEAD` が
  いずれも空。Developer の実装は **すべて未 commit の working tree 変更**（`issue-watcher.sh`
  は modified / unstaged、`reviewer_max_turns_flow_test.sh` と `reviewer_max_turns_retry_test.sh`
  は untracked）として存在するのみで、commit 群が 1 つも積まれていない。`git status` 上
  origin ブランチは local と up-to-date のため、push 済みブランチにも実装 commit は無い。
  この状態では PR にマージされる成果が空であり、requirements.md の全 numeric AC が commit
  状態で未カバー。あわせて `tasks.md` / `design.md` / `impl-notes.md` が spec ディレクトリに
  不在で、`impl-notes.md` のテスト結果・AC 紐付けも提供されていない。
- **Required Action**: working tree の実装（`issue-watcher.sh` の変更）と 2 つのテストファイルを
  commit し、`docs(...)` 成果物（`impl-notes.md`、および Architect 領分の `tasks.md`）を
  spec ディレクトリに揃えて、`main..HEAD` の差分に実装・テストが載る状態にすること。

### Finding 2
- **Target**: NFR 1.3 / NFR 3.1（README 同期・migration note）
- **Category**: AC 未カバー
- **Detail**: 実装は `REVIEWER_MAX_TURNS` 既定値を 30→50 に引き上げ、新 env var
  `REVIEWER_MAX_TURNS_EXTENDED` と新規 escalation カテゴリ `reviewer-max-turns-exhausted`
  （return code 6）を追加しているが、**README は working tree 上でも一切更新されていない**
  （`git status` で README に変更なし）。README は依然として `REVIEWER_MAX_TURNS` 既定を
  `30` と記載（`README.md:5631`、`README.md:7245`）。NFR 1.3（既定値引き上げの migration
  note）および NFR 3.1（`REVIEWER_MAX_TURNS` 説明 / オプション env var 一覧 /
  Reviewer 障害カテゴリ説明の同一 PR 更新）に対応する観測可能な変更が差分・既存コードの
  いずれにも無い。
- **Required Action**: README の該当箇所（`REVIEWER_MAX_TURNS` 既定値 30→50 の migration
  note、`REVIEWER_MAX_TURNS_EXTENDED` のオプション env var 一覧追加、`reviewer-max-turns-exhausted`
  障害カテゴリ説明）を同一 PR で更新し、commit に含めること。

## Summary

ブランチ HEAD が base（`main`）と同一 SHA で `main..HEAD` が空のため、Developer の実装・
テストが 1 件も commit されておらず（working tree に未 commit で存在）、commit 状態で全
numeric AC が未カバー。加えて README 同期（NFR 1.3 / NFR 3.1）が working tree でも未対応。
未 commit の実装内容・テスト自体は健全（テスト全 PASS）だが、commit されていないため
approve できない。実装を commit し、`tasks.md` / `impl-notes.md` と README 更新を揃えて
再提出すること。

RESULT: reject