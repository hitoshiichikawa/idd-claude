# Design Document

## Overview

**Purpose**: idd-claude が実装パターンとして提示してきた「Feature Flag Protocol」（`if (flag) { 新挙動 } else { 旧挙動 }`）を、**プロジェクト単位で opt-in / opt-out できる規約として明文化**し、採用宣言したプロジェクトでのみ Implementer / Reviewer エージェントがその規約に従って動くようにする。これにより、未完成機能を main にマージしても既存挙動を壊さない選択肢を提供しつつ、flag 残存による技術債を嫌うプロジェクトには負担を強いない。

**Users**: idd-claude を導入する各 consumer repo の保守者（採否を決める）と、Implementer / Reviewer エージェント（宣言を読み取って挙動を切り替える）。

**Impact**: 現状は Feature Flag Protocol への言及が `repo-template/CLAUDE.md` に存在せず、エージェントが flag 適用するかどうかは未定義（実質 opt-out）。本変更は (a) `repo-template/CLAUDE.md` に採否宣言節を追加し、(b) `.claude/rules/feature-flag.md` を新設して規約詳細を定義し、(c) Developer / Reviewer エージェント定義（`.claude/agents/developer.md`, `.claude/agents/reviewer.md`）に「対象 repo の CLAUDE.md を読み、宣言があれば feature-flag.md を読む」フローを追加する。**watcher 側の prompt builder は変更しない**（後方互換性を最大化するため、解釈はエージェント自身に閉じる）。

### Goals

- `repo-template/CLAUDE.md` に Feature Flag Protocol の採否を宣言する**専用節**を追加し、opt-in / opt-out それぞれの記述書式と「宣言なし = opt-out」のフォールバックを明記する
- `.claude/rules/feature-flag.md`（および `repo-template/.claude/rules/feature-flag.md`）を新設し、命名方針・初期値・有効化条件・旧パス保存・両系統テスト・クリーンアップ責務を一覧化する
- Developer / Reviewer エージェントが**プロジェクト固有の CLAUDE.md を読んで採否を判断する**読み取りフローを定義し、watcher の prompt builder には変更を加えない（後方互換性最優先）
- 既存プロジェクト（宣言なし）が opt-out として動作することを担保し、本変更導入前と機能的に等価な状態を維持する（NFR 1.1）

### Non-Goals

- LaunchDarkly / Unleash / GrowthBook 等の外部 Feature Flag SaaS との連携（Out of Scope / 要件 2.5）
- Flag 値の動的変更（A/B テスト、段階リリース、ユーザー属性別出し分け）
- Flag テレメトリの自動収集
- idd-claude 自身（dogfooding 対象）の opt-in 宣言追加（本 PR では宣言節を repo-template に追加するのみ。本体採否は別 Issue）
- watcher / install.sh / setup.sh / GitHub Actions ワークフローへの flag 反映（本要件はテンプレート規約・エージェントプロンプトに限定）
- flag-on / flag-off テストを **自動実行する仕組み**の実装（要件 5 は規約提示にとどめる方針を採用 — Open Question 2 への設計判断）

## Architecture

### Existing Architecture Analysis

idd-claude は **bash + markdown + GitHub Actions YAML** で構成されたツールリポジトリで、以下の階層でエージェントの挙動が決まる:

1. **watcher の prompt builder**（`local-watcher/bin/issue-watcher.sh` の `build_dev_prompt_a` / `build_reviewer_prompt` 等）が、Issue ごとに heredoc で prompt 文字列を組み立て `claude --print` に渡す
2. **エージェント定義**（`.claude/agents/developer.md` / `.claude/agents/reviewer.md`）が「必ず先に読むルール」「実装フロー」を規定
3. **対象 repo の CLAUDE.md**（テンプレートは `repo-template/CLAUDE.md`、`install.sh` で各 repo にコピーされる）が**プロジェクト憲章**として全エージェントから参照される
4. **共通ルール**（`.claude/rules/*.md`）が EARS 記法・design-principles 等の横断的規約を提供

**尊重すべきドメイン境界**:
- watcher の prompt builder インターフェース（`DEV_PROMPT` heredoc の構造）は触らない（既稼働の cron / launchd を壊さないため）
- `repo-template/**` の既存節の見出しテキスト・階層は破壊しない（NFR 1.2、既 installed の consumer repo に再 install で上書きされる）
- エージェント定義（`developer.md` / `reviewer.md`）の既存「必ず先に読むルール」リストは保持し、追記のみ行う

**解消・回避する technical debt**:
- 現状 Phase 4 の言及は README に「別 Issue として分離」とだけ書かれており、実質的な規約は未定義。Implementer がプロジェクトごとに flag 適用するか判断できない曖昧さがある

### Architecture Pattern & Boundary Map

採用する構造は **Declaration in CLAUDE.md → Read by Agent at Runtime → Conditional Behavior**。
watcher の prompt 段階では何も判断せず、エージェント自身が対象 repo の CLAUDE.md を Read して挙動を切り替える。

