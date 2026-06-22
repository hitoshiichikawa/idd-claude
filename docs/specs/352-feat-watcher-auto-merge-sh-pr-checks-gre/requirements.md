# Requirements Document

## Introduction

idd-claude の auto-dev パイプラインでは、watcher が Issue → 実装 PR の作成・更新までを自動化
しているが、PR の最終 merge には **人手で approve + merge ボタン押下** が必要な状態が残っている。
本要件では、実装 PR（head が `^claude/issue-.*-impl` パターン、`ready-for-review` ラベル、draft で
ない、`mergeable=MERGEABLE`）に対して **GitHub ネイティブの auto-merge を有効化**する Auto-Merge
Processor を新規 module（`modules/auto-merge.sh`、関数 prefix `am_`）として導入し、最終 merge
クリックを撤廃する。実 merge は GitHub 側で **必須 status checks（CI + `codex-review` +
`claude-review`）が全 green** に到達したタイミングで実行される設計であり、watcher は直接 branch を
merge しない。新機能は `AUTO_MERGE_ENABLED`（既定 `false`）と `FULL_AUTO_ENABLED=true`（#348）の
**AND 二重 opt-in** 配下に置き、いずれかが無効なら一切の auto-merge 有効化操作を行わず、従来の
人間 merge 運用と完全に等価に振る舞う。

## Requirements

### Requirement 1: opt-in gate（AND 二重 opt-in と既定無効）

**Objective:** As an idd-claude operator, I want the auto-merge processor to be strictly opt-in
under both its own gate and the global kill switch, so that 既定では従来の人間 merge 運用と完全に
等価に振る舞い、不具合時に 1 つの env を倒すだけで停止できる

#### Acceptance Criteria

1. The watcher Config block shall declare `AUTO_MERGE_ENABLED` with a default value of `false`
2. When `AUTO_MERGE_ENABLED` is set to the exact string `true` and `FULL_AUTO_ENABLED` is enabled, the Auto-Merge Processor shall evaluate target PRs according to Requirement 2 and Requirement 3
3. If `AUTO_MERGE_ENABLED` is unset, empty, `false`, `0`, `True`, `TRUE`, `1`, or any other value other than the exact string `true`, the Auto-Merge Processor shall not invoke `gh pr merge` against any PR
4. If `FULL_AUTO_ENABLED` is disabled, the Auto-Merge Processor shall not invoke `gh pr merge` against any PR regardless of `AUTO_MERGE_ENABLED`
5. While the AND gate is disabled, the Auto-Merge Processor shall produce external side effects (gh / git API 呼び出し / ラベル遷移 / コメント投稿) that are observably identical to the pre-introduction state

### Requirement 2: 対象 PR の選定条件

**Objective:** As an idd-claude operator, I want the processor to only target implementation PRs that match a well-defined shape, so that 人間が手書きした PR / 設計 PR / 他用途のブランチを誤って auto-merge 化しない

#### Acceptance Criteria

1. The Auto-Merge Processor shall select only open PRs whose head branch name matches the pattern `^claude/issue-.*-impl`
2. The Auto-Merge Processor shall select only PRs that carry the `ready-for-review` label at the time of evaluation
3. The Auto-Merge Processor shall exclude PRs whose `isDraft` is `true`
4. The Auto-Merge Processor shall select only PRs whose `mergeable` field equals `MERGEABLE` at the time of evaluation
5. If a PR's `mergeable` field equals `CONFLICTING`, the Auto-Merge Processor shall not invoke `gh pr merge` against that PR（既存 merge-queue / auto-rebase 経路に委譲する）
6. If a PR's `mergeable` field equals `UNKNOWN` or has not been computed yet, the Auto-Merge Processor shall not invoke `gh pr merge` against that PR in the current cycle（次サイクル以降に再評価する）

### Requirement 3: auto-merge 有効化（squash + branch 削除）

**Objective:** As an idd-claude operator, I want the processor to enable GitHub's native auto-merge in squash mode with branch deletion, so that 必須 checks 全 green 達成時に GitHub 側で自動的に squash merge され、ブランチ後始末も含めて手作業が消える

#### Acceptance Criteria

1. When a PR satisfies all conditions in Requirement 2 and the AND gate is enabled, the Auto-Merge Processor shall invoke `gh pr merge --auto --squash --delete-branch` against that PR
2. The Auto-Merge Processor shall not invoke any direct branch merge / push / `git merge` against the base branch（実 merge は GitHub 側に委ねる）
3. While GitHub's required status checks for the PR are not all `success`, the Auto-Merge Processor shall rely on GitHub's auto-merge state machine to defer the actual merge（watcher 側で待ち合わせや polling を行わない）
4. When GitHub completes the auto-merge after the required status checks reach green, the head branch shall be deleted automatically as a side effect of the `--delete-branch` flag passed at enable time

