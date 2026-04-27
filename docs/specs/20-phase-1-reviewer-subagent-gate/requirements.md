# Requirements Document

## Introduction

idd-claude の現状の impl フローでは、Developer が実装とテストを完了した直後に Project Manager が
PR を作成するため、「実装した本人が自分のコードを評価する」構造になり、AC の取りこぼしや
テスト観点の不足を独立に検出できない。本機能では、Developer 完了後に **独立 context** で動く
Reviewer サブエージェントを 1 回起動し、最新 commit の差分・テスト実行結果・受入基準対応関係を
読み取って approve / reject を決定する。reject されたら Developer に 1 度だけ差し戻し、再度
Reviewer に判定させる。再 reject では `claude-failed` で人間に委ねる。Per-task ループ
（Phase 2）、Debugger（Phase 3）、Feature Flag Protocol（Phase 4）は本 Issue の対象外で、
本 Phase は「最小変更・高 ROI」を最優先に、既存の「全タスクを Developer が一気に実装する」
モデルを保ったまま、独立レビューゲートだけを差し込む。

## Requirements

### Requirement 1: Reviewer サブエージェント定義の追加

**Objective:** As a workflow operator, I want Reviewer エージェントを他の Claude サブエージェント（PM / Architect / Developer / PjM）と同じ階層・同じ規約で配置したい, so that consumer repo へのインストールやレビュー時に新規エージェントの存在と責務が一目で把握でき、既存テンプレートの一貫性が崩れない

#### Acceptance Criteria

1. The idd-claude template shall `.claude/agents/reviewer.md` を、既存の PM / Architect / Developer / PjM 定義と同階層に追加する
2. The Reviewer Agent definition shall フロントマター（`name` / `description` / `tools` / `model` フィールド）を既存サブエージェント定義と同じスキーマで持つ
3. The Reviewer Agent definition shall 自身の役割が「Developer 完了後の独立レビュー」であり、要件・設計・実装の追加や書き換えを行わないことを明記する
4. The Reviewer Agent definition shall 着手前に読むべきルール（CLAUDE.md のテスト規約、`docs/specs/<番号>-<slug>/requirements.md` の AC、`tasks.md` の AC 対応表）を明記する
5. The Reviewer Agent definition shall 出力フォーマット（`approve` / `reject` 判定、reject 時の理由カテゴリ列挙、対応する requirement numeric ID への参照）を規定する
6. The idd-claude installer shall consumer repo へのインストール時に reviewer.md を `.claude/agents/` 配下に配置する（既存テンプレートファイル群と同じ配置契約に従う）

### Requirement 2: impl モードでの Reviewer 起動

**Objective:** As a workflow operator, I want Developer の実装完了後に必ず Reviewer が独立 context で起動するようにしたい, so that 「実装した本人が自分のコードに OK を出して PR が作られる」構造を排除し、独立レビューが入るゲートを常設できる

#### Acceptance Criteria

1. When watcher が impl モードまたは impl-resume モードで Developer のステップを正常終了した, the Issue Watcher shall 続けて Reviewer ステップを 1 回起動する
2. The Issue Watcher shall Reviewer を Developer とは独立した Claude セッション（独立 context）として起動する
3. The Issue Watcher shall Reviewer 起動時に、最新 commit の `git diff`、Developer が実行したテスト結果、対象 Issue の `tasks.md` の AC 対応表、CLAUDE.md のテスト規約 をレビュー入力として参照可能な状態で提示する
4. The Issue Watcher shall Reviewer の起動を、Triage モード・skip-triage 経由の軽微 Issue・Architect を経由した design → impl-resume の各ケースを含む **すべての impl 系モード** で行う
5. If Developer ステップが失敗（非 0 exit）で終了した, the Issue Watcher shall Reviewer を起動せず、既存の `claude-failed` 遷移をそのまま適用する
6. The Issue Watcher shall design モード（PM → Architect → PjM）の終端では Reviewer を起動しない
7. While Reviewer ステップ実行中, the Issue Watcher shall Issue ラベルを `claude-picked-up` のまま保持し、`ready-for-review` への遷移を Reviewer の判定確定後に行う

