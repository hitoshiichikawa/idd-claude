# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-374-impl-fix-pr-reviewer-claude-review-status-per
- HEAD commit: 59d7a31e6fc17accba579a30cfe835547c969326
- Compared to: main..HEAD
- 変更ファイル統計: README.md (+10) / impl-notes.md (新規) / requirements.md (新規) /
  local-watcher/bin/issue-watcher.sh (+8) / local-watcher/bin/modules/pr-reviewer.sh (+200) /
  local-watcher/test/pr_publish_claude_status_from_branch_test.sh (新規 622 行)
- Feature Flag Protocol: 本リポジトリ（root の CLAUDE.md）には `## Feature Flag Protocol` 節が
  存在せず、`opt-in` 宣言ではないため、flag 観点の細目チェックは **行わない**。通常の 3 カテゴリ
  判定のみを適用した。

## Verified Requirements

### Requirement 1: per-task 経路での claude-review status publish の発火

- 1.1 — `process_claude_review_status_catchup`（pr-reviewer.sh:1310 付近）が AND 二重 opt-in 配下で
  open PR scan → `pr_publish_claude_status_from_branch` → 既存 `pr_publish_claude_status`
  へ approve→success を委譲。テスト Section 7 Case 7.C で `gh api POST ... state=success` を検証。
- 1.2 — 同経路で reject→failure。テスト Section 4 で `state=failure` / `description=claude: reject`
  を検証。
- 1.3 — `pr_publish_claude_status`（既存）→ `pr_publish_commit_status` を経由するため、
  context 名・state 解決・description 長制限は #349 既存契約と一致（既存 `pr_publish_commit_status_test.sh`
  が回帰固定）。
- 1.4 — catch-up は `pr_fetch_candidate_prs`（`gh pr list --state open`）から駆動するため、
  publish 時点で PR の存在が構造的に保証される。テスト Section 7 Case 7.C / 7.D で確認。
- 1.5 — catch-up は watcher サイクル毎に最新の review-notes.md（origin/<head_ref>:<spec>/review-notes.md）
  を読み直すため、複数 task 連続完了時も最終 RESULT に収束。GitHub の latest-wins セマンティクスで担保。

### Requirement 2: 非 per-task 経路の挙動温存

- 2.1 / 2.2 / 2.3 — 既存 `publish_claude_review_status` 呼び出し 12 箇所は **一切変更されていない**
  （`git diff main..HEAD -- local-watcher/bin/issue-watcher.sh` の差分は新規 `process_claude_review_status_catchup`
  呼び出し追加のみ）。非 per-task 経路の publish タイミング・呼び出し回数・state・description・
  target_url は本修正前後で同一。

### Requirement 3: PR 未作成時 / parse 失敗時の安全な skip

- 3.1 — head_ref パターン外（feature/...）は silent skip（テスト Section 2）。
  spec-dir-not-found / ls-tree-failed も WARN + rc=0（テスト Section 5 Case 5.A / 5.D）。
- 3.2 — review-notes.md 不在（`git cat-file -e` 失敗）で WARN + skip（テスト Section 5 Case 5.B）。
- 3.3 — parse_review_result 失敗 / 不正 RESULT で WARN + skip（テスト Section 5 Case 5.C / 5.E）。
- 3.4 — 全 skip 経路で rc=0、呼び出し元の `|| pr_warn`（issue-watcher.sh:1510）でパイプライン継続。
- 3.5 — 全 WARN ログに `branch=` / `pr=#` / `reason=` 識別子を含む（テスト Section 5 で `assert_contains`）。

### Requirement 4: PR 作成後の最終 publish 整合（latest-wins）

- 4.1 / 4.2 — 上記 Req 1.1 / 1.2 と同経路。catch-up が PR head sha 宛てに `context=claude-review`
  state=success/failure を publish。
- 4.3 — 既存 `pr_publish_claude_status` → GitHub Commit Status API（latest-wins per (sha, context)）。
  本修正で API レイヤは変更なし。
- 4.4 — `pr_fetch_candidate_prs` が open PR のみを返すため、PR 未存在時は catch-up loop に
  入らず副作用ゼロ。

### Requirement 5: 後方互換と既定動作の温存

