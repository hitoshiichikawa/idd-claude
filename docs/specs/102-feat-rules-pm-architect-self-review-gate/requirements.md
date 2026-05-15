# Requirements Document

- Issue: [#102](https://github.com/hitoshiichikawa/idd-claude/issues/102) "feat(rules): PM/Architect の self-review-gate に Claude Code /goal を適用して Mechanical Checks ループを自動化する"
- 対象ファイル想定:
  - `.claude/rules/requirements-review-gate.md`（本体 self-hosting 用）
  - `.claude/rules/design-review-gate.md`（本体 self-hosting 用）
  - `repo-template/.claude/rules/requirements-review-gate.md`（consumer 配布用）
  - `repo-template/.claude/rules/design-review-gate.md`（consumer 配布用）
  - `README.md`（Claude Code 最低バージョン記載・migration note）

## Introduction

Claude Code v2.1.139 で導入された `/goal <条件>` は、宣言した完了条件を毎ターン後に小型モデルで判定し、未達なら自動で次ターンを実行する仕組みである。idd-claude の PM / Architect は `requirements.md` / `design.md` 確定前に self-review-gate を実施しているが、現行ルールでは「Mechanical Checks」（numeric ID 網羅 / EARS 形式 AC 存在 / 実装語彙混入なし / Requirements Traceability 全埋め / File Structure Plan に "TBD" 残置なし / Orphan component なし）の機械検出をエージェントが自力でループし、漏れが発生するケースがある。

本機能では、Mechanical Checks の全クリアを `/goal` の完了条件として宣言してループ収束させる運用ノートを、`.claude/rules/requirements-review-gate.md` および `.claude/rules/design-review-gate.md` に追記する（self-hosting 本体と consumer 配布テンプレートの両系統に反映）。同時に `README.md` で Claude Code 最低バージョン要件（基本動作 v2.0.0 / `/goal` 利用時 v2.1.139）を明記し、`/goal` 非対応環境では従来どおりの「最大 2 パス」運用が継続することを保証する。bash スクリプト・workflow YAML・install.sh / setup.sh・env var 名・ラベル名・cron 登録文字列・exit code は本機能で変更しない（markdown のみ）。

## Requirements

### Requirement 1: PM 自己レビューゲートへの `/goal` 運用ノート追記

**Objective:** As a PM エージェント, I want `requirements-review-gate.md` の Mechanical Checks 節に `/goal` を使ったループ自動化の運用ノートが書かれてほしい, so that Mechanical Checks の検出漏れを `/goal` の自動評価ループで収束させられる

#### Acceptance Criteria

1. The `requirements-review-gate.md` shall Mechanical Checks 節の末尾に `/goal` を用いた自動ループ運用を説明するサブセクションを 1 箇所以上含む
2. The `requirements-review-gate.md` shall PM 向けの `/goal` 完了条件文字列テンプレート例を、Issue 本文の仮案（「すべての requirement 見出しに numeric ID があり / すべての requirement に EARS 形式 AC が 1 件以上あり / 実装語彙が混入していない」）と意味的に等価な形で 1 つ以上提示する
3. The `requirements-review-gate.md` shall 当該サブセクションが Claude Code v2.1.139 以降でのみ利用可能であることを 1 行以上で明示する
4. When PM エージェントが Claude Code v2.1.139 以降の環境で `requirements.md` ドラフトを確定する直前である, the PM agent shall 本サブセクションに記載された完了条件文字列に基づいて `/goal` を発行する手順を実行する
5. Where Claude Code が v2.1.139 未満である, the PM agent shall 本サブセクションの `/goal` 手順をスキップし、従来の「最大 2 パス」レビュー手順をそのまま適用する
6. The `requirements-review-gate.md` shall Mechanical Checks の 3 条件（numeric ID 網羅 / EARS 形式 AC 存在 / 実装語彙混入なし）の文言・順序を本変更後も保持し、判定対象自体を変更しない

### Requirement 2: Architect 自己レビューゲートへの `/goal` 運用ノート追記

**Objective:** As an Architect エージェント, I want `design-review-gate.md` の Mechanical Checks 節に `/goal` を使ったループ自動化の運用ノートが書かれてほしい, so that Requirements Traceability / File Structure Plan / orphan component の機械検出ループを `/goal` で確実に収束させられる

#### Acceptance Criteria

1. The `design-review-gate.md` shall Mechanical Checks 節の末尾に `/goal` を用いた自動ループ運用を説明するサブセクションを 1 箇所以上含む
2. The `design-review-gate.md` shall Architect 向けの `/goal` 完了条件文字列テンプレート例を、Issue 本文の仮案（「すべての numeric requirement ID が design.md に出現し / File Structure Plan に "TBD" やプレースホルダがなく / Components セクション全コンポーネントが対応ファイルを持つ」）と意味的に等価な形で 1 つ以上提示する
3. The `design-review-gate.md` shall 当該サブセクションが Claude Code v2.1.139 以降でのみ利用可能であることを 1 行以上で明示する
4. When Architect エージェントが Claude Code v2.1.139 以降の環境で `design.md` ドラフトを確定する直前である, the Architect agent shall 本サブセクションに記載された完了条件文字列に基づいて `/goal` を発行する手順を実行する
5. Where Claude Code が v2.1.139 未満である, the Architect agent shall 本サブセクションの `/goal` 手順をスキップし、従来の「最大 2 パス」レビュー手順をそのまま適用する
6. The `design-review-gate.md` shall Mechanical Checks の 3 条件（Requirements Traceability 全埋め / File Structure Plan に "TBD" 残置なし / Orphan component なし）の文言・順序を本変更後も保持し、判定対象自体を変更しない

### Requirement 3: 「最大 2 パス」表現と `/goal` のターン上限の関係明示

**Objective:** As a idd-claude エージェント運用者, I want 既存の「最大 2 パス」表現と `/goal` 利用時のターン上限の関係をルール本文で読み取れること, so that `/goal` が無限ループに陥らない上限規約として運用できる

#### Acceptance Criteria

1. The `requirements-review-gate.md` shall 「最大 2 パス」表現を本変更後も保持する
2. The `design-review-gate.md` shall 「最大 2 パス」表現を本変更後も保持する
3. The `requirements-review-gate.md` shall `/goal` 運用ノートのサブセクション内で、「最大 2 パス」を `/goal` 利用時のターン上限として併記する（撤廃ではなく併記方針）
4. The `design-review-gate.md` shall `/goal` 運用ノートのサブセクション内で、「最大 2 パス」を `/goal` 利用時のターン上限として併記する（撤廃ではなく併記方針）
5. While `/goal` 自動ループが 2 ターン経過しても完了条件を満たさない, the review-gate runbook shall 自動ループを終了し、人間エスカレーションまたは要件フェーズ戻しを選択する運用を明文化する

### Requirement 4: README への Claude Code 最低バージョン明記

**Objective:** As a idd-claude 新規導入者, I want `README.md` に Claude Code 最低バージョンが明記されていること, so that `/goal` を利用する運用と利用しない運用のどちらでも前提環境を即座に判定できる

#### Acceptance Criteria

1. The `README.md` shall Claude Code 最低バージョン要件として「基本動作: v2.0.0 / `/goal` 利用時: v2.1.139」相当の併記を 1 箇所以上に含む
2. The `README.md` shall 当該バージョン記載と self-review-gate の `/goal` 運用ノートとの対応関係（v2.1.139 未満では `/goal` 節をスキップする旨）を読み取れる形で記述する
3. The `README.md` shall 既存の Claude Code CLI インストール手順節（`npm install -g @anthropic-ai/claude-code` を含む節）と矛盾しない位置に当該バージョン要件を併記する
4. The `README.md` shall 既存 `.claude/rules/` 概要テーブル中の `requirements-review-gate.md` / `design-review-gate.md` の説明と、本機能で追記されるルール内容が乖離しない範囲に更新する

### Requirement 5: consumer 配布用テンプレートへの反映

**Objective:** As a idd-claude 利用 consumer リポジトリ運用者, I want `repo-template/.claude/rules/` 配下の同名ルールにも同じ `/goal` 運用ノート追記が反映されていること, so that `install.sh` 再実行で配布されるルールセットが self-hosting 本体と同じ規約で動作する

#### Acceptance Criteria

1. The `repo-template/.claude/rules/requirements-review-gate.md` shall Requirement 1 で本体に追記したものと意味的に等価な `/goal` 運用ノートのサブセクションを含む
2. The `repo-template/.claude/rules/design-review-gate.md` shall Requirement 2 で本体に追記したものと意味的に等価な `/goal` 運用ノートのサブセクションを含む
3. The `repo-template/.claude/rules/requirements-review-gate.md` shall 本体ファイルと同じ Mechanical Checks の 3 条件・「最大 2 パス」表現を保持する
4. The `repo-template/.claude/rules/design-review-gate.md` shall 本体ファイルと同じ Mechanical Checks の 3 条件・「最大 2 パス」表現を保持する
5. When 既 installed の consumer リポジトリ運用者が `install.sh` を再実行する, the install workflow shall 本変更後の `repo-template/.claude/rules/*review-gate*.md` を配布対象として扱う（再実行時の上書き挙動は既存 `install.sh` 規約に準拠）

### Requirement 6: dogfooding 確認

**Objective:** As a 本 Issue のレビュワー, I want 本 Issue 自身の PM / Architect 段階で新ルールに沿って `/goal` が運用された痕跡を PR から読み取れること, so that 規約改定が self-hosting 上で実機適用されたことを検証できる

#### Acceptance Criteria

1. When 本 Issue の PR 本文または `docs/specs/102-feat-rules-pm-architect-self-review-gate/` 配下の成果物を確認する, the PR shall PM 段階で `/goal` 完了条件を宣言してループしたこと、または `/goal` 非対応環境のため従来手順で進めたことのいずれかを 1 箇所以上で明示する
2. When 本 Issue が Architect ステージを経由する場合の PR 本文または `docs/specs/102-feat-rules-pm-architect-self-review-gate/` 配下の成果物を確認する, the PR shall Architect 段階で同様に `/goal` 運用の有無と結果を 1 箇所以上で明示する
3. The PR for Issue #102 shall 本 Requirement 6 を満たすために bash スクリプト・workflow YAML・install.sh / setup.sh を変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher shall 本変更によって `REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `PR_ITERATION_DEV_MODEL` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_MAX_TURNS` / `BASE_BRANCH` を含む既存の環境変数名・既定値・参照方法を一切変更しない
2. The labels script shall 本変更によって既存ラベル名（`auto-dev` / `claude-claimed` / `claude-picked-up` / `awaiting-design-review` / `ready-for-review` / `needs-iteration` / `needs-decisions` / `needs-rebase` / `needs-quota-wait` / `claude-failed` / `skip-triage` / `staged-for-release`）の名前・色・description を変更しない
3. The watcher shall 本変更によって `~/bin/issue-watcher.sh` を起動する cron 登録文字列および exit code の意味（正常 / 処理対象なし / エラー / escalate / skip）を変更しない
4. Where Claude Code が v2.1.139 未満である, the review-gate rules shall 本変更前と完全に同一の手順（Mechanical Checks → 判断レビュー → 最大 2 パス）で動作する

### NFR 2: 変更スコープの限定

1. The change set shall `.claude/rules/requirements-review-gate.md` / `.claude/rules/design-review-gate.md` / `repo-template/.claude/rules/requirements-review-gate.md` / `repo-template/.claude/rules/design-review-gate.md` / `README.md` の 5 ファイルを基本スコープとし、他の markdown は本変更で意味的に乖離が生じる場合に限り更新対象とする
2. The change set shall `local-watcher/bin/*.sh` / `install.sh` / `setup.sh` / `.github/workflows/*.yml` / `.github/scripts/*.sh` を変更しない
3. The change set shall `repo-template/CLAUDE.md` / `repo-template/.claude/agents/*.md` を本変更で必須スコープに含めない（self-review-gate ルール 2 種以外は対象外）

### NFR 3: 一貫性と可読性

1. The `requirements-review-gate.md` and `design-review-gate.md` shall self-hosting 本体と `repo-template/.claude/rules/` 配下の同名ファイルの間で、`/goal` 運用ノート節の見出し・例示・バージョン要件の文言を意味的に同一に保つ
2. The review-gate rules shall `/goal` 完了条件文字列の例示において、`When` / `If` / `While` / `Where` / `shall` 等の EARS トリガーキーワードを混入させない（運用ノート例示は自然言語の AND 結合で記述する）
3. The README shall Claude Code 最低バージョン記載と self-review-gate の `/goal` 運用ノートとの相互参照（リンクまたは節名の明示参照）を 1 箇所以上提供する

### NFR 4: migration note

1. Where 既存の「最大 2 パス」表現について本変更で運用解釈が拡張される（撤廃ではなく `/goal` 併記）, the README shall 当該変更点を 1〜3 行の migration note として 1 箇所以上に追記する

## Out of Scope

- Reviewer ↔ Developer の差し戻しループを `/goal` に置き換える変更（Reviewer / Developer agent の運用は本 Issue では変更しない）
- Developer の "shellcheck/actionlint クリーン" / "テスト通過" を `/goal` 化する変更
- `local-watcher/bin/issue-watcher.sh` の修正・新規 env var（例: `IDD_CLAUDE_USE_GOAL` 等）の追加
- LaunchDarkly / Unleash / GrowthBook 等の外部 Feature Flag SaaS との連携・置き換え
- `/goal` の評価モデル（既定 Haiku）を切り替える機構の実装、または `TRIAGE_MODEL` / `DEV_MODEL` 同等の評価モデル env var の新設
- 既存ラベル・cron 登録文字列・exit code・env var 名の変更
- `.claude/agents/*.md`（PM / Architect / Developer / Reviewer / PjM 各エージェント定義）の本文書き換え（self-review-gate 参照は既存リンクで足りる）
- `tasks-generation.md` / `feature-flag.md` / `design-principles.md` / `ears-format.md` への `/goal` 適用拡張
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への `/goal` 適用拡張
- `repo-template/CLAUDE.md` 本文への `/goal` 運用ノート転記（参照は既存の `.claude/rules/` テーブル経由で足りる）

## 確認事項（人間判断を仰ぐ項目）

Issue 本文「判断を委ねたい点」相当。本要件では仮案を採用しているが、人間レビュワーの最終確定を仰ぐ:

- **`/goal` 評価モデルの明示**: Mechanical Checks の評価モデルとして Claude Code 既定の Haiku で十分か、それともルール本文で Sonnet を明示推奨すべきか。本要件は「評価モデル切り替え機構の実装」を Out of Scope に置いたうえで、運用ノート上の推奨モデル表現はレビュワー判断に委ねる
- **「最大 2 パス」表現の扱い**: 本要件では Issue 本文の仮案に従い「撤廃ではなく `/goal` 利用時のターン上限として併記」を AC として確定したが、最終的に撤廃方針へ振り直す場合は本 requirements を差し戻すこと
- **consumer 配布範囲**: 本要件では `repo-template/.claude/rules/` 配下にも反映する方針を AC として確定したが、本体のみに留める場合は Requirement 5 を差し戻すこと
- **README 上のバージョン記載位置**: 本要件では「既存の Claude Code CLI インストール手順節と矛盾しない位置に併記」までを AC として確定し、具体的な節位置・節新設の要否は design / 実装で確定する余地を残している

## 自己レビュー記録

`.claude/rules/requirements-review-gate.md` のゲートに従って自己レビューを実施した記録。本 Issue 自身が `/goal` 適用対象の規約改定であるため、PM 段階で `/goal` 風の完了条件宣言で自己ループしたことを残す（dogfooding）。

### `/goal` 風の完了条件宣言（パス 1）

PM Mechanical Checks 完了条件:

1. すべての requirement 見出しに numeric ID がある（`Requirement 1` 〜 `Requirement 6`、`NFR 1` 〜 `NFR 4`）
2. すべての requirement に EARS 形式 AC が 1 件以上ある（`When` / `If` / `While` / `Where` / `The <subject> shall` のいずれかで始まる）
3. 実装語彙の混入がない（DB 名・フレームワーク名・API パターン等を AC 本文に書いていない）

### パス 1 セルフチェック結果

- **Mechanical Check 1（numeric ID）**: 機能要件 `Requirement 1` 〜 `Requirement 6`、非機能要件 `NFR 1` 〜 `NFR 4` がすべて numeric ID を持つ。英字 ID（`Requirement A` 等）の混入なし → **PASS**
- **Mechanical Check 2（EARS 形式 AC 存在）**: 各 Requirement / NFR の AC が `When` / `If` / `While` / `Where` / `The <subject> shall` のいずれかで始まることを目視確認 → **PASS**
- **Mechanical Check 3（実装語彙混入なし）**: AC 本文に bash 関数名・diff コマンド・正規表現パターン等の実装詳細を書いていない（評価モデル名「Haiku」は『確認事項』節に閉じ込め、AC 本文では使用していない） → **PASS**
- **判断レビュー（カバレッジ）**: Issue 本文の「受入基準の候補」「スコープ外」「制約・非機能要件」「仮案」が Requirement 1〜6 / NFR 1〜4 / Out of Scope / 確認事項のいずれかにマッピングされている → **PASS**
- **判断レビュー（曖昧語）**: "robust" / "fast" / "secure" 等の曖昧語は使っていない。バージョン要件は v2.0.0 / v2.1.139 として数値化済 → **PASS**

### パス 1 結論

全 Mechanical Checks と判断レビューを 1 パスで通過したため、再パスは不要。`requirements.md` を確定する。
