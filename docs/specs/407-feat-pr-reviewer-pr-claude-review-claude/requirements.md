# Requirements Document

## Introduction

idd-claude のマージゲート設計では、impl PR（`claude/issue-<N>-impl-<slug>`）には
独立 Reviewer（`.claude/agents/reviewer.md`）が起動し `review-notes.md` の `RESULT:` 行を
根拠に `claude-review` commit status を publish する経路が存在する。一方、設計 PR
（`claude/issue-<N>-design-<slug>`）には対応する独立レビュア・publish 経路が存在せず、
`claude-review` を branch protection の必須 status check として要求する consumer repo
では設計 PR が永久 BLOCKED 状態となり、admin-bypass による merge に依存する運用課題が
発生している（#404 spec の Open Questions / ae-mdm ドッグフーディングフィードバックで明示済み）。

本要件は、設計 PR 専用の独立 Claude 設計レビュア（impl PR 用 Reviewer / #404 adjudicator
とは別コンポーネント）を追加し、設計 PR に対しても `claude-review` status を publish して
通常 merge 経路を成立させることを目的とする。人間運用の `awaiting-design-review` ラベル
ゲートとは **OR** 条件として併存し（どちらか一方の充足で merge 可能）、admin-merge への
依存を恒常的に外す。本変更は opt-in gate（既定 OFF）配下で導入し、既存 watcher / consumer
repo の挙動を完全に維持する後方互換を担保する。

## 背景・課題

- **現状の非対称性**: impl PR には独立 Reviewer + `claude-review` publish 経路があるが、
  設計 PR には対応するレビュア・publish 経路がない
- **永久 BLOCKED 問題**: `claude-review` を必須 status check とする consumer repo では、
  設計 PR が `claude-review = pending` のまま merge 不可となり、admin-bypass が常態化する
- **#404 adjudicator のスコープ外**: #404（merge 済み）は impl PR の codex 指摘を裁定する
  adjudicator を導入したが、設計 PR は対象外（#404 spec の Out of Scope / Open Questions
  で明示）
- **人間判断の確定事項**:
  - Q1（merge ゲート設計）→ **Option B（OR）** で確定: `claude-review = success` 単独で
    merge 可能とし、人間の `awaiting-design-review` ラベルゲートとは OR 条件で併存する。
    `claude-review = success` の場合に admin-merge を不要とすることを目的とする
  - Q2（#404 adjudicator との統合方式）→ **Option B（独立コンポーネント）** で確定:
    設計 PR 専用の独立 Reviewer / 独立 agent prompt として追加し、既存の impl PR 用
    adjudicator（#404）には触らない

## 用語定義

- **設計 PR**: head ブランチが `claude/issue-<N>-design-<slug>` 形式の PR。Architect が
  `docs/specs/<N>-<slug>/{requirements.md,design.md,tasks.md}` を生成し提出する PR
- **impl PR**: head ブランチが `claude/issue-<N>-impl-<slug>` 形式の PR。Developer が
  実装・テストを提出する PR
- **設計 Reviewer**: 本 Issue で新規追加する、設計 PR 専用の独立 Claude レビュアエージェント
  （impl PR 用 Reviewer・#404 adjudicator とは別コンポーネント）
- **`claude-review` status**: commit status の context 名。`success` / `failure` / `pending`
  のいずれかを取り、consumer repo の branch protection で必須化される運用を想定する
- **`awaiting-design-review` ラベル**: 設計 PR に付与される人間レビュー待ちラベル
  （`LABEL_AWAITING_DESIGN`、既存運用）

## スコープ

### In Scope

- 設計 PR (`claude/issue-<N>-design-<slug>`) に対する独立 Claude 設計レビュアの追加
- 設計レビュアによる `claude-review` commit status の publish（`success` / `failure`）
- 判定結果（approve / reject）に応じた `needs-iteration` ラベル付与
- 設計 PR 用 agent prompt（impl PR 用 Reviewer 定義とは別ファイル）の追加
- opt-in gate（既定 OFF）と後方互換性の担保
- 観測可能性（判定結果・根拠の PR コメント / watcher ログ出力）

