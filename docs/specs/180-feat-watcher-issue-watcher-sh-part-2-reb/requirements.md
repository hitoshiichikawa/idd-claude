# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` は 1 万行を超える単一 bash スクリプトであり、3 段階の
段階的モジュール分割リファクタリングが進行中である。本 spec はその **Part 2** を対象とし、
クォータ待機制御・マージキュー・自動 Rebase の 3 プロセッサを独立モジュールへ切り出す。

前提として Part 1（#177）が「モジュールロード基盤」を提供しているはずだが、main の実状では
`core_utils.sh` への関数移動は完了している一方で、`issue-watcher.sh` 側の `source` 配線も
`install.sh` のモジュール配置も存在せず、移動済みロガーを参照する既存テスト 3 本が現に失敗して
いる。本 spec はこの基盤欠落を Part 2 のスコープで吸収し（後述「確認事項」で人間レビュー対象と
して明示する）、3 プロセッサの抽出に必要なロード配線・install 配置・テスト追従までを含める。
このスクリプトは self-hosting で本番稼働中のため、外部から観測可能な挙動を一切変えない差分等価
リファクタリングであることが最優先制約である。

## 関連

- Depends on: #177
- Sibling: #181

## Requirements

### Requirement 1: クォータ待機制御プロセッサの切り出し

**Objective:** As a watcher の保守者, I want クォータ枯渇検出・待機制御ロジックが独立モジュールに
集約されること, so that 巨大スクリプトから当該責務を分離してレビュー・保守できる

#### Acceptance Criteria

1. The watcher shall クォータ待機制御の各関数（レート制限検出・ステージ実行ラッパー・reset 時刻の永続化と読み出し・Resume 処理）を独立した 1 つのモジュールファイルに集約して提供する
2. When メインサイクル処理がクォータ待機制御関数を呼び出したとき, the watcher shall 分割前と同一のシグネチャ・戻り値・副作用で当該関数を解決し実行する
3. When Resume 処理がクォータ待機制御関数を呼び出したとき, the watcher shall 分割前と同一のシグネチャ・戻り値・副作用で当該関数を解決し実行する
4. While クォータ枯渇が検出されたとき, the watcher shall 分割前と同一の exit code（quota 検出時の sentinel コード）と reset 時刻の永続化結果を返す

### Requirement 2: マージキュー制御プロセッサの切り出し

**Objective:** As a watcher の保守者, I want approved PR のマージ順序制御・再チェックロジックが独立
モジュールに集約されること, so that マージキュー責務を分離して保守できる

#### Acceptance Criteria

1. The watcher shall マージキュー制御の各関数（定期マージ処理・再チェック処理）を独立した 1 つのモジュールファイルに集約して提供する
2. When 定期サイクルがマージキュー処理を呼び出したとき, the watcher shall 分割前と同一のマージ順序判定・状態遷移で処理を実行する
3. When 再チェック処理が呼び出されたとき, the watcher shall 分割前と同一の再検証ロジックで処理を実行する

### Requirement 3: 自動 Rebase プロセッサの切り出し

**Objective:** As a watcher の保守者, I want コンフリクトした approved PR の自動 Rebase ロジックが
独立モジュールに集約されること, so that 自動 Rebase 責務を分離して保守できる

#### Acceptance Criteria

1. The watcher shall 自動 Rebase 制御の各関数（候補抽出・rebase 実行・差分分類・approve 解除・エスカレーション等）を独立した 1 つのモジュールファイルに集約して提供する
2. When 自動 Rebase 処理が呼び出されたとき, the watcher shall 分割前と同一の allowlist パスベース判定で rebase 対象を選別する
3. While 自動 Rebase 処理が走るとき, the watcher shall 分割前と同一の条件で既存 approve の解除を行う
4. If rebase が解決不能なコンフリクトに遭遇したとき, the watcher shall 分割前と同一のエスカレーション挙動（claude-failed 相当の状態遷移）を行う

### Requirement 4: モジュールロード配線の確立

**Objective:** As a watcher 本体, I want 自身の配置ディレクトリ基準で新規 3 モジュールと既存
`core_utils.sh` を動的に `source` できること, so that 抽出後に全関数が実行時に解決される

#### Acceptance Criteria

1. When `issue-watcher.sh` が起動したとき, the watcher shall 自身のスクリプトディレクトリを基準とする相対パスで切り出し済みモジュールおよび既存共通ユーティリティモジュールを `source` する
2. While cron-like の最小 PATH 環境で起動されたとき, the watcher shall モジュールのロードをスクリプトディレクトリ基準で解決し、外部の作業ディレクトリに依存せず成功させる
3. When 全モジュールが正常にロードされたとき, the watcher shall 切り出した 3 プロセッサの全関数を未定義参照なく解決する
4. If 必須モジュールが配置先に欠落しているとき, the watcher shall 欠落したモジュール名を含むエラーメッセージを標準エラー出力へ出し、exit code 1 で安全に停止する

### Requirement 5: install.sh によるモジュール配置

**Objective:** As a watcher の運用者, I want `install.sh` がモジュールスクリプトをローカル実行
ディレクトリへ冪等に配置すること, so that 分割後の watcher がローカル環境で全モジュールをロードできる

#### Acceptance Criteria

