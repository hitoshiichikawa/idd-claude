# 要件定義: Issue #150 — Issue 間依存関係の表現フォーマットを `.claude/rules/issue-dependency.md` として正式ルール化

## 概要

idd-claude では tasks.md 内のタスク間依存（`_Depends:_`）は `.claude/rules/tasks-generation.md`
で正式ルール化されているが、**Issue 間 / cross-Issue の依存関係を Issue 本文で表現する
フォーマット規約は存在しない**。結果として既存 Issue では `Depends on:` / `前提依存:` /
`Parent:` / `Umbrella:` / `分割元:` / `Blocks:` / `Related:` / `Sibling:` が混在しており、
人間の読み取りと将来的な自動化（依存グラフ可視化、Triage プロンプトの精査、auto-dev の
ブロッキング判定など）の双方で不安定さを生んでいる。

本 Issue では `.claude/rules/issue-dependency.md`（および `repo-template/.claude/rules/issue-dependency.md`）
を新規追加し、関係種別と canonical 記法・配置ルール・互換 alias を文書として固定化する。
さらに PM agent 指針 / プロジェクト憲章 / Triage プロンプトに参照を追記し、新規起票時に
canonical 記法が選択される導線を整える。実装語彙には踏み込まず、本要件は markdown
ルールファイル群の追加・追記のみを範囲とする。

## ステークホルダーと利用シナリオ

- **PM agent**: Issue 起票・分割・要件化時に、依存・親子関係を canonical 記法で本文に明記する
- **Triage agent**: Issue 本文の `## 関連` / `Depends on:` を精査し、ブロッキング状態の有無を判定する
- **Architect / Developer agent**: cross-Issue 依存を読み取って impl の順序・前提理解を獲得する
- **人間の運用者**: PR レビュー・Issue 棚卸し時に、関係種別を一貫した表現で読み取れる
- **既存 Issue の起票者**: alias 記法（`前提依存:` / `Blocked by:` / `Umbrella:` 等）で書いた
  既存 Issue が canonical と等価に扱われる（retrofit 不要）

## スコープ

### 包含

- `.claude/rules/issue-dependency.md`（本 repo の self-hosting 用）の新規追加
- `repo-template/.claude/rules/issue-dependency.md`（installed consumer repo 配布用）の新規追加
- 関係種別（Depends on / Parent / Split from / Sibling / Related）の canonical 定義と意味記述
- canonical 配置場所（`## 関連` セクション、英語 repo では `## Related`）の明示
- 複数値の書き方（1 関係 = 1 行 + 番号スペース区切りを canonical、`Depends on: #1, #2, #3` カンマ区切り併記許容）
- 互換 alias とマッピング（`前提依存:` / `Blocked by:` / `親 Issue:` / `Umbrella:` / `分割元:`）
- `repo-template/.claude/agents/product-manager.md` への指針追記（Issue 起票時の依存表現明記）
- `repo-template/CLAUDE.md` の「各エージェントが参照する共通ルール」テーブルへの参照追記
- 本 repo `CLAUDE.md` および `local-watcher/bin/triage-prompt.tmpl` への参照追記（self-hosting 反映）
- 後方互換性: 既存 alias 形式は canonical と等価扱い

### 除外

- 既存 Issue 本文の retrofit（過去 Issue を canonical に書き換える作業）
- ラベル運用ルール化（Issue #146 のスコープ）
- GitHub native の `Closes #N` / `Fixes #N` の取り扱い変更
- 依存グラフの可視化ツール（将来検討）
- watcher / Triage プロンプトの **判定ロジック実装変更**（プロンプト本文への参照追記のみが本 Issue のスコープ）
- 本 ruleset を強制するための CI lint / pre-commit hook 等の自動チェック導入
- `repo-template` 以外の場所（local-watcher template 等）への配布

## 要件

### 1. ルールファイル本体（`.claude/rules/issue-dependency.md`）の必須内容

**Objective:** As a 規約利用者（PM / Triage / 人間運用者）, I want Issue 間依存の canonical 記法・意味・配置場所・互換 alias を 1 つの参照ファイルで読み取れる, so that 表現の揺れに迷わず統一フォーマットで Issue を書ける。

#### 1.1 ファイル存在

The repo shall `.claude/rules/issue-dependency.md` をリポジトリルートからの相対パスで配置する。

#### 1.2 関係種別 5 種の定義

The `issue-dependency.md` shall 関係種別として `Depends on` / `Parent` / `Split from` / `Sibling` / `Related` の 5 種類を canonical 記法として明記する。

#### 1.3 各関係種別の意味記述

The `issue-dependency.md` shall 各関係種別について「意味（何を示す関係か）」と「ブロッキング性の有無」を本文または表形式で記述する。

#### 1.4 canonical 配置場所

