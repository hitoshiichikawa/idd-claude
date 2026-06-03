# Requirements Document

## Introduction

Issue #279 / PR #280 で導入された Security Review Processor は **advisory 固定**で実装されており、
`/security-review` の検出結果に関わらずマージブロック操作を行わない設計となっている。本機能は
その上に **strict モード**を追加し、検出された脆弱性のうち運用者が指定する severity 閾値以上の
項目が 1 件以上見つかった場合に、対象 PR へマージ阻害を意図したラベルを付与して人間レビュワー
（または既存 PR Iteration Processor (#26) 経由で auto-dev）に修正を促す。strict モードは
opt-in（既定 advisory）で導入し、未設定 / `advisory` / 不正値ではすべて既存 #279 の挙動（advisory）
を維持する。Reviewer エージェントの 3 カテゴリ判定・PR Reviewer Processor (#261)・PR Iteration
Processor (#26)・Merge Queue 等の既存挙動および後方互換性は維持する。

## Requirements

### Requirement 1: モード切替の env 仕様と既定 advisory

**Objective:** As an idd-claude operator, I want Security Review の挙動を env var で
advisory / strict に切り替えたい, so that 既存運用に影響を与えずに段階的に strict 化を試行できる

#### Acceptance Criteria

1. While モード指定 env が `strict` と完全一致しない（未設定 / 空文字 / `advisory` / `Strict` 等の
   typo / その他不正値を含む）状態である間, the Security Review Gate shall ゲート挙動を `advisory`
   と解釈する
2. While モード指定 env が `strict` と完全一致している状態である間, the Security Review Gate
   shall ゲート挙動を `strict` と解釈し、Requirement 3 で定めるラベル付与判定を実行する
3. The Security Review Gate shall 解決されたゲート挙動値（`advisory` / `strict`）をサイクル
   サマリログに 1 行記録する
4. If モード指定 env に不正値（`strict` / `advisory` 以外）が設定された場合, the Security
   Review Gate shall 警告ログを 1 行記録した上で `advisory` 相当の挙動を採用する（既存 #279 の
   `sec_check_strict_request` の safe-fallback と等価）
5. The Security Review Gate shall モード指定 env の既定値を `advisory` とし、未設定の状態で
   watcher を起動しても本機能導入前と観測可能挙動が等価となるよう振る舞う

### Requirement 2: severity 閾値の env 仕様

**Objective:** As an idd-claude operator, I want マージ阻害ラベル付与の severity 閾値を env var で
指定したい, so that リポジトリ特性に応じて検出感度を調整できる

#### Acceptance Criteria

1. The Security Review Gate shall severity 閾値を表す env var を受け付け、許容値を
   `critical` / `high` / `medium` / `low` / `info` の 5 段階の小文字 token に限定する
2. The Security Review Gate shall severity 閾値 env の既定値を `high` とする（未設定時は
   `critical` および `high` の 2 段階を「閾値以上」として扱う）
3. When severity 閾値 env が 5 段階のいずれかに完全一致する値で設定された場合, the Security
   Review Gate shall その閾値と同等以上の severity（critical > high > medium > low > info の
   順序）に該当する検出項目を「閾値以上」と判定する
4. If severity 閾値 env に上記 5 段階に含まれない値（typo / 大文字混在 / 空白混入等）が
   設定された場合, the Security Review Gate shall 警告ログを 1 行記録した上で既定値
   （`high`）に倒して処理を継続する
5. The Security Review Gate shall 解決された severity 閾値値をサイクルサマリログに 1 行記録する

### Requirement 3: strict モードのラベル付与判定

**Objective:** As an idd-claude operator, I want strict モードで severity 閾値以上の検出 1 件以上が
見つかった PR にマージ阻害ラベルを付与したい, so that 重大な脆弱性を含む変更が無人マージされない

#### Acceptance Criteria

1. When ゲート挙動が `strict` と解決され、かつ対象 PR のスキャン結果に severity 閾値以上の検出が
   1 件以上含まれていた場合, the Security Review Gate shall 対象 PR にマージ阻害を意図した
   ラベルを 1 つ付与する
2. When ゲート挙動が `strict` と解決され、かつ対象 PR のスキャン結果に severity 閾値以上の検出が
   0 件であった場合, the Security Review Gate shall 対象 PR へのマージ阻害ラベル付与を行わず、
   既存 #279 advisory と同等のコメント投稿のみを行う
3. While ゲート挙動が `advisory` と解決された状態である間, the Security Review Gate shall
   severity 閾値以上の検出件数に関わらず、対象 PR へのマージ阻害ラベル付与を一切行わない
4. The Security Review Gate shall ラベル付与時にも既存 #279 と同等のコメント投稿
   （`## セキュリティレビュー結果` 見出し + 検出項目 + hidden marker）および
   `security-notes.md` 書き出しを併せて行う
5. The Security Review Gate shall ラベル付与判定の結果（付与有無 / 検出件数 / 閾値以上件数 /
   閾値値）を運用者がログから判定できる形で 1 行記録する
6. The Security Review Gate shall マージ阻害ラベルが既に対象 PR に付与されている状態で同一
   SHA に対する再判定を行わない（既存 #279 の hidden marker による SHA 単位の冪等性に従う）

### Requirement 4: PR Iteration Processor (#26) との接続および運用者 override

**Objective:** As an idd-claude operator, I want strict モードで付与されたラベルが既存 PR
Iteration 動線で扱えるようにし、false positive 時は手動で override できるようにしたい,
so that 検出結果が無人パイプラインで自然に処理されつつ運用者の最終判断を尊重できる

#### Acceptance Criteria

1. The Security Review Gate shall 付与するマージ阻害ラベルを、人間運用者が GitHub UI から
   手動で剥がすことによって当該 PR の処理経路を override できる形で実装する
2. When 運用者が当該マージ阻害ラベルを対象 PR から手動で剥がした場合, the Security Review Gate
   shall 同一 SHA に対するラベル再付与を行わない（既存 #279 の hidden marker による
   SHA 単位の冪等性に従い、同一 SHA に対する再評価を抑止する）
3. When 対象 PR の head コミットが更新され、結果として head SHA が変化した場合, the Security
   Review Gate shall 新しい SHA に対して Requirement 3 の判定を新規に実行する（過去 SHA で
   剥がされたラベル状態は新 SHA の判定に影響しない）
4. The Security Review Gate shall マージ阻害ラベルが PR Iteration Processor (#26) の反復対応
   動線にそのまま流れることを前提とした既存ラベル運用（既存 `needs-iteration` 流用または
   新規ラベルの追加）を、その動線が成立する形で実装する（具体的なラベル名選定および
   `.github/scripts/idd-claude-labels.sh` への追加要否は設計領分）
5. The Security Review Gate shall マージ阻害ラベル付与時に投稿するコメント本文に、運用者が
   false positive であると判断した場合の override 手順（ラベル手剥がし）を 1 行以上で明示する

### Requirement 5: severity 抽出と閾値以上件数のカウント

**Objective:** As an idd-claude operator, I want `/security-review` の出力から severity 閾値以上の
検出件数を機械的にカウントしたい, so that ラベル付与判定が決定論的に行える

#### Acceptance Criteria

1. The Security Review Gate shall `/security-review` の出力テキストから 5 段階 severity
   （`critical` / `high` / `medium` / `low` / `info`）の検出件数を抽出する手段を備える
2. When severity 閾値が解決された場合, the Security Review Gate shall 閾値以上に該当する
   severity 段階の検出件数を合算し、ラベル付与判定の入力として用いる
3. If severity 抽出処理が失敗した場合（出力スキーマが想定外 / `/security-review` 自身の実行
   失敗等）, the Security Review Gate shall ラベル付与を行わず安全側 advisory に倒した上で
   既存 #279 の `kind=scan-failed` 経路と同等のエラーコメントを投稿する
4. The Security Review Gate shall severity 抽出結果（5 段階別の件数 / 閾値以上合計件数）を
   `security-notes.md` の Severity Summary 表に記録する（既存 #279 Req 3.5 の成果物書き出しに
   情報追加する形）

### Requirement 6: 既存 #279 advisory 動作および他プロセッサとの非回帰

**Objective:** As an idd-claude operator, I want strict モード追加によって既存 #279 advisory
動作・既存 Reviewer / PR Iteration / Merge Queue / PR Reviewer Processor (#261) の動作が
変化しないことを保証したい, so that strict モード未使用リポジトリでは導入前と完全に等価な挙動が
維持される

#### Acceptance Criteria

1. While モード指定 env が `strict` と完全一致しない状態である間, the Security Review Gate
   shall 既存 #279 advisory 実装と観測可能挙動が等価である（コメント投稿 / hidden marker /
   `security-notes.md` 書き出しの仕様が #279 と同一であり、ラベル付与を一切行わない）
2. The Security Review Gate shall Reviewer エージェントの判定対象カテゴリ（missing AC /
   missing test / boundary 逸脱の 3 カテゴリ）を追加・変更・削除しない
3. The Security Review Gate shall Reviewer の `review-notes.md` 内容および
   `RESULT: approve|reject` 判定論理に介入しない
4. The Security Review Gate shall PR Reviewer Processor (#261) の `needs-iteration` 付与
   動線および Merge Queue / Auto Rebase / Design Review Release の各既存プロセッサのラベル
   操作領域に追加・変更を加えない（流用ラベルを採用する場合でも、当該プロセッサが扱う
   ラベル「種別」の意味的変更は行わない）

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While モード指定 env が `strict` と完全一致しない状態である間, the watcher shall 本機能
   導入前および既存 #279 advisory 実装と観測可能挙動が等価である（既存のラベル遷移・コメント
   投稿・他プロセッサ起動順序・exit code 意味を含む）
2. The Security Review Gate shall 既存 env var（`REPO` / `REPO_DIR` / `BASE_BRANCH` /
   `PR_REVIEWER_ENABLED` / `PR_ITERATION_ENABLED` / `MERGE_QUEUE_ENABLED` / `LABEL_*` 系 /
   既存 #279 で導入された `SECURITY_REVIEW_*` env 群）の名前・意味・既定値を変更しない
3. The Security Review Gate shall 既存 cron / launchd 登録文字列を変更しない

### NFR 2: ランタイム非依存

1. The Security Review Gate shall 新規ランタイム（Node.js / Python / Ruby 等）の追加を伴わずに
   動作する
2. The Security Review Gate shall 依存 CLI を既存パイプラインで前提済みの集合（`gh` / `jq` /
   `git` / `flock` / `claude` 等）の範囲に留め、新規 CLI ツールの導入を行わない

### NFR 3: 観測可能性

1. The Security Review Gate shall 主要な分岐点（モード解決値 / severity 閾値解決値 / severity
   抽出件数 / 閾値以上件数 / ラベル付与有無 / 既存ラベル検出による skip / 不正値 fallback /
   severity 抽出失敗）を運用者がログから判定できる形で記録する

### NFR 4: 冪等性

1. The Security Review Gate shall 同一 PR 同一 SHA に対して watcher を複数回起動しても、
   観測可能な副作用（PR コメント / ラベル / 成果物ファイル）が 1 回分のみとなることを保証する
   （既存 #279 NFR 4.1 と同一の冪等性契約に従う）
2. While 運用者が手動でマージ阻害ラベルを剥がした状態である間, the Security Review Gate
   shall 同一 SHA に対する再付与を行わない

### NFR 5: 静的解析品質

1. While 本機能の新規／変更ファイル群に対して `shellcheck`（および該当する場合 `actionlint`）を
   実行した状態である間, the static analysis result shall 警告ゼロで完了する（既存リポジトリ
   運用と同じ `.shellcheckrc` / `actionlint` 抑止方針に従う）

### NFR 6: ドキュメント整合性

1. The Security Review Gate shall README の「Security Review Processor (#279)」節に、本機能で
   追加される env var 名・既定値・有効化条件・severity 閾値の意味・ラベル付与挙動・運用者
   override 手順を明記する
2. While 本機能の追加または挙動変更を含む PR が作成された状態である間, the documentation
   shall 同一 PR 内で README / CLAUDE.md / 該当 rule ファイルの該当箇所が同時更新されている

### NFR 7: 二重管理整合（agents / rules を編集する場合）

1. Where 本機能の実装が `.claude/agents/*.md` または `.claude/rules/*.md` の変更を伴う場合,
   the implementation shall 同一 PR 内で root `.claude/{agents,rules}/` と
   `repo-template/.claude/{agents,rules}/` の双方を byte 一致で更新する
2. While 上記更新が同一 PR に含まれた状態である間, the verification step shall
   `diff -r .claude/agents repo-template/.claude/agents` および
   `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認する

## Out of Scope

- 検出脆弱性に対する自動修正（auto-fix）コミット生成（既存 #279 と同一）
- severity 閾値の動的調整・A/B テスト・ユーザー属性別の出し分け
- サードパーティ製セキュリティスキャナの統合（既存 #279 と同一）
- `/security-review` 公式実装自体の差し替え・改造
- 既存 Reviewer の判定対象カテゴリ拡張（Reviewer は 3 カテゴリ判定のまま不変、本機能とは
  独立に動作する）
- セキュリティ検出結果に基づくテレメトリの自動収集・外部送信
- 既存リポジトリの過去 PR への遡及スキャン
- マージブロックを GitHub branch protection ルール経由で強制する設定（本機能は idd-claude
  パイプライン内のラベル付与までを責務とし、branch protection 設定は運用者領域）
- false positive の機械学習的な抑止・自動 dismissal（運用者の手動 override のみを提供）

## Open Questions

- マージ阻害ラベル名の最終選定（既存 `needs-iteration` 流用 / 新規 `needs-security-fix` 追加）
  は **Architect の設計領分**として残す。本要件は「マージ阻害を意図したラベルが 1 つ付与される」
  「PR Iteration Processor (#26) の反復対応動線にそのまま流れる」「運用者がラベル手剥がしで
  override できる」という挙動レベルの AC に閉じる
- env var 名の最終確定（`SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY` 等の具体名）は
  Architect の設計領分。本要件は「モード切替 env」「severity 閾値 env」という意味レベルで規定する
- `/security-review` 出力からの severity 抽出パース戦略の具体（既存 #279 の grep 近似実装の流用 /
  構造化出力への切り替え / Skill tool 出力スキーマの直接 parse）は Architect / Developer の領分

## 関連

- Depends on: #279
- Parent: #279
- Related: #26 #261 #13