### Out of Scope

- 既存 impl PR Reviewer（`.claude/agents/reviewer.md`、`claude-review` catch-up publish
  経路）への変更
- 既存 #404 adjudicator（codex advisory + claude-review の impl PR 経路）への変更
- codex advisory レビューの設計 PR への適用
- 人間運用の `awaiting-design-review` ラベルゲートの自動化・置換（本 Issue では併存させ、
  人間判断ゲートはそのまま維持する）
- consumer repo 側の branch protection 設定変更（`claude-review` 必須化等）の自動化
- 設計 Reviewer の判定精度 100% の達成（LLM 判定の本質的限界を受容）
- 設計 PR 以外（impl PR / 非 idd-claude PR）への本レビュア適用

## Requirements

### Requirement 1: 設計 PR への独立 Claude 設計レビュア起動

**Objective:** As an idd-claude watcher 運用者, I want 設計 PR (`claude/issue-<N>-design-<slug>`)
に対して独立 Claude 設計レビュアが自動起動すること, so that 設計 PR に対しても impl PR と
同様の自動 review 経路が成立し admin-merge への依存を解消できる

#### Acceptance Criteria

1. When watcher が open かつ non-draft の設計 PR（head ブランチが
   `claude/issue-<N>-design-<slug>` 形式）を検出する, the Design Reviewer Processor shall
   独立 Claude context で設計レビュアを起動する
2. When 設計レビュアが起動する, the Design Reviewer shall 当該 PR の
   `docs/specs/<N>-<slug>/requirements.md` / `design.md` / `tasks.md` を独立 context で読む
3. If 対象 PR の head ブランチが `claude/issue-<N>-impl-<slug>` 形式または上記設計 PR
   pattern に合致しない, the Design Reviewer Processor shall 当該 PR を処理対象から除外する
4. If 同一 PR の同一 sha に対して既に設計レビュアの判定が確定済みである, the Design Reviewer
   Processor shall 同一 sha に対する重複起動を避ける（hidden marker / 既存判定検出による
   冪等性確保）
5. While 設計レビュアが起動中である, the Design Reviewer shall `requirements.md` /
   `design.md` / `tasks.md` 本文の書き換えを行わない（判定のみ）

---

### Requirement 2: 設計レビュアの判定基準

**Objective:** As an idd-claude maintainer, I want 設計レビュアの判定軸を明示的に限定したい,
so that レビュア起動による判定範囲が暴走せず、Architect 成果物の品質に直結する観点のみで
合否が決まる

#### Acceptance Criteria

1. The Design Reviewer shall 判定軸を「AC カバレッジ（`requirements.md` の numeric ID が
   `design.md` / `tasks.md` のいずれかで参照されているか）」「design-tasks 整合（`design.md`
   の Components が `tasks.md` の `_Boundary:_` に反映されているか）」「traceability
   （`tasks.md` の `_Requirements:_` が `requirements.md` の AC ID に正しくリンクしているか）」
   の 3 観点に限定する
2. When 上記 3 観点のいずれかに違反が検出される, the Design Reviewer shall 判定結果を
   `reject` とする
3. When 上記 3 観点すべてで違反が検出されない, the Design Reviewer shall 判定結果を
   `approve` とする
4. If 判定に確信が持てない（`requirements.md` の文意が曖昧で AC カバレッジを判定できない等）,
   the Design Reviewer shall 判定結果を `approve` に倒す（保守的判定: false-reject による
   設計 PR 永久 BLOCKED を回避）
5. The Design Reviewer shall 判定結果（`approve` / `reject`）と各判定軸への該当根拠
   （自然言語の理由）を 1 対 1 で対応付けた形式で出力する
6. The Design Reviewer shall スタイル違反 / 命名 / typo / 表記揺れ / フォーマットを理由
   とする `reject` を出さない（impl PR Reviewer の reject 基準と整合）

---

### Requirement 3: `claude-review` commit status の publish

**Objective:** As an idd-claude watcher 運用者, I want 設計レビュアが判定結果に基づき
`claude-review` commit status を publish したい, so that 設計 PR が `claude-review` を必須
status check とする consumer repo で通常 merge 経路に乗る

