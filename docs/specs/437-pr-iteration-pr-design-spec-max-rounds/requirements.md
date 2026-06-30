# Requirements Document

## Introduction

PR Iteration / PR Reviewer + Adjudicator は、codex 由来のレビュー指摘を裁定し、`needs-iteration`
ラベルと iteration round を駆動する。しかし「正当だが当該 PR タイプのスコープ外（design.md /
spec の変更が必要で、impl PR では規約上それらを書き換えられない）」な指摘が出ると、裁定が
legitimate のまま round が空回りし、`max_rounds` 消尽でしか終われず、実装が scope 完結している
PR でも `claude-failed` に落ちる構造的問題がある（ドッグフーディング実例: ae-mdm PR #51）。
本要件は、(1) Adjudicator に第 3 判定 out-of-scope を導入し、(2) Developer の out-of-scope 宣言を
構造化シグナル化し、(3) 指摘内容ベースの no-progress 早期打ち切りを加え、(4) これら全体を既存
opt-in 鉄則の下で後方互換に導入することを定義する。実装方針・モジュール分割・関数設計は本書では
扱わず、Architect の design.md に委ねる。

## 関連

- Related: #404
- Related: #122
- Related: #397

## Requirements

### Requirement 1: Adjudicator の第 3 判定カテゴリ（out-of-scope）

**Objective:** As a watcher 運用者, I want Adjudicator が「正当だが当該 PR スコープ外」な指摘を独立カテゴリで分類できること, so that 設計変更が必要な正当指摘で impl PR が無限反復せず適切な経路へ還流できる

#### Acceptance Criteria

1. When Adjudicator が 1 件の指摘を裁定するとき, the Adjudicator は当該指摘を `legitimate` / `excessive` / `out-of-scope` の 3 値のいずれか 1 つに分類する
2. Where 指摘が当該 PR の requirements.md / design.md の確定事項と矛盾し当該 PR タイプでは対処できない設計・spec 変更を要求しているとき, the Adjudicator は当該指摘を `out-of-scope` に分類する
3. If 指摘が `out-of-scope` か `legitimate` かで判定に確信が持てないとき, the Adjudicator は当該指摘を `legitimate` に分類する
4. The Adjudicator は各指摘の分類に対し、分類根拠（どの確定事項・どの AC・どの境界に矛盾するか）を含む reason を出力する
5. When Adjudicator が裁定結果を出力するとき, the Adjudicator は `out-of-scope` 件数を集計値として出力に含める

### Requirement 2: out-of-scope 指摘が iteration round を消費しないこと

**Objective:** As a watcher 運用者, I want out-of-scope と裁定された指摘が impl iteration の round を消費しないこと, so that 無駄な反復 round とトークンコストを発生させずに済む

#### Acceptance Criteria

1. When ある PR の全 legitimate 指摘が解消され残る指摘が `out-of-scope` のみになったとき, the PR Iteration Processor は当該 PR に対する新しい impl iteration round を起動しない
2. While 1 件以上の `legitimate` 指摘が残っているとき, the PR Iteration Processor は従来どおり iteration round を起動する
3. When Adjudicator が `needs-iteration` ラベルの付与可否を確定するとき, the Adjudicator は `out-of-scope` 件数を `legitimate` 件数として数えない
4. If ある PR の指摘が `out-of-scope` のみ（`legitimate` ゼロ）であるとき, the Adjudicator は `needs-iteration` ラベルを付与しない

### Requirement 3: out-of-scope 指摘のルーティング

**Objective:** As a watcher 運用者, I want out-of-scope と裁定された指摘が放置されず明示された経路へルーティングされること, so that 設計変更が必要な正当指摘が失われず適切に追跡される

#### Acceptance Criteria

1. When ある PR で `out-of-scope` 指摘が確定したとき, the PR Iteration Processor は当該指摘を「設計フェーズ還流」「フォローアップ Issue 起票」「人間への needs-decisions エスカレート」のいずれか 1 つの既定経路へルーティングする
2. Where 既定ルーティング先が `needs-decisions`（推奨デフォルト）に設定されているとき, the PR Iteration Processor は当該 Issue / PR に対し人間判断を促すエスカレーションを行う
3. When `out-of-scope` 指摘をルーティングするとき, the PR Iteration Processor は当該指摘の内容・分類根拠を人間が追跡できる形（PR コメントまたはログ）で記録する
4. If `out-of-scope` 指摘のルーティング操作（コメント投稿 / ラベル付与）が失敗したとき, the PR Iteration Processor は WARN をログに残し silent fail しない
5. The PR Iteration Processor は同一 PR・同一 SHA に対する同一 out-of-scope ルーティングを重複実行しない

### Requirement 4: Developer の out-of-scope 宣言の構造化シグナル

