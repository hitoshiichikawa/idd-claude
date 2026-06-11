# 実装ノート — Issue #327 / .claude/rules への paths: スコープ導入

## 概要

全 7 ルールファイル（`.claude/rules/` + `repo-template/.claude/rules/` の byte 一致同期）に
YAML frontmatter `paths:` を付与し、Claude Code のルール自動ロードを「全コンテキスト常時」から
「該当パスに触れるセッションのみ」の条件ロードへ切り替えた。本文（SPDX ヘッダ含む）は不変。

## 変更ファイル

1. `.claude/rules/{ears-format,requirements-review-gate}.md` → `paths: docs/specs/**/requirements.md`
2. `.claude/rules/{design-principles,design-review-gate}.md` → `paths: docs/specs/**/design.md`
3. `.claude/rules/tasks-generation.md` → `paths: docs/specs/**/tasks.md, docs/specs/**/design.md`
4. `.claude/rules/feature-flag.md` → `paths: .claude/rules/feature-flag.md`（自己参照 = 明示 Read 時のみ）
5. `.claude/rules/issue-dependency.md` → `paths: .claude/rules/issue-dependency.md`（同上）
6. `repo-template/.claude/rules/` — 上記と byte 一致同期
7. `README.md` — install 節（rules safe-overwrite の説明近傍）に Migration note を追加

各ファイルの frontmatter 直後に「条件ロード（#327）」の 1 行注意コメントを置き、将来の編集で
frontmatter が誤削除されないようにした（Req 1.4）。

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| Req 1.1 | 7 ファイル × 2 コピーの frontmatter | `head` 目視 + 下記 grep |
| Req 1.2 | 既存本文は cat 連結のみ（変更なし） | `git diff` が各ファイル先頭への追記のみであること |
| Req 1.3 | repo-template 同期 | `diff -r .claude/rules repo-template/.claude/rules` → 空 |
| Req 1.4 | frontmatter 直後の注意コメント | 各ファイル 6 行目 |
| Req 2.1 | agent 定義は不変 | `git diff --stat` に `.claude/agents` なし |
| Req 2.2 | triage-prompt.tmpl は不変 | 同上 |
| Req 3.1 | README Migration note | 文面確認 |
| NFR 1 | スクリプト変更なし | `git diff --stat` に .sh / .yml なし |
| NFR 2 | ルール本文セマンティクス不変（正準 regex を含む節は無変更） | 本文 diff なし |

## 検証結果

- `diff -r .claude/rules repo-template/.claude/rules` → 空（IN SYNC）
- 各ルールの消費者到達経路を棚卸し（スコープ化で孤児にならないことの確認）:
  - ears-format / requirements-review-gate → PM が明示 Read（product-manager.md）+ requirements.md に触れるセッションで自動付与
  - design-principles / design-review-gate → Architect が明示 Read（architect.md）+ design.md に触れる Developer / Reviewer で自動付与
  - tasks-generation → Architect 明示 Read + tasks.md / design.md に触れる Developer / Reviewer で自動付与
  - feature-flag → developer.md / reviewer.md の opt-in 条件付き明示 Read（本来の設計意図どおりに復帰）
  - issue-dependency → product-manager.md の明示参照 + triage-prompt.tmpl がパス記載とエイリアス要約をインライン保持（Triage は必要時に Read 可能）
  - ハーネス側の参照（`tc_count_tasks` / `design-review-gate` regex mirror 等）はコメントによる正準参照のみで、実行時にルールファイルを読まない（grep 確認）

## 設計上の判断

- **明示 Read を主経路として維持**: `paths` トリガーは「該当ファイルを読んだとき」に発火するため、
  新規に requirements.md / design.md を**作成**するセッション（PM / Architect の初回）では発火しない
  可能性がある。agent 定義の「必ず先に読む」指示を不変とすることで到達を保証し、`paths` は
  Developer / Reviewer 等の後段ロールへの自動付与として機能させる
- **自己参照スコープ（feature-flag / issue-dependency）**: 通常のファイル操作では発火せず、
  明示 Read したセッションにのみ付与される。Read のツール結果と二重になる軽微な重複は許容
  （対象は当該 1 セッションのみで、従来の「全コンテキスト常時」より大幅に小さい）
- **サブエージェントへの paths 適用**: 公式 docs はサブエージェントが「CLAUDE.md と rules を
  ロードする」と記すが、`paths` フィルタの適用有無は明記がない。フィルタが適用されない場合でも
  挙動は従来（常時ロード）と同じであり安全側

## 確認事項（PR レビュワー向け）

- 旧バージョンの Claude Code（`paths` 非対応）では frontmatter が無視され常時ロードが継続する
  可能性がある（劣化ではなく従来挙動の維持）。frontmatter ブロック自体が context に混入しても
  数行のため影響は無視できる
- 削減効果の実測は #325（Token Usage Report / PR #334）の merge 後、Triage / Stage C の
  `in=` / `cache_read=` の before/after で観測可能

## 派生タスク候補

- CLAUDE.md「エージェントが参照する共通ルール」表への条件ロード列の追記（#330 スリム化に内包予定）
