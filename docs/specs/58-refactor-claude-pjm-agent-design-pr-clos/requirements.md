# Requirements Document

## Introduction

PR #56 の merge 時に、設計 PR の本文に含まれていた `- Closes #55` キーワードが GitHub の auto-close 機能に反応し、対応 Issue #55 が意図せず close される事故が発生した。原因は PjM agent（design-review モード）が定義済みテンプレートに無い「関連 Issue / PR」セクションを即興で追加し、その中に `Closes` キーワードを混入させたことである。

本要件定義は、設計 PR の本文に `Closes` / `Fixes` / `Resolves` 等の auto-close キーワードが二度と混入しないよう、PjM agent 定義・設計 PR テンプレート・README 規約・PR 作成後の自己点検手順という多層的な抑止策を導入することを目的とする。対象は idd-claude リポジトリ自身（self-hosted 版）と `repo-template/` 配下（consumer repo に配布されるテンプレート）の双方であり、impl PR の挙動および GitHub 側のキーワード仕様は対象外とする。

## Requirements

### Requirement 1: PjM agent 定義による禁止構文の明示

**Objective:** As an idd-claude maintainer, I want PjM agent の design-review モード定義に auto-close キーワードの禁止が明記されている状態を保ちたい, so that エージェントが設計 PR を生成する際に Issue の意図しない自動 close を引き起こさない

#### Acceptance Criteria

1. The PjM agent design-review mode definition shall 設計 PR 本文の Issue 参照では `Refs #<issue-number>` 形式のみを許容する旨を明記する
2. The PjM agent design-review mode definition shall `Closes` / `Fixes` / `Resolves` / `Close` / `Fix` / `Resolve` / `Closed` / `Fixed` / `Resolved` の 9 キーワードを禁止語として列挙する
3. The PjM agent design-review mode definition shall 禁止理由として「設計 PR が merge された際に GitHub の auto-close 機能で Issue が意図せず close される事故を防ぐため」を明記する
4. When the PjM agent design-review モードで設計 PR 本文を生成するとき, the PjM agent shall テンプレートに存在しないセクションを即興で追加してはならない旨を遵守事項として持つ
5. The リポジトリ shall `.claude/agents/project-manager.md` と `repo-template/.claude/agents/project-manager.md` の両ファイルで上記の記載を一致させる

### Requirement 2: 設計 PR テンプレートへの許容書式サンプルの組み込み

**Objective:** As a PjM agent, I want 設計 PR 本文テンプレートに「関連 Issue / PR」を表現する正規セクションと許容書式サンプルが提示されている状態にしたい, so that 即興でセクションを追加せず、Refs 形式のみで関連性を表現できる

#### Acceptance Criteria

1. The 設計 PR 本文テンプレート shall 関連 Issue / PR を記述するための正規セクションを 1 つ持つ
2. The 設計 PR 本文テンプレート shall 当該セクションのサンプル記述として `Refs #<issue-number>` 形式の例を 1 件以上提示する
3. The 設計 PR 本文テンプレート shall `Closes` / `Fixes` / `Resolves` を含むキーワードをサンプル記述に使用しない
4. The 設計 PR 本文テンプレート shall 当該セクションに記述する関連項目が無い場合に "なし" と記載する旨のガイダンスを含む
5. The リポジトリ shall `.claude/agents/project-manager.md` と `repo-template/.claude/agents/project-manager.md` の両テンプレートで同一のセクション構造とサンプルを保つ

### Requirement 3: PjM agent による PR 作成後の自己点検

**Objective:** As an idd-claude maintainer, I want PjM agent が設計 PR 作成直前または作成直後に PR 本文をスキャンして禁止キーワードを検出する手順を持っていたい, so that 対策 1・2 をすり抜けてキーワードが混入しても merge 前に検出・是正できる

#### Acceptance Criteria

1. The PjM agent design-review mode definition shall PR 本文を `gh pr create` に渡す前または直後にスキャンし、禁止語の有無を確認する手順を持つ
2. When 自己点検で禁止キーワードを検出したとき, the PjM agent shall 該当箇所を `Refs #<issue-number>` 形式に修正してから設計 PR を確定する
3. If 禁止キーワードを検出したまま自動修正できないとき, the PjM agent shall 設計 PR 作成を中断し、Issue にラベル `claude-failed` を付与して人間に委ねる
4. The 自己点検手順 shall 検出対象として Requirement 1.2 と同一の 9 キーワード（大文字・小文字違いを含む）を網羅する

### Requirement 4: README への規約反映