#### Acceptance Criteria

1. When 設計レビュアの判定結果が `approve` である, the Design Reviewer Processor shall
   当該 PR の HEAD sha に対して `claude-review` commit status を `success` で publish する
2. When 設計レビュアの判定結果が `reject` である, the Design Reviewer Processor shall
   当該 PR の HEAD sha に対して `claude-review` commit status を `failure` で publish する
3. When 設計レビュアが exec-failed / rate-limit / timeout 等で判定を生成できない,
   the Design Reviewer Processor shall `claude-review` status を `failure` で publish せず
   `pending` のまま据え置く（後続サイクルでの再試行を可能にする）
4. The Design Reviewer Processor shall `claude-review` commit status の context 名を
   既存 impl PR 経路と同一の文字列（`claude-review`）に揃え、consumer repo の branch
   protection 設定で両者を統一的に必須化できる状態を維持する
5. While `claude-review = success` が publish された状態である, the consumer repo の
   merge ゲートは `awaiting-design-review` ラベルの有無に依らず充足可能となる（人間
   ラベルゲートと OR 条件で併存する）

---

### Requirement 4: reject 時の `needs-iteration` ラベル付与と反復経路

**Objective:** As an idd-claude watcher 運用者, I want 設計レビュアが reject 判定を出した
場合に Architect の反復経路（`PR_ITERATION_DESIGN_ENABLED=true` 配下）が自動起動するように
したい, so that reject を受けた設計 PR が次サイクルで Architect により改稿され、人間介入なし
で iteration が回る

#### Acceptance Criteria

1. When 設計レビュアの判定結果が `reject` である, the Design Reviewer Processor shall
   当該 PR に `needs-iteration` ラベルを付与する
2. When 設計レビュアの判定結果が `approve` である, the Design Reviewer Processor shall
   `needs-iteration` ラベルを付与しない（既に付与済みなら解消する）
3. While `needs-iteration` ラベルが設計 PR に付与された状態である, the existing PR
   Iteration Processor（`PR_ITERATION_DESIGN_ENABLED=true` 経路）shall 当該 PR を反復対象
   として処理し、Architect 役割で `docs/specs/<N>-<slug>/` 配下を改稿する
4. The Design Reviewer Processor shall 設計 PR の `needs-iteration` 反復後の挙動
   （成功時 `awaiting-design-review` 遷移等、既存 `PR_ITERATION_DESIGN_*` 経路の挙動）
   を変更しない

---

### Requirement 5: 観測可能性（判定結果の運用者可視化）

**Objective:** As an idd-claude watcher 運用者, I want 設計レビュアの判定結果（approve/reject
と各判定軸への該当根拠）を後から監査できる形で観測したい, so that false-reject / 誤 approve
が発生した際に原因を特定し、判定基準を改善できる

#### Acceptance Criteria

1. The Design Reviewer shall 判定結果（`approve` / `reject`）と各判定軸への該当根拠を
   PR コメント または watcher ログ の少なくとも一方で外部観測可能にする
2. The Design Reviewer shall 判定サマリ（approve/reject の verdict、3 観点それぞれの違反
   有無）を watcher ログに 1 行以上の集計形式で出力する
3. Where 判定結果を PR コメントとして投稿する, the Design Reviewer shall コメント本文に
   `<!-- idd-claude:<marker-key> -->` 形式の hidden marker を含め、PR Iteration Processor
   の self-filter（#400 規約）で誤って iteration agent 入力から除外されない marker key を
   採用する
4. The Design Reviewer shall 観測ログの prefix・timestamp 書式を既存 watcher のログ規約
   （`<module>:` prefix / `[YYYY-MM-DD HH:MM:SS]` timestamp）に整合させる

---

### Requirement 6: opt-in gate と後方互換

**Objective:** As an existing idd-claude watcher user, I want 設計 Reviewer 機能を opt-in
gate 配下で導入し、未有効時は導入前と完全に同一の挙動を維持したい, so that 既存 cron /
launchd 設定・既存 consumer repo に migration 作業を強いずに本変更を取り込める

#### Acceptance Criteria