```mermaid
flowchart LR
    subgraph "Repo-template (本 PR で更新)"
        CT[repo-template/CLAUDE.md<br/>＋ Feature Flag 節]
        RT[repo-template/.claude/rules/<br/>feature-flag.md]
    end

    subgraph "Consumer repo (install.sh 経由で配置)"
        CC[CLAUDE.md<br/>opt-in or opt-out 宣言]
        RC[.claude/rules/<br/>feature-flag.md]
    end

    subgraph "Agent runtime (claude --print)"
        DEV[Developer agent<br/>.claude/agents/developer.md]
        REV[Reviewer agent<br/>.claude/agents/reviewer.md]
    end

    CT -->|install.sh copy| CC
    RT -->|install.sh copy| RC

    DEV -.Read CLAUDE.md.-> CC
    DEV -.if opt-in: Read.-> RC
    REV -.Read CLAUDE.md.-> CC
    REV -.if opt-in: Read.-> RC

    DEV --> BEHAVIOR{flag 裏実装<br/>分岐}
    REV --> CHECK{flag 観点<br/>レビュー}
```

**Architecture Integration**:
- 採用パターン: **In-document declaration + agent-side interpretation**（宣言は CLAUDE.md 内、解釈はエージェント側）
- ドメイン／機能境界:
  - **テンプレート責務**（`repo-template/CLAUDE.md` / `repo-template/.claude/rules/feature-flag.md`）— 宣言書式と規約詳細の正本
  - **エージェント責務**（`.claude/agents/developer.md` / `.claude/agents/reviewer.md`）— 宣言の読み取りと挙動分岐
  - **watcher 責務**（`issue-watcher.sh`）— **本 PR では変更しない**（後方互換性最優先）
- 既存パターンの維持:
  - watcher の prompt heredoc 構造は不変
  - 既存の Developer / Reviewer の必読ファイルリスト（CLAUDE.md / requirements.md / etc.）は不変、追記のみ
  - 既存の `.claude/rules/*.md` の参照表（CLAUDE.md 内）に 1 行追加のみ
- 新規コンポーネントの根拠:
  - **`feature-flag.md`**: 規約詳細を CLAUDE.md 直書きすると CLAUDE.md が肥大化するため、cc-sdd 互換の `.claude/rules/` に独立ファイルで切り出す（既存 `ears-format.md` / `design-principles.md` と同パターン）
  - **CLAUDE.md の Feature Flag 節**: 「採否宣言の単一ソース」を明確化するため、エージェントが `grep` 不要で見つけられる固定見出しとして配置

### 設計判断: 宣言書式の選択（Open Question 3 への回答）

| 候補 | Pros | Cons | 採否 |
|---|---|---|---|
| YAML frontmatter（`---` ブロック） | 機械 parse が容易 | CLAUDE.md は markdown 本文を LLM が読む前提。frontmatter があると既存運用への可読性インパクトが大きい / 既存 CLAUDE.md は frontmatter を使っていない | 不採用 |
| 専用マーカー section + 固定行 | エージェント（LLM）も `grep` も両方読める / 既存節に追記可能 | フリーフォーマットなので誤記しやすい | **採用** |
| プレーン散文 | 書きやすい | エージェントが宣言を見落としやすい / 機械検証が困難 | 不採用 |

**採用: 専用 section + 固定行マーカー**

- 見出し: `## Feature Flag Protocol`（h2、固定）
- 宣言行: 節内に `**採否**: opt-in` または `**採否**: opt-out` の 1 行（**Bold ラベル + コロン + 値**）
- 値は `opt-in` / `opt-out` のみ。それ以外（`enabled`, `disabled`, 空値、未記載）は **opt-out として解釈**（要件 1.3）
- マーカーコメント（任意）: `<!-- idd-claude:feature-flag-protocol opt-in -->` を節内に置けば `grep` での自動抽出も可能（規約詳細ルールに記載）

### 設計判断: エージェントによる宣言読み取りの実装方法

| 候補 | Pros | Cons | 採否 |
|---|---|---|---|
| watcher 側で前処理し prompt に inline 埋め込み | エージェントが Read 不要で確実 | `issue-watcher.sh` 改修必須 / **後方互換リスク**（既稼働 cron に影響）/ heredoc が肥大化 | 不採用 |
| エージェント定義側で「Read CLAUDE.md → 該当節を解釈」を指示 | watcher 不変 / 後方互換性最大 / 既存「必ず先に読むルール」を拡張するだけ | エージェントが見落とすリスク（→ 必読フローと節見出しの固定化で軽減） | **採用** |
| 別途 helper script で抽出 | bash で確実 | Node.js 等を呼ばないという CLAUDE.md 禁止事項に抵触しないが、新規 script は冪等性レビュー対象になる | 不採用 |

**採用: エージェント定義側に Read 指示を追加**

- `developer.md` / `reviewer.md` の「必ず先に読むルール」に `CLAUDE.md` の Feature Flag 節を読む手順を追加
- 宣言が opt-in なら `.claude/rules/feature-flag.md` を Read してから実装／レビューに入る
- 宣言が opt-out（または無宣言）なら追加の Read を行わず通常フロー
- 既存の Developer プロンプト（`build_dev_prompt_a`）は `CLAUDE.md を読む` ことを既に要求しているため（line 1437, 1454）、watcher 改修は不要

### Technology Stack

| Layer | Choice / Version | Role in Feature | Notes |
|-------|------------------|-----------------|-------|
| Documentation | Markdown (CommonMark) | 宣言節と規約詳細の記述 | 既存 `.claude/rules/*.md` と同形式 |
| Agent definitions | Markdown with YAML frontmatter | Developer / Reviewer の必読フロー追加 | 既存 `.claude/agents/*.md` を上書き |
| Template distribution | `install.sh`（既存・変更なし） | `repo-template/**` を consumer repo にコピー | 既存の `cp` ベースの配置を流用 |
| Backward-compat verification | bash + `grep` | 既存節見出しの保全と新規節の存在確認 | 手動スモークテストで実施 |

