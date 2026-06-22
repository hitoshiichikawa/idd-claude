# Requirements Document

## Introduction

idd-claude の Phase D Auto Rebase Processor は、現状 `mechanical` 判定の rebase のみ approve を
維持して auto-merge に到達させ、`semantic` 判定（`MECHANICAL_PATHS` allowlist 外の差分を含む
rebase）では approve を全件 dismissal して `ready-for-review` に戻し、人間レビューを待つ運用に
なっている。本機能（D-12）はこの **semantic 経路に限り** Claude による conflict 解消を opt-in で
追加し、Claude が生成した解決 commit を PR head に積んだうえで既存の `codex-review` /
`claude-review`（pr-reviewer.sh / #261）を **再発火** させて二重ゲートを通った場合のみ
auto-merge が可能となるよう拡張する。**Claude の解決結果を無検証で merge することは絶対に行わない**
ことが本機能の安全性核心であり、Claude 解決後も approve は dismissal され続け、PR Reviewer の
再レビュー（codex-review / claude-review）と人間 / 自動 approve 復帰を経て初めて auto-merge に
到達する。新規 gate `AUTO_REBASE_SEMANTIC` は既定 `off` とし、`FULL_AUTO_ENABLED`（#348 kill
switch）との AND 二重 opt-in で初めて発火する。本機能のパイロット運用先は altpocket-server を
想定し、idd-claude 本体は self-hosting（dogfooding）対象として運用する。

## 決定済み事項（Issue 本文より）

本要件定義は、Issue #366 本文に明記されている以下の決定事項を前提とする:

- **対象範囲**: 既存 Phase D Auto Rebase Processor の semantic 経路のみを拡張する（mechanical
  経路は変更しない）
- **新 gate**: `AUTO_REBASE_SEMANTIC`（既定 `off` / 受理値 `claude` / それ以外は `off` に正規化）
- **二重 opt-in**: `AUTO_REBASE_SEMANTIC=claude` AND `FULL_AUTO_ENABLED=true` の AND 評価
- **解決結果は新規 commit として PR に積む**（rebase 履歴の上書きではなく、レビュー履歴を残す
  追加 commit として扱う）
- **再レビュー再発火**: pr-reviewer.sh の codex-review / claude-review（#261 / #349）が
  Claude 解決 commit に対して再発火することを要件化する（無検証 merge 禁止）
- **解決不能 / 反復失敗時のエスカレーション**: `needs-decisions` ラベルで人間に委ねる（Issue 05
  / failed-recovery.sh の attempt budget 思想と整合）
- **既存 `AUTO_REBASE_MODE=claude` との直交関係**: 機械的 conflict は従来経路、本機能は semantic
  経路のみを追加で拡張する（二重実行しない）
- **gate `off` 時の挙動**: #366 導入前と完全等価（現行 semantic = approve dismiss → 人間待ち）
- **DoD**: shellcheck クリーン / 近接テスト / root↔repo-template 同期 / README 追記

## 用語

- **mechanical conflict / mechanical 判定**: rebase 後の変更ファイルが `MECHANICAL_PATHS`
  allowlist に**すべて**含まれる状態。既存 Phase D で approve を維持し auto-merge に向かう経路
- **semantic conflict / semantic 判定**: rebase 後の変更ファイルが 1 件でも `MECHANICAL_PATHS`
  allowlist 外、または `MECHANICAL_PATHS` 未設定の状態。現行は approve dismiss + 人間待ち
- **Claude 解決 commit**: 本機能で新たに導入する、Claude が semantic conflict を解消した結果を
  PR head に積む追加 commit
- **再レビュー（re-review）**: 既存 pr-reviewer.sh（#261 / #349）の codex-review /
  claude-review が新しい head SHA に対して再評価を実行すること
- **attempt budget**: 同一 PR に対する Claude 解決試行の通算上限（上限到達で `needs-decisions`
  エスカレーション）
- **二重ゲート**: 「Claude 解決 commit が PR に積まれる」+「pr-reviewer による再レビューが
  approve / non-block 判定を返す」の 2 条件 AND（本機能の安全性核心）

## アクター

- **idd-claude operator**: watcher / cron / launchd を運用する人間。env var 設定 / gate
  切替 / `needs-decisions` ラベル外しを担う
- **watcher**: `local-watcher/bin/issue-watcher.sh` + `modules/auto-rebase.sh` +
  `modules/pr-reviewer.sh` を含む cron 実行スクリプト