**Objective:** As an idd-claude maintainer, I want README の設計 PR ゲート / ラベル状態遷移の説明箇所に「設計 PR では Refs のみ使用」の規約が明示された状態にしたい, so that ワークフロー利用者がドキュメントだけで auto-close 事故を回避できる

#### Acceptance Criteria

1. The README shall 設計 PR ゲートに関する節で、設計 PR 本文の Issue 参照は `Refs` 形式のみを使用する規約を明記する
2. The README shall `Closes` / `Fixes` / `Resolves` を設計 PR で使用してはならない理由（auto-close 事故防止）を明記する
3. Where impl PR が説明されている節, the README shall impl PR では従来どおり `Closes` キーワードが許容される旨を明記し、design / impl の差を明確にする

### Requirement 5: テンプレート consumer への後方互換性

**Objective:** As a consumer repo maintainer, I want `repo-template/` の更新が既存 installed repo に対しても破壊的でないことを保証されたい, so that 本対応の取り込みが既存ワークフローを壊さない

#### Acceptance Criteria

1. The リポジトリ shall 既存の設計 PR 本文テンプレートに含まれる主要セクション（概要 / 対応 Issue / 含まれる成果物 / レビュー観点 / 次のステップ / 確認事項）の見出しを保持する
2. The リポジトリ shall 設計 PR 用 PjM の実施事項（push / `gh pr create` / ラベル更新 / Issue コメント投稿）の順序と挙動を保持する
3. While 既存の `awaiting-design-review` ラベル運用が継続しているとき, the PjM agent shall 既存のラベル遷移契約（削除 `claude-picked-up` / 追加 `awaiting-design-review`）を変更しない
4. If 設計 PR 本文テンプレートに新セクションを追加する場合, the リポジトリ shall README の該当箇所を同一 PR 内で更新する

## Non-Functional Requirements

### NFR 1: 検出網羅性（運用観点）

1. The 禁止キーワード検出 shall 大文字・小文字の組み合わせ（`Closes`, `closes`, `CLOSES`, `Close`, `Fixes`, `fixes`, `Fix`, `Resolves`, `resolves`, `Resolve`, および過去分詞 `Closed`, `Fixed`, `Resolved` を含む）に対して取りこぼしなく反応する
2. The 禁止キーワード検出 shall キーワードの直前に Markdown 装飾（`-`, `*`, `>`, スペース）が付いた形（例: `- Closes #55`）も検出対象に含める
3. The 禁止キーワード検出 shall コードブロック・引用ブロック内に出現したキーワードについても検出対象とする（PR 本文として GitHub に解釈されるため）

### NFR 2: ドキュメント整合性

1. The リポジトリ shall 本対応で更新するファイル（PjM agent 定義 2 ファイル / README / 関連ドキュメント）の間で禁止キーワード一覧が一致する
2. The リポジトリ shall 本対応の挙動変更を README の「ラベル状態遷移」または「設計 PR ゲート」相当の節に同一 PR 内で反映する

## Out of Scope

- impl PR 本文テンプレートの変更（`Closes #<issue-number>` は impl PR では正規の使い方であり継続して許容する）
- GitHub 側の auto-close キーワード仕様への介入（GitHub Settings / Branch Protection / Action による pre-merge ブロック等）
- 過去 PR #56 の本文の事後修正（Issue #55 はすでに close 済みのため、履歴の遡及修正は本対応の対象外）
- 手作業で PjM agent を介さず作成された PR への自動チェック（idd-claude が責任を持つのは agent 経由の PR のみ）
- LaunchDarkly / Unleash 等の外部 Feature Flag SaaS 連携、CI 上での pre-merge linter 化（将来検討）
- Reviewer / Architect agent 定義への同様の禁止語明記（本 Issue は PjM agent の design-review モード起因の事故対応に限定する）

## Open Questions

なし。

Issue 本文で「Architect が決めるべき」とされていた以下 3 点については、本対応に Architect 起動は不要と判断し、PM が以下の方針を確定した:

- **対策 3（self-check）の導入可否**: 対策 1・2 のみでは過去事故の再発防止が完全には保証できないため、対策 3 を導入する。実装難易度は低く（PR 本文文字列に対する正規表現スキャン）、リスクとコストの非対称性から見て採用が妥当（Requirement 3）
- **「関連 Issue / PR」セクションの扱い**: テンプレートの**正規セクション**として追加する。自由記述として末尾に許容すると即興セクション追加の温床となり、本事故の根本原因が再発する（Requirement 2.1）
- **PR #56 の body 後追い修正**: 実施しない。Issue #55 はすでに close 済みであり、履歴を書き換えても auto-close は復元できないため、コストに見合わない（Out of Scope に明記）