1. When 運用者がローカル配置を伴う `install.sh` を実行したとき, the install スクリプト shall `local-watcher/bin/modules/` 配下の全モジュールスクリプトを `$HOME/bin/modules/` へ配置する
2. When 運用者が同一の `install.sh` を 2 回目以降に実行したとき, the install スクリプト shall 既に同一内容で配置済みのモジュールを SKIP として扱い再コピーしない
3. If 配置先に内容差分のある既存モジュールが存在し上書き指定がないとき, the install スクリプト shall 既存ファイルを上書きせず保護する
4. When 運用者が dry-run を付けて実行したとき, the install スクリプト shall モジュール配置をファイルシステムに反映せず、実行時と同じ分類の予定操作を dry-run プレフィクス付きで列挙する
5. The install スクリプト shall モジュール配置を `$HOME` 配下のユーザースコープで完結させ、sudo を必要としない

### Requirement 6: 既存テストの継続通過

**Objective:** As a watcher の保守者, I want 既存スモークテストが分割後の構成でもクリーンに通過する
こと, so that 分割が差分等価であることを機械的に検証できる

#### Acceptance Criteria

1. When 既存スモークテスト一式を分割後の構成で実行したとき, the test スイート shall 1 件も失敗せずに通過する
2. While 既存テストが切り出し対象の関数を抽出して評価する方式を採るとき, the 分割後の構成 shall 当該テストが移動後の定義位置から対象関数を解決できるようにする
3. If モジュール分割以前から失敗していたテスト（移動済みロガーを参照するもの）が存在するとき, the 分割後の構成 shall 当該テストが移動後の定義を解決できるよう追従させ、通過状態へ戻す

## Non-Functional Requirements

### NFR 1: 後方互換性（差分等価）

1. The watcher shall 既存環境変数名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）を分割前と同一の意味で受け付ける
2. The watcher shall 既存環境変数の初期値・グローバル設定変数の値を分割前と同一に保つ
3. The watcher shall 既存の exit code の意味を分割前と同一に保つ
4. The watcher shall ログ出力先・ログ書式・ログプレフィクスを分割前と同一に保つ
5. The watcher shall ラベル遷移契約（`auto-dev` → `claude-claimed` 等の状態遷移）を分割前と同一に保つ
6. The watcher shall 既存 cron / launchd の登録文字列（`$HOME/bin/issue-watcher.sh` を呼ぶ起動行）を変更不要なまま動作させる
7. While 切り出した関数が呼び出されるとき, the 分割後の構成 shall 分割前と差分等価な挙動（同一の入出力・副作用）を示す

### NFR 2: インストールの冪等性と非特権性

1. When `install.sh` を再実行したとき, the install スクリプト shall モジュール配置を含めて破壊的変更を起こさず冪等に完了する

### NFR 3: 観測可能性

1. When モジュールのロードまたは配置で失敗が発生したとき, the watcher または install スクリプト shall その失敗を silent fail させず、exit code またはログで運用者に明示する

## Out of Scope

- 開発ループ・検証ステージ・昇格パイプライン系ロジックの切り出し（Part 3 / #181 の対象）
- 切り出した 3 プロセッサのリファクタを超えた挙動変更・新機能追加
- 新しい環境変数・ラベル・exit code 意味の導入
- `core_utils.sh` の内容変更（Part 1 で確立済みの共通ユーティリティの再設計）
- 3 プロセッサ以外の関数群（Dispatcher 本体・Triage・PR 反復など）の切り出し
- モジュール分割の内部構造（どの関数をどう束ねるか、`source` 順序、ファイル間依存の解決方式、モジュールファイル名）の決定 → `design.md` の領分
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への波及
- `setup.sh` のクローン挙動変更（install のモジュール配置に必要な範囲を超える変更）

## 確認事項

- **【最重要】Part 1 基盤欠落の吸収範囲**: main 上では Part 1（#177）が想定する「モジュールロード
  基盤」が未配線である（`issue-watcher.sh` に `source .../modules/core_utils.sh` 行がなく、
  `install.sh` も `modules/` を配置せず、移動済みロガーを参照する既存テスト 3 本
  [`qa_run_claude_stage_test.sh` / `repo_prefix_log_test.sh` / `verify_pushed_or_retry_test.sh`]
  が現に失敗している）。本 spec はこの欠落を Part 2 で吸収する方針（Requirement 4・5・6.3）で
  要件化した。**「Part 1 を別 Issue で先行修正し、Part 2 は純粋に 3 プロセッサ抽出だけに限定する」**
  という選択肢も成立するため、どちらを採るかは人間の決定が必要。
- **モジュールファイル名の命名規約**: Issue 本文は underscore 命名（`quota_aware.sh` /
  `merge_queue.sh` / `auto_rebase.sh`）を示すが、既存 `core_utils.sh` および repo の命名慣習との
  整合を踏まえると hyphen 命名（`quota-aware.sh` / `merge-queue.sh` / `auto-rebase.sh`）も候補。
  本 spec は要件としてファイル名を確定せず「独立した 1 モジュールファイルに集約」とのみ規定した。
  最終的な命名は `design.md`（Architect）／人間判断に委ねる。
- 上記以外の Part 2 固有の人間決定事項は、現時点で Issue 本文・コメントに未提示（Issue にコメントなし）。
