# Requirements Document

## Introduction

idd-claude のワークフローは worktree 内の `.claude/agents/*.md`（エージェント定義）と
`.claude/rules/*.md`（EARS / レビューゲート等の共通ルール）に依存して動作する。これらが
worktree に存在しないまま agent stage を起動すると、PM / Architect / Developer / Reviewer は
ルール非装備の degraded 状態で実行され、外形的には正常に見える成果物を出し続ける。実際に
ある消費 repo が 2026-05-17 に `.claude/` を gitignore＋tracking 除外したことで、`.claude/rules`
が worktree に届かない degraded 実行が数週間 silent に継続する事故が起きた（#237 は `.claude/`
を worktree に届ける delivery 側の対策）。

本機能はその delivery が「実際に届いているか」を能動検証・可視化する側を担う。すなわち
(1) worktree reset 完了直後・最初の agent stage 起動前に scaffolding の到達性を検査する preflight
ゲートと、(2) 各 crontab repo の足場・依存ツール・必須ラベル・base ブランチ解決可否を副作用なく
点検する `doctor` 点検サブコマンドの 2 機構を追加し、silent な degraded 進行を構造的に防ぐ。

## Requirements

### Requirement 1: Preflight scaffolding health gate（reset 後・agent stage 前の足場検査）

**Objective:** As a idd-claude 運用者, I want worktree reset 完了直後に `.claude` 足場の到達性を検査してほしい, so that ルール非装備の degraded 実行が silent に agent stage へ進むのを防げる

#### Acceptance Criteria

1. When worktree reset（`git reset --hard` ＋ `clean -fdx`）と `.claude` 注入処理が完了した後・最初の agent stage を起動する前のタイミングで, the watcher shall worktree 内の `.claude/agents` ディレクトリと `.claude/rules` ディレクトリそれぞれに非空のファイルが存在するかを検査する
2. When 足場検査で `.claude/agents` または `.claude/rules` の不在または空状態を検出したとき, the watcher shall loud な WARN ログとして欠落内容（どちらが欠落したか）を運用者可視の形で出力する
3. When 足場検査で欠落を検出したとき, the watcher shall 当該 Issue 上に運用者が気付ける可視シグナル（Issue コメントまたはラベル等の人間可視な痕跡）を残す
4. While 足場検査が欠落を検出した状態であっても, the watcher shall その事実を silent に握りつぶして無告知のまま degraded で agent stage へ進めてはならない
5. While `.claude/agents` と `.claude/rules` の双方に非空ファイルが存在する worktree の場合, the gate shall pass し agent stage を本機能導入前と同一の挙動で起動する

### Requirement 2: 既定可視化挙動と opt-in 停止挙動の切り替え

**Objective:** As a idd-claude 運用者, I want 足場欠落時の既定挙動を「可視化のみ」とし停止挙動を opt-in で選べるようにしてほしい, so that 既存の自動進行フローを壊さずに、より厳格な運用へ段階的に移行できる

#### Acceptance Criteria

1. When 足場欠落を検出し opt-in の停止設定が無効な状態のとき, the watcher shall WARN と可視シグナルを残したうえで処理を継続する（既定 = 可視化のみ）
2. Where 運用者が opt-in 設定で停止挙動を有効化している場合, the watcher shall 足場欠落を検出した Issue を agent stage へ進めず人間判断待ちの状態へ遷移させる
3. While opt-in の停止設定が未指定・無効値・空のいずれかの場合, the watcher shall 既定の可視化のみ挙動（AC 2.1）として解釈する

### Requirement 3: 足場検査の異常時 fail-open

**Objective:** As a idd-claude 運用者, I want 足場検査自体が確定不能なときに処理が止まらないようにしてほしい, so that 検査の I/O 異常で無実の Issue が誤って失敗扱いにならない

#### Acceptance Criteria

1. If 足場検査が I/O エラー等で足場の存否を確定できない場合, the watcher shall warn を残したうえで処理を継続する（fail-open）
2. If 足場検査が確定不能で fail-open した場合, the watcher shall その確定不能の事実を運用者可視のログとして残す
3. While 足場検査が確定不能の場合であっても, the watcher shall 当該 Issue を検査失敗のみを理由に失敗状態へ遷移させてはならない

### Requirement 4: doctor 点検サブコマンド（オンデマンド・read-only）

**Objective:** As a idd-claude 運用者, I want 各 crontab repo の装備状態を副作用なく点検するサブコマンドがほしい, so that フル装備か degraded かを実行前に一覧で把握できる

