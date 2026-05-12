# Requirements Document

## Introduction

idd-claude のワークフローでは Claude Code（LLM）が PM / Architect / Developer / Reviewer / PjM
の各役割で reasoning を行うが、現状の `CLAUDE.md` には「内部思考に使う自然言語」と
「ユーザーに見える成果物に使う自然言語」の方針が明文化されていない。

英語は同等内容を表現するのに必要なトークン数が日本語より少ないため、reasoning（chain-of-thought
／scratch ／内部メモ）を英語ベースに統一することで、reasoning トークン消費の抑制が見込める。
一方で、Issue / PR / コメント / `docs/specs/` 配下の成果物などユーザーが直接読むアウトプットは
従来どおり日本語ベースを維持し、運用者の可読性とレビュー速度を損なわない必要がある。

本 Issue は、この「内部思考 = 英語 / ユーザー I/F = 日本語」という方針を、idd-claude 自身
（self-hosting）と install.sh で配布される consumer repo の双方に対して、適切な場所に
明文化することを目的とする。実装詳細（どのファイルのどの節に何を書くか）の最終決定は
`design.md` に委ね、本書ではあくまで「何が達成されていれば完了とみなすか」を定義する。

## Requirements

### Requirement 1: 思考言語と出力言語の方針明文化

**Objective:** As an idd-claude プロジェクト運用者, I want LLM の内部思考言語とユーザー向け
出力言語の使い分け方針を CLAUDE.md 系のプロジェクト憲章で参照可能にしたい, so that 各エージェント
（PM / Architect / Developer / Reviewer / PjM）が一貫した言語選択で動作し、reasoning トークン
消費が抑制されつつユーザーの可読性が保たれる

#### Acceptance Criteria

1. The CLAUDE.md shall LLM の内部思考（reasoning / chain-of-thought / 内部スクラッチパッド）に
   英語をベース言語として用いる旨を明示的に記述する
2. The CLAUDE.md shall ユーザーが直接読むアウトプット（後述 Requirement 2 のスコープ）に
   日本語をベース言語として用いる旨を明示的に記述する
3. When エージェントが作業を開始したとき, the Claude Code エージェント shall 当該方針節を
   読むことで内部思考と出力の言語選択を一意に決定できる（追加の確認なしに）
4. The 方針節 shall 既存の `## エージェント連携ルール` / `## コード規約` / `## 禁止事項` などの
   見出しと衝突せず、独立して識別できる見出し（h2 レベル）として配置される
5. If エージェントが本方針節を読まずに作業を開始したとき, the Claude Code エージェント shall
   既存の他の規約（EARS 記法・コミット規約等）と同様にプロジェクト憲章の一部として強制力を
   受けるものとして扱う

### Requirement 2: ユーザー向けアウトプットの言語スコープ定義

**Objective:** As an idd-claude プロジェクト運用者, I want「ユーザー向けアウトプット = 日本語」
の対象範囲を曖昧さなく列挙したい, so that エージェントがアウトプットの種類ごとに迷わず言語を
選択でき、レビュー時の指摘・差し戻しが発生しない

#### Acceptance Criteria

1. The CLAUDE.md shall 日本語をベースとするアウトプット種別を列挙する。少なくとも以下を含める:
   GitHub Issue / PR の本文・コメント・レビューコメント、`docs/specs/<番号>-<slug>/` 配下の
   markdown 成果物（`requirements.md` / `design.md` / `tasks.md` / `impl-notes.md` /
   `review-notes.md`）
2. The CLAUDE.md shall 英語表記が固定されている要素を例外として明示する。少なくとも以下を含める:
   EARS のトリガーキーワード（`When` / `If` / `While` / `Where` / `shall`）、
   Conventional Commits のプレフィックス（`feat` / `fix` / `docs` 等）、ブランチ名規約
   （`claude/issue-<番号>-<slug>`）、識別子・コマンド名・ファイルパス