### Requirement 3: Reviewer の判定ロジックと出力契約

**Objective:** As a reviewer / human operator, I want Reviewer の判定基準が「AC 未カバー」「missing test（テスト未追加 / RED フェーズ不在）」「boundary 逸脱」の 3 カテゴリに限定され、判定結果と理由が機械可読な形で残るようにしたい, so that 過剰な reject による開発停止を避けつつ、reject 理由が後続フェーズ（差し戻し・人間エスカレーション）で参照できる

#### Acceptance Criteria

1. The Reviewer Agent shall 各実装変更について、対応する requirement numeric ID（例: 1.1, 2.3）の AC を全て読み、いずれかに該当する `approve` / `reject` の判定を出力する
2. When Reviewer が変更内容を AC と照合した結果、いずれかの requirement numeric ID に対応する観測可能な実装またはテストが見つからない, the Reviewer Agent shall `reject` を出力し、理由カテゴリとして「AC 未カバー」を選択する
3. When Reviewer が新規追加された AC 対応の挙動について、対応するテストケースの追加が確認できない, the Reviewer Agent shall `reject` を出力し、理由カテゴリとして「missing test」を選択する
4. When Reviewer が tasks.md の `_Boundary:_` で許可されていないコンポーネントへの変更を検出した, the Reviewer Agent shall `reject` を出力し、理由カテゴリとして「boundary 逸脱」を選択する
5. The Reviewer Agent shall reject 理由を上記 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）以外に拡張しない
6. If 検出された問題がスタイル違反・命名・フォーマット・lint で検出可能な軽微事項のみである, the Reviewer Agent shall `reject` を出力せず `approve` を出力する
7. When Reviewer が `reject` を出力する, the Reviewer Agent shall reject 対象を「対応する requirement numeric ID（または `_Boundary:_` 違反のコンポーネント名）」と「理由カテゴリ」と「Developer が次に行うべき具体的な是正アクション」の 3 要素で記録する
8. When Reviewer が `approve` を出力する, the Reviewer Agent shall 確認した requirement numeric ID の一覧と、各 ID をカバーするテストケース名（または該当箇所）を 1 行以上で記録する
9. The Reviewer Agent shall requirements.md / design.md / tasks.md / 既存実装コードを書き換えない

### Requirement 4: reject 時の差し戻しループと再 reject の終端処理

**Objective:** As a workflow operator, I want reject が出たら Developer に 1 回だけ自動差し戻し、それでも reject が続く場合は人間に判断を委ねるようにしたい, so that 自動修正の機会を 1 度確保しつつ、無限ループを避けて運用コストの上限を保証できる

#### Acceptance Criteria

1. When Reviewer が初回 `reject` を出力した, the Issue Watcher shall Developer を再度起動し、Reviewer の reject 理由（対象 requirement ID / 理由カテゴリ / 是正アクション）を Developer プロンプトに渡して修正を依頼する
2. When Developer の再実装ステップが正常終了した, the Issue Watcher shall Reviewer を 2 回目（最終回）として再度起動する
3. When Reviewer が 2 回目の判定で `approve` を出力した, the Issue Watcher shall 既存どおり PjM ステップに進み、`claude-picked-up` から `ready-for-review` へラベルを遷移させる
4. When Reviewer が 2 回目の判定でも `reject` を出力した, the Issue Watcher shall PjM ステップを起動せず、対象 Issue から `claude-picked-up` を除去し `claude-failed` ラベルを付与する
5. When 2 回目の `reject` で `claude-failed` が付与された, the Issue Watcher shall 対象 Issue にコメントを 1 件投稿し、Reviewer の reject 理由・対応する requirement numeric ID・watcher ログのファイルパスを含める
6. The Issue Watcher shall Reviewer の差し戻しループを 1 イテレーション（= Reviewer 最大 2 回起動 / Developer 最大 2 回起動）に固定し、それ以上は自動継続しない
7. If 2 回目の Developer 再実装ステップが失敗（非 0 exit）で終了した, the Issue Watcher shall Reviewer を 2 回目に進めず、既存の Developer 失敗時遷移（`claude-failed` 付与）をそのまま適用する
8. If Reviewer ステップ自体が非 0 exit で異常終了した, the Issue Watcher shall PjM ステップを起動せず `claude-failed` ラベルを付与し、Issue にエラーログのパスをコメント投稿する