#### Acceptance Criteria

1. When 運用者が doctor 点検サブコマンドを実行したとき, the watcher shall 対象として設定された各 repo（REPO / REPO_DIR）について点検を実施しレポートを出力する
2. When doctor が各 repo を点検するとき, the watcher shall `.claude/agents` と `.claude/rules` の scaffolding 到達性を点検項目として含める
3. When doctor が各 repo を点検するとき, the watcher shall 依存 CLI（gh / jq / flock / git / claude）の存在可否を点検項目として含める
4. When doctor が各 repo を点検するとき, the watcher shall ワークフローが前提とする必須ラベルの存在可否を点検項目として含める
5. When doctor が各 repo を点検するとき, the watcher shall base ブランチの解決可否を点検項目として含める
6. When doctor が点検を完了したとき, the watcher shall 各 repo を「フル装備」または「degraded」として識別できる一覧形式でレポートする
7. While doctor を実行している間, the watcher shall 対象 repo・worktree・Issue・ラベルに対する書き込みや状態変更を一切行わない（read-only / 副作用なし）

### Requirement 5: 後方互換性の維持

**Objective:** As a idd-claude 運用者, I want 本機能導入によって既存運用の挙動が変わらないことを保証してほしい, so that tracked 運用の既存 repo と自動進行フローが影響を受けない

#### Acceptance Criteria

1. While worktree に `.claude/agents` と `.claude/rules` が既に存在する tracked 運用 repo の場合, the gate shall pass し false positive な WARN を出さず本機能導入前と同一の挙動を保つ
2. The watcher shall 既存の環境変数名・ラベル遷移契約・exit code の意味・既存ログ書式を本機能導入前と同一に保つ
3. When 同一の足場検査または doctor 点検が同一状態に対して再実行されたとき, the watcher shall 状態を変化させず同一の判定結果を返す（冪等性）

## Non-Functional Requirements

### NFR 1: 後方互換性・false positive 抑止

1. While 検査対象の worktree に `.claude/agents` と `.claude/rules` が存在する tracked 運用 repo の場合, the gate shall NO-OP として通過し、既存の degraded でない repo に対し誤検知（false positive）の WARN を 0 件に保つ

### NFR 2: 可観測性

1. When 足場欠落または fail-open を検出したとき, the watcher shall 欠落・継続・停止のいずれの分岐を取ったかを運用者が事後に判別できる粒度でログに記録する

### NFR 3: 性能（オンデマンド点検のレイテンシ）

1. The doctor サブコマンド shall 対象 repo 1 件あたりの点検をネットワーク待ち時間を除き数秒以内のオーダーで完了し、対象 repo 数に対して線形以下の時間で全レポートを出力する

### NFR 4: 副作用なし・安全性

1. While doctor が実行中の場合, the watcher shall git の作業ツリー・index・refs を変更せず、Issue / PR / ラベルへの書き込み API を呼び出さない

### NFR 5: 冪等性（self-hosting 前提）

1. When 足場検査・fail-open 処理・doctor 点検のいずれかが繰り返し実行されたとき, the watcher shall 副作用を累積させず、同一入力状態に対して同一の観測可能結果を返す

## Out of Scope

- `.claude/`（agents / rules）を worktree へ届ける delivery 側の仕組み（#237 の責務）。本 Issue は
  delivery が届いているかを検証・可視化する側のみを扱う
- 欠落した `.claude/` 足場を doctor / gate が自動的に修復・再注入する機能（検査と可視化に留め、
  修復は delivery 側 #237 / 運用者判断に委ねる）
- agents / rules ファイルの**内容の正当性**（中身が正しいルールか・最新か）の検証。本機能は
  「非空で存在するか」という到達性レベルの検査に限定する
- 足場欠落時の自動 PR 作成・自動 commit・自動ラベル運用変更などの能動的な状態修復
- 具体的な環境変数名・サブコマンド構文・関数名・モジュール分割・ログ書式の確定（design.md の領分）
- 依存 CLI そのもののインストール・自動セットアップ（doctor は存否点検のみ）

## Open Questions

- なし（Issue 本文に必要情報が揃っており、人間コメントによる追加の決定事項は存在しない。停止挙動の
  opt-in 設定の具体名・doctor の起動構文・可視シグナルの具体的手段（コメント／ラベル）は実装観測挙動
  として記述済みで、その実現手段は design.md / Architect の領分に委ねる）