The `issue-dependency.md` shall Issue 本文の `## 関連` セクション（英語 repo では `## Related`）を canonical 配置場所として明示する。

#### 1.5 複数値の表記

The `issue-dependency.md` shall 「1 関係 = 1 行 + 番号スペース区切り（例: `Depends on: #1 #2 #3`）」を canonical として、かつカンマ区切り（例: `Depends on: #1, #2, #3`）も許容形式として例示する。

#### 1.6 互換 alias マッピング

The `issue-dependency.md` shall 互換 alias（`前提依存:` / `Blocked by:` / `親 Issue:` / `Umbrella:` / `分割元:`）と canonical（`Depends on:` / `Parent:` / `Split from:`）の対応を表または箇条書きで明記する。

#### 1.7 逆ブロッキングの扱い

The `issue-dependency.md` shall 逆ブロッキング関係（`Blocks: #N`）を Issue 本文に書かず、被ブロッキング側の `Depends on:` で表現する旨を明記する。

#### 1.8 tool-parse 必須度の明示

The `issue-dependency.md` shall 各関係種別について「tool-parse 必須 / 推奨 / informational のいずれか」のレベルを明示する。

#### 1.9 適用範囲の明示

The `issue-dependency.md` shall 本ルールが「新規 Issue 起票時に適用される」ことと「既存 Issue の retrofit を要求しない」ことを明文化する。

### 2. repo-template 配布

**Objective:** As a idd-claude を install した consumer repo の運用者, I want 本ルールが repo-template から配布されて自分の repo の `.claude/rules/` に同じ規約が配置される, so that 複数プロジェクト間で Issue 依存表記が統一できる。

#### 2.1 repo-template 配置

The `repo-template/.claude/rules/issue-dependency.md` shall `.claude/rules/issue-dependency.md` と等価な内容で配置される。

#### 2.2 本 repo と consumer repo の内容整合

The `repo-template/.claude/rules/issue-dependency.md` and the `.claude/rules/issue-dependency.md` shall 同一の関係種別定義・配置ルール・alias マッピングを含む（プロジェクト固有の例示差分は許容するが、canonical 定義と alias マッピングは一致させる）。

### 3. プロジェクト憲章（CLAUDE.md）への参照追記

**Objective:** As a エージェント（PM / Triage / Architect / Developer / Reviewer）, I want 共通ルールテーブルから `issue-dependency.md` の存在と用途を発見できる, so that 作業前に正しいルールを Read で読み込める。

#### 3.1 repo-template/CLAUDE.md への追記

The `repo-template/CLAUDE.md` shall 「各エージェントが参照する共通ルール」テーブルに `issue-dependency.md` の行を追加し、参照エージェントと役割を明記する。

#### 3.2 本 repo CLAUDE.md への追記

The `CLAUDE.md` shall self-hosting の反映として、同じく「各エージェントが参照する共通ルール」テーブルに `issue-dependency.md` の行を追加する。

#### 3.3 言語方針との整合

The `issue-dependency.md` shall CLAUDE.md の「言語方針」と矛盾しない記述（canonical 表記の言語選択と Issue 本文の出力言語の関係）を含む。

### 4. PM agent 指針への追記

**Objective:** As a PM agent, I want 自分の指示書（`product-manager.md`）に「Issue 起票時に依存表現を canonical で書く」ことが明記されている, so that 起票・分割・要件化のたびに参照すべき規約を見落とさない。

#### 4.1 repo-template/.claude/agents/product-manager.md への追記

The `repo-template/.claude/agents/product-manager.md` shall PM agent の指針として「Issue 起票・分割時に `## 関連` セクションを設け、`Depends on:` / `Parent:` / `Split from:` / `Sibling:` / `Related:` の canonical 記法で依存を明記する」要求を含むセクションを追加する。

#### 4.2 ルール参照リンク

The `repo-template/.claude/agents/product-manager.md` shall 追記セクションから `.claude/rules/issue-dependency.md` への参照リンクを含む。

### 5. Triage プロンプトへの追記

**Objective:** As a Triage agent, I want プロンプト本文から `## 関連` / `Depends on:` 精査の指針と canonical ルールの参照先を発見できる, so that Issue 本文の依存表現を一貫した基準で読み取れる。

#### 5.1 本 repo Triage プロンプト

The `local-watcher/bin/triage-prompt.tmpl` shall 判定基準として `## 関連` セクション・`Depends on:` パターンの精査指針および `.claude/rules/issue-dependency.md` への参照を含む。

#### 5.2 repo-template の同期

Where `repo-template/` 配下に Triage プロンプトの template が存在する場合, the repo shall それを本 repo と等価な内容に同期する（本要件確定時点では `repo-template/` 配下に triage template は存在しないため、本項は将来追加時の整合制約として記録する）。

### 6. 後方互換性

