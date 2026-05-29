# Implementation Notes #268

## 変更ファイル

本実装は markdown ドキュメントのみの編集で、コード変更はありません。

- `.claude/agents/architect.md` — `# 行動指針` の直前に `# 外部仕様の不確実性を Web 検索で解消する` 節を追加
- `repo-template/.claude/agents/architect.md` — 同上（byte 一致）
- `.claude/rules/design-principles.md` — `## アプローチ` と `## 警告: 1000 行を超えたら複雑すぎる` の間に `## 外部仕様の不確実性を Web 検索で解消する` 節を追加
- `repo-template/.claude/rules/design-principles.md` — 同上（byte 一致）

## byte 一致検証結果

最終 commit 直前に以下を実行し、両系統の差分が空であることを確認しました。

```
$ diff -r .claude/agents repo-template/.claude/agents && echo "agents byte-identical OK"
agents byte-identical OK
$ diff -r .claude/rules repo-template/.claude/rules && echo "rules byte-identical OK"
rules byte-identical OK
```

## 受入基準カバレッジ

| Requirement | カバー手段 |
|---|---|
| 1.1 | `.claude/agents/architect.md` に「外部仕様の不確実性を Web 検索で解消する」節を追加 |
| 1.2 | `repo-template/.claude/agents/architect.md` に root と同一内容（byte 一致）の節を追加 |
| 1.3 | 当該節「いつ Web 検索を行うか」に「不確実な箇所について Web 検索で一次情報を確認する」を明記 |
| 1.4 | 当該節「いつ Web 検索を行うか」に「idd-claude 内部の既存仕様・既存実装の場合は Web 検索を必須とせず既存ドキュメント・既存コードの参照を優先する」を明記 |
| 1.5 | 当該節「いつ Web 検索を行わないか（最小限の運用）」に「不明な場合・新規ツール導入時に限定して必要最小限に留める」を明記 |
| 2.1 | `.claude/rules/design-principles.md` に「外部仕様の不確実性を Web 検索で解消する」節を追加 |
| 2.2 | `repo-template/.claude/rules/design-principles.md` に root と同一内容（byte 一致）の節を追加 |
| 2.3 | 当該節「検索対象のスコープ」に「対象は外部ツール・ライブラリ・API・CLI コマンドの仕様」と限定明記 |
| 2.4 | 当該節「検索結果のリンク記録（推奨止め）」に「リンクを design.md に残すことを推奨する」と記述 |
| 2.5 | 同節に「義務化はしない。リンクを記録するか否かは Architect の裁量に委ねる」と明記 |
| 3.1 | `diff -r .claude/agents repo-template/.claude/agents` が空であることを確認（上記検証結果） |
| 3.2 | `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認（上記検証結果） |
| 3.3 | PR 本文の「確認事項」セクションに byte 一致検証コマンドと結果を記載する旨を後段 PjM 向けに impl-notes に明示（本セクション参照） |
| 4.1 | architect.md の既存セクション（要件読み込み手順, design.md / tasks.md テンプレート, 自己レビューゲート, Budget overflow 対応等）を一切編集せず、新規節 `# 外部仕様の不確実性を Web 検索で解消する` を `# 行動指針` の直前に挿入のみ |
| 4.2 | design-principles.md の既存セクション（目的, アプローチ, 警告 1000 行, セクション順序の柔軟性, 必須セクション表, Optional セクション, File Structure Plan の書き方, 参考）を一切編集せず、新規節 `## 外部仕様の不確実性を Web 検索で解消する` を `## アプローチ` と `## 警告: 1000 行を超えたら複雑すぎる` の間に挿入のみ |
| 4.3 | `.claude/rules/ears-format.md` / `design-review-gate.md` / `tasks-generation.md` / `feature-flag.md` / `issue-dependency.md` / `requirements-review-gate.md` は本変更で一切編集していない |
| NFR 1.1 | 既存 env var 名・ラベル名・cron 登録文字列は一切変更していない |
| NFR 1.2 | `local-watcher/bin/*.sh` は一切編集していない |
| NFR 1.3 | 過去の `design.md` への遡及的な書き換えは行っていない |
| NFR 2.1 | 追加節は日本語ベースで記述（reasoning 効率は CLAUDE.md「言語方針」に準拠） |
| NFR 2.2 | 識別子・コマンド名・ファイルパス・ツール名（`design.md` / `requirements.md` / `local-watcher/bin/` / `Supporting References` 等）は英語固定の表記を維持 |

## 確認事項（PjM への申し送り）

- 後段の PR 作成時、本文の「確認事項」セクションに以下を含めること:
  - `diff -r .claude/agents repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` が空（byte 一致）であることを示す（Req 3.3）
  - 既存節の意味変更がない（挿入のみで既存テキストは未変更）ことをレビュワーに明示
- Out of Scope（developer.md / product-manager.md / reviewer.md / project-manager.md / debugger.md への Web 検索指示追加, 新規 MCP サーバ等）は本 PR に含まれていない

## 補足

- 設計判断: 節の挿入位置は `architect.md` では `# 行動指針` の直前（外部仕様検証は行動指針の前提条件であるため）、`design-principles.md` では `## アプローチ` の直後（設計の全体方針の補足として早期に提示するため）を選択した。本選択は要件には現れていない裁量だが、既存節の意味を変えないという Req 4.1 / 4.2 の制約は満たす。
- byte 一致の維持: 初回 edit で repo-template 側の括弧を半角に書き間違えたため、初回 diff で差分検出 → 全角括弧に修正 → 再 diff で OK というワークフローを経た。両系統の最終状態は byte 一致。

STATUS: complete
