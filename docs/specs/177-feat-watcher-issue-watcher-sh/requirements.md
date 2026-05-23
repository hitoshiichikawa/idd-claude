# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` は約 12,000 行の単一 Bash スクリプトに肥大化しており、保守・拡張・AI 協調開発（編集時のトークンコストとデグレリスク）・関数単位のテストの全てがボトルネックになっている。本機能は、責務ごとにスクリプトを `modules/` 配下へ分割し、`issue-watcher.sh` 本体を起動時に modules を動的ロードするエントリポイント兼ディスパッチャに再構成することで、保守性と開発効率を高める。idd-claude は self-hosting（dogfooding）で本スクリプト自身が次回 cron 実行で自分を動かすため、既存運用（cron / launchd が `$HOME/bin/issue-watcher.sh` を直接起動）との完全な後方互換性と冪等性が最重要要件となる。本リファクタリングは外部から観測される振る舞いを一切変えない（差分等価）ことを前提とする。

## Requirements

### Requirement 1: 動的モジュールロードによる起動

**Objective:** As a 運用者（cron / launchd で watcher を起動する人）, I want `issue-watcher.sh` がモジュール分割後も従来と同一の単一起動コマンドで全機能を読み込んで動作すること, so that 既存の cron / launchd 登録を一切変更せずにモジュール化の恩恵を受けられる

#### Acceptance Criteria

1. When `$HOME/bin/issue-watcher.sh` が起動されたとき, the Issue Watcher shall 自身の配置ディレクトリ配下の `modules/` から必要な全モジュールをロードしてから処理を開始する
2. The Issue Watcher shall 起動経路（cron / launchd / 手動実行）やカレントディレクトリに依存せず、自身の配置位置を基準に `modules/` を解決する
3. If ロード対象のモジュールが 1 件でも欠落または読み込み不能であるとき, the Issue Watcher shall 処理を継続せず非ゼロ exit code で停止し、欠落モジュールを特定できるエラーメッセージを標準エラー出力に出す
4. When 全モジュールのロードが成功したとき, the Issue Watcher shall モジュール化導入前と同一の機能セット（Triage / 各モード / 各 Processor）を提供する

### Requirement 2: インストーラによるモジュール配置

**Objective:** As a 運用者（install.sh でローカル watcher を導入・更新する人）, I want `install.sh` 実行時に `modules/` 配下の全モジュールが `$HOME/bin/modules/` へ過不足なく配置されること, so that 動的ロードが成立し、再実行しても環境が壊れない

#### Acceptance Criteria

1. When `install.sh` がローカル watcher のインストールを実行したとき, the Installer shall `local-watcher/bin/modules/` 配下の全モジュールを `$HOME/bin/modules/` へ配置する
2. While `install.sh` を再実行したとき, the Installer shall モジュール配置を冪等に扱い、既存のユーザー環境を破壊しない
3. When `install.sh` が `--dry-run` で実行されたとき, the Installer shall モジュール配置についても実コピーを行わず予定操作のみを既存と同一の分類書式で列挙する
4. The Installer shall モジュール配置の各操作（新規 / スキップ / 上書き等）を既存のインストールログと同一の書式で観測可能にする

### Requirement 3: 既存設定・起動契約の後方互換性

**Objective:** As a 運用者, I want モジュール分割後も既存の環境変数・起動コマンド・ログ出力先・ラベル遷移・exit code の意味が導入前と完全に等価であること, so that self-hosting 環境を含む既稼働の cron / launchd が無告知の破壊を受けない

#### Acceptance Criteria

1. The Issue Watcher shall 既存の全環境変数（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）の名称・デフォルト値・override 挙動をモジュール化導入前と等価に保つ
2. When 既存の cron / launchd 起動コマンド（`$HOME/bin/issue-watcher.sh` を env var 付きで直接起動）がそのまま実行されたとき, the Issue Watcher shall モジュール化導入前と同一の処理サイクルを実行する
3. The Issue Watcher shall ログ出力先・ラベル遷移契約・exit code の意味をモジュール化導入前と等価に保つ
4. If モジュール化に伴い後方互換性を破る変更が不可避であるとき, the Issue Watcher shall その変更を README の migration note として明文化したうえでのみ導入する

