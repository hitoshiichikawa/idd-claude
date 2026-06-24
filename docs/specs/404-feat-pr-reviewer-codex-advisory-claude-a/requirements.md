# Requirements Document

## Introduction

idd-claude の PR Reviewer（`local-watcher/bin/modules/pr-reviewer.sh`）は現状、codex 由来の
レビュー指摘（`codex-review` commit status）を必須 merge ゲートとして扱っており、codex の過剰
指摘 / nitpick / exec-failed / drip-feed 未収束（#399 参照）がそのまま merge ブロッカーになる
運用課題がある。ドッグフーディング先（ae-mdm）では暫定対処として branch protection の必須
チェックを `codex-review` → `claude-review` に差し替えており、codex を advisory 化する正規の
仕組みが求められている。本 Issue は、(1) codex の指摘を **legitimate（実害）** と **過剰（spec 外
/ AC 非紐付け / 主観的 / 重複列挙）** に分類する **Claude adjudicator 層** を追加し、(2) `needs-iteration`
の付与・解消を adjudicator が握る形に再構成して legitimate のみで iteration を駆動し、(3) merge
ゲートを `codex-review`（advisory）から `claude-review`（必須相当）へシフトすることを目的と
する。既定 OFF の opt-in gate を必須とし、既存 watcher / consumer repo の挙動を完全に維持する
後方互換を担保する。本要件では adjudicator の統合方式（既存 Reviewer 統合 vs 独立裁定ステップ）
は規定せず、いずれの設計でも AC を満たせる粒度に倒す。

## Requirements

### Requirement 1: codex 指摘の adjudicator 分類

**Objective:** As a auto-dev 運用者, I want Claude adjudicator が codex の各指摘を「legitimate」と「過剰」に分類すること, so that codex の価値（実害検出）を保持しつつ過剰指摘で merge が止まる事態を解消できる

#### Acceptance Criteria

1. When PR Reviewer の codex 実行が指摘を 1 件以上出力する, the Claude adjudicator shall 各指摘を `legitimate` または `excessive` のいずれかに分類した結果を生成する
2. When ある codex 指摘が requirements.md の特定 AC に直結する / design.md の Components or Interfaces に直結する / 後方互換性破壊や security 退行を指摘する, the Claude adjudicator shall 当該指摘を `legitimate` に分類する
3. When ある codex 指摘が AC に紐付かない / spec 範囲外 / 同一観点の重複列挙 / 主観的スタイル寄りである, the Claude adjudicator shall 当該指摘を `excessive` 候補として扱う
4. If 指摘の分類に確信が持てない, the Claude adjudicator shall 当該指摘を `legitimate` に分類する（保守的判定の原則）
5. The Claude adjudicator shall すべての codex 指摘に対して分類結果（`legitimate` / `excessive`）と分類根拠（自然言語の理由）を 1 対 1 で対応付ける

---

### Requirement 2: legitimate 指摘のみで iteration を駆動

**Objective:** As a auto-dev 運用者, I want adjudicator が legitimate と判定した指摘のみが PR Iteration Processor を起動するようにしたい, so that 過剰指摘で Developer 反復が空転せず、legitimate 指摘の取りこぼしも発生しない

#### Acceptance Criteria

1. When Claude adjudicator が legitimate 指摘を 1 件以上検出する, the Claude adjudicator shall PR に `needs-iteration` ラベルを付与した状態（または維持した状態）にする
2. When Claude adjudicator が legitimate 指摘ゼロかつ excessive のみ検出する, the Claude adjudicator shall `needs-iteration` ラベルを付与しない（既に付与済みなら解消する）
3. When codex が exec-failed / rate-limit 等で指摘を出力できない, the Claude adjudicator shall `needs-iteration` ラベルを codex 失敗のみを理由に付与しない
4. While PR Iteration Processor が起動される, the PR Iteration Processor shall adjudicator が `excessive` と判定した指摘を iteration agent の入力対象から除外する
5. While PR Iteration Processor が起動される, the PR Iteration Processor shall adjudicator が `legitimate` と判定した指摘を iteration agent の入力に含める
6. The Claude adjudicator shall PR Reviewer 既存の出力契約（`## 概要` / `## 指摘事項` / `## 結論` / `VERDICT:` 1 行 / `[high|medium|low] <file>:<line> — <内容>` 形式）を破壊しない

---

### Requirement 3: merge ゲートの `claude-review` シフト

**Objective:** As a watcher 運用者, I want merge ゲートを codex-review（advisory）から claude-review（必須相当）に切り替えたい, so that codex の一時失敗・過剰指摘で auto-merge が永久 block される事態を解消できる

#### Acceptance Criteria

