# Requirements Document

## Introduction

idd-claude の PR Reviewer（`local-watcher/bin/modules/pr-reviewer.sh` の既定プロンプトを生成する
ヒアドキュメント部）は、現状のプロンプト本文に「網羅的に全指摘を一度に出す」要求と
「`docs/specs/<番号>-<slug>/` 配下の spec 文書間（requirements ⇄ design ⇄ tasks）整合チェック」
の指示が欠落している。その結果、LLM が 1 パスあたり数件の指摘のみを返す drip-feed 挙動となり、
反復ラウンドが 4 回以上に伸びてトークンコスト・人手介入・収束遅延を招いている。本 Issue は、
**既定プロンプト文言のみの変更**で 1 パス目の指摘密度を高め、反復ラウンドを 1〜2 パスに収束させる
ことを目的とする。既存の出力契約（`## 概要` / `## 指摘事項` / `VERDICT:` 1 行）と
`PR_REVIEWER_PROMPT` による上書き運用は維持し、後方互換性を壊さない。

## Requirements

### Requirement 1: 既定プロンプトへの網羅性要求の追加

**Objective:** As a PR Reviewer 利用者（watcher 運用者・Architect・Developer）, I want 既定プロンプトが「差分全体を 1 パスで網羅し列挙漏れなく指摘する」ことを LLM に明示的に要求すること, so that drip-feed による反復ラウンドが削減され、トークンコストと収束時間が下がる。

#### Acceptance Criteria

1. The PR Reviewer default prompt shall 「差分全体を網羅的に走査し、検出した指摘を 1 パスで列挙漏れなく出力する」旨の指示を本文中に含める
2. The PR Reviewer default prompt shall 「同一観点で複数箇所に存在する指摘は drip-feed せず最初のパスで全件列挙する」旨の指示を本文中に含める
3. The PR Reviewer default prompt shall 既存の「レビュー観点（優先度順）」5 項目（正確性のバグ / 受入基準の未カバー / テスト不足 / セキュリティ退行 / 後方互換性の破壊）の構造と順序を保持する
4. When `PR_REVIEWER_PROMPT` 環境変数が未設定または空である場合, the PR Reviewer shall 上記網羅性要求を含む新しい既定プロンプトを使用する
5. Where `PR_REVIEWER_PROMPT` 環境変数に非空の値が設定されている場合, the PR Reviewer shall その値を優先して使用し、新しい既定プロンプトの文言を上書きしない

---

### Requirement 2: spec 文書間整合チェック観点の追加

**Objective:** As a PR Reviewer 利用者, I want 既定プロンプトが `docs/specs/<番号>-<slug>/` 配下の requirements.md / design.md / tasks.md の内部整合（AC ⇄ 設計 ⇄ タスクのトレーサビリティ）を 1 パス目でチェックするよう LLM に指示すること, so that spec 文書間の不整合が後段のレビュー / iteration で発覚せず、初回パスで検出される。

#### Acceptance Criteria

1. The PR Reviewer default prompt shall 「diff に `docs/specs/<番号>-<slug>/` 配下のファイル変更が含まれる場合は requirements.md / design.md / tasks.md の整合性を突き合わせて検査する」旨の指示を本文中に含める
2. The PR Reviewer default prompt shall 「requirements.md の各 AC が design.md でカバーされているか」を整合チェック観点として明示する
3. The PR Reviewer default prompt shall 「design.md の Components / Interfaces が tasks.md のタスクで実装手順化されているか」を整合チェック観点として明示する
4. The PR Reviewer default prompt shall 「tasks.md の各タスクの `_Requirements:_` アノテーションが requirements.md の実在 AC を参照しているか」を整合チェック観点として明示する
5. If diff に `docs/specs/` 配下のファイル変更が含まれない場合, the PR Reviewer default prompt shall spec 整合チェック観点の指示が他のレビュー観点（コード差分の正確性・テスト不足等）の実施を阻害しないよう、観点として条件付き適用であることを文中で明確化する