**Objective:** As a watcher 運用者, I want Developer が「当該指摘は当該 PR のスコープ外」と判断したことを構造化マーカーで宣言できること, so that watcher がそれを機械的に検出して反復を打ち切れる

#### Acceptance Criteria

1. When Developer が iteration round で「指摘が design.md / spec 確定事項と矛盾し当該 PR では対処不能」と判断したとき, the Developer は応答本文に構造化マーカー（例: `OUT-OF-SCOPE: design` / `OUT-OF-SCOPE: spec-stale`）を出力する
2. When PR Iteration Processor が Developer 応答本文を解析するとき, the PR Iteration Processor は当該構造化マーカーの有無を検出する
3. If PR Iteration Processor が Developer 応答に out-of-scope 構造化マーカーを検出したとき, the PR Iteration Processor は当該指摘に対する iteration を打ち切り、Requirement 3 のルーティング経路へ引き渡す
4. The Developer は構造化マーカーを出力する際に、どの確定事項・どの AC と矛盾するかの根拠を同じ応答本文に併記する
5. If Developer 応答に out-of-scope 構造化マーカーが存在しないとき, the PR Iteration Processor は従来どおりの round 進行判定を行う

### Requirement 5: 指摘内容ベースの no-progress 早期打ち切り

**Objective:** As a watcher 運用者, I want 同一の design-level 指摘が連続して堂々巡りする状況を max_rounds 到達前に検出して打ち切れること, so that 同一指摘の反復で max_rounds まで走り切る無駄を削減できる

#### Acceptance Criteria

1. When 同一指摘が連続する round で `legitimate` かつ Developer が out-of-scope 回答を返し続けているとき, the PR Iteration Processor は当該連続回数を round ごとに計数する
2. If 指摘内容ベースの no-progress 連続回数が閾値（推奨デフォルト 2 round）以上に達したとき, the PR Iteration Processor は `max_rounds` 到達前に当該指摘の iteration を打ち切り、Requirement 3 のルーティング経路へエスカレートする
3. While head branch に新規 commit が積まれても指摘内容が同一で Developer 回答が out-of-scope のままであるとき, the PR Iteration Processor は SHA 変化のみを理由に no-progress カウンタをリセットしない
4. When 指摘内容ベースの no-progress により早期打ち切りを行ったとき, the PR Iteration Processor は打ち切り理由（指摘内容ベース no-progress / 連続回数 / 閾値）をログに記録する
5. If 指摘内容が round 間で実質的に変化したとき, the PR Iteration Processor は指摘内容ベースの no-progress 連続回数をリセットする

### Requirement 6: Reviewer / Adjudicator プロンプトの明文化

**Objective:** As a watcher 運用者, I want 「design.md の確定事項と矛盾する強化要件は impl PR の reject 理由にしない」が明文化されていること, so that impl Reviewer / Adjudicator が design-level 指摘を impl PR の失敗理由に誤用しない

#### Acceptance Criteria

1. The Adjudicator プロンプトは「requirements.md / design.md の確定事項と矛盾し当該 PR タイプでは対処不能な強化要件は `out-of-scope` に分類する」旨の判定指針を含む
2. The impl Reviewer の判定指針は「design.md の確定事項と矛盾する設計レベル指摘を impl PR の reject 理由にしない（設計 iteration / 別 Issue へ回す）」旨を含む
3. Where impl Reviewer が設計レベル指摘を検出したとき, the impl Reviewer は当該指摘を AC 未カバー / missing test / boundary 逸脱の 3 カテゴリのいずれにも該当しないものとして reject 理由にしない
4. The Reviewer / Adjudicator のプロンプト明文化は、idd-claude / consumer repo の双方で参照される文言として root と repo-template の双方に同一内容で反映される

## Non-Functional Requirements

### NFR 1: 後方互換性・opt-in gate

1. Where 新挙動（out-of-scope 分類 / 構造化マーカー検出 / 内容ベース no-progress）が env gate で opt-in されていないとき, the watcher は本機能導入前と完全に同一の挙動（no-op）を維持する
2. If 新挙動の opt-in gate に未設定・空・不正値・typo が与えられたとき, the watcher は当該 gate を安全側（無効）に正規化する
3. The watcher は本機能導入時に既存の env var 名・既存ラベル名・既存 commit status context 名・既存 exit code の意味・既存ログ書式・既存 cron 登録文字列のいずれも変更しない
4. Where 既存の `legitimate` / `excessive` 二値裁定経路を前提とする既存挙動が opt-in 無効のとき, the watcher は当該経路の出力スキーマ（裁定結果の既存フィールド）を後方互換に保つ

### NFR 2: 二重管理同期

1. The Reviewer / Adjudicator / Developer プロンプトおよび agents / rules への変更は、root と repo-template の対応物に byte 一致で反映される
2. Where consumer repo に配布される workflow / labels に新挙動の前提（新ラベル等）が追加されるとき, the watcher は当該追加を root と repo-template の双方へ反映する