- **Claude**: `claude` CLI 経由で起動される LLM。semantic conflict 解消の実行主体
- **pr-reviewer**: codex / antigravity（claude-review 含む）を呼び出す既存モジュール。本機能の
  Claude 解決 commit に対して再レビューを実施する責務を担う
- **人間レビュワー**: Claude 解決 commit の差分を最終確認し、approve / iteration 指示を出す

## Requirements

### Requirement 1: 新 gate `AUTO_REBASE_SEMANTIC` の正規化と既定値

**Objective:** As an idd-claude operator, I want the new semantic auto-rebase gate to be normalized to a safe default with strict value matching, so that typo / 未設定で意図せず Claude による semantic 解決が起動するリスクを排除できる

#### Acceptance Criteria

1. The watcher Config block shall declare `AUTO_REBASE_SEMANTIC` with a default value of `off`
2. When `AUTO_REBASE_SEMANTIC` is set to the exact string `claude`, the watcher shall treat the gate as enabled
3. When `AUTO_REBASE_SEMANTIC` is set to the exact string `off`, the watcher shall treat the gate as disabled
4. If `AUTO_REBASE_SEMANTIC` is unset, empty, or set to any value other than the two canonical strings `claude` / `off`, the watcher shall normalize the gate to `off`
5. The watcher shall complete the `AUTO_REBASE_SEMANTIC` normalization before any semantic auto-rebase decision is evaluated
6. The watcher shall log the resolved value of `AUTO_REBASE_SEMANTIC` at cycle startup so that 運用者が現サイクルの gate 解決値を確認できる

### Requirement 2: 二重 opt-in（kill switch との AND 評価）

**Objective:** As an idd-claude operator, I want the semantic auto-rebase to require both the feature gate and the global kill switch, so that 1 つの env 設定ミスで本番に影響する自動修正が走らないように二段の安全策を持てる

#### Acceptance Criteria

1. When `AUTO_REBASE_SEMANTIC` is `claude` and `FULL_AUTO_ENABLED` is `true`, the watcher shall evaluate semantic conflicts as candidates for Claude resolution
2. If `AUTO_REBASE_SEMANTIC` is `off`, the watcher shall not attempt Claude resolution on semantic conflicts regardless of `FULL_AUTO_ENABLED` value
3. If `FULL_AUTO_ENABLED` is not `true`, the watcher shall not attempt Claude resolution on semantic conflicts regardless of `AUTO_REBASE_SEMANTIC` value
4. When the watcher suppresses Claude semantic resolution due to either gate being disabled, the watcher shall fall back to the pre-introduction behavior (approve dismissal + `ready-for-review` + human wait) without any additional side effect
5. The watcher shall evaluate `FULL_AUTO_ENABLED` with the same strict equality semantics already established by #348 (exact string `true`)

### Requirement 3: 既存経路との直交性（後方互換）

**Objective:** As an idd-claude operator, I want this feature to be strictly additive to the existing Auto Rebase Processor, so that 機械的 conflict の自動解消や `AUTO_REBASE_MODE=claude` の挙動が本機能導入で変化しない

#### Acceptance Criteria

1. While `AUTO_REBASE_SEMANTIC` is `off`, the watcher shall produce externally identical behavior to the pre-introduction state for all PRs handled by the Auto Rebase Processor (mechanical / semantic / failed / skip すべての分岐)
2. When the Auto Rebase Processor classifies a rebase as `mechanical`, the watcher shall not invoke Claude semantic resolution regardless of `AUTO_REBASE_SEMANTIC` value
3. When the watcher resolves a semantic conflict via Claude under this feature, the watcher shall not also invoke the existing `AUTO_REBASE_MODE=claude` mechanical rebase path on the same PR within the same cycle (no double execution)
4. The watcher shall preserve the existing `AUTO_REBASE_MODE` env var semantics (`off` / `claude` / typo → `off`) unchanged
5. The watcher shall not rename, repurpose, or remove existing env var names (`AUTO_REBASE_MODE` / `MECHANICAL_PATHS` / `AUTO_REBASE_MODEL` / `AUTO_REBASE_MAX_TURNS` / `AUTO_REBASE_MAX_TURNS_SEC` / `AUTO_REBASE_GIT_TIMEOUT` / `AUTO_REBASE_MAX_PRS` / `AUTO_REBASE_TEMPLATE`), label names, exit code semantics, or cron registration strings as part of this change

