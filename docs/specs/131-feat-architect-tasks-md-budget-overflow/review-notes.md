# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-21T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-131-impl-feat-architect-tasks-md-budget-overflow
- HEAD commit: b532eb6
- Compared to: main..HEAD
- Feature Flag Protocol 採否: CLAUDE.md に `## Feature Flag Protocol` 節なし → opt-out 扱い（通常の 3 カテゴリ判定のみ適用）

## Verified Requirements

- 1.1 件数の機械カウント — `.claude/rules/design-review-gate.md` の「Budget overflow check（tasks.md 件数）」節と `docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh` で件数抽出 regex `^- \[ \]\*? [0-9]+\. ` を明文化
- 1.2 ≤10 件 pass — `.claude/rules/design-review-gate.md` 閾値表「≤ 10 件 pass」+ `test-fixtures/tasks-10.md` で count=10/class=pass を smoke test 実行で確認
- 1.3 11〜13 件 consolidate 試行要求 — `.claude/rules/design-review-gate.md` 閾値表「11〜13 件 consolidate を試行」+ `.claude/agents/architect.md`「11〜13 件: consolidate を試行 → 失敗時 split proposal」セクション。fixture `tasks-11.md` / `tasks-13.md` で consolidate 分類を確認
- 1.4 consolidate 失敗時 Split Proposal 追加 — `.claude/agents/architect.md`「11〜13 件」セクション手順 3「統合してもなお 11〜13 件のままの場合: Split Proposal セクションを design.md 末尾に追加」
- 1.5 ≥14 件 forced split — `.claude/rules/design-review-gate.md` 閾値表「≥14 forced split」+ `test-fixtures/tasks-14.md` で count=14/class=forced_split を smoke test で確認
- 1.6 Split Proposal 追加時 needs-decisions ラベル付与 — `.claude/agents/architect.md`「`needs-decisions` ラベル付与の手順」節
- 1.7 count 方法を `.claude/rules/` 配下に明文化 — `.claude/rules/design-review-gate.md`「Count 抽出 regex（参照実装）」節
- 2.1 判定根拠を含める — `.claude/agents/architect.md` Split Proposal テンプレ「判定根拠」節（件数・適用閾値・consolidate 試行結果）
- 2.2 分割候補のサブ Issue 名称と含むタスク群を列挙 — `.claude/agents/architect.md` Split Proposal テンプレ「分割候補」節
- 2.3 各サブ Issue に対応 requirement numeric ID を明示 — `.claude/agents/architect.md` Split Proposal テンプレ「対応 requirement」項目
- 2.4 確定できない場合「人間判断を要する論点」を列挙 — `.claude/agents/architect.md` Split Proposal テンプレ「人間判断を要する論点」節
- 3.1 needs-decisions ラベル付与状態で設計 PR 作成 — `.claude/agents/architect.md`「`needs-decisions` ラベル付与の手順」節（Architect が `gh` 権限を持たないため PR 本文経由で PjM に連携）
- 3.2 needs-decisions ラベル中 Developer 自動起動抑止 — `.claude/agents/architect.md` 末尾で `While needs-decisions ラベルが付与されている間 ...` を引用（既存 watcher 挙動への依存。本 Issue では変更しない）
- 3.3 設計 PR 本文に識別文字列と Split Proposal 参照 — `.claude/agents/architect.md`「PR 本文に含めるべき情報 1〜3」
- 3.4 ≤10 件で needs-decisions ラベル付与しない — `.claude/rules/design-review-gate.md` 閾値表 + `.claude/agents/architect.md`「≤ 10 件: pass」セクション「`needs-decisions` ラベル付与も行わない」
- 4.1 root と repo-template/ 同期 — `repo-template/.claude/rules/design-review-gate.md` / `tasks-generation.md` / `repo-template/.claude/agents/architect.md` を root と同期。`diff` 3 ファイルで同一性を再確認
- 4.2 既存「3〜10 件目安」と矛盾しない統合 — `.claude/rules/tasks-generation.md`「件数 enforcement との関係」節で 3〜10 件目安と新閾値の関係を明記
- 4.3 ≤10 件で既存挙動と同一 — `.claude/rules/design-review-gate.md`「既存ガイドラインとの関係」節 +`impl-notes.md` 後方互換性確認セクション + `tasks-10.md` fixture pass
- 4.4 install.sh 再実行による影響 → README に migration note — `README.md`「Architect Review Gate の Budget overflow check（#131）」節に migration note を記載
- 5.1 判定境界（10/11/13/14）の期待動作を fixture / スモークで参照可能 — `test-fixtures/tasks-10.md` / `tasks-11.md` / `tasks-13.md` / `tasks-14.md` + `test-count.sh` + `.claude/rules/design-review-gate.md`「境界の参照 fixture」節
- 5.2 各境界ケースが AC 2〜5 の分岐に一意に到達 — `test-count.sh` の `classify` 関数が pass / consolidate / forced_split を一意に返し、smoke test 実行で 4/4 fixture が期待分類に到達
- NFR 1.1 ≤10 件で既存挙動と完全同一 — `tasks-10.md` fixture が `pass` 判定で追加アクションなし
- NFR 1.2 既存セクション ID・見出し未変更 — `tasks-generation.md` は既存「ガイドライン」セクションを残し block quote で追記のみ（diff 確認）
- NFR 2.1 PR 本文に件数と分岐を明示 — `.claude/agents/architect.md`「PR 本文に含めるべき情報 2」
- NFR 2.2 「budget overflow による split proposal 起票」識別文字列 — `.claude/agents/architect.md` Split Proposal テンプレ冒頭の blockquote と「PR 本文に含めるべき情報 1」
- NFR 3.1 同一 PR で `.claude/` と `repo-template/` を変更 — `git diff --stat main..HEAD` で root 側 `.claude/` 3 ファイルと `repo-template/.claude/` 3 ファイルが同一ブランチ内で更新済み
- NFR 3.2 乖離点を PR 本文「確認事項」に列挙 — 本 PR では乖離なし。確認事項に関連 9 項目を列挙済み

## Findings

なし

## Summary

Issue #131 の全 numeric requirement ID（1.1〜1.7 / 2.1〜2.4 / 3.1〜3.4 / 4.1〜4.4 / 5.1〜5.2）と
NFR（1.1〜1.2 / 2.1〜2.2 / 3.1〜3.2）が、`.claude/rules/`、`.claude/agents/architect.md`、
`README.md`、および境界 fixture + smoke test で観測可能にカバーされている。スモークテスト
`test-count.sh` は 4/4 fixture が期待件数・期待分類に一致し、shellcheck はクリーン、
root と `repo-template/` の 3 ファイルは diff 上完全一致。境界逸脱・missing test なし。

RESULT: approve