- 5.1 / 5.2 — `pr_publish_claude_status_from_branch` 冒頭と `process_claude_review_status_catchup`
  冒頭で `pr_status_check_enabled` 早期 return。テスト Section 1 Case 1.A〜1.C / Section 7 Case 7.A で
  AND OFF 時 gh / git / pr_fetch 呼び出しゼロを確認。
- 5.3 — `PR_REVIEWER_STATUS_CHECK_ENABLED` / `FULL_AUTO_ENABLED` の env var 名・正規化規則は
  既存 `pr_status_check_enabled` を流用するため未変更。
- 5.4 — 既存 env var 名 / ラベル名 / exit code / cron 文字列 / ログ出力先 / PR コメント挙動は無変更
  （差分は新規関数追加と processor 呼び出し 1 行追加のみ）。
- 5.5 — review-notes.md の commit / push / コメント投稿挙動は本修正範囲外（変更なし）。

### Requirement 6: 同期と配布の整合性

- 6.1 — `install.sh` の `copy_glob_to_homebin` が `modules/*.sh` を一括コピーする既存挙動を
  維持（修正対象外）。新規ファイル追加なし（既存 `pr-reviewer.sh` への追記のみ）。
- 6.2 — README.md「PR Reviewer Commit Status Publishing (#349)」節へ per-task catch-up 経路の
  説明を追記（+10 行）。
- 6.3 — catch-up は `process_pr_reviewer` 直後にサイクル毎発火する設計のため、配布後の watcher
  で次サイクルで結果整合的に publish される。

### Non-Functional Requirements

- NFR 1.1 / 1.2 / 1.3 — AND OFF 時の外部観測挙動温存（Section 1 / Case 7.A）。`pr_status_check_enabled`
  / `pr_publish_claude_status` / `parse_review_result` のシグネチャは無変更（流用のみ）。
- NFR 2.1 / 2.2 — `bash -n` クリーン（issue-watcher.sh / pr-reviewer.sh / 新規テスト）、
  `shellcheck` クリーン（reviewer 環境で再実行確認、警告ゼロ）。
- NFR 3.1 / 3.2 / 3.3 — `pr_log` で成功 1 行 / skip 各経路で `pr_warn` 1 行、suppression は既存
  `pr_publish_commit_status` の cycle あたり 1 行制限に委ねる（重複ログ抑止）。
- NFR 4.1 / 4.2 / 4.3 — `local-watcher/test/pr_publish_claude_status_from_branch_test.sh` を
  単一スクリプトとして追加。Section 6 grep アサーション 4 件で publish 呼び出し位置の構造的保証
  （`pr_fetch_candidate_prs` を入力に取る / `pr_status_check_enabled` で gate / `PR_REVIEWER_ENABLED`
  非依存）を回帰固定。

## 追加検証

- Reviewer 環境で `bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh` を再実行
  → `PASS=52, FAIL=0`。
- `bash -n` / `shellcheck` を変更 3 ファイルへ再実行 → クリーン（出力ゼロ）。
- `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules`
  → 差分なし（root↔repo-template 同期維持）。
- 境界確認: 差分ファイルは `local-watcher/bin/issue-watcher.sh` / `local-watcher/bin/modules/pr-reviewer.sh`
  / `local-watcher/test/` / `README.md` / `docs/specs/374-.../` の範囲内であり、impl-notes.md
  記載の変更範囲と一致。tasks.md は本 Issue では生成されていないが、これは Architect 不在
  （Triage が `needs_architect: false` 相当と判断）に伴うものであり、impl-notes.md の
  「変更ファイル一覧」と「AC traceability」が境界の正本として機能している。本 reviewer は
  3 カテゴリのみで判定するため、tasks.md 不在は reject 理由としない（boundary 違反は
  検出していない）。

## Findings

なし

## Summary

per-task ループ運用での `claude-review` commit status 不発（Issue #374）に対し、独立 catch-up
processor (`process_claude_review_status_catchup`) を `pr_fetch_candidate_prs` を入力源として
追加する方針で、Req 1.1〜6.3 / NFR 1.1〜4.3 のすべてに対応する実装とテスト（52 件 PASS）が
揃っている。AND 二重 opt-in OFF 時は外部副作用ゼロ、既存 `publish_claude_review_status`
呼び出し 12 箇所は無変更、root↔repo-template / bash -n / shellcheck もクリーン。3 カテゴリ
（AC 未カバー / missing test / boundary 逸脱）のいずれにも該当する問題は検出されなかった。

RESULT: approve