### Requirement 4: Claude による semantic conflict 解決の実行

**Objective:** As an idd-claude operator, I want Claude to attempt resolving semantic conflicts and push the result as an additional commit on the PR head, so that 人間が rebase 作業を肩代わりされつつ、解決結果は履歴として明示的に PR に残る

#### Acceptance Criteria

1. When the Auto Rebase Processor classifies a rebase as `semantic` and the dual opt-in (Req 2.1) is satisfied, the watcher shall invoke Claude to attempt resolving the conflict on a working copy of the PR head branch
2. When Claude successfully resolves the conflict and produces a clean working tree, the watcher shall push the resolved head to the PR's head branch using `git push --force-with-lease` (never `git push --force` 単独)
3. The watcher shall record the head SHA before and after Claude resolution and emit both values in the Phase D log line for the affected PR
4. When Claude resolution succeeds, the watcher shall post a single PR comment that explains (a) the resolved before / after SHA, (b) that approving reviews have been dismissed, (c) that the re-review pipeline (codex-review / claude-review) will re-fire, and (d) that auto-merge is gated on the re-review outcome
5. If Claude exits with timeout (exit 124) or leaves the working tree dirty, the watcher shall abort the rebase, leave the PR head SHA unchanged, and treat the attempt as failed for the purpose of attempt budget counting (Req 7)
6. If `git push --force-with-lease` fails after a successful local resolution, the watcher shall not retry within the same cycle and shall treat the attempt as failed for the purpose of attempt budget counting (Req 7)
7. The watcher shall not attempt Claude semantic resolution on PRs that carry the `claude-failed` label, regardless of dual opt-in state (existing exclusion preserved)

### Requirement 5: 二重ゲート（approve dismissal の維持と再レビュー再発火）

**Objective:** As an idd-claude operator, I want every Claude-resolved commit to be re-reviewed before auto-merge becomes possible, so that LLM が生成した差分が無検証で main に merge されるリスクをゼロにできる

#### Acceptance Criteria

1. When Claude successfully resolves a semantic conflict, the watcher shall dismiss all existing approving reviews on the PR via the review dismissal API (existing `ar_dismiss_all_approvals` 経路を再利用)
2. When Claude successfully resolves a semantic conflict, the watcher shall add the `ready-for-review` label to the PR after dismissing approvals
3. When Claude successfully resolves a semantic conflict, the watcher shall not directly trigger auto-merge on the PR within the same cycle
4. When the PR head SHA changes due to Claude resolution, the PR Reviewer (pr-reviewer.sh) shall re-evaluate the PR in a subsequent cycle as if it were a fresh head, producing codex-review / claude-review output against the new SHA
5. The watcher shall not allow auto-merge to fire on a Claude-resolved PR until both (a) the PR Reviewer's most recent re-review against the post-resolution head SHA has not returned a `needs-iteration` verdict, and (b) at least one approving review exists against the post-resolution head SHA (人間 / 自動 approve 復帰)
6. If branch protection settings dismiss the post-resolution approvals automatically, the watcher shall preserve that behavior (no override of branch protection)

### Requirement 6: Idempotency（同一 PR の再評価で二重実行しない）

**Objective:** As an idd-claude operator, I want repeated watcher cycles to never trigger duplicate Claude resolutions on the same head SHA, so that quota 燃焼 / 同一 commit の重複生成 / レビュー履歴のノイズを防げる

#### Acceptance Criteria

1. When the watcher has already attempted Claude semantic resolution on a given PR head SHA in a previous cycle and the head SHA has not changed, the watcher shall skip Claude invocation on the same PR within the current cycle
2. The watcher shall persist per-PR attempt state (at minimum: last attempted head SHA, attempt count, last outcome, last attempt timestamp) in a machine-readable file under `$HOME/.issue-watcher/` (consistent with existing state file placement policy in CLAUDE.md「機能追加ガイドライン」§6)
3. When the persisted state file for a PR is missing, unreadable, or corrupt, the watcher shall treat the PR as having zero prior attempts (fail-open to safe behavior; attempt budget begins from 0)
4. When a new commit is pushed to the PR head by Claude resolution itself, the watcher shall record the new head SHA as the last attempted SHA so that 同サイクルおよび次サイクルで同一 SHA に対する重複試行が起きない
5. The watcher shall not invoke Claude semantic resolution more than once per PR within a single watcher cycle

### Requirement 7: Attempt budget と needs-decisions エスカレーション

