# Requirements Document

## Introduction

idd-claude の PR レビューパイプラインでは、codex（または antigravity）による自動レビューと、
Claude Reviewer による独立レビュー（`docs/specs/<N>-<slug>/review-notes.md` の最終 `RESULT:`
行）の **二重ゲート**で PR の合否を判定している。現状これらの結果は **PR コメントとしてのみ**
publish されており、GitHub の required status checks による auto-merge ゲート（D-03）に組み込めない。
本要件では、両レビューの合否を **GitHub Commit Status API**（`POST /repos/{owner}/{repo}/statuses/{sha}`）
経由で **`codex-review` / `claude-review`** という安定 context 名の commit status として publish し、
auto-merge を required status checks で成立させる前提を整える（D-04 / D-05 補足 / D-07）。
本機能は `PR_REVIEWER_STATUS_CHECK_ENABLED`（既定 `false`）と `FULL_AUTO_ENABLED=true` の
**AND 二重 opt-in** 配下に置き、いずれかが無効なら一切の status publish を行わず、従来の
コメントのみ挙動と完全に等価に振る舞う（#348 で導入済みの kill switch を踏襲）。

## Requirements

### Requirement 1: opt-in gate（AND 二重 opt-in と既定無効）

**Objective:** As an idd-claude operator, I want commit status publishing to be strictly opt-in under both a feature gate and the global kill switch, so that 既定では従来挙動（コメントのみ）と完全に等価に振る舞い、不具合時に 1 つの env を倒すだけで停止できる

#### Acceptance Criteria

1. The watcher Config block shall declare `PR_REVIEWER_STATUS_CHECK_ENABLED` with a default value of `false`
2. When `PR_REVIEWER_STATUS_CHECK_ENABLED` is set to the exact string `true` and `FULL_AUTO_ENABLED` is enabled, the PR Reviewer Processor shall publish commit statuses according to Requirement 2 and Requirement 3
3. If `PR_REVIEWER_STATUS_CHECK_ENABLED` is unset, empty, `false`, `0`, `True`, `TRUE`, `1`, or any other value other than the exact string `true`, the PR Reviewer Processor shall not invoke the Commit Status API
4. If `FULL_AUTO_ENABLED` is disabled, the PR Reviewer Processor shall not invoke the Commit Status API regardless of `PR_REVIEWER_STATUS_CHECK_ENABLED`
5. While the AND gate is disabled, the PR Reviewer Processor shall continue to post review comments to the PR in a manner that is observably identical to the pre-introduction state

### Requirement 2: codex レビュー結果の commit status publish

**Objective:** As an idd-claude operator, I want codex review verdicts to surface as a stable-named commit status, so that branch protection の required status checks 上で `codex-review` を必須化して auto-merge を成立させられる

#### Acceptance Criteria

1. When the codex review for a PR completes with `VERDICT: approve` and the AND gate is enabled, the PR Reviewer Processor shall publish a commit status with context `codex-review` and state `success` against the PR head sha
2. When the codex review for a PR completes with `VERDICT: needs-iteration` and the AND gate is enabled, the PR Reviewer Processor shall publish a commit status with context `codex-review` and state `failure` against the PR head sha
3. The PR Reviewer Processor shall set the commit status `description` to a short human-readable string that identifies the verdict（例: `codex: approve` / `codex: needs-iteration`、72 文字以内）
4. The PR Reviewer Processor shall set the commit status `target_url` to a URL that points to the review comment（投稿された review コメントの permalink）, or to the PR URL when コメント permalink が取得できない場合
5. When the antigravity tool is used instead of codex and produces a VERDICT, the PR Reviewer Processor shall publish the same `codex-review` context（tool 切替で context 名は変更しない。安定識別子としての `codex-review` を共有する）

### Requirement 3: Claude Reviewer 結果の commit status publish

**Objective:** As an idd-claude operator, I want Claude Reviewer's final RESULT to surface as a stable-named commit status, so that 二重ゲート（codex + claude）のうち claude 側も required status checks に組み込める

#### Acceptance Criteria