新規依存・新規ランタイムなし（CLAUDE.md 禁止事項「Node.js / Python 等を新規追加しない」に従う）。

## File Structure Plan

### Modified Files

```
repo-template/
├── CLAUDE.md                                # ★ 末尾に「## Feature Flag Protocol」節を追加
└── .claude/
    └── rules/
        └── feature-flag.md                  # ★ 新規ファイル（規約詳細の正本）

.claude/
├── agents/
│   ├── developer.md                         # ★ 「必ず先に読むルール」と実装フローに追記
│   └── reviewer.md                          # ★ 「必ず先に読むルール」と判定基準に追記
└── rules/
    └── feature-flag.md                      # ★ 新規（repo-template と同内容、self-hosting 用）

CLAUDE.md                                    # ★ 「エージェントが参照する共通ルール」表に
                                             #    feature-flag.md を 1 行追加（idd-claude 自身は
                                             #    opt-out のため Feature Flag 節は追加しない）

README.md                                    # ★ Phase 4 完了反映（オプション機能一覧の Phase 4
                                             #    マーカーを「実装済み」に更新、Migration note 追記）
```

### File Responsibilities

| File | Responsibility | Why this location |
|---|---|---|
| `repo-template/CLAUDE.md` | プロジェクト固有の採否宣言節のテンプレート（コメント付きで opt-in / opt-out 両方の例を記載） | テンプレートの正本。`install.sh` で consumer repo にコピーされる |
| `repo-template/.claude/rules/feature-flag.md` | 規約詳細（命名方針・旧パス保存・両系統テスト・クリーンアップ責務）。**opt-in 宣言時のみエージェントが読む** | cc-sdd 互換の `.claude/rules/` 配下。既存 `ears-format.md` 等と同パターン |
| `.claude/rules/feature-flag.md` | repo-template と同内容（self-hosting 用） | idd-claude 自身も対象 repo として運用するため |
| `.claude/agents/developer.md` | 必読フローに `CLAUDE.md の Feature Flag 節を確認 → opt-in なら feature-flag.md を読む` を追加。実装フローに「opt-in の場合は flag 裏実装、旧パス温存」を追加 | 既存の必読リストへの最小追記 |
| `.claude/agents/reviewer.md` | 必読フローに同上の手順、判定カテゴリ「boundary 逸脱」の中で「opt-in 宣言時は flag-off パスの不変性を確認」を明文化 | 既存 3 カテゴリ判定ロジックを保持しつつ、boundary 逸脱の確認対象を拡張 |
| `CLAUDE.md`（root） | `.claude/rules/` 一覧表に `feature-flag.md` を 1 行追加。**Feature Flag 節は追加しない**（idd-claude 本体の採否は別 Issue / Out of Scope） | 既存の参照表は両 PR で揃える |
| `README.md` | 「Phase 4: 実装済み」反映と Migration note。consumer repo が再 install するときに上書きされる旨を明記 | 挙動変更を README で告知（CLAUDE.md「README との二重管理」原則） |

### Out of Modification（明示的に触らないファイル）

- `local-watcher/bin/issue-watcher.sh` — 後方互換性最優先（既稼働 cron に影響しない）
- `local-watcher/bin/triage-prompt.tmpl` — Triage は採否判断を行わない
- `install.sh` / `setup.sh` — 既存の `cp` ベースの配置で十分（新規ファイルは自動的にコピー対象）
- `.github/workflows/issue-to-pr.yml` — Out of Scope（要件 96-102 行目）
- `repo-template/.claude/agents/developer.md` / `reviewer.md` — `.claude/agents/*.md` の正本側のみ更新し、template はそれを反映する別 PR でも良いが、本 PR では同期して更新（後述）

> **設計上の注意**: `.claude/agents/*.md` は idd-claude 自身でしか使われないため、`repo-template/.claude/agents/*.md` を同期更新するかは判断ポイント。本設計では **`repo-template/.claude/agents/developer.md` / `reviewer.md` も同 PR で同期更新**する（既存の symmetry を維持し、consumer repo が再 install したときに同じ挙動になるため）。

## Requirements Traceability