**Objective:** As an idd-claude operator, I want repeated failures on the same PR to escalate to human review via `needs-decisions`, so that 解決不能な semantic conflict が無限に Claude を起動し続けて quota / 時間を消費しない

#### Acceptance Criteria

1. The watcher shall enforce a per-PR cumulative attempt budget for Claude semantic resolution, configurable via an env var with a safe default
2. When the cumulative attempt count for a PR reaches the configured budget without a successful resolution that passes re-review, the watcher shall add the `needs-decisions` label to the PR
3. When the watcher adds the `needs-decisions` label due to attempt budget exhaustion, the watcher shall post a single PR comment that includes (a) the cumulative attempt count, (b) the budget value in effect, (c) the head SHA at the time of escalation, and (d) a recommended manual recovery procedure
4. While a PR carries the `needs-decisions` label added by this feature, the watcher shall not attempt further Claude semantic resolution on that PR until the label is removed by a human
5. If a Claude attempt fails due to a transient cause (`fetch-failed` / `push-failed` / `timeout`), the watcher shall increment the attempt budget by 1 (attempt budget は試行開始時に確定する方針 / failed-recovery.sh と整合)
6. The watcher shall not add the `claude-failed` label as a result of attempt budget exhaustion (既存 `claude-failed` 経路と併存させない / `needs-decisions` への一本化)
7. If a Claude attempt succeeds and the post-resolution PR is later approved and merged, the watcher shall consider the attempt budget for that PR satisfied and shall not retain the budget state beyond the PR's lifetime (state ファイルは PR clean up と整合)

### Requirement 8: 既存 `claude-failed` および `needs-rebase` ラベルとの整合

**Objective:** As an idd-claude operator, I want this feature to interoperate cleanly with the existing label-based state machine, so that 既存の Phase A / Phase D / Failed Recovery 経路のラベル契約が崩れない

#### Acceptance Criteria

1. While a PR carries the `claude-failed` label, the watcher shall not attempt Claude semantic resolution under this feature (既存 Phase D 同様の除外を継続)
2. When the watcher escalates a PR to `needs-decisions` due to attempt budget exhaustion, the watcher shall not also add the `claude-failed` label (Req 7.6 と整合)
3. When Claude successfully resolves a semantic conflict, the watcher shall remove the `needs-rebase` label as part of the existing semantic post-processing (`ar_apply_semantic` 既存挙動と整合)
4. If the watcher fails to add `needs-decisions` due to a GitHub API error, the watcher shall emit a warning log line and shall not silently lose the escalation (次サイクルで再試行可能)

### Requirement 9: 観測可能性

**Objective:** As an idd-claude operator, I want to observe every decision and outcome of the Claude semantic resolution path, so that 運用ログから挙動と attempt budget の燃焼状況を後追いできる

#### Acceptance Criteria

1. When the watcher evaluates a semantic conflict candidate, the watcher shall emit a log line that includes the resolved `AUTO_REBASE_SEMANTIC` value, the resolved `FULL_AUTO_ENABLED` value, the PR number, the head SHA, and the resulting action (`attempt` / `skip-gate-off` / `skip-idempotent` / `skip-claude-failed` / `escalate-needs-decisions`)
2. When the watcher completes a Claude semantic resolution attempt, the watcher shall emit a log line that includes the PR number, the before / after head SHA, the outcome (`resolved` / `timeout` / `dirty` / `push-failed`), and the post-attempt cumulative attempt count
3. The watcher shall include a per-cycle summary line that counts semantic resolution outcomes (`semantic-resolved=N, semantic-failed=N, semantic-escalated=N, semantic-skipped=N`) so that 1 行で運用状況が把握できる
4. The watcher shall use a stable log prefix that allows existing `auto-rebase:` grep フィルタを壊さない（新機能のログも同 prefix 配下で識別できること）

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `AUTO_REBASE_SEMANTIC` is unset or set to `off`, the watcher shall produce byte-equivalent external side effects (gh / git API 呼び出し / ラベル遷移 / commit / push / コメント) to the pre-introduction state for any PR handled by the Auto Rebase Processor
2. The watcher shall not change the default value of any existing env var (`AUTO_REBASE_MODE` / `MECHANICAL_PATHS` / `FULL_AUTO_ENABLED` / `AUTO_REBASE_MODEL` / その他) as part of this change
3. The watcher shall not introduce new label names; this feature shall reuse `needs-decisions` / `ready-for-review` / `needs-rebase` / `claude-failed` from the existing label set
4. The watcher shall not change the existing exit code semantics of `process_auto_rebase` (`mechanical` / `semantic` / `failed` / `skip` の戻り値分類)

