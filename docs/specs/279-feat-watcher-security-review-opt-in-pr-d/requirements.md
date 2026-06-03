# Requirements Document

## Introduction

idd-claude の auto-dev パイプラインは Issue から PR 生成・マージキュー経由の半自動マージまで
無人で進行するが、現状はパイプライン内に **セキュリティ脆弱性の検査工程が存在しない**。
Reviewer エージェントは設計上「missing AC / missing test / boundary 逸脱」の 3 カテゴリ判定に
スコープを限定しており、injection / secret leak / 認証認可不備 / XSS / 依存脆弱性などは
構造上守備範囲外である。本機能は Claude Code が提供する公式 `/security-review` を **opt-in /
既定 OFF** のセキュリティゲートとして PR diff に適用し、検出結果を運用者が PR 上で確認できる
形で残すことで、無人パイプラインのセキュリティ検査の穴を塞ぐ。既存の Reviewer 判定・既存
プロセッサ（PR Iteration / Auto Rebase / Merge Queue / PR Reviewer Processor #261 等）の
動作および後方互換性は維持し、未有効化リポジトリでは本機能導入前と完全に同一の挙動とする。

## Requirements

### Requirement 1: Opt-in による有効化と既定 OFF

**Objective:** As an idd-claude operator, I want セキュリティレビューゲートを env var による
opt-in で有効化したい, so that 既存運用リポジトリには一切影響を与えず段階的に導入できる

#### Acceptance Criteria

1. While `SECURITY_REVIEW_ENABLED` が `true` と完全一致しない（未設定 / 空文字 / `false` /
   `0` / `True` 等の typo を含む）状態である間, the Security Review Gate shall 当該 watcher
   サイクルで自身の処理を一切実行せず、安全にスキップする
2. While `SECURITY_REVIEW_ENABLED` が `true` と完全一致している状態である間, the Security
   Review Gate shall 後述の Requirement 2〜6 で定める処理を実行する
3. The Security Review Gate shall opt-in がスキップされた場合、他の既存プロセッサ（Reviewer /
   PR Iteration / Auto Rebase / Merge Queue / PR Reviewer Processor #261 等）の動作に副作用を
   与えない
4. If `SECURITY_REVIEW_ENABLED` が未設定の状態で watcher が起動した場合, the Security Review
   Gate shall ログに「opt-in 未設定のためスキップ」相当の理由を 1 行記録した上で、本機能
   導入前と観測可能挙動が等価な経路へ進む

### Requirement 2: 対象 PR の判定とスキャン実行

**Objective:** As an idd-claude operator, I want 有効化時に対象 PR の差分に対して
`/security-review` 相当のスキャンを実行したい, so that マージ前に脆弱性検出の機会を得られる

#### Acceptance Criteria

1. The Security Review Gate shall 評価対象を「watcher サイクル時点で対象リポジトリにおいて
   open 状態であり、idd-claude が生成したブランチ命名規約（`claude/issue-*` 等）に合致する
   PR」に限定する
2. When 対象 PR がスキャン実行対象として確定した場合, the Security Review Gate shall 当該
   PR の head と base の差分（PR diff）をスキャン入力として `/security-review` 相当の
   セキュリティ検査を 1 回実行する
3. While 対象 PR が draft 状態である状態である間, the Security Review Gate shall 当該 PR を
   スキャン対象から除外する（既存 Reviewer / PR Iteration が draft を除外する運用との整合）
4. When 対象 PR の head コミットが前回スキャン時点から変化していない場合, the Security
   Review Gate shall 重複スキャンを行わず、当該 PR の処理を冪等にスキップする
5. If 同一 watcher サイクル内に複数の対象 PR が存在する場合, the Security Review Gate shall
   運用者が env var で指定した上限件数（既定値は Open Questions に従う）までを処理し、
   上限到達時はその旨をログに記録する