3. Where コミットメッセージ・PR タイトル・ブランチ名・ログ出力等のグレーゾーンが存在する場合,
   the CLAUDE.md shall それぞれを「日本語ベース」「英語ベース」「混在許容」のいずれかに分類して
   明示する
4. If アウトプット種別が方針節で言及されていないとき, the Claude Code エージェント shall 既定で
   日本語ベースを選択する（fallback ルールが方針節に明記されている）

### Requirement 3: 適用先リポジトリの後方互換性

**Objective:** As an idd-claude メンテナ, I want 本変更を idd-claude 自身（self-hosting）と
consumer repo の双方に対して後方互換に適用したい, so that 既稼働の cron / watcher / 既 install
済み consumer repo の挙動を壊さずに方針を浸透させられる

#### Acceptance Criteria

1. The 変更後の `repo-template/CLAUDE.md` shall 既存の h2 セクション構成（`## 技術スタック` /
   `## コード規約` / `## 禁止事項` / `## エージェント連携ルール` / `## Feature Flag Protocol` 等）
   の見出し名・順序・既存本文を破壊的に書き換えない（追記または既存節への小規模追補に限定する）
2. The 変更後の root `CLAUDE.md` shall 既存の h2 セクション構成・本文と矛盾せず、self-hosting
   運用上 watcher・cron が参照する既存規約（env var 名・ラベル・コミット規約・ブランチ命名）を
   従来どおり保つ
3. When consumer repo で `install.sh` を再実行したとき, the install.sh shall 既存の冪等性ルール
   （`.bak` バックアップまたは `--force` opt-in 上書き）に従い、既配置 `CLAUDE.md` を破壊しない
4. If `repo-template/CLAUDE.md` への変更が既存節を書き換える形で行われる場合, the 変更 PR shall
   README に migration note を含める
5. The 変更 PR shall `repo-template/CLAUDE.md` と root `CLAUDE.md` の両方を同一 PR 内で更新する
   （二重管理によるドリフトを防ぐ）

### Requirement 4: 既存規約との整合性

**Objective:** As an idd-claude エージェント, I want 言語方針が既存の EARS 記法ルール・
エージェント定義・テンプレートと矛盾なく解釈できるようにしたい, so that 既存規約と新方針の
衝突による再解釈コストや差し戻しを発生させない

#### Acceptance Criteria

1. The CLAUDE.md の言語方針 shall `.claude/rules/ears-format.md` の「トリガーキーワードは英語固定、
   可変部のみ日本語可」と矛盾しない（EARS の可変部は Requirement 2 の「日本語ベース」スコープに
   含まれることが整合的に読み取れる）
2. The CLAUDE.md の言語方針 shall `.claude/agents/*.md`（PM / Architect / Developer / Reviewer /
   PjM）の既存の日本語による指示文と矛盾しない（エージェント定義は人間運用者向けに書かれており、
   出力言語ではなく「エージェントへの指示書き」として扱われる旨が方針節から判別可能）
3. When エージェントが reasoning 中に EARS 形式や Conventional Commits 等の英語固定要素を扱うとき,
   the Claude Code エージェント shall 言語方針節の例外規定に従って英語表記を保持する
4. If 言語方針節とその他ルールファイル（`.claude/rules/*.md`）の間に矛盾が生じたとき,
   the エージェント shall 解釈を確定せず、PM / 人間にエスカレーションする

### Requirement 5: 方針節への到達性

**Objective:** As an idd-claude エージェント, I want 言語方針節を作業開始時に確実に読み込める
状態にしたい, so that 「読み忘れによる日本語 reasoning」「英語アウトプット」といったルール違反が
発生しない

#### Acceptance Criteria

1. The CLAUDE.md shall 言語方針節をファイル冒頭の「すべてのエージェントは作業開始前にこのファイルを
   読み直してください」という既存記述のスコープ内に含む（独立ファイルに外出ししない、もしくは
   外出しする場合は CLAUDE.md から明示リンクで参照される）