### NFR 3: セキュリティ（未信頼入力の取り扱い）

1. When PR Iteration Processor が PR コメント本文・Developer 応答本文（未信頼 GitHub 入力）を解析するとき, the PR Iteration Processor は変数展開をクォートし、`jq` へ渡す未信頼値は `--arg` / `--argjson` でリテラル渡しする
2. When PR Iteration Processor が未信頼値を `grep` / `git` / `gh` に渡すとき, the PR Iteration Processor は `--` でオプション解釈を打ち切る
3. When PR Iteration Processor が PR 番号・SHA を path / URL / git revision に使うとき, the PR Iteration Processor は PR 番号を `^[0-9]+$`、SHA を `^[0-9a-f]{7,40}$` で使用直前に検証する

### NFR 4: 可観測性

1. When 新挙動により iteration を早期打ち切りまたはルーティングしたとき, the watcher は PR 番号・kind・round・打ち切り理由を 1 行で機械抽出可能なログとして出力する

## Out of Scope

- Adjudicator / Reviewer / Developer の具体的なモジュール分割・関数シグネチャ・env var 名の確定（design.md の領分）
- out-of-scope 構造化マーカーの厳密な文字列書式・正規表現の確定（design.md の領分。本書は例示に留める）
- design / spec 還流先 Issue の自動本文生成テンプレートの詳細設計
- codex Reviewer 自体の指摘生成ロジックの変更（本書は裁定・反復制御のみを対象とする）
- 既存 alias 表記で書かれた過去 Issue の canonical 記法への retrofit
- max_rounds / no-progress-streak 既存カウンタの数値デフォルト変更（本書は内容ベース no-progress を**追加**するもので既存カウンタの値は変更しない）
- 2-branch promote pipeline / merge queue 等、本 Issue と独立した既存 opt-in 機能の挙動変更

## Open Questions

- out-of-scope 裁定指摘の**既定ルーティング先**を「設計フェーズ還流」「フォローアップ Issue 起票」「needs-decisions エスカレート」のどれにするか。本書は推奨デフォルトとして **needs-decisions エスカレート**（人間判断・最も安全側・不可逆操作を伴わない）を採用して AC を記述した（Requirement 3.2）。フォローアップ Issue 自動起票は外部副作用（Issue 量産リスク）を伴うため、opt-in での段階導入が望ましい。最終確定は Architect / 人間レビューに委ねる。
- 指摘内容ベース no-progress 早期打ち切りの **N round 閾値**。本書は推奨デフォルト **2 round**（PR #51 で 2-3 round 短縮可能との Issue 記述に基づく）を採用して AC を記述した（Requirement 5.2）。既存の `PR_ITERATION_NO_PROGRESS_LIMIT`（既定 3）との関係（独立カウンタか統合か）は design.md で確定する。
- 「指摘内容が実質的に変化したか」の判定粒度（Requirement 5.5）。完全一致か、severity/file/message の主要フィールド一致かは design.md の領分だが、ビジネス観点では「同じ design-level 矛盾を指している限り同一とみなす」ことを意図している。
- out-of-scope 構造化マーカーの語彙集合（`design` / `spec-stale` 以外に必要な種別があるか）。本書は Issue 本文の例示 2 種を採用したが、運用上の不足は Open Question として残す。

---

## 自己レビュー結果（要件レビューゲート）

- Mechanical Checks: 全要件見出しが numeric ID（Requirement 1〜6 / NFR 1〜4）。各要件に EARS 形式 AC（When / If / While / Where / The <subject> shall）が 1 件以上存在。実装語彙（DB 名・フレームワーク名・API パターン・関数名・env var 名）は AC 本文に混入させず、例示（マーカー文字列・env 名）は Out of Scope / Open Questions の補足に留めた。
- EARS・テスト可能性: 全 AC が observable / testable。閾値は数値化（no-progress 2 round / SHA 検証パターン）。曖昧語は具体化済み。
- スコープ・カバレッジ: Issue 必須論点 8 点を Requirement 1〜6 + NFR 1〜4 に対応付け（1=第3判定 / 2=round 非消費 / 3=ルーティング / 4=構造化シグナル / 5=内容ベース no-progress / 6=プロンプト明文化 / NFR1=opt-in後方互換 / NFR2=二重管理 / NFR3=セキュリティ）。
- 既存整合: 既存の legitimate/excessive 二値裁定（adjudicator.sh / adjudicator-prompt.tmpl）、no-progress-streak が SHA 変化でリセットされる既存挙動（pr-iteration.sh）、iteration-prompt.tmpl の「設計と矛盾する指摘は取り込まない」運用と矛盾しないことを確認。後方互換は NFR 1 で担保。
- 残存曖昧性は Open Questions に推奨デフォルト付きで列挙し、AC は推奨デフォルト採用形で記述。レビューは 1 パスで確定。
