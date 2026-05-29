# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-268-impl--web
- HEAD commit: 1c74c95a3dc2d4ef7c665d2c66f39fe818560c04
- Compared to: main..HEAD

差分対象ファイル（impl-notes に基づく / `git diff --stat` で確認済み）:

- `.claude/agents/architect.md`（+36 行、`# 行動指針` 直前に Web 検索節を挿入）
- `.claude/rules/design-principles.md`（+27 行、`## アプローチ` と `## 警告:` の間に Web 検索節を挿入）
- `repo-template/.claude/agents/architect.md`（+36 行、root と byte 一致）
- `repo-template/.claude/rules/design-principles.md`（+27 行、root と byte 一致）
- `docs/specs/268--web/requirements.md`（+110 行）
- `docs/specs/268--web/impl-notes.md`（+61 行）

本実装は markdown ドキュメントのみの編集（コード変更なし）。tasks.md は存在しない
（design-less impl 経路）。

## Verified Requirements

- 1.1 — `.claude/agents/architect.md` 新規節「外部仕様の不確実性を Web 検索で解消する」が
  diff に確認できる。外部ツール・ライブラリ・API・CLI コマンドを伴う設計時に不確実な仕様を
  Web 検索で検証するよう指示している
- 1.2 — `repo-template/.claude/agents/architect.md` も同一内容で追加されており、
  `diff -r .claude/agents repo-template/.claude/agents` が空（byte 一致）
- 1.3 — 新規節「いつ Web 検索を行うか」サブセクションに「不確実な箇所について Web 検索で
  一次情報（公式ドキュメント・公式 GitHub README / issue・公式 changelog 等）を確認する」と
  明記
- 1.4 — 同サブセクション内に「設計判断の対象が idd-claude 内部の既存仕様・既存実装である
  場合は、Web 検索を必須とせず、既存ドキュメント・既存コード・既存テストの参照を優先する」と
  明記
- 1.5 — 「いつ Web 検索を行わないか（最小限の運用）」サブセクションに「『不明な場合・新規
  ツール導入時に限定』して必要最小限に留めることを意図しています」と明記
- 2.1 — `.claude/rules/design-principles.md` 新規節「外部仕様の不確実性を Web 検索で解消する」
  が `## アプローチ` 直後に挿入されている
- 2.2 — `repo-template/.claude/rules/design-principles.md` も同一内容で追加されており、
  `diff -r .claude/rules repo-template/.claude/rules` が空（byte 一致）
- 2.3 — 「### 検索対象のスコープ」サブセクションに「対象: 外部ツール・ライブラリ・API・
  CLI コマンドの仕様」と明記し、対象外として「idd-claude 内部の既存仕様・既存実装」「些末な
  書式・命名選択」を列挙
- 2.4 — 「### 検索結果のリンク記録（推奨止め）」サブセクションに「検索結果のリンクを
  `design.md` の該当セクション本文または `## Supporting References` 等の optional セクションに
  残すことを **推奨**します」と記述
- 2.5 — 同サブセクションに「義務化はしません。リンクを記録するか否かは Architect の裁量に
  委ねます（記録の有無を理由に design-review-gate で reject しません）」と明記
- 3.1 — reviewer 自身で `diff -r .claude/agents repo-template/.claude/agents` を実行し、出力が
  「agents OK」のみ（差分なし）であることを確認
- 3.2 — reviewer 自身で `diff -r .claude/rules repo-template/.claude/rules` を実行し、出力が
  「rules OK」のみ（差分なし）であることを確認
- 3.3 — impl-notes.md の「確認事項（PjM への申し送り）」セクションに、PR 本文の「確認事項」へ
  byte 一致検証コマンドと結果を記載すべき旨が明記されている。実 PR 本文への記載は PjM 段階
  の責務であり、Implementer の責務範囲は満たされている
- 4.1 — architect.md の diff は `# 行動指針` の直前に新節を挿入するのみで、既存セクション
  （要件読み込み手順 / design.md / tasks.md テンプレート / 自己レビューゲート参照 / Budget
  overflow 対応等）への編集は無い
- 4.2 — design-principles.md の diff は `## アプローチ` と `## 警告: 1000 行を超えたら複雑すぎる`
  の間に新節を挿入するのみで、既存セクション（目的 / アプローチ / 警告 1000 行 / セクション
  順序 / 必須セクション表 / Optional / File Structure Plan / 参考）への編集は無い
- 4.3 — `git diff --stat main..HEAD -- .claude/rules/ears-format.md .claude/rules/design-review-gate.md .claude/rules/tasks-generation.md .claude/rules/feature-flag.md .claude/rules/issue-dependency.md .claude/rules/requirements-review-gate.md local-watcher/bin/`
  の出力が空であることを確認（他ルールファイル・watcher は未編集）
- NFR 1.1 — diff 範囲は markdown ドキュメントのみ。env var 名・ラベル名・cron 登録文字列は
  変更されていない
- NFR 1.2 — `local-watcher/bin/` への編集は無い（上記 4.3 の diff 確認に含まれる）
- NFR 1.3 — 既存 design.md 群への遡及書き換えは行われていない
- NFR 2.1 — 追加された両節は日本語ベースで記述されている
- NFR 2.2 — 識別子・コマンド名・ファイルパス・ツール名（`design.md` / `requirements.md` /
  `local-watcher/bin/` / `Supporting References` 等）は英語固定の表記を維持

## Findings

なし

## Summary

すべての numeric requirement ID（Req 1.1〜1.5, 2.1〜2.5, 3.1〜3.3, 4.1〜4.3 および
NFR 1.1〜1.3, 2.1〜2.2）が diff 内容で観測可能にカバーされており、boundary 逸脱も無い。
本実装は markdown ドキュメントのみの編集でテスト対象となるコードパスが存在しないため、
missing test 観点は適用されない。root と repo-template の byte 一致も reviewer 自身で再検証済み。

RESULT: approve