1. When `review-notes.md` is committed with a final line `RESULT: approve` and the AND gate is enabled, the watcher shall publish a commit status with context `claude-review` and state `success` against the PR head sha at the time of the commit
2. When `review-notes.md` is committed with a final line `RESULT: reject` and the AND gate is enabled, the watcher shall publish a commit status with context `claude-review` and state `failure` against the PR head sha at the time of the commit
3. The watcher shall set the commit status `description` to a short human-readable string that identifies the result（例: `claude: approve` / `claude: reject`、72 文字以内）
4. The watcher shall set the commit status `target_url` to a URL that points to the committed `review-notes.md` on the PR head（blob URL）, or to the PR URL when blob URL が取得できない場合
5. If `review-notes.md` cannot be parsed by the existing `parse_review_result` contract, the watcher shall not publish a `claude-review` status for that cycle and shall emit a warn-level log identifying the parse failure

### Requirement 4: head sha 更新時の挙動と古い結果の扱い

**Objective:** As an idd-claude operator, I want statuses to track the current PR head sha and not leak stale results, so that auto-merge ゲートが古いレビュー結果に基づいて成立しないことを保証できる

#### Acceptance Criteria

1. When a PR head sha changes between watcher cycles and a new review verdict / RESULT is produced, the PR Reviewer Processor shall publish the new status against the new head sha
2. The PR Reviewer Processor shall not publish a status against, or attempt to mutate, a previous head sha after a new head sha has been observed
3. When a new status is published with the same context name against the same head sha as a previously published status, the watcher shall rely on the GitHub Commit Status API's "latest wins per (sha, context)" semantics（同一 (sha, context) への再 POST で最新値に上書きされる動作）to surface the latest verdict

### Requirement 5: 異常系（publish 失敗時のパイプライン継続）

**Objective:** As an idd-claude operator, I want status publish failures to be observable but non-blocking, so that GitHub API 障害が watcher 本体のパイプライン（Triage / PM / Architect / Developer / Reviewer / PjM）を停止させない

#### Acceptance Criteria

1. If the Commit Status API call fails with an HTTP error response, the PR Reviewer Processor shall emit a warn-level log line that identifies the PR number, head sha, context name, intended state, and HTTP status code
2. If the Commit Status API call fails with a network / transport error, the PR Reviewer Processor shall emit a warn-level log line that identifies the PR number, head sha, context name, intended state, and the transport error category
3. When a status publish call fails, the watcher shall continue processing the remainder of the current cycle without aborting the pipeline
4. The PR Reviewer Processor shall not silently swallow status publish failures（exit code 0 で済ませず log に痕跡を残す）
5. When a status publish call fails, the watcher shall continue to post the review comment（or have already posted it）so that 運用者は status が出ない場合でもコメントから verdict を確認できる

### Requirement 6: gate off 等価性（後方互換）

**Objective:** As an idd-claude operator, I want behavior with the gate disabled to be observably identical to the pre-introduction state, so that 既存運用 / 既存 consumer repo に副作用を一切与えずに段階導入できる

#### Acceptance Criteria