6. If スキャン実行コマンドが非ゼロ終了コードで失敗した場合, the Security Review Gate shall
   失敗である旨のエラーコメントを対象 PR に投稿し、当該 PR のスキャンを中止する

### Requirement 3: 結果の可視化（PR コメントと成果物）

**Objective:** As an idd-claude operator, I want 検出された脆弱性の severity と修正方針を
人間が PR 上で確認できる形で残したい, so that 無人パイプラインでも検出結果を見落とさない

#### Acceptance Criteria

1. When スキャン結果に 1 件以上の検出項目が含まれていた場合, the Security Review Gate shall
   対象 PR にスキャン結果を含むコメントを 1 回投稿する
2. The Security Review Gate shall 投稿するコメント本文に、運用者が人間判断で識別できる
   見出し（例: `## セキュリティレビュー結果`）と、各検出項目の severity および修正方針相当
   の説明を含める
3. When スキャン結果に検出項目が 1 件も含まれていなかった場合, the Security Review Gate
   shall 「クリーンである旨」を明示する見出し（例: `## セキュリティレビュー結果: クリーン`）
   を含むコメントを対象 PR に 1 回投稿し、重複防止用の非表示 HTML マーカーを埋め込む
4. The Security Review Gate shall コメント本文中に当該 PR の head コミット SHA を含む非表示
   HTML マーカーを埋め込み、同一 SHA に対する重複コメント投稿を冪等に防止する
5. The Security Review Gate shall スキャン結果の構造化アーティファクト
   `security-notes.md` を、対応する spec ディレクトリ（`docs/specs/<番号>-<slug>/`）配下に
   書き出し、検出件数・severity 集計・各項目の要約を含める（spec ディレクトリが特定できない
   PR の場合の挙動は Open Questions に従い、書き出しを skip する安全側既定とする）

### Requirement 4: Reviewer エージェントとの独立性

**Objective:** As an idd-claude operator, I want 既存 Reviewer の 3 カテゴリ判定（missing AC /
missing test / boundary 逸脱）と本機能を完全独立で運用したい, so that Reviewer 既存挙動の
回帰を起こさない

#### Acceptance Criteria

1. The Security Review Gate shall Reviewer エージェントの判定対象カテゴリ（missing AC /
   missing test / boundary 逸脱の 3 カテゴリ）を追加・変更・削除しない
2. The Security Review Gate shall Reviewer エージェントが書き出す `review-notes.md` の内容・
   `RESULT: approve|reject` の判定論理に介入しない
3. While 本機能が有効化されている状態である間, the Security Review Gate shall Reviewer の
   approve / reject 結果と独立して、自身のスキャン結果のみに基づきコメント投稿および
   （後述 Requirement 5 で定める）ラベル付与を判断する
4. The Security Review Gate shall 自身の処理失敗・スキャン失敗を Reviewer の判定結果に
   反映しない（Reviewer の差し戻し / 承認動線を変更しない）

### Requirement 5: ゲート挙動（advisory 固定 / strict は別 Issue）

**Objective:** As an idd-claude operator, I want 本 spec ではゲート挙動を advisory に固定し、
検出件数に関わらずマージブロック操作を行わない初期実装とすることで、リスクを最小化した
opt-in 導入を行いたい, so that 運用が安定してから strict 拡張を別 Issue で段階導入できる

#### Acceptance Criteria

1. The Security Review Gate shall ゲート挙動を `advisory` 固定とし、検出結果の severity に
   関わらず、対象 PR のマージを阻害するラベル付与およびマージブロック操作を行わない
   （Requirement 3 のコメント投稿および security-notes.md 書き出しに処理を限定する）
2. The Security Review Gate shall ゲート挙動値（`advisory`）および本 spec での strict 未実装
   である旨をログに 1 行記録する
3. While `strict` 拡張を要求する env var が設定された状態である間, the Security Review Gate
   shall 警告ログを 1 行記録した上で `advisory` 相当の挙動を採用する（strict 実装は本 spec
   の Out of Scope であり、別 Issue で段階拡張する前提）

