# 実装ノート: Issue #150 — `.claude/rules/issue-dependency.md` の追加

## 実装概要

Issue 間依存関係の canonical 記法を `.claude/rules/issue-dependency.md` として正式ルール化し、
repo-template への配布、プロジェクト憲章 / PM agent 指針 / Triage プロンプトへの参照追記を
行った。

### 追加・編集ファイル一覧と要件 ID マッピング

| ファイル | 種別 | 対応する要件 ID |
|---|---|---|
| `.claude/rules/issue-dependency.md` | 新規 | 1.1〜1.9, 6.1〜6.3, 7.1, NFR 2.1〜2.3, 3.2 |
| `repo-template/.claude/rules/issue-dependency.md` | 新規 | 2.1, 2.2, 7.2 |
| `CLAUDE.md` | 編集（テーブル 1 行追加） | 3.2, NFR 3.1 |
| `repo-template/CLAUDE.md` | 編集（テーブル 1 行追加） | 3.1, NFR 3.1 |
| `repo-template/.claude/agents/product-manager.md` | 編集（新規セクション追加） | 4.1, 4.2 |
| `local-watcher/bin/triage-prompt.tmpl` | 編集（新規セクション追加） | 5.1 |

### Commit hash 一覧（main からの差分）

```
8f95d08 docs(rules): add issue-dependency.md for cross-Issue relationship convention
3b788b3 docs(rules): distribute issue-dependency.md via repo-template
63d4b23 docs(claude): reference issue-dependency rule from CLAUDE.md
982215b docs(agent): require canonical Issue dependency notation in product-manager
2862e51 docs(watcher): reference issue-dependency rule in triage prompt
```

## 採用した判断（人間判断既定値）

requirements.md `## 確認事項` の 3 件は人間判断未確定だが、Issue #150 本文の「提案」/
「確認事項」セクションが推奨案を明示しているため、本実装では **Issue body 推奨案** を
ソースとして採用した（Developer の独断ではない）。

1. **canonical 言語 = 英語**
   - canonical 記法: `Depends on:` / `Parent:` / `Split from:` / `Sibling:` / `Related:`
   - 理由: 機械パースの robustness と OSS 汎用性。CLAUDE.md 言語方針「識別子・コマンド名・
     env var 名は英語固定」枠の延長として、`.claude/rules/issue-dependency.md` の
     「言語方針との整合」節に明示
   - alias（`前提依存:` / `Blocked by:` / `親 Issue:` / `Umbrella:` / `分割元:`）は等価扱い

2. **Parent と Umbrella を Parent に統一**
   - 関係種別表で `Parent: #N` のみ canonical 採用し、`Umbrella: #N` は alias として等価扱い
   - 区別が必要な場合は本文中の説明文で補足する運用とした（関係種別の語彙集合を増やさない）

3. **PM agent への適用は `shall`（PM 自身への規約）レベル、ただし強制 lint は導入しない**
   - PM agent 指針本文では「**shall** レベル」と明示したが、CI lint / pre-commit hook 等の
     自動チェックは Issue スコープ外として除外（requirements.md「除外」と整合）
   - 既存 Issue の retrofit は要求せず、新規 Issue 起票時のみ canonical を選択する

## 充足状況（AC マッピング）

| AC | 充足 | 担保箇所 |
|---|---|---|
| 1.1 ファイル存在 | ✓ | `.claude/rules/issue-dependency.md` 配置 |
| 1.2 関係種別 5 種 | ✓ | 「関係種別（canonical 5 種）」表に Depends on / Parent / Split from / Sibling / Related を列挙 |
| 1.3 意味とブロッキング性 | ✓ | 同表に「意味」「ブロッキング性」列を併記 |
| 1.4 canonical 配置場所 | ✓ | 「canonical 配置場所」節で `## 関連` / `## Related` を明示 |
| 1.5 複数値の表記 | ✓ | 「複数値の表記」節でスペース区切り canonical / カンマ区切り許容を表で例示 |
| 1.6 互換 alias マッピング | ✓ | 「互換 alias マッピング」表に 5 種を列挙 |
| 1.7 逆ブロッキングの扱い | ✓ | 「逆ブロッキング」節で被ブロッキング側 `Depends on:` での表現を明示 |
| 1.8 tool-parse 必須度 | ✓ | 関係種別表「tool-parse」列に 必須 / 推奨 / informational を併記 |
| 1.9 適用範囲 | ✓ | 「適用範囲」節で新規適用 / retrofit 不要 / should 強制を明示 |
| 2.1 repo-template 配置 | ✓ | `repo-template/.claude/rules/issue-dependency.md` を本 repo 版と同一内容で配置（diff: identical） |
| 2.2 内容整合 | ✓ | diff 検証で両者一致を確認 |
| 3.1 repo-template/CLAUDE.md 追記 | ✓ | 共通ルールテーブルに 1 行追加 |
| 3.2 本 repo CLAUDE.md 追記 | ✓ | 共通ルールテーブルに 1 行追加 |
| 3.3 言語方針との整合 | ✓ | 「言語方針との整合」節で識別子枠としての英語固定を明示 |
| 4.1 product-manager.md 追記 | ✓ | 「Issue 依存表現の明記（canonical 記法）」セクションを追加 |
| 4.2 ルール参照リンク | ✓ | 同セクション冒頭で `.claude/rules/issue-dependency.md` への内部相対パスリンクを設置 |
| 5.1 Triage プロンプト | ✓ | 「Issue 本文の ## 関連 / 依存表現の精査」セクションを判定基準と出力形式の間に追加 |
| 5.2 repo-template の同期 | n/a（将来制約） | `repo-template/local-watcher/` は存在せず、本要件は将来追加時の整合制約として記録（requirements.md 5.2 本文と一致）|
| 6.1 alias 等価扱い宣言 | ✓ | 「互換 alias マッピング」節と「適用範囲」節で明示 |
| 6.2 retrofit 不要 | ✓ | 「適用範囲」節で明文化 |
| 6.3 既存ドキュメント後方互換 | ✓ | 既存 `.claude/rules/*.md` は内容・配置・参照リンクとも変更なし（CLAUDE.md は新規 1 行追加のみで既存行を破壊せず） |
| 7.1 本 repo 配置 | ✓ | `.claude/rules/issue-dependency.md` を repo ルートから相対配置 |
| 7.2 内容差分制約 | ✓ | 本 repo 版と repo-template 版は完全一致（プロジェクト固有例示差分も無し）|
| NFR 1.1 既存 alias 互換維持 | ✓ | rule 内で alias を canonical と等価と明文化、既存 Issue の retrofit は不要 |
| NFR 1.2 watcher 契約変更なし | ✓ | issue-watcher.sh の env var / exit code / ラベル遷移契約は変更していない（triage-prompt.tmpl への文言追記のみ、`bash -n` で構文確認済み）|
| NFR 2.1 単一参照点 | ✓ | 関係種別 / 配置場所 / alias マッピングはすべて issue-dependency.md 1 ファイル内に閉じる |
| NFR 2.2 行数 200 行以内 | ✓ | 164 行（本 repo / repo-template 同値） |
| NFR 2.3 例示の具体性 | ✓ | 「例示」節に canonical / alias / 複数値 / 逆ブロッキングの 4 例を記載 |
| NFR 3.1 README/CLAUDE.md 整合 | 部分 | 本 PR で CLAUDE.md（本 repo / repo-template）は更新済。README.md は本 Issue では更新対象外（README は idd-claude 全体設計の主要文書だが本ルールは agent 内部参照に閉じるため Triage / 設計判断としてスコープ外）。下記「確認事項」参照 |
| NFR 3.2 出典明記 | ✓ | rule 末尾「参考」節で cc-sdd 原典に対応物なし＝idd-claude 独自規約と明示 |

