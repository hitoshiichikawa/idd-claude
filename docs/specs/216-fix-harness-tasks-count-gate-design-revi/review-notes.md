# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-25T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-216-impl-fix-harness-tasks-count-gate-design-revi
- HEAD commit: 5cbc6aa（docs(specs): #216 実装ノートを追加）
- Compared to: origin/main...HEAD（コミット 4 本: c0b5ca1 / 532b831 / ffb0e1c / 5cbc6aa）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が **存在しない** → opt-out 扱い。flag 観点の確認は行わず通常の 3 カテゴリ判定のみを適用。

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh:1394` の `tc_count_tasks` が `grep -cE '^- \[ \]\*? [0-9]+\. '` に変更され、最上位 numeric ID の未完了タスク行のみを計数。
- 1.2 — 子タスク `1.1` 除外。canonical regex は `[0-9]+\. `（整数 + `.` + 空白）を要求するため `1.1` は不一致。fixture `tasks-toplevel-vs-flat.md`（子 1.1/1.2/5.1/6.1 等を除外して 7 件）/ `tasks-mixed-checkbox.md`（子 1.1/1.2 除外で 4 件）で実測確認。
- 1.3 — 完了 `- [x]` / `- [x]*` 除外。checkbox 部を `\[ \]` に固定。`tasks-toplevel-vs-flat.md`（完了 3./2.1/4.1/7.1 を除外）/ `tasks-mixed-checkbox.md`（完了 5./1.1/2.1 を除外）で実測確認。
- 1.4 — 最上位 deferrable `- [ ]*` を計数に含む。`\]\*?` がアスタリスクを許容。`tasks-toplevel-vs-flat.md` の task 8（`- [ ]* 8.`）/ `tasks-mixed-checkbox.md` の task 2（`- [ ]* 2.`）が canonical grep でマッチすることを実測確認。
- 1.5 — `tc_count_tasks` == `grep -cE '^- \[ \]\*? [0-9]+\. '` の件数。3 fixture で直接 grep と driver 値が一致（mixed=4 / toplevel=7 / 11=11）。
- 2.1 — extract-driver.sh の classification 列が新 count で normal/warn/escalate に分岐（17 ケース全 pass）。
- 2.2 — impl-resume の残作業ベース判定は「完了 `- [x]` 除外」で構造的に成立。`tasks-toplevel-vs-flat.md` が完了行を除外して残未完了 7 件を返すことで担保。
- 2.3 — `tasks-11.md`（11 件）が変更後も escalate を維持（driver pass）。
- 2.4 — 閾値（`TC_WARN_LOWER`=8 / `TC_WARN_UPPER`=10 / `TC_ESCALATE_LOWER`=11）および `tc_classify` ロジックに差分なし（diff 確認済み）。境界 classify(0/7/8/9/10/11/50) が従来通り pass。
- 3.1 — `issue-watcher.sh` の `tc_count_tasks` コメントと `design-review-gate.md` の双方に同一 regex `^- \[ \]\*? [0-9]+\. ` を明記。
- 3.2 — harness コメントに「正準は design-review-gate.md の Budget overflow check」である旨と相互参照を明記。`design-review-gate.md:68` に harness への逆参照を 1 段落追記（additive のみ）。
- 3.3 — README「Tasks Count Gate」節をカウント対象記述を canonical 整合に更新。
- 3.4 — 回帰 fixture `tasks-toplevel-vs-flat.md`（新規）/ `tasks-mixed-checkbox.md` が 4 種 checkbox + 子 + 完了 + deferrable を含み最上位・未完了ベース期待件数を検証。
- 4.1 — `tc_count_tasks` は tasks.md のみを入力とする純粋関数。override シグナル（#214）を参照しない（diff に該当トークンなし）。
- 4.2 — per-task-loop（#21）関連コードに変更なし（diff に該当トークンなし）。
- NFR 1.1 — `tc_should_run` の opt-out 分岐は未変更（diff になし）。`tc_count_tasks` は gate 通過後にのみ呼ばれる。
- NFR 1.2 — README に migration note 追記（escalate → warn/normal への意図した移行を明記）。
- NFR 1.3 — env var 名・マーカー文字列 `<!-- idd-claude:tasks-count-overflow ... -->`・exit code 意味に差分なし（diff / grep で確認）。
- NFR 2.1 — `tc_count_tasks` は環境状態に依存しない pure grep。perf-driver で count=20000 / elapsed=2ms / PASS。

## Out-of-Scope 遵守の確認

- `design-review-gate.md` の変更は **相互参照ブロックの追記のみ**（additive）で、canonical regex 文字列・件数セマンティクス・閾値表は **書き換えられていない**（diff で全行確認）。スコープ外の改変なし。
- 閾値既定値・`tc_classify` ロジックの変更なし。

## Findings

なし

## 検証実行ログ（判定根拠）

- `bash tests/local-watcher/tasks-count/extract-driver.sh` → summary: pass=17 fail=0 total=17 / exit=0
- `bash tests/local-watcher/tasks-count/perf-driver.sh` → count=20000 / elapsed=2ms / PASS / exit=0
- 直接 grep 突合: mixed-checkbox=4 / toplevel-vs-flat=7（旧計数 15）/ tasks-11=11 → いずれも driver 値と一致。

## Open Questions / 確認事項の扱い

impl-notes.md の確認事項 3 点（design-review-gate.md 散文の deferrable 自己矛盾 / 計数二重管理の lint 化要否 / 他 fixture への影響なし）は requirements.md の Open Questions に対応し、いずれも「人間判断にエスカレーション」または「影響なし」として整理済み。実装は requirements.md が確定した正準 regex の一致挙動に厳密整合しており、未解決事項は approve を妨げない性質（散文修正の要否は本 PR スコープ外と要件で確定済み）。

## Summary

全 numeric ID（Req 1.1〜1.5 / 2.1〜2.4 / 3.1〜3.4 / 4.1〜4.2 / NFR 1.1〜1.3 / 2.1）に対応する実装・回帰テストを確認。canonical regex 整合・子/完了除外・最上位 deferrable 包含が fixture と実測 grep で一致し、閾値・env var・マーカー・exit code は不変。design-review-gate.md はスコープ外改変なし。boundary 逸脱・AC 未カバー・missing test いずれも検出せず。

RESULT: approve