1. The PR Reviewer module shall codex 実行結果に基づく `codex-review` commit status を従来どおり publish する（advisory として可視性は維持）
2. The Claude adjudicator shall 裁定結果に基づき `claude-review` commit status を `success` / `failure` / `pending` のいずれかで publish する
3. When Claude adjudicator が legitimate 指摘ゼロと判定し、かつ既存独立 Reviewer の最終 verdict が `reject` でない（approve / 不在 / RESULT 行不在のいずれか）, the Claude adjudicator shall `claude-review` status を `success` で publish する
4. When Claude adjudicator が legitimate 指摘を 1 件以上検出する, the Claude adjudicator shall `claude-review` status を `failure` で publish する
5. When 既存独立 Reviewer の最終 verdict が `reject` である, the Claude adjudicator shall legitimate 指摘ゼロであっても `claude-review` status を `failure` で publish する（Reviewer 判定の上書き防止）
6. When codex が exec-failed / rate-limit 等で指摘を出せない, the Claude adjudicator shall `codex-review` status の失敗を理由に `claude-review` status を `failure` にしない（codex 不在でも legitimate ゼロと判定でき、且つ Reviewer reject も検出されなければ `success` を publish する）
7. The PR Reviewer module shall `codex-review` を必須 status check として要求するロジックを watcher 側に持たない（必須化 / advisory 化は consumer repo の branch protection 設定に委ねる）

---

### Requirement 4: 可観測性（裁定結果の運用者可視化）

**Objective:** As a watcher 運用者 / Reviewer, I want adjudicator の裁定結果（各指摘の legitimate/excessive 分類 + 理由）を後から監査できる形で観測したい, so that 誤 bypass が発生した際に原因を特定し、判定基準を改善できる

#### Acceptance Criteria

1. The Claude adjudicator shall 各 codex 指摘に対する分類（`legitimate` / `excessive`）と分類根拠を PR コメント または watcher ログ の少なくとも一方で外部観測可能にする
2. The Claude adjudicator shall 裁定サマリ（legitimate 件数 / excessive 件数 / 入力となった codex 指摘総数）を watcher ログに 1 行以上の集計形式で出力する
3. The Claude adjudicator shall PR コメントとして裁定結果を投稿する場合、`<!-- idd-claude:<marker-key> -->` 形式の hidden marker を本文に含め、PR Iteration Processor の self-filter（#400 規約）で誤って iteration agent 入力から除外されない marker key を採用する
4. The Claude adjudicator shall 観測ログの prefix・timestamp 書式を既存 watcher のログ規約（`<module>:` prefix / `[YYYY-MM-DD HH:MM:SS]` timestamp）に整合させる

---

### Requirement 5: opt-in gate と後方互換

**Objective:** As an existing watcher user, I want adjudicator 機能を opt-in gate 配下で導入し、未有効時は導入前と完全に同一の挙動を維持したい, so that 既存 cron / launchd 設定・既存 consumer repo に migration 作業を強いずに本変更を取り込める

#### Acceptance Criteria

1. The PR Reviewer module shall 新規 env var による opt-in gate（既定 OFF）を追加し、gate 未設定 / 空 / 不正値 / typo の場合は安全側（無効）に正規化する
2. While opt-in gate が無効である, the PR Reviewer module shall 本変更前と完全に同一のフロー（codex 実行 → `codex-review` status publish → `VERDICT: needs-iteration` での `needs-iteration` ラベル付与）を維持する
3. The PR Reviewer module shall 既存の env var 名（`PR_REVIEWER_PROMPT` / `PR_REVIEWER_ITERATION_PATTERN` / `PR_REVIEWER_GIT_TIMEOUT` / `PR_REVIEWER_HEAD_PATTERN` / `PR_REVIEWER_STATUS_CHECK_ENABLED` / `FULL_AUTO_ENABLED` 等）の名前・既定値・意味を変更しない
4. The PR Reviewer module shall 既存ラベル名（`needs-iteration` / `ready-for-review` / `claude-failed` 等）と既存 commit status context（`codex-review` / `claude-review`）の名前・意味を変更しない
5. The PR Reviewer module shall 既存の exit code 意味・ログ出力先（stderr / stdout 分離契約）を変更しない
6. The idd-claude repository shall 本変更に伴う modules / labels / workflow の追加・修正を root と repo-template の二系統で byte 一致同期した状態で配布する（`diff -r` 検査で差分ゼロを担保）

---

### Requirement 6: トレードオフの明示

**Objective:** As an idd-claude maintainer, I want adjudicator 導入に伴うトレードオフ（独立性希薄化・誤 bypass リスク）を要件レベルで明示したい, so that 設計 / 実装 / 運用の各段階で当該リスクが暗黙化せず、緩和策が継続的に検討される

#### Acceptance Criteria

1. The Claude adjudicator shall 「独立性希薄化」（codex を Claude が裁定することで codex の独立検出価値が薄まる）リスクを README または該当モジュールのドキュメントコメントで明示する
2. The Claude adjudicator shall 「誤 bypass」（legitimate 指摘を excessive と誤判定するリスク）に対する緩和策として、AC 1.4（迷ったら legitimate）と AC 4.1（裁定根拠の観測可能性）を満たすことをドキュメント上で根拠として参照する
3. The Claude adjudicator shall 「過剰判定の 100% 精度」を目標としない旨をドキュメント上で明示する（Out of Scope に整合）

