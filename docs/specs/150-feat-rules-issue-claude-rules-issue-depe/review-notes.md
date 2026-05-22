# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-150-impl-feat-rules-issue-claude-rules-issue-depe
- HEAD commit: f4405d0c46a89ef03cacc65e9623014a0ba83b3f
- Compared to: main..HEAD
- 変更ファイル: 8 件 / 743 行追加（うち実体変更 6 件、spec 配下が `requirements.md` /
  `impl-notes.md` の 2 件）
- Feature Flag Protocol: 本 repo CLAUDE.md に `## Feature Flag Protocol` 節は不在 →
  opt-out 既定として解釈し、flag 観点の確認は適用しない

## Verified Requirements

- 1.1 ファイル存在 — `.claude/rules/issue-dependency.md`（164 行）をリポジトリルートから相対配置
- 1.2 関係種別 5 種 — `.claude/rules/issue-dependency.md:18-24` の「関係種別（canonical 5 種）」
  表で `Depends on` / `Parent` / `Split from` / `Sibling` / `Related` を列挙
- 1.3 意味記述・ブロッキング性 — 同表に「意味」「ブロッキング性」列を併記
- 1.4 canonical 配置場所 — `.claude/rules/issue-dependency.md:30-51`「canonical 配置場所」節で
  `## 関連` / `## Related` を明示
- 1.5 複数値の表記 — `.claude/rules/issue-dependency.md:53-66` でスペース区切り canonical /
  カンマ区切り許容を表で例示
- 1.6 互換 alias マッピング — `.claude/rules/issue-dependency.md:68-79` 表に 5 alias を列挙
- 1.7 逆ブロッキング扱い — `.claude/rules/issue-dependency.md:81-93` で `Blocks:` 非採用と
  被ブロッキング側 `Depends on:` 表現を明文化
- 1.8 tool-parse 必須度 — `.claude/rules/issue-dependency.md:18-24` 表「tool-parse」列で
  必須 / 推奨 / informational を併記
- 1.9 適用範囲 — `.claude/rules/issue-dependency.md:95-101` で新規適用 / retrofit 不要 /
  should レベルを明示
- 2.1 repo-template 配置 — `repo-template/.claude/rules/issue-dependency.md`（164 行）配置
- 2.2 内容整合 — `diff .claude/rules/issue-dependency.md repo-template/.claude/rules/issue-dependency.md`
  が完全一致（差分ゼロ）
- 3.1 repo-template/CLAUDE.md 追記 — `repo-template/CLAUDE.md:204` 共通ルールテーブルに行追加
- 3.2 本 repo CLAUDE.md 追記 — `CLAUDE.md:201` 共通ルールテーブルに行追加
- 3.3 言語方針との整合 — `.claude/rules/issue-dependency.md:103-114`「言語方針との整合」節で
  キー部英語固定の根拠を明示
- 4.1 product-manager.md 追記 — `repo-template/.claude/agents/product-manager.md:93-106` に
  新規セクション「Issue 依存表現の明記（canonical 記法）」を追加し `shall` レベルで明記
- 4.2 ルール参照リンク — 同セクション冒頭で `[.claude/rules/issue-dependency.md](../rules/issue-dependency.md)`
  への相対パスリンクを設置
- 5.1 Triage プロンプト追記 — `local-watcher/bin/triage-prompt.tmpl:49-63` に新規セクション
  「Issue 本文の ## 関連 / 依存表現の精査」を追加、`.claude/rules/issue-dependency.md` への参照を含む
- 5.2 repo-template 同期 — `repo-template/local-watcher/` は存在せず、要件本文どおり「将来追加時の
  整合制約として記録」で n/a
- 6.1 alias 等価扱い宣言 — `.claude/rules/issue-dependency.md:68-79` 互換 alias マッピング表 +
  「適用範囲」節で明示
- 6.2 retrofit 不要 — `.claude/rules/issue-dependency.md:98-99` で明文化
- 6.3 既存ドキュメント後方互換 — `git diff main..HEAD -- .claude/rules/` は新規ファイル追加のみ、
  既存ファイル内容・配置・参照リンク変更なし。CLAUDE.md / repo-template/CLAUDE.md は 1 行追加のみ
- 7.1 本 repo 配置 — `.claude/rules/issue-dependency.md` をリポジトリルートに配置
- 7.2 内容差分制約 — 本 repo 版と repo-template 版が完全一致（差分ゼロ）で制約上限内
- NFR 1.1 既存 alias 表記互換維持 — rule 内で alias を canonical と等価扱い、retrofit 不要を明文化
- NFR 1.2 watcher 契約変更なし — `local-watcher/bin/issue-watcher.sh` は本 PR で変更なし。
  triage-prompt.tmpl は文字列追記のみで `{{NUMBER}}` / `{{TITLE}}` / `{{URL}}` / `{{FILE}}` の
  placeholder 4 種を保持。env var / exit code / ラベル遷移契約に変更なし
- NFR 2.1 単一参照点 — 関係種別・配置場所・alias マッピングは issue-dependency.md 1 ファイル内に閉じる
- NFR 2.2 行数 200 行以内 — 164 行（200 行制限を充足）
- NFR 2.3 例示の具体性 — `.claude/rules/issue-dependency.md:116-158` に canonical / alias /
  複数値 / 逆ブロッキングの 4 例を記載
- NFR 3.1 README/CLAUDE.md 整合 — CLAUDE.md（本 repo / repo-template 双方）を同 PR 内で更新。
  README.md は新規ルール導入で本文挙動説明と直接接続する箇所が無いため未更新（impl-notes.md
  「確認事項 1」に残課題として記録）。要件文言「本ルールの挙動が変わるとき」の解釈として、
  新規追加は「挙動変更」に該当しないと判断可能で、AC 観点では充足扱いとする
- NFR 3.2 出典明記 — `.claude/rules/issue-dependency.md:163-164` で cc-sdd 原典に対応物なし=
  idd-claude 独自規約と明示

## Findings

なし

## Summary

要件 1.1〜7.2 および NFR 1.1〜3.2 のすべてが、新規 2 ファイル（本 repo / repo-template の
`issue-dependency.md`）+ 4 ファイル追記（CLAUDE.md 2 件 / product-manager.md / triage-prompt.tmpl）
で確認可能。`tasks.md` / `design.md` は本 Issue では生成されていないが、要件は文書追加・追記の
スコープに閉じるため `_Boundary:_` 違反の懸念はなく、変更ファイルは全て要件に対応する自然な
配置に収まっている。Feature Flag Protocol 節は本 repo に存在せず opt-out 既定が適用される。
本実装は文書追加であり、新規 behavior コードを伴わないため missing test カテゴリは適用外。

RESULT: approve