1. While the AND gate is disabled, the PR Reviewer Processor shall not call `gh api -X POST repos/<owner>/<repo>/statuses/<sha>` for either `codex-review` or `claude-review`
2. While the AND gate is disabled, the PR Reviewer Processor shall produce review comments、ラベル遷移、ログ出力, and exit codes that are observably identical to the pre-introduction state
3. The watcher shall not gate the existing PR Reviewer Processor (#261) や existing review comment / `needs-iteration` ラベル付与 behind `PR_REVIEWER_STATUS_CHECK_ENABLED`（新 gate はあくまで commit status publish の追加挙動の opt-in に限定する）

### Requirement 7: 観測可能性

**Objective:** As an idd-claude operator, I want to verify whether status publishing was attempted or suppressed in a given cycle, so that 「status が出ない理由」を運用ログから判別できる

#### Acceptance Criteria

1. When a commit status is successfully published, the PR Reviewer Processor shall emit a log line that identifies the PR number, head sha, context name (`codex-review` or `claude-review`), and the published state (`success` or `failure`)
2. While `PR_REVIEWER_STATUS_CHECK_ENABLED` is disabled, the PR Reviewer Processor shall emit at most one informational log line per cycle that identifies the gate as the suppression cause（既存ログ量を膨張させない）
3. While `FULL_AUTO_ENABLED` is disabled, the PR Reviewer Processor shall rely on the existing kill switch suppression log（#348 NFR 4.1）to identify the suppression cause and shall not duplicate that log

## Non-Functional Requirements

### NFR 1: セキュリティ（未信頼入力の取り扱い）

1. When passing untrusted values (PR head sha, PR number, review text excerpt) to `jq`, the PR Reviewer Processor shall use `--arg` / `--argjson`（フィルタ文字列への inline 展開を禁止）
2. When passing untrusted values to `gh` / `git` subcommands, the PR Reviewer Processor shall use `--` to terminate option parsing where applicable
3. The PR Reviewer Processor shall validate the head sha against `^[0-9a-f]{40}$` before using it in the Commit Status API URL path
4. The PR Reviewer Processor shall validate the PR number against `^[0-9]+$` before using it in any URL, path, or log message

### NFR 2: 性能 / API 呼び出し量

1. The PR Reviewer Processor shall publish at most 1 commit status per (PR head sha, context name) per cycle（同一 cycle 内で同じ (sha, context) に複数回 POST しない）
2. The PR Reviewer Processor shall not introduce additional polling loops or background processes; status publish はレビュー完了 / `review-notes.md` commit と同一の処理パスから 1 回呼ばれる

### NFR 3: 後方互換性

1. While `PR_REVIEWER_STATUS_CHECK_ENABLED` is unset, the watcher shall produce external side effects (gh / git API 呼び出し / ラベル遷移 / コミット / push / コメント投稿) that are observably identical to the pre-introduction state
2. The watcher shall not rename, repurpose, or remove existing env var names (including `PR_REVIEWER_ENABLED` / `PR_REVIEWER_TOOL` / `PR_REVIEWER_CODEX_ENABLED` / `PR_REVIEWER_ANTIGRAVITY_ENABLED` / `FULL_AUTO_ENABLED`), label names, exit code semantics, or context naming conventions as part of this change
3. The watcher shall not change the existing `pr_post_review_comment` / `pr_detect_iteration_keyword` / `parse_review_result` function contracts as part of this change

### NFR 4: ドキュメント / 同期

1. The README shall list `PR_REVIEWER_STATUS_CHECK_ENABLED` in the optional feature section with its default value, AND-semantics note (with `FULL_AUTO_ENABLED`), context names (`codex-review` / `claude-review`), and pre-introduction equivalence guarantee
2. The repository shall keep `local-watcher/` and `repo-template/` byte-equivalent for files under shared dual-management scope (`.claude/agents`, `.claude/rules`, workflow, labels script, modules) after the change
3. The README shall include guidance on how to enable `codex-review` / `claude-review` as required status checks in GitHub branch protection（運用者が auto-merge ゲートを成立させる手順）

### NFR 5: 静的解析 / テスト

1. The watcher script and all touched modules shall pass `shellcheck` and `bash -n` after the change is applied
2. The repository shall include unit tests that stub the Commit Status API call and verify the request payload（context / state / description / target_url）for both `codex-review` and `claude-review` paths（success / failure / gate off / publish failure の 4 系統）

## Out of Scope

- リッチな Check Run UI（行注釈・annotation 等）— GitHub App / Check Runs API が必要なため将来拡張
- branch protection 上で `codex-review` / `claude-review` を required status checks として必須化する設定そのもの（人間の repo 設定作業 / Issue 00 系の領分）
- 新しい review tool の追加（codex / antigravity 以外）や Claude Reviewer の判定ロジック変更
- `PR_REVIEWER_ENABLED` / `PR_REVIEWER_TOOL` 等の既存 opt-in env の値・名前・既定値の変更
- `FULL_AUTO_ENABLED` 自体の挙動変更（#348 で確定済み）
- bot account / GitHub App 経由で status を publish する切替（本要件は既存 watcher token で完結する）
- 古い head sha に対する status の事後クリア / 削除（GitHub の latest-wins-per-(sha,context) 仕様に依存し、明示的な削除 API は呼ばない）
- `PR_REVIEWER_STATUS_CHECK_ENABLED` 設定変更の hot reload（cron 次サイクル以降に反映される運用で十分）

## Open Questions

- なし（Issue 本文の AC は本要件で網羅。`description` 文言・`target_url` の確定値は requirements 内で明示済み。実装時に微調整が必要となった場合は impl-notes 経由で人間にエスカレーションする運用とする）

## 関連

- Depends on: #348
- Related: D-03, D-04, D-05 補足, D-07
- Parent: #13