### Requirement 4: 既存経路との境界（CONFLICTING / 失敗系の非干渉）

**Objective:** As an idd-claude operator, I want the auto-merge processor to coexist with existing merge-queue / auto-rebase / failed-recovery paths without overlap, so that 既存の conflict 解決経路と auto-merge 経路が同じ PR を奪い合わない

#### Acceptance Criteria

1. The Auto-Merge Processor shall not add, remove, or rename the `needs-rebase` label on any PR
2. The Auto-Merge Processor shall exclude PRs that carry the `claude-failed` label at the time of evaluation
3. The Auto-Merge Processor shall exclude PRs that carry the `needs-decisions` label at the time of evaluation
4. The Auto-Merge Processor shall not dismiss existing approving reviews on any PR
5. While a PR already has auto-merge enabled in a prior cycle, the Auto-Merge Processor shall not produce an additional state-changing API call against that PR in the current cycle（重複 enable を抑止する）

### Requirement 5: 異常系（API 失敗時のパイプライン継続）

**Objective:** As an idd-claude operator, I want auto-merge enable failures to be observable but non-blocking, so that GitHub API 障害が watcher 本体のパイプライン（Triage / PM / Architect / Developer / Reviewer / PjM）を停止させない

#### Acceptance Criteria

1. If the `gh pr merge --auto` call fails with an HTTP / API error, the Auto-Merge Processor shall emit a warn-level log line that identifies the PR number, head sha, head branch name, and the error category
2. If the `gh pr merge --auto` call fails with a network / transport error, the Auto-Merge Processor shall emit a warn-level log line that identifies the PR number, head branch name, and the transport error category
3. When an auto-merge enable call fails, the watcher shall continue processing the remainder of the current cycle without aborting the pipeline
4. The Auto-Merge Processor shall not silently swallow auto-merge enable failures（exit code 0 で済ませず log に痕跡を残す）
5. If a PR is rejected by GitHub for reasons such as branch protection misconfiguration or auto-merge not being permitted at the repository level, the Auto-Merge Processor shall emit a warn-level log line that distinguishes this case from transient API errors

### Requirement 6: gate off / 非対象 PR での等価性（後方互換）

**Objective:** As an idd-claude operator, I want the introduction of this feature to have zero observable effect when disabled or out of scope, so that 既存運用 / 既存 consumer repo に副作用を一切与えずに段階導入できる

#### Acceptance Criteria

1. While the AND gate is disabled, the Auto-Merge Processor shall not call `gh pr merge` against any PR
2. While the AND gate is disabled, the watcher shall not change existing label transitions, comment postings, exit codes, or log lines emitted by other processors（merge-queue / auto-rebase / pr-iteration / pr-reviewer / その他）
3. The Auto-Merge Processor shall not touch PRs whose head branch does not match `^claude/issue-.*-impl`（人間が手書きした PR / 設計 PR は対象外）
4. The Auto-Merge Processor shall not gate or alter the existing merge-queue / auto-rebase / pr-iteration / pr-reviewer processor behaviors

### Requirement 7: 観測可能性

**Objective:** As an idd-claude operator, I want to verify whether auto-merge was enabled or suppressed in a given cycle, so that 「なぜこの PR が merge されない / された」を運用ログから判別できる

#### Acceptance Criteria

1. When the Auto-Merge Processor successfully enables auto-merge on a PR, the watcher shall emit a log line that identifies the PR number, head sha, head branch name, and the enable action（例: `auto-merge enabled (squash, delete-branch)`）
2. While `AUTO_MERGE_ENABLED` is disabled, the Auto-Merge Processor shall emit at most one informational log line per cycle that identifies the gate as the suppression cause（既存ログ量を膨張させない）
3. While `FULL_AUTO_ENABLED` is disabled, the Auto-Merge Processor shall rely on the existing kill switch suppression log（#348 NFR 4.1）to identify the suppression cause and shall not duplicate that log
4. The watcher shall include the resolved `AUTO_MERGE_ENABLED` value in cycle startup output so that 運用者が現在の auto-merge 有効状態を確認できる

## Non-Functional Requirements

### NFR 1: セキュリティ（未信頼入力の取り扱い）

1. When passing PR head sha or PR number to `jq`, the Auto-Merge Processor shall use `--arg` / `--argjson`（フィルタ文字列への inline 展開を禁止）
2. When passing untrusted values (PR number, head branch name) to `gh` subcommands, the Auto-Merge Processor shall use `--` to terminate option parsing where applicable
3. The Auto-Merge Processor shall validate the PR number against `^[0-9]+$` before using it in any URL, path, or log message
4. The Auto-Merge Processor shall validate the head branch name against the configured head pattern before passing it to any external command