| Req ID | Summary | Components | Interfaces / Files | Notes |
|---|---|---|---|---|
| 1.1 | CLAUDE.md に専用節 | TemplateClaudeMd | `repo-template/CLAUDE.md` の末尾に `## Feature Flag Protocol` 節 | 固定見出し |
| 1.2 | opt-in / opt-out 書式提示 | TemplateClaudeMd | 同上節内に `**採否**: opt-in` / `**採否**: opt-out` の例を併記 | 両例を bullet で示す |
| 1.3 | 宣言なし → opt-out フォールバック | DeveloperAgentDef, ReviewerAgentDef | `developer.md` / `reviewer.md` の必読フローに「節が無い／値が opt-in 以外なら opt-out として扱う」を明記 | エージェント側の解釈ロジック |
| 1.4 | opt-out デフォルト明記 | TemplateClaudeMd, FeatureFlagRule | 節の冒頭に `> デフォルトは **opt-out** です` を bold で記載 / `feature-flag.md` 冒頭にも同記述 | 誤読防止 |
| 2.1 | rules ディレクトリに規約詳細ファイル | FeatureFlagRule | `repo-template/.claude/rules/feature-flag.md` 新規作成（および root `.claude/rules/feature-flag.md`） | cc-sdd 互換配置 |
| 2.2 | 宣言記述書式の提示 | FeatureFlagRule | `feature-flag.md` 内 `## 採否宣言の書式` セクション | CLAUDE.md と同じ書式を再掲 |
| 2.3 | flag 名命名・初期値・有効化条件 | FeatureFlagRule | `## Flag 命名と初期値` セクション | 例: `<feature-name>_enabled`, 初期値 false |
| 2.4 | カバー要件（旧パス保存・両系統テスト・クリーンアップ） | FeatureFlagRule | `## Implementer が満たすべき要件（チェックリスト）` セクション | 一覧形式 |
| 2.5 | 外部 SaaS を扱わない明記 | FeatureFlagRule | `## Non-Goals` または `## Scope 外` セクション | LaunchDarkly 等を列挙して除外 |
| 3.1 | opt-in 時の Implementer プロンプトに flag 裏実装指示 | DeveloperAgentDef | `developer.md` 「実装ルール」「実装フロー」に opt-in 分岐を追記 | watcher prompt は不変 |
| 3.2 | 両系統が同一テストスイートで実行可能 | DeveloperAgentDef, FeatureFlagRule | `developer.md` 実装フロー + `feature-flag.md` の `## 両系統テスト` 指針 | 実行責務はプロジェクト側に委ねる |
| 3.3 | flag-off パスの不変性 | DeveloperAgentDef, FeatureFlagRule | `developer.md` 実装フロー + `feature-flag.md` の旧パス温存ルール | 差分レビューで Reviewer が確認 |
| 3.4 | opt-out 時は通常の単一実装 | DeveloperAgentDef | `developer.md` 必読フローで宣言 = opt-out / 無宣言なら追加指示なし | 後方互換性の中核 |
| 4.1 | opt-in 時の Reviewer プロンプトに flag 観点 | ReviewerAgentDef | `reviewer.md` 「判定基準」に opt-in 時の flag 観点を追記 | watcher prompt は不変 |
| 4.2 | opt-out 時は flag 観点なし | ReviewerAgentDef | `reviewer.md` 必読フローで分岐 | 既存 3 カテゴリ判定を保持 |
| 4.3 | flag-off パスの差分等価確認 | ReviewerAgentDef, FeatureFlagRule | `reviewer.md` 「行動指針」に「opt-in 時は flag-off パスの差分等価を確認」を追記 / `feature-flag.md` に確認手順 | 機械検証は git diff の目視 |
| 4.4 | flag-off 変化なら reject | ReviewerAgentDef | `reviewer.md` 判定カテゴリ「boundary 逸脱」内のサブ条件として明記 | 既存 3 カテゴリ枠内に収める |
| 5.1 | 両系統実行 | FeatureFlagRule | `feature-flag.md` `## 両系統テスト` セクション | 規約提示にとどめる（Open Q2） |
| 5.2 | いずれか失敗で全体失敗 | FeatureFlagRule | 同上セクション内のチェックリスト | プロジェクト側で実装 |
| 5.3 | 実行責務（local / CI）の指針 | FeatureFlagRule | 同上セクション「責務分担の選択肢」 | 推奨例 + プロジェクトに委ねる旨 |
| 6.1 | クリーンアップ PR 義務 | FeatureFlagRule | `## クリーンアップ責務` セクション | 全タスク完了後の別 PR |
| 6.2 | クリーンアップ起票責務 | FeatureFlagRule | 同セクション「人間が umbrella Issue ベースで起票する」と明記（Open Q1 への回答） | Implementer は単一 Issue しか見えないため umbrella 完了判断不可 |
| 6.3 | 残存 flag の棚卸し方針 | FeatureFlagRule | 同セクション「件数閾値: 同時に 5 個以上の active flag が main に残った場合は棚卸し Issue を起票」 | 数値化（要件 NFR の曖昧語回避方針） |
| NFR 1.1 | 既存プロジェクトへの後方互換性 | DeveloperAgentDef, ReviewerAgentDef, watcher | 「宣言なし → opt-out」 + watcher 不変で実現 | スモークテスト項目に含める |
| NFR 1.2 | 既存節見出しを破壊しない | TemplateClaudeMd | 末尾に追記する手順を tasks.md で明示 | `diff` で既存節の不変を確認 |
| NFR 2.1 | 1 ページ内可読性 | TemplateClaudeMd, FeatureFlagRule | 節は 60 行以内、`feature-flag.md` は 200 行以内目安 | 完成後の wc -l 確認 |
| NFR 2.2 | 採用宣言サンプル 1 つずつ | TemplateClaudeMd, FeatureFlagRule | CLAUDE.md 節 + `feature-flag.md` 双方に opt-in / opt-out 例 | 重複ではなく、宣言例 + 解説の役割分担 |
| NFR 3.1 | 言語・基盤非依存 | FeatureFlagRule | 言語別実装例は載せず、抽象パターンのみ記述 | TypeScript / Python / Go の例は付録ではなく外部参照に |

## Components and Interfaces

### Documentation Layer

#### TemplateClaudeMd

| Field | Detail |
|---|---|
| Intent | consumer repo に配置されるプロジェクト憲章テンプレートに、採否宣言節の雛形を提供する |
| Requirements | 1.1, 1.2, 1.4, NFR 1.2, NFR 2.1, NFR 2.2 |