### Requirement 6: 結果コメント投稿と冪等性

**Objective:** As an idd-claude operator, I want 同一 PR 同一 SHA に対する重複スキャン / 重複
コメントを防ぎたい, so that PR のタイムラインが冗長にならず運用負荷を抑えられる

#### Acceptance Criteria

1. When 対象 PR にコメントまたはエラーコメントを投稿する場合, the Security Review Gate
   shall コメント本文中に当該 PR の head コミット SHA を含む非表示 HTML マーカーを埋め込む
2. While 対象 PR の既存コメント群に当該コミット SHA を含む同種マーカーが存在する状態で
   ある間, the Security Review Gate shall 当該 PR に対する同種のコメント投稿および新規
   スキャン実行を行わない
3. When 対象 PR の head コミットが更新され、結果として head SHA が変化した場合, the Security
   Review Gate shall 新しい SHA に対するスキャン処理を新規実行として扱う
4. The Security Review Gate shall マーカーの文字列形式を、運用者が GitHub UI で目視確認可能な
   非表示コメント（HTML コメント形式）として実装する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `SECURITY_REVIEW_ENABLED` が `true` と完全一致しない状態である間, the watcher shall
   本機能導入前と完全に同一の挙動を維持する（既存のラベル遷移・コメント投稿・他プロセッサ
   起動順序・exit code 意味を含む観測可能挙動が等価）
2. The Security Review Gate shall 既存 env var（`REPO` / `REPO_DIR` / `BASE_BRANCH` /
   `PR_REVIEWER_ENABLED` / `PR_ITERATION_ENABLED` / `MERGE_QUEUE_ENABLED` / `LABEL_*` 系等）
   の名前・意味・既定値を変更しない
3. The Security Review Gate shall 既存 cron / launchd 登録文字列を変更しない

### NFR 2: ランタイム非依存

1. The Security Review Gate shall 新規ランタイム（Node.js / Python / Ruby 等）の追加を
   伴わずに動作する（Claude Code 公式 `/security-review` 機構または公式 GitHub Action の
   いずれかに依拠する経路に限定する）
2. The Security Review Gate shall 依存 CLI を既存パイプラインで前提済みの集合（`gh` / `jq` /
   `git` / `flock` / `claude` 等）の範囲に留め、新規 CLI ツールの導入を行わない
3. While 本機能が有効化された状態である間, the watcher shall 既存の最小 PATH 解決
   （cron 環境想定）配下で動作する

### NFR 3: 観測可能性

1. The Security Review Gate shall 主要な分岐点（opt-in スキップ理由 / 対象 PR 件数 /
   draft 除外 / 重複 SHA 検出 / スキャン実行 / スキャン失敗 / コメント投稿 / ラベル付与
   / ゲート厳格度判定）を運用者がログから判定できる形で記録する

### NFR 4: 冪等性

1. The Security Review Gate shall 同一 PR 同一 SHA に対して watcher を複数回起動しても、
   観測可能な副作用（PR コメント / ラベル / 成果物ファイル等の外部書き込み）が 1 回分の
   みとなることを保証する（重複防止機構は Requirement 6 に従う）

### NFR 5: 静的解析品質

1. While 本機能の新規／変更ファイル群に対して `shellcheck`（および該当する場合
   `actionlint`）を実行した状態である間, the static analysis result shall 警告ゼロで完了
   する（既存リポジトリ運用と同じ `.shellcheckrc` / `actionlint` 抑止方針に従う）

### NFR 6: ドキュメント整合性

1. The Security Review Gate shall README の「オプション機能一覧」相当の節に、新規 env var
   名・既定値・有効化条件・opt-in である旨・ゲート厳格度の挙動・成果物保存有無を明記する
2. While 本機能の追加または挙動変更を含む PR が作成された状態である間, the documentation
   shall 同一 PR 内で README / CLAUDE.md / 該当 rule ファイルの該当箇所が同時更新されて
   いる

