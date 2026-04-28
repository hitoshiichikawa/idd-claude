# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-04-28T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-23-impl-phase-4-feature-flag-protocol-claude-md
- HEAD commit: 2d60d83b6d89f8d092904e44b8f7efd520955ba2
- Compared to: main..HEAD
- Changed files: 10 files, +725 / -10 (markdown only)

## Verified Requirements

- 1.1 — `repo-template/CLAUDE.md` 行 179 に `## Feature Flag Protocol` 節を新設（h2 固定、専用節）
- 1.2 — 同節 行 185 で `**採否**: opt-out` を初期値、HTML コメントで opt-in 切替例を明示。`feature-flag.md` 行 91-126 にも opt-in / opt-out サンプルを併記
- 1.3 — `.claude/agents/developer.md` 行 26-27 / `.claude/agents/reviewer.md` 行 28-29 に「節がない／値が `opt-in` 以外なら opt-out として解釈」フォールバックを記載
- 1.4 — `repo-template/CLAUDE.md` 行 181 に `> **デフォルトは opt-out です**` を bold で明記、typo 安全側の記述あり。`feature-flag.md` 行 25 にも同記述
- 2.1 — `repo-template/.claude/rules/feature-flag.md` および root `.claude/rules/feature-flag.md` を新規作成（同内容、141 行）
- 2.2 — `feature-flag.md` 行 18-36 `## 採否宣言の書式` セクション（CLAUDE.md における h2 見出し・宣言行・マーカーコメントを提示）
- 2.3 — `feature-flag.md` 行 38-46 `## Flag 命名と初期値` セクション（命名方針 / 初期値 false / 有効化条件の記述要領）
- 2.4 — `feature-flag.md` 行 48-56 `## Implementer が満たすべき要件` チェックリスト（旧パス温存 / 両系統テスト / 差分等価 / flag 列挙）
- 2.5 — `feature-flag.md` 行 80-89 `## Non-Goals` で LaunchDarkly / Unleash / GrowthBook を明示除外
- 3.1 — `.claude/agents/developer.md` 行 71-84 `## opt-in 時の追加実装フロー` で flag 裏実装指示
- 3.2 — `developer.md` 行 78「同一テストスイートが flag-on / flag-off の両方で実行可能」+ `feature-flag.md` 行 58-68
- 3.3 — `developer.md` 行 79-81「flag-off 差分等価」+ git diff セルフチェック
- 3.4 — `developer.md` 行 26-27 / 行 84「opt-out / 無宣言は通常フロー、追加フロー適用しない」明記
- 4.1 — `.claude/agents/reviewer.md` 行 30-31 / 55-59 で opt-in 時の flag 観点（boundary 逸脱の細目 a-d）を追加
- 4.2 — `reviewer.md` 行 28-29 / 行 71「opt-out および無宣言は flag 観点を適用しない」明記
- 4.3 — `reviewer.md` 行 61-69 `### opt-in 時の確認手順`（git diff で flag-off ブロックの等価確認手順）
- 4.4 — `reviewer.md` 行 55-59 で flag-off path mutation など 4 細目について `boundary 逸脱` で reject と明文化
- 5.1 — `feature-flag.md` 行 60「同一テストスイートを flag-on / flag-off の 2 通りで実行する」
- 5.2 — `feature-flag.md` 行 61「いずれか 1 系統でも失敗したら全体結果を失敗として扱う」
- 5.3 — `feature-flag.md` 行 62-66「責務分担の選択肢」(a) ローカル / (b) CI / (c) 規約のみ
- 6.1 — `feature-flag.md` 行 72「flag 定義と `if (flag)` 分岐を除去する別 PR を作成する義務」
- 6.2 — `feature-flag.md` 行 73-75「人間が umbrella Issue 完了時に手動で起票」と明記（Open Q1 への design 判断と整合）
- 6.3 — `feature-flag.md` 行 76-78「同時に active flag が 5 個を超えたら棚卸し Issue を起票」と数値化
- NFR 1.1 — watcher / install.sh / setup.sh / yml 不変、`developer.md` / `reviewer.md` で「opt-out / 無宣言は既存挙動と等価」を明記。impl-notes Smoke 1 で install.sh の `.bak` バックアップ動作を確認
- NFR 1.2 — `grep -E '^## ' repo-template/CLAUDE.md` で既存 9 節 + 参考資料の見出しテキスト・h2 階層が保全されていることを確認（新規 `## Feature Flag Protocol` のみ追加）
- NFR 2.1 — `feature-flag.md` 141 行（200 行目安以内）/ Feature Flag 節 36 行（60 行目安以内）
- NFR 2.2 — `feature-flag.md` 行 91-126 と `repo-template/CLAUDE.md` 節内に opt-in / opt-out 採用宣言サンプルを 1 つずつ含む
- NFR 3.1 — `feature-flag.md` 内に言語固有のコード例なし。「lower_snake_case 推奨。プロジェクトの言語慣習に合わせて」と抽象化されている

## Boundary Check

design.md File Structure Plan に列挙された全ファイルのみを変更している:

- `repo-template/CLAUDE.md` (TemplateClaudeMd) — 末尾に節追加のみ、既存節破壊なし
- `repo-template/.claude/rules/feature-flag.md` + root `.claude/rules/feature-flag.md` (FeatureFlagRule) — 新規作成
- `.claude/agents/developer.md` + repo-template (DeveloperAgentDef) — 追記のみ
- `.claude/agents/reviewer.md` + repo-template (ReviewerAgentDef) — 追記のみ（既存 3 カテゴリ判定は保持）
- root `CLAUDE.md` — 共通ルール表に 1 行追加のみ、Feature Flag 節は追加していない（idd-claude 自身は Out of Scope）
- `README.md` — Phase 4 マーカー更新と Migration note（design.md "Documentation Updates" に明示）

"Out of Modification" 対象（`local-watcher/bin/issue-watcher.sh`, `install.sh`, `setup.sh`, `.github/workflows/*.yml`, `triage-prompt.tmpl`）への変更はゼロ。boundary 逸脱なし。

## Findings

なし

## Summary

すべての numeric AC（1.1-1.4, 2.1-2.5, 3.1-3.4, 4.1-4.4, 5.1-5.3, 6.1-6.3, NFR 1.1, 1.2, 2.1, 2.2, 3.1）について実装またはドキュメント記述で対応が確認できた。design.md File Structure Plan に列挙された範囲のみへの変更で boundary 逸脱なし。impl-notes.md に手動スモークテスト 1-5 の結果が記録されており、NFR 1.2（既存節保全）/ NFR 2.1（行数）/ install.sh 冪等性が裏付けられている。markdown のみの変更のため shellcheck / actionlint 対象外で missing test の問題なし。

RESULT: approve