## テスト・検証結果

### 静的解析

- `bash -n local-watcher/bin/issue-watcher.sh` — 構文 OK
- `shellcheck` は本 Issue で bash スクリプトを変更していないため不要（既存の SC2317 警告は
  triage-prompt.tmpl とは無関係の issue-watcher.sh 既存箇所で、本実装の評価対象外）
- `actionlint` は `.github/workflows/` を変更していないため不要

### 行数確認

```
164 .claude/rules/issue-dependency.md
164 repo-template/.claude/rules/issue-dependency.md
```

両方とも 200 行以内（NFR 2.2 充足）。

### 内容整合性

```
diff .claude/rules/issue-dependency.md repo-template/.claude/rules/issue-dependency.md
# → identical（差分なし）
```

要件 2.2 / 7.2 充足。

### スモーク（参照追記の grep 確認）

`grep -nE "issue-dependency"` の結果:

- `CLAUDE.md:201` — 共通ルールテーブル行
- `repo-template/CLAUDE.md:204` — 共通ルールテーブル行
- `repo-template/.claude/agents/product-manager.md:97` — 新規セクション内の参照リンク
- `local-watcher/bin/triage-prompt.tmpl:52` — 新規セクション内の参照リンク

すべての必須追記箇所に参照が反映されている。

### プレースホルダ互換性（triage-prompt.tmpl）

`{{NUMBER}}` / `{{TITLE}}` / `{{URL}}` / `{{FILE}}` の 4 種が変更前と同じ位置に保持されている
ことを `grep -nE '\{\{[A-Z_]+\}\}'` で確認。issue-watcher.sh の placeholder 展開ロジック
（sed 置換）への影響なし。

### CLAUDE.md 言語方針との整合

`.claude/rules/issue-dependency.md` 「言語方針との整合」節で、canonical 記法のキー部分を
「識別子・コマンド名・env var 名と同じ枠」として英語固定とする根拠を CLAUDE.md「言語方針」
の「種別ごとの言語選択」表（"識別子・コマンド名・ファイルパス・env var 名・ラベル名" 行）
と整合させて記述した。Issue 本文の説明文・補足は日本語ベースのままで構わない旨も明示。

## 確認事項（残課題）

1. **README.md への参照追記の要否**: NFR 3.1 は「本ルールの挙動が変わるとき同 PR で更新」と
   規定するが、本 PR は新規ルール導入であり README の本文挙動説明と直接接続する箇所が無い
   ため、本 PR では README 編集を行わなかった。レビュワーが「将来の発見性のため README にも
   `.claude/rules/issue-dependency.md` への 1 行参照を入れるべき」と判断する場合、追加 commit
   で対応可能。要件 NFR 3.1 の「挙動が変わるとき」の解釈に依存するため、本セクションに残課題
   として記録する。

2. **Issue body の確認事項 3 件の最終確定**: Step 1 で採用した 3 件の人間判断既定値
   （canonical=英語 / Parent と Umbrella の統合 / should レベル）は Issue body の推奨案を
   ソースとしているが、Issue body 上でこれらが「人間レビュー済み・確定」とは明記されていない。
   PR レビュー時に人間が differ する場合は、本 PR を `needs-iteration` で差し戻して
   再実装する想定（rule ファイル本体 + CLAUDE.md / product-manager.md / triage-prompt.tmpl の
   4 箇所を同時に修正する形になる）。

3. **既存 spec 内の `_Depends:_` 表記との関係**: tasks.md の `_Depends:_` は **同一 tasks.md
   内のタスク ID（例: `2.1`）への参照**で、Issue 番号 `#N` は参照しない別レイヤである旨を
   rule 末尾「参考」節で明示したが、エージェントが混同しないかは運用観察が必要。