### Requirement 4: 既存テストの不破壊

**Objective:** As a 開発者（watcher を保守する人）, I want モジュール分割後も既存のシェルスクリプトテストが全て成功すること, so that リファクタリングがデグレを起こしていないことを観測可能に保証できる

#### Acceptance Criteria

1. When `local-watcher/test/` 配下の全テストが実行されたとき, the Test Suite shall モジュール化構成のもとで全テストが成功する
2. When `tests/local-watcher/` 配下の全テストが実行されたとき, the Test Suite shall モジュール化構成のもとで全テストが成功する
3. While 個別関数を検証する既存テストが対象関数を抽出して読み込むとき, the Test Suite shall 関数の移動先にかかわらず対象関数を解決して検証できる
4. If リファクタリングにより既存テストが対象関数を解決できなくなるとき, the Test Suite shall その不整合を成功扱いで隠さず、テスト失敗として観測可能にする

### Requirement 5: 静的解析クリーン

**Objective:** As a 開発者, I want 分割後のエントリポイントと全モジュールが静的解析で警告ゼロであること, so that モジュール化後もコード品質基準を維持できる

#### Acceptance Criteria

1. When `issue-watcher.sh` に対して `shellcheck` を実行したとき, the Static Analysis shall 警告ゼロを報告する
2. When `modules/` 配下の各モジュールに対して `shellcheck` を実行したとき, the Static Analysis shall 各モジュールについて警告ゼロを報告する

## Non-Functional Requirements

### NFR 1: 後方互換性・差分等価性

1. The Issue Watcher shall モジュール化導入前後で外部から観測される振る舞い（処理結果・ログ書式の契約・ラベル遷移・exit code）を差分等価に保つ
2. While self-hosting 環境（idd-claude 自身を対象 repo として cron 実行）で次回サイクルが動作するとき, the Issue Watcher shall モジュール化導入前と同一の挙動でその回の処理を完走する

### NFR 2: 冪等性

1. When `install.sh` を 2 回以上連続して実行したとき, the Installer shall モジュール配置の最終結果を 1 回実行時と同一にする
2. If モジュール配置先に既存ファイルが存在し内容に差分があるとき, the Installer shall 既存ファイル群（`*.sh` / `*.tmpl` 等）に対する現行の上書き・退避方針と矛盾しない方針で配置を行う

### NFR 3: 起動環境の堅牢性

1. While cron / launchd の最小 PATH 環境で起動されたとき, the Issue Watcher shall `$HOME` を基準にモジュールと依存コマンドを解決し、対話シェルの profile に依存せず動作する
2. The Issue Watcher shall モジュール解決にユーザーのカレントディレクトリやシンボリックリンク先の差異を前提とせず、自身の配置位置から相対解決する

## Out of Scope

- モジュール分割の具体的な単位・境界（どの関数をどのモジュールに置くか）の確定（`design.md` / Architect の領分）
- 動的 source の実装方式（source ループの具体コード、`BASH_SOURCE` 解決の実装詳細）
- 既存テストが対象関数を解決するための具体的な実装手段（本体に関数を残すか / テスト側の抽出元を変えるか / 共通ローダを介すか等の選択）。本要件は「既存テストが移動後も全て成功する」ことを観測可能な AC として求めるに留める
- 機能挙動そのものの変更・新機能追加・バグ修正（本 Issue は純粋なリファクタリングであり振る舞いを変えない）
- GitHub Actions 経路（`.github/workflows/issue-to-pr.yml`）のモジュール化（本 Issue はローカル watcher スクリプトの分割が対象）
- `repo-template/` 配下テンプレートの分割（本 Issue は `local-watcher/bin/issue-watcher.sh` が対象）
- ファイル分割によるパフォーマンス最適化目標（起動時間短縮等）の数値設定

## Open Questions

なし