---

### Requirement 3: 既存出力契約の維持

**Objective:** As a watcher 運用者, I want 既定プロンプト変更後も既存の出力フォーマット契約（`## 概要` / `## 指摘事項` / `## 結論` / `VERDICT:` 1 行）が崩れず、後段の parse 側（VERDICT 検出・ラベル付与）が無修正で動作すること, so that 既存の VERDICT 検出・iteration ラベル付与・commit status publish の挙動が壊れない。

#### Acceptance Criteria

1. The PR Reviewer default prompt shall 出力構造として `## 概要` / `## 指摘事項` / `## 結論` の 3 セクション見出しを厳守させる指示を保持する
2. The PR Reviewer default prompt shall 結論セクションの最終行に `VERDICT: needs-iteration` または `VERDICT: approve` のいずれか 1 行を単独で出力させる指示を保持する
3. The PR Reviewer default prompt shall 指摘事項の各行が `[high|medium|low] <file>:<line> — <内容と根拠>` 形式である指示を保持する
4. The PR Reviewer default prompt shall 「指摘が無ければ『指摘なし』」と記述する指示を保持する
5. The PR Reviewer default prompt shall 「ファイルを編集しない（read-only）」「差分に実在する file:line を根拠として必ず引用する」「スタイル / lint レベルの指摘は対象外」の 3 制約を保持する
6. The PR Reviewer default prompt shall プレースホルダ `{BASE}` / `{HEAD}` / `{PR}` を未置換のまま出力し、置換は呼び出し元に委ねる構造を保持する

---

### Requirement 4: 後方互換性と既定値の据え置き

**Objective:** As an existing watcher user, I want 本変更が既定プロンプト文言のみで完結し、コードフロー・env var・ラベル・exit code・ログ書式が変更されないこと, so that 既存 cron / launchd 設定を変えずに本変更を取り込め、`PR_REVIEWER_PROMPT` の上書き運用者にも影響が出ない。

#### Acceptance Criteria

1. The PR Reviewer module shall 本変更によって既存の env var 名（`PR_REVIEWER_PROMPT`, `PR_REVIEWER_ITERATION_PATTERN`, `PR_REVIEWER_GIT_TIMEOUT`, `PR_REVIEWER_HEAD_PATTERN`, `PR_REVIEWER_STATUS_CHECK_ENABLED`, `FULL_AUTO_ENABLED` 等）の名前・既定値・意味を変更しない
2. The PR Reviewer module shall 本変更によって既存のラベル名（`needs-iteration`, `ready-for-review`, `claude-failed` 等）の付与契約を変更しない
3. The PR Reviewer module shall 本変更によって exit code の意味・ログ出力先・ログ prefix を変更しない
4. The PR Reviewer module shall 本変更が既定プロンプト本文の差し替えのみで完結し、プロンプト解決順序（`PR_REVIEWER_PROMPT` 非空時は override / 空時は既定）と置換ロジック・一時ファイル経由の引き渡し方式を変更しないことを保証する
5. Where `PR_REVIEWER_PROMPT` を非空で設定済みの既存利用者が存在する場合, the PR Reviewer shall 本変更導入後もその値を優先使用し、新しい既定プロンプト文言が一切流入しないことを保証する

---

### Requirement 5: root ↔ repo-template 二重管理の同期

**Objective:** As an idd-claude maintainer, I want 既定プロンプト文言の更新が root と repo-template の二系統で byte 一致を保つこと, so that consumer repo が `install.sh` 再実行や次回更新時に同じ既定プロンプトを受け取れる。

#### Acceptance Criteria

1. The idd-claude repository shall 既定プロンプト本文を含むスクリプトが root 系統と repo-template 系統の両方に同一実体として存在する場合、双方で byte 一致するよう同一 PR で更新する（片系統のみが存在する場合は当該系統のみを更新する）
2. The idd-claude repository shall 既定プロンプト変更後に root と repo-template 間の差分がゼロであること（両系統に存在する場合）を `diff -r` 相当の検査で確認可能な状態を保つ
3. The README.md shall プロンプト変更の意図と上書き方法（`PR_REVIEWER_PROMPT` 環境変数による override）が、本変更で文言が改訂された場合でも引き続き正しく記述されている状態を保つ