### NFR 7: 二重管理整合（agents / rules を編集する場合）

1. Where 本機能の実装が `.claude/agents/*.md` または `.claude/rules/*.md` の変更を伴う場合,
   the implementation shall 同一 PR 内で root `.claude/{agents,rules}/` と
   `repo-template/.claude/{agents,rules}/` の双方を byte 一致で更新する
2. While 上記更新が同一 PR に含まれた状態である間, the verification step shall
   `diff -r .claude/agents repo-template/.claude/agents` および
   `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認する

## Out of Scope

- サードパーティ製セキュリティスキャナ（ECC / AgentShield / 商用 SAST / DAST 等）の統合
- watcher / install.sh / setup.sh 等のハーネス自身に対するセキュリティ監査（本機能の対象は
  PR diff のみ）
- 検出脆弱性に対する自動修正（auto-fix）コミット生成
- 言語別 / フレームワーク別の独自ルールセットの開発・配布
- `/security-review` 公式実装自体の差し替え・改造（公式機構の出力を消費する経路のみを対象）
- 既存 Reviewer の判定対象カテゴリ拡張（Reviewer は 3 カテゴリ判定のまま不変、本機能とは
  独立に動作する）
- **strict モード（severity 閾値に基づくマージ阻害ラベル付与）の実装**: 本 spec では
  advisory 固定とし、strict 拡張は **別 Issue #281 として段階導入する**。
  本 spec の Requirement 5 でも strict 拡張時のラベル名・閾値 env var・PR Iteration への
  接続点は規定しない
- セキュリティ検出結果に基づくテレメトリの自動収集・外部送信
- 既存リポジトリの過去 PR への遡及スキャン（本機能の対象は本機能有効化以降に open である
  PR に限定）

## Open Questions

> 本節は PR レビュー（#280 round 1）で **以下のとおり確定済み**。残課題は実装段階で
> `impl-notes.md` に記録する。

- ~~統合経路の最終選択~~ → **確定**: watcher 内から `claude` CLI headless 起動経路（公式
  GitHub Action 経路は Non-Goals）
- ~~ゲート厳格度の既定値~~ → **確定**: advisory 固定。strict 拡張は **別 Issue として分割**
  （#281 として起票済み）
- ~~結果保存先の最終選択~~ → **確定**: PR コメント + `security-notes.md` 成果物の両方を
  併用。`security-notes.md` は対応 spec ディレクトリ（`docs/specs/<番号>-<slug>/`）配下に
  書き出す（Req 3.5）
- ~~プロセッサ構造~~ → **確定**: 独立 Security Review Processor として
  `local-watcher/bin/modules/security-review.sh` 新規追加
- ~~env var 命名の完全集合~~ → **確定**: `SECURITY_REVIEW_ENABLED` のみ本 spec で必須。
  上限件数 `SECURITY_REVIEW_MAX_PRS` 等の調整 env は design.md「Environment Variables」表で
  確定。strict 関連 env / 閾値 / ラベル名は別 Issue で扱う
- ~~検出ゼロ時の挙動~~ → **確定**: 「クリーンである旨」を明示するコメントを 1 回投稿（Req 3.3）
- ~~`security-notes.md` 配置先~~ → **確定**: `docs/specs/<番号>-<slug>/security-notes.md`
  （spec ディレクトリが特定できない PR は書き出しを skip）
- 残課題（実装段階で確定 / `impl-notes.md` 記録）: `claude` CLI headless での
  `/security-review` 起動 prompt の正確な文字列。公式ドキュメント上「-p モードで slash command
  は使えず、タスクを記述せよ」とされており、本 spec では「タスク記述 + Skill tool 経由
  `/security-review` 起動を期待する prompt 文字列」を初期実装とし、実機の `claude` バージョン
  ごとに微調整する余地を `SECURITY_REVIEW_PROMPT` env で残す

## 関連

- Depends on: #261
- Related: #13
- Sibling: #281