1. The Design Reviewer Processor shall 新規 env var による opt-in gate（既定 OFF）を追加し、
   gate 未設定 / 空 / 不正値 / typo の場合は安全側（無効）に正規化する
2. While opt-in gate が無効である, the watcher shall 設計 PR に対する `claude-review`
   status publish・`needs-iteration` ラベル付与・設計レビュア起動のいずれも行わない
   （本変更導入前と完全に同一のフロー）
3. The watcher shall 既存の env var 名（`PR_REVIEWER_*` / `PR_ITERATION_DESIGN_*` /
   `AUTO_MERGE_DESIGN_*` / `DESIGN_REVIEW_RELEASE_*` / `LABEL_AWAITING_DESIGN` 等）の
   名前・既定値・意味を変更しない
4. The watcher shall 既存ラベル名（`needs-iteration` / `awaiting-design-review` /
   `ready-for-review` / `claude-failed` 等）と既存 commit status context（`codex-review` /
   `claude-review`）の名前・意味を変更しない
5. The watcher shall 既存の exit code 意味・ログ出力先（stderr / stdout 分離契約）・
   cron 登録文字列を変更しない
6. The idd-claude repository shall 本変更に伴う modules / agents / labels / workflow の
   追加・修正を root と repo-template の二系統で byte 一致同期した状態で配布する
   （`diff -r .claude/agents repo-template/.claude/agents` および
   `diff -r .claude/rules repo-template/.claude/rules` で差分ゼロを担保）

---

### Requirement 7: 独立コンポーネントとしての分離（#404 adjudicator との非統合）

**Objective:** As an idd-claude maintainer, I want 設計 Reviewer を impl PR 用 Reviewer・
#404 adjudicator から独立したコンポーネントとして実装したい, so that 設計 PR と impl PR の
判定ロジックが互いに干渉せず、それぞれの責務境界が保たれる

#### Acceptance Criteria

1. The Design Reviewer shall impl PR 用 Reviewer 定義（`.claude/agents/reviewer.md`）とは
   独立した agent 定義ファイルとして実装される
2. The Design Reviewer Processor shall impl PR 用 Reviewer の既存 `claude-review` publish
   経路と独立した処理経路として実装され、両者の入出力契約が相互に依存しない
3. The Design Reviewer Processor shall #404 adjudicator（codex advisory + claude-review の
   impl PR 経路）のコード・env var・ラベル運用に変更を加えない
4. When impl PR と設計 PR が同時に open である, the Design Reviewer Processor shall 設計 PR
   のみを処理対象とし、impl PR の既存 Reviewer / adjudicator 経路には介入しない

---

## Non-Functional Requirements

### NFR 1: 観測可能性

1. The Design Reviewer Processor shall 1 PR あたりの観測ログ行数の増加を、既存 PR Reviewer
   サイクルの観測ログ行数 + 10 行以内に収める（過度な追加ログによる log file 肥大化を抑制）
2. The Design Reviewer shall 判定結果が PR コメントとして投稿される場合、当該コメントが
   PR Iteration Processor の self-filter（#400 規約: `idd-claude:pr-iteration` prefix
   のみ除外）で iteration agent 入力から誤除外されない marker key を採用する

### NFR 2: 後方互換性

1. While opt-in gate が無効である, the watcher shall 1 サイクル分のログ出力内容を本変更
   導入前と diff レベルで一致させる（追加ログ・追加 commit status を発生させない）
2. The idd-claude repository shall 既存テスト（`local-watcher/test/` 配下の pr-reviewer /
   pr-iteration 関連テスト）を退行させない

### NFR 3: テスト整備

1. The local-watcher repo shall 本要件を検証する近接テストを `local-watcher/test/` 配下に
   追加し、以下のケースを観測可能な形で最低限含める:
   - opt-in gate 無効時、設計 PR に対する `claude-review` status publish が発生しないこと
   - opt-in gate 有効時、設計 PR に対する `approve` 判定で `claude-review = success` が
     publish され `needs-iteration` が付与されないこと
   - opt-in gate 有効時、設計 PR に対する `reject` 判定で `claude-review = failure` が
     publish され `needs-iteration` が付与されること
   - 設計 Reviewer が exec-failed / timeout 状態となった場合に `claude-review` status を
     `pending` のまま据え置くこと
   - impl PR（`claude/issue-<N>-impl-<slug>`）には設計 Reviewer が起動しないこと