## Non-Functional Requirements

### NFR 1: 反復ラウンド削減効果

1. When 同等規模の設計 PR / 実装 PR で本変更前後を比較した場合, the PR Reviewer iteration 反復ラウンド数 shall 現状の平均 4 回以上から 1〜2 回に減少することを観測可能とする（observable な指標として PR ごとの round counter / `pr-iteration:` ログ行を集計する形で検証する）
2. The PR Reviewer default prompt shall プロンプト文言の追加によって 1 パスあたりの LLM 出力トークン量が増加することを許容する一方、トータルのラウンド数削減によって PR 全体の累計トークン消費量が現状と同等以下に収まることを目標値として明示する（具体的な数値は設計 / 検証フェーズで定める）

### NFR 2: 観測可能性

1. The PR Reviewer module shall 本変更後も既存と同一の prefix（`pr-reviewer:` / `pr-iteration:`）・timestamp 書式（`[YYYY-MM-DD HH:MM:SS]`）で観測ログを出力する
2. The PR Reviewer module shall 本変更によって 1 サイクルあたりの観測ログ行数が同等以下に保たれることを保証する（プロンプト文言変更に伴う追加ログを発生させない）

## Out of Scope

- 既定プロンプト本文を生成するヒアドキュメント以外のコードフロー（プロンプト解決順序・置換ロジック・一時ファイル生成・呼び出し元連携）の変更
- 新規 env var の追加（プロンプト変更を制御する gate flag を追加しない。Issue 本文方針に基づく）
- 既存 env var の既定値変更
- VERDICT 検出 regex（`PR_REVIEWER_ITERATION_PATTERN`）の変更
- commit status publish の挙動変更
- 既定プロンプトの **完全な書き直し**（既存の優先度順 5 観点・出力契約は保持し、網羅性と spec 整合チェックの追加を主眼とする）
- `PR_REVIEWER_PROMPT` 以外の上書き手段（tool 別プロンプト等）の追加
- LLM 出力トークン量の絶対上限制御
- 反復ラウンドの上限値（`PR_ITERATION_MAX_ROUNDS`）の変更
- レビュー対象 PR 検出ロジックの変更
- repo-template / consumer repo への影響を伴う破壊的変更（migration note を要するもの）

## Open Questions

- **濃淡付け（high / medium 優先 vs 完全網羅）の方針**: Issue 本文の「仮案・判断を委ねたい点」に記載のトレードオフ（網羅性強化により 1 ラウンド負荷が増えるリスク）について、「high / medium を優先し low は任意」とする濃淡付けを既定プロンプト文中に明記するか、完全網羅を要求するかは Architect / Developer の設計判断に委ねる。本要件では「low の任意化」「完全網羅」のいずれを採用しても AC 1.1, 1.2 を満たすものとする
- **整合チェック観点の表現粒度**: AC 2.2〜2.4 の観点を 3 つの独立した bullet として記述するか、1 つにまとめて記述するかはプロンプトの可読性 / LLM の理解度に応じて Architect / Developer が決定する。要件としては 3 観点が文面上識別可能であれば形式は問わない
- **既定プロンプトの目標長**: プロンプト文言の追加でヒアドキュメント本文がどの程度増えるかは Architect / Developer の文面設計に委ねる。要件としては「過度な長文化により LLM の attention が散らないこと」を品質目標として置く程度に留める
- **NFR 1.2 のトータルトークン量目標値**: 「現状と同等以下」を具体的な数値（例: -20% / 同等）として宣言するかは検証フェーズで定める。本 PR で計測手段（既存 watcher ログから集計）を提示し、目標値は別途運用観測で決定する