2. Where 言語方針節を独立ルールファイル（例: `.claude/rules/language-policy.md`）として
   切り出す設計が採られる場合, the CLAUDE.md shall 既存の「エージェントが参照する共通ルール」
   表に当該ファイルを追記し、どのエージェントが Read するかを明示する
3. The 言語方針節 shall `.claude/agents/*.md` の各エージェント定義を個別に書き換えなくても、
   `CLAUDE.md` を読むだけで方針が確実に届く構造になっている

## Non-Functional Requirements

### NFR 1: ドキュメント可読性

1. The 言語方針節 shall 60 行以内で記述される（既存セクションと同等の粒度を保ち、CLAUDE.md
   全体の見通しを損なわない）
2. The 言語方針節 shall 内部思考言語と出力言語の対比が一目で把握できる形式（箇条書きまたは表）で
   提示される

### NFR 2: 既稼働運用への影響

1. The 変更 shall 既存の cron / launchd で稼働中の `local-watcher/bin/issue-watcher.sh` の
   挙動を変更しない（env var 名 / exit code / ラベル遷移 / ログ出力先を保つ）
2. The 変更 shall 次回 watcher 実行時に新方針が自動的に適用される（dogfooding 上、別途の
   手動デプロイを必要としない）

### NFR 3: 検証可能性

1. When PR を作成したとき, the PjM エージェント shall CLAUDE.md（root および repo-template 双方）の
   diff が言語方針節の追加 / 修正に限定されていることを確認できる
2. The 変更 shall `shellcheck` / `actionlint` の警告を増やさない（markdown のみの変更であれば
   この NFR は trivially 充足）

## Out of Scope

- 既存の `.claude/agents/*.md`（エージェント定義ファイル）の日本語本文を英語化すること
  （エージェント定義は人間運用者が読むドキュメントであり、本 Issue のスコープ外）
- 既存の `docs/specs/<番号>-<slug>/` 配下の過去成果物（requirements.md / design.md 等）を
  遡及的に書き換えること
- LLM のシステムプロンプト本体（Claude Code 側）に対する変更（idd-claude はプロジェクト憲章
  CLAUDE.md による誘導しか行わない）
- reasoning トークン消費量の実測・モニタリング機構の構築（効果測定は本 Issue では行わない）
- 日本語以外の言語（中国語・韓国語等）への多言語化対応
- bash スクリプト内コメント・ログ出力メッセージの言語統一（grey zone として方針節で
  分類は行うが、既存実装の書き換えは行わない）
- `README.md` 本文の言語方針記述（README は OSS ユーザー向けドキュメントとして既存方針を
  維持。CLAUDE.md とのリンクのみ追加可能性あり、これは design 判断）

## Open Questions

- 言語方針節を CLAUDE.md 本体に追記するか、`.claude/rules/language-policy.md` として独立
  ルールファイルに分離するかは design.md（Architect）の判断に委ねる（要件としては「到達性が
  確保されること」のみ規定）
- コミットメッセージ本文（Conventional Commits の prefix 後の説明部分）を日本語ベースとするか
  英語ベースとするかは、既存 commit log を確認した上で design / 実装フェーズで分類を決定する
  （既存運用上は日本語が混在しており、本 Issue で破壊的に変更すべきかは人間判断が必要な
  可能性あり）
- bash スクリプトのログ出力メッセージ（`issue-watcher.sh` の `echo` 文字列等）は現状日本語混在。
  これを「ユーザー向けアウトプット = 日本語」に含めるか「内部 I/O = 英語可」に含めるかは
  design フェーズで明示分類する
- ブランチ slug（`claude/issue-<番号>-<slug>`）の slug 部分は Issue タイトルを英語化したものを
  使うか、ローマ字化したものを使うかは現状 ad-hoc。本 Issue で確定させるかは人間判断