### Requirement 5: 環境変数による上書きと既定値

**Objective:** As a watcher operator, I want Reviewer の使用モデルと最大 turn 数を環境変数で上書きできるようにしたい, so that モデル更新時に scripts を書き換えず cron / launchd 側から制御でき、既存 watcher の env 命名規約と整合する

#### Acceptance Criteria

1. The Issue Watcher shall 環境変数 `REVIEWER_MODEL` を読み取り、未設定時のデフォルトを `claude-opus-4-7` とする
2. The Issue Watcher shall 環境変数 `REVIEWER_MAX_TURNS` を読み取り、未設定時のデフォルトを `30` とする
3. While Reviewer ステップを起動中, the Issue Watcher shall `REVIEWER_MODEL` の値を Claude Code の model 指定として使用する
4. While Reviewer ステップを起動中, the Issue Watcher shall `REVIEWER_MAX_TURNS` の値を Claude Code の最大 turn 数指定として使用する
5. The Issue Watcher shall `REVIEWER_MODEL` および `REVIEWER_MAX_TURNS` を、既存環境変数（`TRIAGE_MODEL` / `DEV_MODEL` / `TRIAGE_MAX_TURNS` / `DEV_MAX_TURNS` 等）と独立に扱い、互いの値が他方の挙動に影響しないようにする

### Requirement 6: 後方互換性とラベル契約の維持

**Objective:** As an existing watcher user, I want Reviewer 導入によって既稼働の cron / launchd 設定・PR 作成 / Issue ラベル遷移・consumer repo にインストール済みのテンプレートが壊れないようにしたい, so that 本機能の導入が opt-in 不要で安全に main へ取り込め、既存ユーザの再設定コストが発生しない

#### Acceptance Criteria

1. The Issue Watcher shall 既存環境変数（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `TRIAGE_MAX_TURNS`, `DEV_MAX_TURNS` 等）の名称・既定値・意味を変更しない
2. The Issue Watcher shall 既存ラベル（`auto-dev`, `claude-picked-up`, `awaiting-design-review`, `ready-for-review`, `claude-failed`, `needs-decisions`, `skip-triage`, `needs-rebase`, `needs-iteration`）の名称・付与契約・遷移意味を変更しない
3. The Issue Watcher shall 既存の lock ファイルパス・ログ出力先（`LOG_DIR`）・watcher 全体の exit code の意味を変更しない
4. The Issue Watcher shall 既存の cron / launchd 登録文字列（`REPO=... REPO_DIR=... $HOME/bin/issue-watcher.sh` の形）を変更しないまま Reviewer ステップが組み込まれて動作する
5. While Reviewer 導入後の最初の正常パス（reject なし）を実行中, the Issue Watcher shall PR 作成タイミング・PR 本文・Issue コメント投稿の構造を、本機能導入前と読み手にとって等価な内容に保つ
6. The idd-claude installer shall 既に consumer repo に展開済みのテンプレートを再実行で上書き更新する際、reviewer.md の追加以外に既存ファイルへの破壊的変更を加えない

### Requirement 7: ドキュメント更新（DoD）

**Objective:** As a new operator, I want Reviewer ステップの存在・有効化条件・モデル / turn 数の上書き手順・差し戻しループの挙動を README から読み取れるようにしたい, so that 既存ユーザが本機能の影響範囲を即判断でき、トラブルシュート時に 1 次情報源にアクセスできる

#### Acceptance Criteria

1. The README.md shall Reviewer サブエージェントの存在・目的・impl 系モードでの常時起動を記述するセクションを含む
2. The README.md shall 環境変数 `REVIEWER_MODEL` および `REVIEWER_MAX_TURNS` の名称・デフォルト値・上書き例を記載する
3. The README.md shall reject 時の差し戻しループ（最大 1 回の Developer 再実行と再 reject 時の `claude-failed`）の挙動を記載する
4. The CLAUDE.md（プロジェクト憲章）shall 「エージェント連携ルール」節に Reviewer の責務範囲（要件・設計・実装の追加 / 書き換えを行わない）を追記する
5. The reviewer.md shall consumer repo にインストールされる前提で、対象 repo の `CLAUDE.md` の「テスト規約」と整合する判定基準を持つことを明示する