**Responsibilities & Constraints**
- `repo-template/CLAUDE.md` の末尾（参考資料節の前 or 後）に `## Feature Flag Protocol` 節を 1 つ追加
- 既存節（技術スタック / コード規約 / テスト規約 / ブランチ・コミット規約 / 禁止事項 / エージェント連携ルール / 共通ルール表 / PR 品質チェック / 機密情報の扱い / 参考資料）の見出しテキスト・h2 階層を変更しない（NFR 1.2）
- 節は 60 行以内目安（NFR 2.1）

**Dependencies**
- Inbound: `install.sh` — consumer repo へのコピー (Critical)
- Outbound: `feature-flag.md` — 規約詳細への内部リンク (Required)
- External: なし

**Contracts**: Documentation contract（書式の正本）

##### Section Contract（CLAUDE.md 内に追加する節の構造）

```markdown
## Feature Flag Protocol

> **デフォルトは opt-out です**。本節を削除する／空のままにする／値を `opt-in` 以外に
> する場合、自プロジェクトは Feature Flag Protocol を採用しない（= 通常の単一実装パス）と
> 解釈されます。

**採否**: opt-out

<!-- 採用する場合は上の行を `**採否**: opt-in` に変更し、規約詳細を確認してください -->
<!-- 規約詳細: `.claude/rules/feature-flag.md` -->

### この規約を採用するメリット
- 未完成機能を main にマージしても既存挙動を壊さない
- 段階的な機能リリースが可能

### この規約を採用するデメリット
- flag 残存による技術債の管理コスト
- 両系統テストのメンテナンスコスト

### 推奨ケース / 非推奨ケース
- **推奨**: 大規模機能で複数 PR をまたぐ実装、リリース日が確定している機能
- **非推奨**: 単純な追加機能、テストが薄いプロジェクト
```

- Preconditions: `repo-template/CLAUDE.md` が既存である
- Postconditions: 既存節の hash が変わらない（diff で `+` 行のみ）
- Invariants: h1 は 1 つのまま、新規見出しは h2

#### FeatureFlagRule

| Field | Detail |
|---|---|
| Intent | Feature Flag Protocol の規約詳細（書式・命名・カバー要件・テスト指針・クリーンアップ責務）の正本 |
| Requirements | 2.1, 2.2, 2.3, 2.4, 2.5, 5.1, 5.2, 5.3, 6.1, 6.2, 6.3, NFR 2.1, NFR 2.2, NFR 3.1 |

**Responsibilities & Constraints**
- `.claude/rules/feature-flag.md` と `repo-template/.claude/rules/feature-flag.md` を新規作成（同内容）
- 200 行以内目安（NFR 2.1）
- 言語非依存の抽象パターンで記述（NFR 3.1）— 具体実装例は擬似コードまたは「(言語別の慣習に合わせる)」記法
- LaunchDarkly / Unleash / GrowthBook 等の SaaS は **Non-Goals** セクションで明示的に除外（要件 2.5）

**Dependencies**
- Inbound: `developer.md` / `reviewer.md`（opt-in 宣言時に Read される） (Critical)
- Outbound: なし
- External: なし

**Contracts**: Documentation contract（規約の正本）

##### File Outline Contract（feature-flag.md の構造）

```markdown
# Feature Flag Protocol（規約詳細）

> **このファイルは opt-in 宣言したプロジェクトでのみエージェントが Read します。**
> 採否宣言は対象 repo の CLAUDE.md `## Feature Flag Protocol` 節を参照。

## 概要
- 規約の目的（未完成機能を main に安全にマージするための実装パターン）
- 「規約」であって「自動化」ではない（フラグ管理 SaaS との連携はしない）

## 採否宣言の書式（要件 2.2）
- CLAUDE.md における専用節の見出し（`## Feature Flag Protocol`）と宣言行（`**採否**: opt-in`）
- マーカーコメント例（任意）
- 宣言なし／不正値 → opt-out 解釈（要件 1.3）

## Flag 命名と初期値（要件 2.3）
- 命名方針: `<feature-name>_enabled`（lower_snake_case 推奨、言語慣習に合わせる）
- 初期値: false（既定で旧パスが選択される）
- 有効化条件: 環境変数 / 設定ファイル / プロジェクト固有の機構（言語非依存）

## Implementer が満たすべき要件（要件 2.4 / 3.1 / 3.2 / 3.3）
- [ ] 旧パスを削除せず温存する
- [ ] flag-on / flag-off の両パスが同一テストスイートで実行できる
- [ ] flag-off パスの挙動は本機能導入前と同一（差分等価）
- [ ] flag 名と初期値を CLAUDE.md または README に列挙する

## 両系統テスト（要件 5.1 / 5.2 / 5.3）
- 同一テストスイートを flag-on / flag-off で 2 回実行
- いずれか失敗で全体失敗
- 責務分担の選択肢（プロジェクトが選ぶ）:
  - (a) ローカル実行: 開発者がコマンドラインで両系統を実行
  - (b) CI 実行: CI matrix 等で 2 系統を並列実行
  - (c) 規約上の指針提示にとどめ、各プロジェクトが自由に選択

## クリーンアップ責務（要件 6.1 / 6.2 / 6.3）
- 全タスク完了後、flag 定義と `if (flag)` 分岐を除去する**別 PR を作成する義務**
- 起票責務: **人間が umbrella Issue 完了時に手動で起票**（Implementer は単一 Issue 文脈しか持たないため）
- 残存 flag 棚卸し: **同時に active flag が 5 個を超えたら棚卸し Issue を起票**