**Objective:** As a 既存 Issue の起票者および既存 Issue を読むエージェント, I want 過去に書かれた alias 形式（`前提依存:` / `Blocked by:` / `Umbrella:` 等）が canonical と等価扱いになる, so that 既存 Issue の書き換え（retrofit）作業が不要になる。

#### 6.1 alias の等価扱い宣言

The `issue-dependency.md` shall 互換 alias 形式が canonical と等価に扱われる旨を明文化する。

#### 6.2 retrofit 不要の明文化

The `issue-dependency.md` shall 既存 Issue 本文の書き換え（retrofit）を本ルール導入の必須前提としない旨を明文化する。

#### 6.3 既存ドキュメントの後方互換

While 本 Issue のルール追加を行うとき, the repo shall 既存の `.claude/rules/*.md` ファイルの内容・配置場所・参照リンクを破壊的に変更しない。

### 7. self-hosting 反映

**Objective:** As a idd-claude 自身の運用者, I want 本 repo（idd-claude）にも同じルールが配置され、self-hosting のワークフローがそれに従って動く, so that 本 repo の Issue 起票・Triage・PM 起動でも canonical 記法が選択される。

#### 7.1 本 repo `.claude/rules/issue-dependency.md`

The repo shall `.claude/rules/issue-dependency.md` を本 repo のリポジトリルートに配置する（`repo-template/` 側と同期した内容）。

#### 7.2 self-hosting と repo-template の差分管理

The repo shall 本 repo `.claude/rules/issue-dependency.md` と `repo-template/.claude/rules/issue-dependency.md` の内容差分が canonical 定義・alias マッピングを越えない範囲に収まることを保つ。

## 非機能要件

### NFR 1: 後方互換性

#### 1.1 既存 alias 表記の互換維持

The repo shall 既存の `前提依存:` / `Blocked by:` / `親 Issue:` / `Umbrella:` / `分割元:` の表記を含む既存 Issue 本文に対して、本ルール導入後も canonical と等価として扱う運用を保つ。

#### 1.2 既存 watcher / 自動化への影響なし

The repo shall 本ルール追加によって `local-watcher/bin/issue-watcher.sh` の env var / exit code / ラベル遷移契約を変更しない。

### NFR 2: 可読性・保守性

#### 2.1 単一の参照点

The `issue-dependency.md` shall 関係種別・配置場所・alias マッピングの一次参照点として 1 ファイル内に閉じた構成を保つ。

#### 2.2 行数の節度

The `issue-dependency.md` shall ファイル全体の行数が 200 行以内に収まる（design-principles.md の「1000 行を超えたら複雑すぎる」より厳しい個別ルール水準）。

#### 2.3 例示の具体性

The `issue-dependency.md` shall canonical 表記・alias 表記・複数値表記について少なくとも各 1 件の具体例（実際の Issue 番号を仮置きでも可）を含む。

### NFR 3: ドキュメント整合性

#### 3.1 README / CLAUDE.md との整合

When 本ルールの挙動が変わるとき, the repo shall `README.md` と `CLAUDE.md`（本 repo / repo-template 双方）の参照記述を同 PR 内で更新する。

#### 3.2 cc-sdd 由来の出典明記

Where `.claude/rules/` 配下に他ルールと同様の出典脚注がある場合, the `issue-dependency.md` shall 同形式で参考リンクまたは出典を明記する（cc-sdd 原典に対応物が存在しない場合は idd-claude 独自規約として明示する）。

## 確認事項

以下は Issue 本文の「確認事項」に挙げられたまま、コメントで未解決の論点です。実装着手前に
人間判断を仰ぐ必要があります（PM agent としては推測で確定させず、本セクションに残します）。

1. **canonical 言語の選択**: 英語 (`Depends on:`) を canonical とすべきか、日本語 (`前提依存:`)
   を canonical とすべきか。Issue 本文では英語を canonical 案として提示しているが、CLAUDE.md の
   言語方針（「GitHub Issue / PR の本文・コメント・レビューコメント」は日本語ベース）との
   整合性をどう取るかを決定する必要がある。
2. **`Parent` と `Umbrella` の意味区別**: 統一すべきか分離すべきか。Issue 本文では両者を
   `Parent: #N` に統一する案だが、umbrella Issue（複数 sub-task をまとめる管理 Issue）と
   通常の親子関係を区別したいケースがあるかどうかを確認する必要がある。
3. **rule 適用範囲（強制 / 推奨）**: 新規 Issue を起票する際、canonical 記法を **強制（lint
   レベルで違反検出）** するか、**推奨（PM agent / 人間運用者の自主性に委ねる）** か。Out of
   Scope では「CI lint / pre-commit hook 等の自動チェック導入」を除外しているため、現状は
   推奨レベルが暫定的に成立するが、PM agent の指針セクション（要件 4.1）の trigger
   キーワードを `shall`（必須）にするか `should`（推奨）にするかは本確認事項の判断に依存する。
