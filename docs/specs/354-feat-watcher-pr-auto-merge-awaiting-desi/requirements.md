# Requirements Document

## Introduction

idd-claude の auto-dev パイプラインでは、PM → Architect → PjM の流れで生成された **設計 PR**
（head が `^claude/issue-.*-design` パターン、対応 Issue に `awaiting-design-review` ラベル付与）
の最終 merge に **人手の approve + merge ボタン押下** が残っている。実装 PR 側は #352 で
`AUTO_MERGE_ENABLED` 配下の Auto-Merge Processor により squash auto-merge 化したが、設計 PR は
スコープ外として除外されていた。本要件では、設計 PR に対して **GitHub ネイティブの auto-merge**
を `gh pr merge --auto --squash --delete-branch` 経路で有効化する Auto-Merge Processor を導入する。
実 merge は GitHub 側で **必須 status checks 全 green** に到達したタイミングで実行され、watcher
は直接 branch を merge しない。設計レビュー結果（codex / Claude Reviewer）は #349 の仕組みを
**設計 PR 経路にも適用**し、必須 status checks として branch protection 上で成立させる。新機能は
`AUTO_MERGE_DESIGN_ENABLED`（既定 `false`）と `FULL_AUTO_ENABLED=true`（#348）の **AND 二重 opt-in**
配下に置き、いずれかが無効なら一切の auto-merge 有効化操作を行わず、従来の人間 merge 運用と完全に
等価に振る舞う。既存の Design Review Release Processor（`DESIGN_REVIEW_RELEASE_ENABLED`、merge 検知で
`awaiting-design-review` 自動除去）は本機能と独立に共存し、auto-merge 完了後の Issue ラベル後始末を
担う。

## Requirements

### Requirement 1: opt-in gate（AND 二重 opt-in と既定無効）

**Objective:** As an idd-claude operator, I want the design auto-merge processor to be strictly opt-in under both its own gate and the global kill switch, so that 既定では従来の人間 merge 運用と完全に等価に振る舞い、不具合時に 1 つの env を倒すだけで停止できる

#### Acceptance Criteria

1. The watcher Config block shall declare `AUTO_MERGE_DESIGN_ENABLED` with a default value of `false`
2. When `AUTO_MERGE_DESIGN_ENABLED` is set to the exact string `true` and `FULL_AUTO_ENABLED` is enabled, the Design Auto-Merge Processor shall evaluate target PRs according to Requirement 2 and Requirement 3
3. If `AUTO_MERGE_DESIGN_ENABLED` is unset, empty, `false`, `0`, `True`, `TRUE`, `1`, or any other value other than the exact string `true`, the Design Auto-Merge Processor shall not invoke `gh pr merge` against any PR
4. If `FULL_AUTO_ENABLED` is disabled, the Design Auto-Merge Processor shall not invoke `gh pr merge` against any PR regardless of `AUTO_MERGE_DESIGN_ENABLED`
5. While the AND gate is disabled, the Design Auto-Merge Processor shall produce external side effects (gh / git API 呼び出し / ラベル遷移 / コメント投稿) that are observably identical to the pre-introduction state

### Requirement 2: 対象 PR の選定条件（設計 PR の境界）

**Objective:** As an idd-claude operator, I want the processor to only target design PRs that match a well-defined shape, so that 人間が手書きした PR / 実装 PR / 他用途のブランチを誤って auto-merge 化しない

#### Acceptance Criteria

1. The Design Auto-Merge Processor shall select only open PRs whose head branch name matches the pattern `^claude/issue-.*-design`
2. The Design Auto-Merge Processor shall exclude PRs whose `isDraft` is `true`
3. The Design Auto-Merge Processor shall select only PRs whose `mergeable` field equals `MERGEABLE` at the time of evaluation
4. If a PR's `mergeable` field equals `CONFLICTING`, the Design Auto-Merge Processor shall not invoke `gh pr merge` against that PR
5. If a PR's `mergeable` field equals `UNKNOWN` or has not been computed yet, the Design Auto-Merge Processor shall not invoke `gh pr merge` against that PR in the current cycle（次サイクル以降に再評価する）
6. The Design Auto-Merge Processor shall not invoke `gh pr merge` against any PR whose head branch matches the implementation PR pattern `^claude/issue-.*-impl`（#352 経路との非干渉）

### Requirement 3: auto-merge 有効化（squash + branch 削除）

**Objective:** As an idd-claude operator, I want the processor to enable GitHub's native auto-merge in squash mode with branch deletion for design PRs, so that 必須 status checks 全 green 達成時に GitHub 側で自動的に squash merge され、設計 PR 専用 branch の後始末も含めて手作業が消える

#### Acceptance Criteria