### NFR 4: パフォーマンス

1. The Design Reviewer Processor shall 設計 PR 1 件あたりの判定時間を、impl PR Reviewer
   の判定時間と同等オーダー（既定で 5 分以内）に収める。timeout 値は既存 `PR_REVIEWER_*`
   timeout 設定と独立に env var で override 可能とする

---

## 制約事項

- 本機能は **opt-in gate（env var、既定 OFF）** で制御し、gate 未設定 / 空 / 不正値 / typo
  は安全側（無効）に正規化する（`AUTO_REBASE_MODE=off` 等の既存規範に整合）
- 既存 env var 名 / ラベル名 / commit status context 名 / exit code 意味 / cron 登録文字列を
  破壊しない（idd-claude 「禁止事項」節および「機能追加ガイドライン」節 3 の opt-in / 後方
  互換鉄則に整合）
- root `.claude/{agents,rules}/` と `repo-template/.claude/{agents,rules}/` は byte 一致を
  維持する（同一 PR で `diff -r` 空を確認）
- 設計 Reviewer は判定のみを行い、`requirements.md` / `design.md` / `tasks.md` / コード /
  テスト の書き換えを行わない（impl PR Reviewer と同等の判定責務境界）
- 未信頼 GitHub 入力（PR 本文・コメント・ブランチ名・branch 上ファイル）の取り扱いは
  CLAUDE.md「機能追加ガイドライン」節 5 に従う（quote / `jq --arg` / `--` / ID / SHA 検証 /
  Actions env 間接化）

---

## 依存関係

- **Depends on**: #404（codex advisory 化と Claude adjudicator） — merge 済み。本 Issue は
  #404 で確立した「`claude-review` を impl PR の merge ゲートとして publish する経路」の
  対称となる設計 PR 側の経路を追加する
- **Related**: #112（`PR_ITERATION_DESIGN_ENABLED=true` 既定化）、#349（`claude-review`
  catch-up publish 経路）、#374（既存 `claude-review` catch-up publish 経路）、#400
  （PR Iteration self-filter の marker key 規約）

---

## 未確定事項

- **設計 Reviewer の opt-in gate 名**: 既存命名規約（`*_ENABLED=true` / 既定 false）に
  従う前提だが、具体的な env var 名（`DESIGN_REVIEWER_ENABLED` / `PR_DESIGN_REVIEWER_ENABLED`
  等）は Architect が `PR_REVIEWER_*` / `PR_ITERATION_DESIGN_*` 既存 namespace との整合を
  考慮して決定する
- **設計 Reviewer の判定生成物の保存場所**: impl PR Reviewer は `review-notes.md` の
  `RESULT:` 行を介して `claude-review` を publish する。設計 PR でも同等の `review-notes.md`
  相当ファイルを生成するか、PR コメント本文のみで完結させるかは Architect の設計判断に
  委ねる（Requirement 5.1 は「いずれか一方」で満たせる粒度）
- **設計 Reviewer の起動契機**: (a) 設計 PR が open / non-draft になった時点で即起動 / (b)
  `awaiting-design-review` ラベル付与契機で起動 / (c) Architect commit push 契機で起動、
  のいずれを採用するかは Architect の設計判断に委ねる（Requirement 1.1 は「watcher が
  検出する」レベルの粒度）
- **PR コメント vs watcher ログの主従**: Requirement 5.1 は「いずれか一方」で満たせる
  粒度。両方残すか PR コメントのみ / ログのみとするかは Architect の設計判断
- **判定キャッシュ / 冪等性の実装方式**: Requirement 1.4 の「同一 sha に対する重複起動回避」
  を hidden marker / 既存判定検出 / ラベル状態 / 別の方式のいずれで実装するかは Architect
  の設計判断

---

## 関連

- Depends on: #404
- Related: #112 #349 #374 #400