### NFR 2: ドキュメント / 同期

1. The README shall add a subsection under "Auto Rebase Processor (Phase D)" that documents `AUTO_REBASE_SEMANTIC`, its canonical values (`off` / `claude`), default value, AND-semantics with `FULL_AUTO_ENABLED`, attempt budget env var name and default, dual gate guarantee (re-review must pass before auto-merge), and pre-introduction equivalence guarantee for `off`
2. The repository shall keep `.claude/agents/` ↔ `repo-template/.claude/agents/` byte-equivalent and `.claude/rules/` ↔ `repo-template/.claude/rules/` byte-equivalent after the change (CLAUDE.md「機能追加ガイドライン」§4)
3. The repository shall keep `local-watcher/bin/modules/auto-rebase.sh` and any new modules in sync with `repo-template/local-watcher/bin/modules/` after the change (install.sh が配置する dual-management ファイルのドリフトを防ぐ)
4. The repository shall document the attempt budget escalation flow (`needs-decisions` ラベル付与 / コメント文面 / 復旧手順) in the same README subsection so that 運用者が escalate された PR を復旧できる

### NFR 3: 静的解析・テスト

1. The watcher script and any new module shall pass `shellcheck` and `bash -n` after the change is applied (CLAUDE.md「テスト・検証」§静的解析)
2. The repository shall include 近接 test (`local-watcher/test/`) that covers at minimum the following cases: gate `off` で従来 semantic 挙動が保たれること / dual opt-in 不成立で Claude 起動しないこと / Claude 解決成功時に approve dismissal + `ready-for-review` 付与が行われること / 同一 head SHA への二重試行が抑止されること / attempt budget 到達時に `needs-decisions` がつきコメントが投稿されること
3. The repository shall include 近接 test that covers env normalization for at least one invalid / typo value of `AUTO_REBASE_SEMANTIC` (`Claude` / `on` / `true` / 空文字列 等) falling back to `off`
4. The repository shall include 近接 test that verifies `process_auto_rebase` の戻り値分類が本機能導入前と同一のままであること（mechanical / semantic / failed / skip それぞれ）

### NFR 4: セキュリティ・運用境界

1. The watcher shall pass unsanitized PR / branch input to Claude / `git` / `gh` / `jq` / `bash -c` only through the existing safe-handling patterns established in CLAUDE.md「機能追加ガイドライン」§5 (quote / `--arg` / `--` でオプション解釈打ち切り / 数値 ID と SHA の正規表現検証)
2. The watcher shall not allow Claude semantic resolution to push to base branches (`BASE_BRANCH` / `MERGE_QUEUE_BASE_BRANCH` 等); pushes shall be limited to the PR's head branch via `git push --force-with-lease`
3. The watcher shall not attempt Claude semantic resolution on fork PRs (existing `head repo owner == base repo owner` チェックを再利用)
4. The watcher shall not attempt Claude semantic resolution on PRs whose head branch does not match `MERGE_QUEUE_HEAD_PATTERN` (人間の手書き PR を巻き込まないための既存ガードを再利用)

### NFR 5: 性能・運用

1. The watcher shall limit the number of PRs subjected to Claude semantic resolution per cycle via an env var that defaults to a value no larger than the existing `AUTO_REBASE_MAX_PRS` default (`3`) so that 1 サイクルで quota を燃焼し尽くさない
2. The watcher shall apply an external timeout to each Claude semantic resolution invocation (consistent with existing `AUTO_REBASE_MAX_TURNS_SEC` default `600` 秒)
3. The watcher shall not retain attempt-budget state files for PRs that have been merged or closed for more than a reasonable retention window (具体値は design.md で確定 / state ファイル GC 方針が定義されていること)

## Error Handling

- **Claude が dirty 状態で終了**: rebase abort し、head SHA を変更せず、attempt 加算済みで次サイクルに委ねる（Req 4.5）
- **`git push --force-with-lease` 失敗**: ローカル解決はあっても push しない。attempt 加算済みで次サイクルに委ねる（Req 4.6）
- **review dismissal API 失敗**: 既存 `ar_dismiss_all_approvals` の Error Handling（HTTP 422 skip / 他は失敗扱い）を踏襲する（Req 5.1）
- **`needs-decisions` ラベル付与失敗**: WARN ログを出して次サイクルで再試行可能とする（Req 8.4）
- **state ファイル read 失敗 / parse 失敗**: 0 attempts として扱う fail-open（Req 6.3）
- **GitHub API rate limit**: 既存 Phase D 同様、当該サイクルは skip し次サイクルで再試行する（既存挙動を踏襲）