## Non-Functional Requirements

### NFR 1: 観測可能性

1. The Claude adjudicator shall 裁定 1 回あたりの観測ログ行数の増加を、PR Reviewer 既存サイクルの観測ログ行数 + 10 行以内に収める（過度な追加ログによる log file 肥大化を抑制）
2. The Claude adjudicator shall 裁定結果が PR コメントとして投稿される場合、当該コメントが PR Iteration Processor の self-filter（#400 規約）で iteration agent 入力から誤除外されない marker key を採用する

### NFR 2: 後方互換性

1. The PR Reviewer module shall opt-in gate 無効時に、watcher ログ 1 サイクル分の出力内容が本変更導入前と diff レベルで一致する（追加ログ・追加 commit status を発生させない）
2. The idd-claude repository shall 既存テスト（`local-watcher/test/` 配下の pr-reviewer / pr-iteration 関連テスト）を退行させない

### NFR 3: テスト整備

1. The local-watcher repo shall 本要件を検証する近接テストを `local-watcher/test/` 配下に追加し、以下のケースを観測可能な形で最低限含める:
   - opt-in gate 無効時、本変更導入前と同一の codex-review status / needs-iteration ラベル挙動を取ること
   - opt-in gate 有効時、legitimate ゼロ・excessive のみの裁定で `claude-review = success` かつ `needs-iteration` 不付与となること
   - opt-in gate 有効時、legitimate 1 件以上で `claude-review = failure` かつ `needs-iteration` 付与となること
   - codex exec-failed 状態で legitimate ゼロの裁定により `claude-review = success` を publish できること

## Out of Scope

- codex の rate-limit / exec-failed 無限リトライ修正（別 bug Issue として起票予定。Issue 本文「スコープ外」明示）
- codex 以外のレビューツール（antigravity 等を除く新規ベンダー）の追加
- adjudicator の過剰判定 100% 精度の達成（LLM 裁定の本質的限界を受容、Requirement 6.3）
- consumer repo 側の branch protection 設定（`codex-review` 必須解除 / `claude-review` 必須化）の自動化。watcher は status publish のみを担い、必須化判断は consumer repo の運用者に委ねる（Requirement 3.6）
- 設計 PR（`claude/issue-<N>-design-*`）に対する `claude-review` status publish 経路の追加（後述 Open Questions 参照。本 Issue では impl PR の adjudicator 化のみをスコープとし、設計 PR ゲートは別 Issue 起票を提案）
- 既存 env var の既定値変更
- adjudicator 統合方式（既存 Reviewer 統合 vs 独立裁定ステップ）の確定。本要件ではいずれの設計でも AC を満たせる粒度に倒し、選択は Architect に委ねる（Issue 本文「仮案・判断を委ねたい点」に整合）
- VERDICT 検出 regex（`PR_REVIEWER_ITERATION_PATTERN`）の互換破壊
- iteration agent の prompt template 本文書き換え（#399 で対応済み）

## Open Questions

- **設計 PR ゲートの併発課題を本 Issue スコープに含めるか**: ae-mdm ドッグフーディングのフィードバック（Issue #404 コメント 1）として、設計 PR（`claude/issue-<N>-design-*`）には `review-notes.md` が存在しないため `claude-review` status の catch-up publish 経路（#374）が発火せず、必須化すると設計 PR が永久 BLOCKED になる事象が共有されている。案 A（設計 PR にも `claude-review` 相当の status publish 経路を追加）と案 B（設計 PR は人間 admin merge として扱う / ae-mdm の暫定運用）が提示されているが、本要件では impl PR の adjudicator 化のみをスコープとし、設計 PR ゲートは別 Issue として切り出すことを推奨する。本 Issue に取り込むかは人間判断待ち
- **adjudicator 統合方式の選択**: Issue 本文「仮案・判断を委ねたい点」に記載のとおり、(1) 既存独立 Reviewer に統合する案（実装軽量、ただし legitimate 指摘の選別反映は不可）と (2) codex 指摘専用の裁定ステップを分離する案（本提案に忠実、ただし新規ステップ追加）の選択は Architect の設計判断に委ねる
- **`excessive` と判定された指摘の最終的な保存場所**: PR コメント本文に列挙して履歴を残すか、watcher ログにのみ残すか、両方残すかは Architect の設計判断に委ねる（Requirement 4.1 は「いずれか一方」で満たせる粒度）
- **adjudicator の opt-in gate 名**: 既存命名規約（`*_ENABLED=true` / 既定 false）に従う前提だが、具体的な env var 名は Architect が `PR_REVIEWER_*` namespace 内で命名する
- **`claude-review` status publish の主体**: 既存 catch-up publish 経路（`pr_publish_claude_status_from_branch`、`local-watcher/bin/modules/pr-reviewer.sh` 内）と adjudicator publish 経路の責務分担は Architect の設計判断に委ねる

## 関連

- Depends on: #399 #400
- Related: #397