## Non-Goals（要件 2.5）
- LaunchDarkly / Unleash / GrowthBook 等の外部プラットフォーム連携・移行
- Flag 値の動的変更（A/B、段階リリース、ユーザー属性別出し分け）
- Flag テレメトリの自動収集

## 採用宣言サンプル（要件 NFR 2.2）
### opt-in 例
（CLAUDE.md 節の opt-in 版コピペサンプル）
### opt-out 例
（同 opt-out 版コピペサンプル）
```

- Preconditions: `.claude/rules/` ディレクトリが存在する（既存）
- Postconditions: 既存ファイルを変更しない、新規 `feature-flag.md` のみ追加
- Invariants: 言語固有のコード例を含めない

### Agent Layer

#### DeveloperAgentDef

| Field | Detail |
|---|---|
| Intent | Developer エージェントの定義に「対象 repo の CLAUDE.md を読み、opt-in なら feature-flag.md を読み、flag 裏実装する」フローを追加する |
| Requirements | 3.1, 3.2, 3.3, 3.4, NFR 1.1 |

**Responsibilities & Constraints**
- `.claude/agents/developer.md` および `repo-template/.claude/agents/developer.md` を更新（symmetry 維持）
- 既存「実装ルール」「実装フロー」セクションを破壊しない（追記のみ）
- 既存の `# やらないこと（領分違い）` 節は保持
- watcher の prompt builder（`build_dev_prompt_a` 等）は変更しない（後方互換性最優先 / NFR 1.1）

**Dependencies**
- Inbound: watcher prompt（CLAUDE.md を Read することは既存 prompt で要求済み） (Critical)
- Outbound: 対象 repo の `CLAUDE.md` (Critical), `.claude/rules/feature-flag.md`（opt-in 時のみ） (Conditional)
- External: なし

**Contracts**: Agent prompt contract（エージェント定義の正本）

##### Behavior Contract（追記する手順）

```markdown
# 必ず先に読むルール（追記）

着手前に対象 repo の `CLAUDE.md` を Read し、`## Feature Flag Protocol` 節の有無と
`**採否**:` 行の値を確認する:

- 節が存在しない、または値が `opt-in` 以外（`opt-out` / 空 / 不正値）: 通常フローで実装
- 値が `opt-in`: 続けて `.claude/rules/feature-flag.md` を Read し、規約詳細に従う

# 実装フロー（追記）

opt-in が確認された場合、各タスクで以下を満たす:

1. 新規挙動を `if (flag) { 新挙動 } else { 旧挙動 }` パターンで実装し、旧パスを温存する
2. flag 名は `feature-flag.md` の命名方針（`<feature-name>_enabled`）に従う
3. 初期値は false（旧パスが既定）
4. 同一テストスイートが flag-on / flag-off の両方で実行可能な状態を維持する
5. flag-off パスの挙動は本機能導入前と同一（差分等価）であることを `git diff main..HEAD` で
   セルフチェックする
6. `impl-notes.md` に追加した flag 名と初期値を列挙する
```

- Preconditions: 対象 repo に CLAUDE.md が存在する（idd-claude installer の前提）
- Postconditions: opt-out / 無宣言の場合の挙動が本機能導入前と等価（NFR 1.1）
- Invariants: watcher prompt の構造を破壊しない

#### ReviewerAgentDef

| Field | Detail |
|---|---|
| Intent | Reviewer エージェントの定義に「opt-in 宣言時は flag 観点（旧パス保存・両系統テスト・命名）を確認、opt-out なら通常通り 3 カテゴリ判定」を追加する |
| Requirements | 4.1, 4.2, 4.3, 4.4, NFR 1.1 |

**Responsibilities & Constraints**
- `.claude/agents/reviewer.md` および `repo-template/.claude/agents/reviewer.md` を更新（symmetry 維持）
- 既存の **判定 3 カテゴリ**（AC 未カバー / missing test / boundary 逸脱）の枠を維持する（要件 4 の「flag 観点」は **boundary 逸脱の細目**として位置づけ、新カテゴリは作らない）
- 既存「reject しない条件」の lint / スタイル除外原則を保持
- watcher の `build_reviewer_prompt` は変更しない（後方互換性最優先 / NFR 1.1）

**Dependencies**
- Inbound: watcher prompt（CLAUDE.md を Read することは既存 prompt で要求済み） (Critical)
- Outbound: 対象 repo の `CLAUDE.md` (Critical), `.claude/rules/feature-flag.md`（opt-in 時のみ） (Conditional), `git diff main..HEAD`（既存ツール） (Critical)
- External: なし

**Contracts**: Agent prompt contract（エージェント定義の正本）

##### Behavior Contract（追記する手順）

```markdown
# 必ず先に読むルール（追記）

着手前に対象 repo の `CLAUDE.md` を Read し、`## Feature Flag Protocol` 節の `**採否**:` 行を確認:

- opt-in 以外: 通常の 3 カテゴリ判定のみ（既存挙動を保持）
- opt-in: `.claude/rules/feature-flag.md` を続けて Read し、判定基準に flag 観点を追加

# 判定基準（追記: opt-in 時のみ）

`boundary 逸脱` カテゴリの細目として、以下を確認する:

- (a) 旧パスのコードが残っているか（`git diff main..HEAD` で旧パス側の実装行が削除されていない）
- (b) 新規挙動が `if (flag) { ... } else { ... }` パターンで分岐しているか
- (c) flag-off パスの差分が**意味的に空**か（型変更・リファクタは可、挙動変更は不可）
- (d) flag 命名が `feature-flag.md` の方針に従っているか

(a)(c) の確認手順:
1. `git diff main..HEAD -- <変更ファイル>` を実行
2. 各 hunk について「flag-off で実行されるブロック」が変更前と等価かを目視確認
3. 等価でなければ `boundary 逸脱`（細目: flag-off path mutation）として reject

# 反例（reject 対象）

- 旧パスが削除されている
- 新規挙動が flag 分岐なしで直接 main path に注入されている
- flag-off ブランチでも新挙動の副作用が走る（フラグの fail-open / fail-close 設計ミス）
```

- Preconditions: 対象 repo に CLAUDE.md が存在し、Reviewer は最新 commit を `git diff main..HEAD` で確認できる
- Postconditions: opt-out / 無宣言の場合は本機能導入前と完全に同一の判定挙動（NFR 1.1）
- Invariants: 判定は引き続き 3 カテゴリのみ（AC 未カバー / missing test / boundary 逸脱）

### Distribution Layer

#### InstallScript（変更なし、既存挙動の確認のみ）

| Field | Detail |
|---|---|
| Intent | `repo-template/**` の新規ファイル（`feature-flag.md`）を consumer repo に自動配置する |
| Requirements | NFR 1.1（後方互換性） |

**Responsibilities & Constraints**
- 既存 `install.sh` の `cp -R repo-template/. <target>/` ベースの配置で、新規 `repo-template/.claude/rules/feature-flag.md` も自動的にコピーされる前提
- **本 PR では `install.sh` を変更しない**。既存 `.bak` バックアップ機構で既存 CLAUDE.md は保護される（重要: 既 installed の repo は `--force` 等の既存挙動でのみ上書き）

**Dependencies**: 既存挙動を確認するのみ（手動スモークテストで検証）

## Data Models

本機能は宣言的なドキュメントとエージェント解釈ロジックのみで、永続化されるデータ構造は存在しない。

### Configuration Model（CLAUDE.md 内宣言）

| Field | Type | Values | Default | Notes |
|---|---|---|---|---|
| `**採否**:` | Enum string | `opt-in` \| `opt-out` | `opt-out`（無記載・不正値含む） | h2 `## Feature Flag Protocol` 節内に置く |
| `<!-- idd-claude:feature-flag-protocol opt-in -->` | Optional marker comment | `opt-in` \| `opt-out` | （任意） | grep での自動抽出用、必須ではない |

## Error Handling

### Error Strategy

本機能はドキュメントベースの規約とエージェント解釈ロジックで構成され、**runtime での bash / API エラーは発生しない**。エラーは以下のいずれかの形で表面化する:

1. **エージェントが宣言を見落とす**（読み忘れ）→ 必読フローへの明示記載 + 既存「必ず先に読むルール」セクションの拡張で軽減
2. **宣言値が不正**（`enabled` / 大文字 / 空白）→ opt-out として解釈（要件 1.3）し、Implementer / Reviewer ともに通常フローで動作（fail-safe）
3. **規約違反**（opt-in 宣言下で旧パスを削除している等）→ Reviewer が `boundary 逸脱` で reject

### Error Categories and Responses

- **User Errors（採否宣言の記述ミス）**: opt-out フォールバックで安全側に倒す。`feature-flag.md` の冒頭 FAQ で「`enabled` ではなく `opt-in` と書く」を例示
- **System Errors（該当なし）**: ドキュメントベースのため発生しない
- **Business Logic Errors（規約違反）**: Reviewer が `boundary 逸脱` 判定で reject。Reviewer の `review-notes.md` Findings に「flag-off path mutation」のような具体カテゴリラベルを書くことで Developer の再実装を導く

### 後方互換性の故障モード

| 失敗シナリオ | 検出方法 | 緩和策 |
|---|---|---|
| 既存 consumer repo が再 install で破壊される | 手動スモークテスト（`install.sh --repo /tmp/scratch`） | install.sh は既存ファイルを `.bak` にバックアップ（既存挙動）。本 PR では install.sh を変更しない |
| 既稼働 cron / launchd の watcher が壊れる | dry run（`REPO=owner/test ... issue-watcher.sh`） | watcher / prompt builder を変更しない設計選択 |
| エージェントが Feature Flag 節を読み飛ばす | E2E（idd-claude self test issue で opt-in 宣言を入れて発動確認） | 必読フロー筆頭に追加 + section header を固定 |
| 宣言値の typo（`opt_in` / `Opt-In`） | Reviewer の boundary 逸脱判定が走らない | opt-out フォールバック（要件 1.3）+ `feature-flag.md` で「値は lowercase の `opt-in` のみ有効」を明記 |

## Testing Strategy

本リポジトリには unit test フレームワークは無いため、**静的解析 + 手動スモークテスト + dogfooding** の組み合わせで検証する。各テスト項目は requirements.md の AC と紐付ける。

### Static Checks（自動）

1. `markdownlint` 相当（手動: 各 markdown ファイルの h1 数、見出し階層、リンク先の相対パスを目視）
2. `grep` で既存節見出しが破壊されていないことを確認（`grep -E '^## (技術スタック|コード規約|テスト規約|ブランチ・コミット規約|禁止事項|エージェント連携ルール|PR 品質チェック|機密情報の扱い|参考資料)' repo-template/CLAUDE.md` がすべて hit する → NFR 1.2）
3. `grep` で新規節が追加されていることを確認（`grep '^## Feature Flag Protocol' repo-template/CLAUDE.md` が hit）

### Manual Smoke Tests

1. **install.sh 冪等性確認** — `/tmp/scratch-pre` repo を作って旧 CLAUDE.md だけ置き、`./install.sh --repo /tmp/scratch-pre` で新規 `feature-flag.md` がコピーされ、CLAUDE.md は `.bak` で保護されることを確認（NFR 1.1）
2. **opt-out フォールバック** — `/tmp/scratch-optout` で CLAUDE.md に Feature Flag 節を**追加しない**まま Developer エージェントを手動起動し、prompt 中に flag 関連の指示が出ないことを確認（要件 3.4 / NFR 1.1）
3. **opt-in 経路** — `/tmp/scratch-optin` で CLAUDE.md 末尾に `## Feature Flag Protocol` + `**採否**: opt-in` を追記し、Developer エージェントが `feature-flag.md` を Read することを確認（要件 3.1）
4. **Reviewer 経路（opt-in）** — 上記 opt-in repo で flag-off パスを意図的に変更した PR を作り、Reviewer が `boundary 逸脱` で reject することを確認（要件 4.4）
5. **Reviewer 経路（opt-out）** — opt-out repo では Reviewer prompt に flag 観点が出ないことを確認（要件 4.2）

### Dogfooding（E2E）

6. **idd-claude self-test** — 本 PR merge 後、idd-claude 自身は opt-out のままだが、テスト用 Issue を立てて Developer / Reviewer が新しい必読フローで動くこと（既存挙動と等価）を確認（NFR 1.1）

### Coverage Mapping

| AC | 検証方法 |
|---|---|
| 1.1, 1.2, 1.4 | Static check 3（節と宣言行の存在）+ NFR 2.1（行数確認） |
| 1.3 | Smoke 2（opt-out フォールバック）+ Static check の宣言値正規表現 |
| 2.1〜2.5 | `feature-flag.md` の内容レビュー（PR review） + 行数 |
| 3.1〜3.4 | Smoke 2, 3 |
| 4.1〜4.4 | Smoke 4, 5 |
| 5.1〜5.3 | `feature-flag.md` の規約レビュー（実装テストは Out of Scope） |
| 6.1〜6.3 | `feature-flag.md` の規約レビュー |
| NFR 1.1 | Smoke 1, 2, 6 |
| NFR 1.2 | Static check 2 |
| NFR 2.1 | `wc -l` で各ファイルの行数確認 |
| NFR 2.2 | PR review（opt-in / opt-out 例の存在確認） |
| NFR 3.1 | PR review（言語固有実装例が無いことを確認） |

## Documentation Updates

CLAUDE.md「README との二重管理」原則に従い、本 PR では以下も同時更新する:

- **`README.md`**: line 1100 付近「Feature Flag Protocol（Phase 4）は別 Issue として分離します」を「実装済み（Phase 4 / Issue #23）」に更新。「オプション機能（opt-in / 常時有効）一覧」表の opt-in 節に Feature Flag Protocol を 1 行追加（**プロジェクト単位で CLAUDE.md 宣言**で有効化、と明記）
- **`CLAUDE.md`（root）**: 「エージェントが参照する共通ルール」表に `feature-flag.md` を 1 行追加（idd-claude 自身は opt-out なので Feature Flag 節は追加しない）

### Migration Note（README に追記する内容）

```markdown
### Phase 4: Feature Flag Protocol（プロジェクト単位 opt-in）

各プロジェクトは `CLAUDE.md` に `## Feature Flag Protocol` 節を追加し、
`**採否**: opt-in` を宣言することで本規約を有効化できる。デフォルトは opt-out。
既 installed の consumer repo は再 install しても CLAUDE.md は `.bak` に退避され
上書きされないため、Phase 4 への移行は手動で節を追加する必要がある。
```

## Open Questions（PM の Open Questions への設計判断）

| PM の Open Question | 設計側の判断 | 判断根拠 |
|---|---|---|
| クリーンアップ PR の起票責務（Implementer か人間か） | **人間が起票**（umbrella Issue 単位） | Implementer は単一 Issue 文脈しか持たず、複数機能完了の判定は不可能。`feature-flag.md` の `## クリーンアップ責務` に「人間が umbrella Issue 完了時に手動起票」と明記 |
| テスト両系統実行の責務（local / CI / 規約のみ） | **規約上の指針提示にとどめる**（プロジェクト各自が選択） | テストフレーム非依存方針（NFR 3.1）と矛盾するため、idd-claude 側で実行機構を提供しない。`feature-flag.md` で 3 つの選択肢を例示 |
| 採否宣言ブロックの形式（YAML frontmatter / マーカー section / 散文） | **専用 markdown section + 固定 bold 行** | 既存 CLAUDE.md が markdown 散文形式で、エージェント（LLM）が直接読む前提のため。frontmatter は既存運用と乖離する |
| idd-claude 自身（dogfooding）の採否 | **本 PR では宣言節を追加しない（実質 opt-out）** | requirements.md Out of Scope の通り、本体採否は別 Issue で意思決定。本 PR は規約とテンプレートの整備のみ |