1. When a PR satisfies all conditions in Requirement 2 and the AND gate is enabled, the Design Auto-Merge Processor shall invoke `gh pr merge --auto --squash --delete-branch` against that PR
2. The Design Auto-Merge Processor shall not invoke any direct branch merge / push / `git merge` against the base branch（実 merge は GitHub 側に委ねる）
3. While GitHub's required status checks for the PR are not all `success`, the Design Auto-Merge Processor shall rely on GitHub's auto-merge state machine to defer the actual merge（watcher 側で待ち合わせや polling を行わない）
4. When GitHub completes the auto-merge after the required status checks reach green, the head branch shall be deleted automatically as a side effect of the `--delete-branch` flag passed at enable time

### Requirement 4: 設計レビュー結果の必須 status checks 化

**Objective:** As an idd-claude operator, I want design review verdicts (codex / Claude Reviewer) to surface as GitHub commit statuses against design PR head shas, so that auto-merge ゲートが design 経路でも required status checks で成立し、設計 reject では merge されない

#### Acceptance Criteria

1. When a design PR receives a codex / antigravity review verdict and the AND gate is enabled, the PR Reviewer Processor shall publish a commit status with a stable context name against the design PR head sha（context 命名は #349 で定義済みの `codex-review` を共有または `codex-review` と等価な安定識別子を採用する。本要件は publish 経路が design PR にも適用されることを規定する）
2. When a design PR receives a Claude Reviewer `RESULT` from `review-notes.md` and the AND gate is enabled, the PR Reviewer Processor shall publish a commit status with a stable context name against the design PR head sha（context 命名は #349 で定義済みの `claude-review` を共有または `claude-review` と等価な安定識別子を採用する）
3. When a design review verdict is `approve`, the published commit status state shall be `success`
4. When a design review verdict is `needs-iteration` (codex) or `reject` (Claude Reviewer), the published commit status state shall be `failure`
5. If a design PR head sha changes between watcher cycles, the PR Reviewer Processor shall publish the new verdict's commit status against the new head sha and shall not mutate prior shas（#349 Req 4 を design 経路にも適用する）
6. While the AND gate is disabled, the PR Reviewer Processor shall not publish any commit status for design PRs

### Requirement 5: 既存 Design Review Release Processor との共存

**Objective:** As an idd-claude operator, I want the existing Design Review Release Processor (auto-removal of `awaiting-design-review` after merge) to keep working unchanged, so that auto-merge 完了後の Issue ラベル後始末経路を破壊せずに自動 merge を導入できる

#### Acceptance Criteria

1. The Design Auto-Merge Processor shall not add, remove, or rename the `awaiting-design-review` label on any Issue or PR
2. The Design Auto-Merge Processor shall not invoke the Design Review Release Processor's entry point directly（両 processor は同一サイクル内で独立に評価される）
3. When the Design Auto-Merge Processor has enabled auto-merge on a design PR and GitHub later completes the merge, the existing Design Review Release Processor shall detect the merged design PR on a subsequent cycle and remove the `awaiting-design-review` label from the linked Issue per its pre-existing behavior（#112 / #80 の既存仕様）
4. The Design Auto-Merge Processor shall not gate or alter `DESIGN_REVIEW_RELEASE_ENABLED` behavior

### Requirement 6: 既存経路との境界（実装 PR / conflict / failed の非干渉）