### NFR 2: 後方互換性

1. While `AUTO_MERGE_ENABLED` is unset, the watcher shall produce external side effects (gh / git API 呼び出し / ラベル遷移 / コミット / push / コメント投稿) that are observably identical to the pre-introduction state
2. The watcher shall not rename, repurpose, or remove existing env var names (including `FULL_AUTO_ENABLED` / `MERGE_QUEUE_ENABLED` / `MERGE_QUEUE_HEAD_PATTERN` / `AUTO_REBASE_MODE` / `PR_REVIEWER_*`), label names (`ready-for-review` / `needs-rebase` / `claude-failed` / `needs-decisions`), exit code semantics, or cron registration strings as part of this change
3. The watcher shall not change the existing merge-queue / auto-rebase / pr-iteration / pr-reviewer function contracts as part of this change

### NFR 3: 性能 / API 呼び出し量

1. The Auto-Merge Processor shall invoke at most 1 `gh pr merge --auto` API call per PR per cycle
2. The Auto-Merge Processor shall not introduce additional polling loops, background processes, or sleeps waiting for required status checks（実 merge 完了待ちは GitHub 側に委ねる）

### NFR 4: ドキュメント / 同期

1. The README shall list `AUTO_MERGE_ENABLED` in the optional feature section with its default value, AND-semantics note (with `FULL_AUTO_ENABLED`), target PR conditions, and pre-introduction equivalence guarantee
2. The README shall include guidance on how to configure repository-level auto-merge permission and required status checks (`codex-review` / `claude-review` + CI) as prerequisites for the auto-merge to actually fire
3. The repository shall keep `local-watcher/` and `repo-template/` byte-equivalent for files under shared dual-management scope (`.claude/agents`, `.claude/rules`, workflow, labels script, modules) after the change

### NFR 5: 静的解析 / テスト

1. The watcher script and the new `auto-merge.sh` module shall pass `shellcheck` and `bash -n` after the change is applied
2. The repository shall include unit tests at `local-watcher/test/auto-merge_test.sh` that stub `gh` and verify the decision branches: (a) all conditions satisfied → `gh pr merge --auto --squash --delete-branch` is invoked exactly once, (b) `mergeable=CONFLICTING` → no `gh pr merge` invocation, (c) draft PR → no invocation, (d) head pattern mismatch → no invocation, (e) AND gate disabled → no invocation, (f) `gh pr merge` failure → warn log emitted and pipeline continues

### NFR 6: 配布 / 二重管理

1. The `install.sh` shall distribute `local-watcher/bin/modules/auto-merge.sh` to `$HOME/bin/modules/` together with the other modules under the existing module distribution path
2. The watcher shall load `auto-merge.sh` via the existing `REQUIRED_MODULES` loader so that the module's function definitions are available before any Auto-Merge Processor entry point is evaluated

## Out of Scope

- 設計 PR（`docs/specs/<N>-<slug>/design.md` の人間レビュー / 確定）に対する auto-merge 適用（Issue 04 範囲）
- CI 失敗時の自動修復・再試行（Issue 05 範囲）
- `mergeable=CONFLICTING` PR の conflict 解決（既存 merge-queue / auto-rebase 経路に委譲）
- branch protection 設定そのもの（required status checks の必須化、auto-merge 許可 toggle 等は Issue 00 範囲。運用者が repo 側で事前設定する前提）
- `codex-review` / `claude-review` の commit status publish 自体（#349 で導入済み）
- 既存 opt-in 機能（`MERGE_QUEUE_ENABLED` / `AUTO_REBASE_MODE` / `PR_REVIEWER_*` / `FULL_AUTO_ENABLED` 等）の値・名前・既定値の変更
- merge 方式の選択肢追加（rebase / merge commit など。本要件では squash 固定）
- 既に auto-merge が enable 済みの PR に対する disable / 取り下げ操作
- `AUTO_MERGE_ENABLED` 設定変更の hot reload（cron 次サイクル以降に反映される運用で十分）

## Open Questions

- なし（Issue 本文の AC は本要件で網羅。head パターン文字列の厳密形（`^claude/issue-.*-impl` か、`^claude/issue-[0-9]+-impl-` 相当の厳密版か）は実装時に既存 `MERGE_QUEUE_HEAD_PATTERN` / `PR_ITERATION_HEAD_PATTERN` の規約と整合させる方針とし、design.md で確定する。`mergeable=UNKNOWN` 時のリトライ間隔は cron サイクルに委ねるため別途待ち設定は導入しない）

## 関連

- Depends on: #348 #349
- Parent: #13
- Related: D-03, D-04, D-06, D-07
