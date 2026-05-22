# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-133-impl-feat-architect-developer-tasks-md-checkb
- HEAD commit: e6e3bac7125592ca54ba49e70b06f4e95de0909a
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に該当節なし → opt-out 解釈（flag 観点の細目チェックは適用しない）

## Verified Requirements

- 1.1 — `.claude/rules/tasks-generation.md` L31-36「すべての実装タスク行は…checkbox 形式で開始することを必須」を明示
- 1.2 — `.claude/rules/tasks-generation.md` L40-41「markdown header のみ（例: `## T-01: タスク名` / `### Task 1` …）でタスクを表現することは禁止」を明示
- 1.3 — `.claude/rules/tasks-generation.md` L38-39「親タスク行・子タスク行のいずれにも checkbox を付与すること」を明示
- 1.4 — `.claude/rules/tasks-generation.md` L75-77 deferrable 節維持 + 「`- [ ]*` も checkbox 形式の一種として扱われ…違反として報告されません」追記
- 1.5 — `.claude/rules/tasks-generation.md` L68-71「ID 規則」節（numeric 階層 ID 必須、`T-01` / `FR-01` 不可）は diff で変更されていない（既存規定維持）
- 2.1 — `.claude/rules/design-review-gate.md` L46-48 Mechanical Checks 箇条書きに「tasks.md checkbox enforcement check」項目追加
- 2.2 — `.claude/rules/design-review-gate.md` 新設「tasks.md checkbox enforcement check」節「判定パターン」「検証手順」項で「checkbox 不在のタスク行を 1 件でも検出した場合に違反として報告」を明示
- 2.3 — 同節「検証手順」3「該当行を `- [ ] <numeric ID>. <タスク名>` 形式に修正してから確定する」を明示
- 2.4 — 同節「判定パターン（参照実装）」項に POSIX 互換 ERE `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` を記載（参照可能な形式）
- 2.5 — 同節「Budget overflow check との関係」項で「両者は同じ『タスク行 = リスト項目 + checkbox + numeric ID』という規約を共有」を明示
- 3.1 — `.claude/agents/architect.md` L192-212 テンプレに `- [ ]*` deferrable 例追加、全タスク行が `- [ ]` / `- [ ]*` の checkbox 形式（markdown header のみのタスク例なし）
- 3.2 — `.claude/agents/architect.md` L257-262 自己レビュー品質チェックリストに「tasks.md checkbox enforcement」項目追加
- 3.3 — `.claude/agents/architect.md` L221-228 新設「Checkbox 形式の必須化」節で「Developer の resume 機能…前提を確実に成立させるため」と理由を 1 行以上で説明
- 4.1 — `.claude/agents/developer.md` L110-115「タスク完了は checkbox 編集で表現する: タスク完了時は `tasks.md` 上で該当タスク行の `- [ ]` を `- [x]` に書き換えることでタスク完了を表現する」を明示
- 4.2 — `.claude/agents/developer.md` L116-118 既存規約「マーカー更新は実装 commit と分けて `docs(tasks): mark <task-id> as done` で commit する」を維持（diff で「batch commit は不可」追記のみ）
- 4.3 — `.claude/agents/developer.md` L86-94「impl-resume / tasks.md 進捗追跡規約」節（`IMPL_RESUME_PROGRESS_TRACKING=true|false` の状態下）配下に L110-115「これが進捗の **正本** であり、内部 TaskCreate / TaskUpdate ツール…hidden marker 等を **進捗の正本としては用いない**」を明示
- 4.4 — `.claude/agents/developer.md` L105-106 既存「行内 4 文字差分」規約を維持（diff で削除なし）
- 5.1 — `.claude/rules/design-review-gate.md`「適用範囲（後方互換性）」節「本チェックの対象は **Architect が新規に生成・編集する `tasks.md`** に限定する」を明示
- 5.2 — 同節「既存 deferrable テストタスク表記 `- [ ]*` は有効な checkbox 形式として扱う（違反として報告しない）」を明示
- 5.3 — 同節「≤ 10 件の正常ケースを含む Budget overflow check の挙動は変化しない」を明示。Reviewer 側で `docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh` を再実行し、4 fixture (10/11/13/14 件) が期待 class と一致することを確認
- 5.4 — 同節「既に main に merge 済みの spec の `tasks.md` に対する **遡及的なルール違反検出は要求しない**（retrofit は本 rule のスコープ外）」を明示
- NFR 1.1 — 既存ルール（EARS / requirements-review-gate / design-principles / feature-flag）との矛盾は diff レビュー範囲で検出せず（既存節への追記・新規節追加のみ）
- NFR 1.2 — 追加された規約は markdown / checkbox / numeric ID のみで構成、特定実装言語に依存しない記述
- NFR 1.3 — `.claude/rules/design-review-gate.md` Mechanical Checks 箇条書き（L38-48）で既存 4 項目（Requirements traceability / File Structure Plan / orphan component / Budget overflow check）と並列粒度で列挙
- NFR 2.1 — 判定パターンが POSIX 互換 ERE で明示され、第三者が 1 分以内に機械的判定可能
- NFR 2.2 — Reviewer 側で `grep -cE '^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? '` を 4 fixture に適用し、全 checkbox 行（最上位 + 子 + deferrable）が 100% 検出されることを再確認 (tasks-10/11/13/14 で checkbox-lines == detected-task-lines)

## Findings

なし

## Summary

Issue #133 が要求する 4 ファイル（`.claude/rules/tasks-generation.md` / `.claude/rules/design-review-gate.md` / `.claude/agents/architect.md` / `.claude/agents/developer.md`）の変更が、Req 1.1〜5.4 および NFR 1.1〜2.2 のすべての numeric ID に対してドキュメント記述または既存規約維持として観測可能。Budget overflow check の判定境界不変（AC 5.3）および判定 regex の fixture 検出率 100% (NFR 2.2) は Reviewer 側で再実行して担保を確認した。Out of Scope（watcher prompt 改修・retrofit・env 名改名）に手を出しておらず、boundary 逸脱は検出されない。本 repo は unit test フレームワークを持たない markdown ルール変更が主体のため、CLAUDE.md「テスト・検証」節に従って grep + 既存 fixture リグレッション検証で AC を担保しており missing test も該当しない。

RESULT: approve