**Objective:** As an idd-claude operator, I want the design auto-merge processor to coexist with the implementation auto-merge processor (#352) and existing recovery paths without overlap, so that 既存の auto-merge / conflict 解決経路が同じ PR を奪い合わない

#### Acceptance Criteria

1. The Design Auto-Merge Processor shall not add, remove, or rename the `needs-rebase` label on any PR
2. The Design Auto-Merge Processor shall exclude PRs that carry the `claude-failed` label at the time of evaluation
3. The Design Auto-Merge Processor shall exclude PRs that carry the `needs-decisions` label at the time of evaluation
4. The Design Auto-Merge Processor shall exclude PRs that carry the `needs-iteration` label at the time of evaluation（設計 PR iteration 中は merge 有効化しない）
5. The Design Auto-Merge Processor shall not dismiss existing approving reviews on any PR
6. While a design PR already has auto-merge enabled in a prior cycle, the Design Auto-Merge Processor shall not produce an additional state-changing API call against that PR in the current cycle（重複 enable を抑止する）
7. The Design Auto-Merge Processor shall not gate or alter the existing Auto-Merge Processor (#352) behavior for implementation PRs

### Requirement 7: 異常系（API 失敗時のパイプライン継続）

**Objective:** As an idd-claude operator, I want auto-merge enable failures on design PRs to be observable but non-blocking, so that GitHub API 障害が watcher 本体のパイプライン（Triage / PM / Architect / Developer / Reviewer / PjM）を停止させない

#### Acceptance Criteria

1. If the `gh pr merge --auto` call fails with an HTTP / API error, the Design Auto-Merge Processor shall emit a warn-level log line that identifies the PR number, head sha, head branch name, and the error category
2. If the `gh pr merge --auto` call fails with a network / transport error, the Design Auto-Merge Processor shall emit a warn-level log line that identifies the PR number, head branch name, and the transport error category
3. When an auto-merge enable call fails, the watcher shall continue processing the remainder of the current cycle without aborting the pipeline
4. The Design Auto-Merge Processor shall not silently swallow auto-merge enable failures（exit code 0 で済ませず log に痕跡を残す）
5. If a design PR is rejected by GitHub for reasons such as branch protection misconfiguration or auto-merge not being permitted at the repository level, the Design Auto-Merge Processor shall emit a warn-level log line that distinguishes this case from transient API errors

### Requirement 8: gate off / 非対象 PR での等価性（後方互換）

**Objective:** As an idd-claude operator, I want the introduction of this feature to have zero observable effect when disabled or out of scope, so that 既存運用 / 既存 consumer repo に副作用を一切与えずに段階導入できる

#### Acceptance Criteria

1. While the AND gate is disabled, the Design Auto-Merge Processor shall not call `gh pr merge` against any PR
2. While the AND gate is disabled, the watcher shall not change existing label transitions, comment postings, exit codes, or log lines emitted by other processors（Design Review Release Processor / merge-queue / auto-rebase / pr-iteration / pr-reviewer / Auto-Merge Processor #352 / その他）
3. The Design Auto-Merge Processor shall not touch PRs whose head branch does not match `^claude/issue-.*-design`（人間が手書きした PR / 実装 PR は対象外）
4. The Design Auto-Merge Processor shall not gate or alter the existing Design Review Release Processor / Auto-Merge Processor (#352) / merge-queue / auto-rebase / pr-iteration / pr-reviewer behaviors

### Requirement 9: 観測可能性

**Objective:** As an idd-claude operator, I want to verify whether design auto-merge was enabled or suppressed in a given cycle, so that 「なぜこの設計 PR が merge されない / された」を運用ログから判別できる

#### Acceptance Criteria

1. When the Design Auto-Merge Processor successfully enables auto-merge on a design PR, the watcher shall emit a log line that identifies the PR number, head sha, head branch name, and the enable action（例: `design auto-merge enabled (squash, delete-branch)`）
2. While `AUTO_MERGE_DESIGN_ENABLED` is disabled, the Design Auto-Merge Processor shall emit at most one informational log line per cycle that identifies the gate as the suppression cause（既存ログ量を膨張させない）
3. While `FULL_AUTO_ENABLED` is disabled, the Design Auto-Merge Processor shall rely on the existing kill switch suppression log（#348 NFR 4.1）to identify the suppression cause and shall not duplicate that log
4. The watcher shall include the resolved `AUTO_MERGE_DESIGN_ENABLED` value in cycle startup output so that 運用者が現在の design auto-merge 有効状態を確認できる

## Non-Functional Requirements

### NFR 1: セキュリティ（未信頼入力の取り扱い）

1. When passing PR head sha or PR number to `jq`, the Design Auto-Merge Processor shall use `--arg` / `--argjson`（フィルタ文字列への inline 展開を禁止）
2. When passing untrusted values (PR number, head branch name) to `gh` subcommands, the Design Auto-Merge Processor shall use `--` to terminate option parsing where applicable
3. The Design Auto-Merge Processor shall validate the PR number against `^[0-9]+$` before using it in any URL, path, or log message
4. The Design Auto-Merge Processor shall validate the head branch name against the configured head pattern before passing it to any external command

### NFR 2: 後方互換性

1. While `AUTO_MERGE_DESIGN_ENABLED` is unset, the watcher shall produce external side effects (gh / git API 呼び出し / ラベル遷移 / コミット / push / コメント投稿) that are observably identical to the pre-introduction state
2. The watcher shall not rename, repurpose, or remove existing env var names (including `FULL_AUTO_ENABLED` / `AUTO_MERGE_ENABLED` / `DESIGN_REVIEW_RELEASE_ENABLED` / `PR_REVIEWER_STATUS_CHECK_ENABLED` / `MERGE_QUEUE_ENABLED` / `AUTO_REBASE_MODE` / `PR_REVIEWER_*`), label names (`awaiting-design-review` / `needs-rebase` / `claude-failed` / `needs-decisions` / `needs-iteration`), exit code semantics, or cron registration strings as part of this change
3. The watcher shall not change the existing Design Review Release Processor / Auto-Merge Processor (#352) / merge-queue / auto-rebase / pr-iteration / pr-reviewer function contracts as part of this change

### NFR 3: 性能 / API 呼び出し量

1. The Design Auto-Merge Processor shall invoke at most 1 `gh pr merge --auto` API call per design PR per cycle
2. The Design Auto-Merge Processor shall not introduce additional polling loops, background processes, or sleeps waiting for required status checks（実 merge 完了待ちは GitHub 側に委ねる）

### NFR 4: ドキュメント / 同期

1. The README shall list `AUTO_MERGE_DESIGN_ENABLED` in the optional feature section with its default value, AND-semantics note (with `FULL_AUTO_ENABLED`), target PR conditions (`^claude/issue-.*-design`), and pre-introduction equivalence guarantee
2. The README shall include guidance on how to configure repository-level auto-merge permission and required status checks (design レビューに対応する `codex-review` / `claude-review` 等の安定 context 名 + CI) as prerequisites for the design auto-merge to actually fire
3. The README shall describe the coexistence between `AUTO_MERGE_DESIGN_ENABLED` (この機能) and `DESIGN_REVIEW_RELEASE_ENABLED` (merge 後ラベル後始末) を 1 箇所で参照可能な形で記述する
4. The repository shall keep `local-watcher/` and `repo-template/` byte-equivalent for files under shared dual-management scope (`.claude/agents`, `.claude/rules`, workflow, labels script, modules) after the change

### NFR 5: 静的解析 / テスト

1. The watcher script and the touched / new modules shall pass `shellcheck` and `bash -n` after the change is applied
2. The repository shall include unit tests that stub `gh` and verify the decision branches: (a) all conditions satisfied → `gh pr merge --auto --squash --delete-branch` is invoked exactly once for a design PR, (b) `mergeable=CONFLICTING` → no `gh pr merge` invocation, (c) draft PR → no invocation, (d) head pattern mismatch (impl PR / 人間 PR) → no invocation, (e) AND gate disabled → no invocation, (f) `gh pr merge` failure → warn log emitted and pipeline continues
3. The repository shall include unit tests that verify design review verdict commit statuses are published against design PR head shas under the AND gate and suppressed when the gate is disabled

### NFR 6: 配布 / 二重管理

1. The `install.sh` shall distribute any new / modified module files to `$HOME/bin/modules/` together with the other modules under the existing module distribution path
2. The watcher shall load the design auto-merge entry point via the existing `REQUIRED_MODULES` loader so that the relevant function definitions are available before any Design Auto-Merge Processor entry point is evaluated

## Out of Scope

- 実装 PR（`^claude/issue-.*-impl`）に対する auto-merge 適用（#352 で実装済み）
- CI 失敗時の自動修復・再試行（別 Issue 範囲）
- `mergeable=CONFLICTING` 設計 PR の conflict 解決（既存 merge-queue / auto-rebase 経路に委譲、または別 Issue で扱う）
- branch protection 設定そのもの（required status checks の必須化、auto-merge 許可 toggle 等は人間運用者が repo 側で事前設定する前提）
- 設計レビュー判定ロジック自体の変更（codex / Claude Reviewer の VERDICT / RESULT 解釈は既存契約踏襲）
- `awaiting-design-review` ラベルの自動除去ロジック変更（既存 Design Review Release Processor が継続担当）
- 既存 opt-in 機能（`AUTO_MERGE_ENABLED` / `DESIGN_REVIEW_RELEASE_ENABLED` / `MERGE_QUEUE_ENABLED` / `AUTO_REBASE_MODE` / `PR_REVIEWER_*` / `FULL_AUTO_ENABLED` 等）の値・名前・既定値の変更
- merge 方式の選択肢追加（rebase / merge commit など。本要件では squash 固定）
- 既に auto-merge が enable 済みの設計 PR に対する disable / 取り下げ操作
- `AUTO_MERGE_DESIGN_ENABLED` 設定変更の hot reload（cron 次サイクル以降に反映される運用で十分）
- 設計レビュー status の context 命名変更（既存 #349 の `codex-review` / `claude-review` を共有または等価識別子で運用。新規 context 名導入の要否は design.md で判断）

## Open Questions

- 設計 PR 経路のレビュー status context 名は #349 の `codex-review` / `claude-review` をそのまま共有するか、`design-codex-review` / `design-claude-review` のような design 専用 context を新設するかは、branch protection の required status checks 設定運用（impl PR と design PR で異なる required を設定したいか）に依存する。本要件では「安定識別子で publish される」ことのみ規定し、命名は design.md で確定する（Requirement 4 AC 1〜2 で許容している）
- Design Auto-Merge Processor を `modules/auto-merge.sh`（既存）に統合するか、`modules/auto-merge-design.sh` として分離するかは関数 prefix namespace と File Structure Plan の領分（design.md / Architect）

## 関連

- Depends on: #348 #349 #352
- Parent: #13
- Related: D-03, D-04