## Non-Functional Requirements

### NFR 1: 実行コスト・タイムバジェット

1. The Issue Watcher shall Reviewer ステップ 1 回あたりの追加コストを、`REVIEWER_MAX_TURNS=30` の上限内に収める
2. The Issue Watcher shall Reviewer ステップを 1 Issue あたり最大 2 回（初回 + 再 reject 時の最終回）までに制限し、それ以上の自動再起動を行わない
3. While 1 Issue を impl モードで完了させる過程で, the Issue Watcher shall Developer の自動再実行を最大 2 回（初回 + reject 後 1 回）までに制限する

### NFR 2: 観測可能性

1. The Issue Watcher shall Reviewer の判定結果（`approve` / `reject` / 異常終了）と、reject 時の理由カテゴリ・対象 requirement numeric ID を watcher ログに 1 行以上で記録する
2. The Issue Watcher shall Reviewer ステップ起動時に、使用モデル ID（`REVIEWER_MODEL` の値）と最大 turn 数（`REVIEWER_MAX_TURNS` の値）をログに記録する
3. The Issue Watcher shall Developer 再実行を行った場合、再実行が「Reviewer reject に基づく差し戻しである」と識別できる文言をログに残す

### NFR 3: 静的解析・スモークテスト

1. The Issue Watcher のシェルスクリプト変更箇所 shall `shellcheck` を警告 0 で通過する
2. The idd-claude maintainer shall 本リポジトリの軽微 Issue を用いた E2E スモークテスト（auto-dev → Triage → impl → Reviewer → PjM → ready-for-review）を 1 回以上完走させ、結果を PR 本文の Test plan に記載する
3. The idd-claude maintainer shall reject 経路の動作確認（意図的に AC 未カバーの実装を作り、Reviewer が reject → Developer 再実行 → Reviewer 2 回目の判定に進むこと）を 1 回以上スモークテストとして実施し、結果を PR 本文の Test plan に記載する

## Out of Scope

- Per-task implementation loop（タスク単位の TDD 自走ループ）→ Phase 2 として別 Issue
- Debugger サブエージェントの起動 → Phase 3 として別 Issue
- Feature Flag Protocol（実装の段階的有効化）→ Phase 4 として別 Issue
- Reviewer による自動修正（Reviewer がコードを書き換える運用）→ 本 Phase は判定のみ
- Reviewer 起動可否の env opt-in / opt-out（本 Phase は impl 系モード全 Issue で常時起動とし、env で無効化する選択肢は提供しない）
- 3 回目以降の Developer 再実行 / Reviewer 再判定（本 Phase は最大 1 ラウンドの差し戻しに固定）
- スタイル違反 / lint 観点の reject（lint 系ツールに委ねる）
- Reviewer の判定結果を PR 本文に転載する整形機能（PjM の責務範囲を変更しない前提）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への Reviewer 組み込み
- Reviewer 専用のラベル新設（既存 `claude-picked-up` / `claude-failed` の遷移に乗せる）

## Open Questions

- 再 reject で `claude-failed` を付ける際に投稿する Issue コメントの粒度（reject 理由を逐語転載するか、要約と watcher ログ参照に留めるか）について Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- Reviewer の入力として渡す「テスト実行結果」の取得方式（Developer が `impl-notes.md` 等に書き込んだ出力を参照するのか、watcher が独立にテストコマンドを再実行するのか）について Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- Reviewer の `approve` / `reject` 判定結果を `docs/specs/<番号>-<slug>/` 配下に永続化するか（例: `review-notes.md`）の保存形式について Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- Developer 再実行時のブランチ運用（同一 impl ブランチに追加 commit を積むのか、reject 修正用の派生ブランチを切るのか）について Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- Reviewer ステップ異常終了時に、Developer 完了済みの commit 群を残したまま `claude-failed` にするのか、ブランチを破棄するのかについて Issue 本文で明示されていないため、design フェーズで具体化する余地がある