## Out of Scope

- 既存 `AUTO_REBASE_MODE=claude` の mechanical conflict 挙動の変更（mechanical 経路は本機能の対象外）
- `MECHANICAL_PATHS` allowlist 構文の拡張（regex 化 / 否定パターン等）。本機能は allowlist の既存
  semantics を変えない
- semantic 判定アルゴリズムの高度化（AST diff / 関数単位の overlap 解析等）。判定は既存
  `ar_classify_diff` のままで、本機能は判定後の挙動のみ拡張する
- Phase E Path Overlap Checker（入口側予防 / #18）との統合変更。Phase E は in-flight 突合の
  入口側予防であり、本機能（出口側の自動解決）と直交配置のまま
- `claude-failed` ラベルの semantics 変更や別ラベルへの置換。本機能は新ラベルを導入しない
- attempt budget 到達後の `needs-decisions` 自動解除（Issue #362 の `safe` 自動続行とは別経路で
  運用される。本機能の `needs-decisions` は常に `human-only` 相当）
- パイロット運用先（altpocket-server）以外の repo への展開判断（運用ロールアウト計画）
- pr-reviewer.sh（codex-review / claude-review）側の挙動変更。本機能は「再レビューが新 head SHA
  に対して再発火する」既存挙動に依存するが、pr-reviewer 自体は本 Issue の改修対象外

## Open Questions

- attempt budget の **既定値** と **env var 名**（例: `AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS` / 既定
  `3` 等）は design.md / Architect の領分。本要件は「per-PR 通算 attempt 上限が env で設定可能で
  安全側 default を持つ」までを規定する（Req 7.1）
- attempt budget 状態ファイルの **パスとフォーマット**（JSON / 1 ファイル / per-PR 分割 等）は
  design.md の領分。本要件は「`$HOME/.issue-watcher/` 配下に machine-readable に保存される」
  までを規定する（Req 6.2）
- Claude 解決後のコメント本文の **必須記載項目**（before/after SHA / dismissal 説明 / 再レビュー
  誘導 / auto-merge ゲート説明）の具体的な文面・フォーマットは design.md / Architect の領分。
  本要件は (a)〜(d) の項目をすべて含むことのみ規定する（Req 4.4）
- 再レビュー結果が `needs-iteration` の場合、本機能の attempt budget を加算するか否か（解決
  commit は積まれたが品質が不足したケース）。本要件では「attempt 加算は試行開始時に確定」と
  整合させて加算側に倒すが、`needs-iteration` ループとの相互作用は design.md / Architect が
  確認すべき。

## 関連

- Parent: #13
- Depends on: #261 #348 #349 #359
- Related: D-12

---

## Self Review

Mechanical Checks:
- Numeric ID: 全要件見出しが numeric ID（Requirement 1〜9 / NFR 1〜5）。OK
- AC の存在: 全要件・全 NFR に EARS 形式 AC が 1 件以上。OK
- 実装語彙: bash / shell 関数名（`ar_apply_semantic` 等）は既存 module への参照として用語節 /
  Error Handling 節に限定して登場。AC 本文には実装詳細（DB / framework / API パターン）を
  混入していない。OK

判断レビュー:
- スコープ・カバレッジ: 二重 opt-in / Claude 解決の実行 / 二重ゲート（dismissal + 再レビュー）/
  idempotency / attempt budget エスカレーション / 既存ラベル整合 / 観測可能性 / 後方互換 / セキュ
  リティ・運用境界 / 性能の各観点をカバー
- EARS 準拠: 全 AC が `When` / `If` / `While` / `Where` / `The <subject> shall` のいずれかで
  開始
- testable / observable: 各 AC は env 設定 / ラベル状態 / ログ出力 / API 呼び出しで検証可能
- 実装詳細排除: 状態ファイルのパス / attempt budget 既定値 / コメント文面 / re-review 連携の
  内部実装は Open Questions に逃がし design.md / Architect の領分とした

最大 2 パスのうち 1 パス目で確定可能と判断し、Open Questions に逃がした 4 項目を Architect への
申し送りとする。
