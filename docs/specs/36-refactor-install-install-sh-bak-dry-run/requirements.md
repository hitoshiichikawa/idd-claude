# Requirements: install.sh 冪等性バグ修正と配置漏れ予防 (#36)

## Introduction

idd-claude のインストーラ（`install.sh`）は、`local-watcher/` 以下のスクリプトと
`repo-template/` 以下のテンプレートを利用者の `$HOME/bin/` および対象リポジトリへ配置する
ユーザースコープのツールである。現状の実装は (1) 個別 `cp` の列挙によって新規ファイル追加時に
配置漏れが起きやすい、(2) 再実行で `CLAUDE.md.bak` がテンプレ由来の内容で上書きされ初回バックアップが
消失する、(3) `.claude/agents/` と `.claude/rules/` のカスタム編集が無告知で上書きされる、という
3 つの構造的リスクを抱えている。

本要件定義は、これらのリスクをユーザー観測可能な挙動レベルで除去し、再実行と将来の機能追加に
対する堅牢性を高めることを目的とする。スコープは `install.sh` のインストールフロー（対象リポジトリ
配置・ローカル watcher 配置）、関連する `setup.sh` 連携、および README の冪等性ポリシー記述に
限定する。`repo-template/` のテンプレート構造そのものや `setup.sh` の clone 戦略は変更しない。

## Scope

### In Scope

- `install.sh` のファイル配置ロジックの宣言性（新規ファイル追加に伴う `install.sh` 修正の不要化）
- `install.sh` 再実行時の `CLAUDE.md.bak` の保護
- `.claude/agents/` および `.claude/rules/` 配下既存ファイルの上書き挙動の安全化
- 実コピーを行わずに予定操作を表示する `--dry-run` モード
- 既存 env var 名・ラベル名・cron / launchd 登録文字列・watcher の挙動の後方互換性維持
- README への冪等性ポリシー節追加（`.bak` 保護 / agents・rules 上書き / `--dry-run` の説明）

### Out of Scope

- `repo-template/` テンプレート構造そのものの変更
- `setup.sh` の clone 戦略変更（`$HOME/.idd-claude` への shallow clone は維持）
- カスタム編集と template の自動 3-way merge（`git merge-file` 等の高度な統合）
- `.claude/agents/` / `.claude/rules/` のスキーマバージョニング（template 進化への自動追従機構）
- `local-watcher/bin/` 配下に格納されるべきファイル種別の追加・削除（本要件は宣言的配置のみ扱う）

## Requirements

### Requirement 1: ワイルドカード配置による配置漏れ予防

**Objective:** As an idd-claude メンテナ, I want `install.sh` のファイル配置を宣言的（パターン指定）にしたい, so that 新規 `*.tmpl` / `*.sh` を `local-watcher/bin/` に追加しただけで `install.sh` を修正することなく利用者環境へ配置される

#### Acceptance Criteria

1. When 利用者が `install.sh --local` を実行したとき, the install script shall `local-watcher/bin/` 配下の全 `*.sh` ファイルを `$HOME/bin/` に配置する
2. When 利用者が `install.sh --local` を実行したとき, the install script shall `local-watcher/bin/` 配下の全 `*.tmpl` ファイルを `$HOME/bin/` に配置する
3. When `local-watcher/bin/` に新規 `*.sh` または `*.tmpl` ファイルが追加された状態で `install.sh --local` を実行したとき, the install script shall 当該新規ファイルを `install.sh` 自体への変更なしで `$HOME/bin/` に配置する
4. When `install.sh --local` が `*.sh` ファイルを `$HOME/bin/` に配置したとき, the install script shall 配置した全 `*.sh` に実行権限を付与する
5. When `install.sh --local` を実行した結果として配置されるファイル集合は, the install script shall 本要件導入前のリリースで配置されていたファイル集合と等価である（既存ファイルが欠落しない）
6. If `local-watcher/bin/` 配下に対応するパターンのファイルが 1 つも存在しないとき, the install script shall エラー終了せず、配置 0 件である旨を標準出力に記録して継続する

### Requirement 2: CLAUDE.md.bak の冪等性保護

**Objective:** As an idd-claude 利用者, I want `install.sh --repo` を何度再実行しても初回 install 時の自分のオリジナル `CLAUDE.md` が `.bak` として保持されたままであってほしい, so that カスタマイズ前の状態を後から参照・復元できる

#### Acceptance Criteria

1. When 利用者が `install.sh --repo <path>` を実行し、対象リポジトリに `CLAUDE.md` が存在し、かつ `CLAUDE.md.bak` がまだ存在しないとき, the install script shall 既存の `CLAUDE.md` を `CLAUDE.md.bak` としてバックアップする
2. If 対象リポジトリに既に `CLAUDE.md.bak` が存在するとき, the install script shall 既存の `CLAUDE.md.bak` を上書きせずそのまま保持する
3. When 既存の `CLAUDE.md.bak` を保持したとき, the install script shall 保持した旨（再実行を検知してバックアップを温存したこと）を標準出力に記録する
4. When `install.sh --repo <path>` を 2 回以上連続で実行したとき, the install script shall 初回実行時に保存された `CLAUDE.md.bak` の内容を変更しない
5. If 対象リポジトリに `CLAUDE.md` が存在しないとき, the install script shall バックアップを作成せず、テンプレート由来の `CLAUDE.md` を新規配置する

### Requirement 3: agents / rules カスタム編集の安全弁

**Objective:** As an idd-claude 利用者, I want `.claude/agents/` および `.claude/rules/` に施したプロジェクト固有のカスタム編集が、`install.sh` 再実行で予告なく失われないようにしてほしい, so that template 追従と自分のカスタマイズを両立できる

#### Acceptance Criteria

1. When `install.sh --repo <path>` を実行し、対象リポジトリの `.claude/agents/` または `.claude/rules/` 配下に対応するファイルが既に存在するとき, the install script shall 既存ファイル内容が予告なく失われる結果（無条件・無告知の上書き）を生じさせない
2. When `install.sh --repo <path>` を実行し、対象リポジトリの `.claude/agents/` または `.claude/rules/` 配下に対応するファイルが存在しないとき, the install script shall 当該テンプレートファイルを新規配置する
3. When `install.sh --repo <path>` の実行結果として既存ファイルの取り扱いを判断したとき, the install script shall 「新規配置」「上書き」「スキップ」のいずれの分類で処理したかをファイルごとに標準出力に記録する
4. Where 利用者が明示的な opt-in フラグを付与したとき, the install script shall 既存ファイルに対しても上書きを許可する挙動を提供する
5. If 既存ファイルを上書きする処理を行うとき, the install script shall 利用者がその事実を事後に確認・復元できる手段（バックアップ、または明示的な事前ログ）を提供する
6. The install script shall `.claude/agents/` および `.claude/rules/` の上書きポリシーを `install.sh --help` または同等のヘルプ出力から把握可能な形で文書化する

> 注: (a) 警告強化のみ / (b) `--force` opt-in / (c) 差分比較 + `.bak` 退避 のいずれの実装策を採るかは Architect が `design.md` で決定する。本要件は「カスタム編集が予告なく消えない」「新規ファイルは漏れなく配置される」というユーザー観測可能な性質のみを規定する。

### Requirement 4: --dry-run モード

**Objective:** As an idd-claude 利用者, I want `install.sh` が実際にファイルをコピーする前に「何が起きるか」を確認したい, so that 既存環境への影響を事前に把握してから実行可否を判断できる

#### Acceptance Criteria

1. When 利用者が `install.sh --dry-run` を `--repo` または `--local` または `--all` のいずれかと組み合わせて実行したとき, the install script shall ファイルシステムを変更しない（新規作成・上書き・パーミッション変更・ディレクトリ作成のいずれも行わない）
2. When `install.sh --dry-run` を実行したとき, the install script shall 通常実行時に配置・バックアップ・スキップ対象となる各ファイルパスを標準出力に列挙する
3. When `install.sh --dry-run` が各対象ファイルを列挙するとき, the install script shall 各ファイルが「新規配置」「上書き」「スキップ」のいずれに分類されるかを判別可能な形式で出力する
4. When `install.sh --dry-run` を実行したとき, the install script shall 終了コード 0 で正常終了する（前提ツール不足など別系統のエラーがない限り）
5. When `install.sh --dry-run` の出力を取得した直後に同じ引数で `--dry-run` を外して実行したとき, the install script shall dry-run 出力で「新規配置」「上書き」と分類されたファイルを実際に配置する
6. The install script shall `--dry-run` フラグの挙動を `install.sh --help` または同等のヘルプ出力に記載する

> 注: dry-run の出力フォーマット（プレーンテキスト / JSON / 両対応）と、`setup.sh` 経由（`curl | bash`）で `--dry-run` を渡せる設計とするかは Architect が `design.md` で決定する。本要件は「`install.sh` 単体実行時に副作用なしで予定操作が確認できる」ことのみを必須とする。

### Requirement 5: 後方互換性

**Objective:** As an idd-claude 既存利用者, I want 既存の cron / launchd 登録、環境変数、ラベル、`install.sh` の起動方法を変更せずに本改修の恩恵を受けたい, so that 再 install のみで移行が完了し、運用設定の書き換えが発生しない

#### Acceptance Criteria

1. The install script shall 既存の起動形式（`./install.sh` 対話モード、`--repo`、`--local`、`--all`、`--repo <path>`、`-h` / `--help`）を従来と同じ意味で受理する
2. The install script shall 既存の利用者向け環境変数名（`REPO`、`REPO_DIR`、`LOG_DIR`、`LOCK_FILE`、`TRIAGE_MODEL`、`DEV_MODEL` 等）の名前・意味・デフォルト値を変更しない
3. When 利用者が改修後の `install.sh --local` を実行したとき, the install script shall 既存の cron / launchd 登録文字列（`REPO=... REPO_DIR=... $HOME/bin/issue-watcher.sh ...`）の書き換えを利用者に要求しない
4. When 利用者が改修後の `install.sh --repo <path>` を実行したとき, the install script shall 対象リポジトリに従来配置されていたファイル群を引き続き配置する（配置先パス・ファイル名・実行権限の意味を変えない）
5. The install script shall 配置するラベル定義スクリプト（`.github/scripts/idd-claude-labels.sh`）が定義する既存ラベル名を変更・削除しない
6. If 利用者が sudo で `install.sh` を実行しようとしたとき, the install script shall 従来通り警告を表示し、利用者の明示的な確認なしには続行しない

### Requirement 6: ドキュメント更新

**Objective:** As an idd-claude 利用者, I want 本改修で導入される冪等性ポリシーと新フラグを README から把握したい, so that ヘルプ出力や Issue を辿らずとも、再実行の安全性と `--dry-run` の使い方を理解できる

#### Acceptance Criteria

1. When 利用者が `README.md` を参照したとき, the README shall `CLAUDE.md.bak` の冪等性保護仕様（再実行で上書きされないこと）を記載する
2. When 利用者が `README.md` を参照したとき, the README shall `.claude/agents/` および `.claude/rules/` の上書き挙動（採用ポリシーと、利用者がカスタム編集を保護する手段）を記載する
3. When 利用者が `README.md` を参照したとき, the README shall `install.sh --dry-run` の使い方と出力の読み方を記載する
4. The README shall 本改修によって既存利用者に追加で必要となる手順がない（または最小である）旨を明示する

## Non-Functional Requirements

### NFR 1: 冪等性

1. When `install.sh` を同一引数で連続して 2 回以上実行したとき, the install script shall 1 回目実行後と 2 回目以降実行後で利用者が観測可能なファイル内容（特に `CLAUDE.md.bak` および利用者がカスタム編集した `.claude/agents/` / `.claude/rules/` 配下ファイル）に差分を生じさせない
2. The install script shall 副作用のある操作（ファイル新規作成・上書き・バックアップ作成・パーミッション変更・ディレクトリ作成）の実行有無を、`--dry-run` フラグの有無のみで切り替え可能とする

### NFR 2: 観測可能性

1. When `install.sh` がファイル配置・バックアップ・スキップを行ったとき, the install script shall 各操作の対象パスと処理分類（新規配置 / 上書き / スキップ / バックアップ）を標準出力に出力する
2. If `install.sh` が前提ツール不足や引数誤りで処理を継続できないとき, the install script shall エラーメッセージを標準エラー出力に出し、非ゼロの終了コードで終了する

### NFR 3: ユーザースコープ前提

1. The install script shall ユーザースコープ（`$HOME` 配下）への配置のみで完結し、本改修によって新たに sudo を必要とする手順を導入しない

## Open Questions

なし。

> 補足: 以下の論点は要件レベルで規定せず、Architect が `design.md` で決定する事項として明示する:
> 1. `.claude/agents/` および `.claude/rules/` の上書きポリシーの具体実装 ((a) / (b) / (c) / ハイブリッド)
> 2. `repo-template/.github/scripts/`、`repo-template/.github/workflows/` 等のワイルドカード化範囲（個別 `cp` を残すべきファイルの有無）
> 3. `--dry-run` の出力フォーマット（プレーンテキスト / JSON / 両対応）
> 4. `setup.sh` 経由（`curl | bash`）で `--dry-run` を流せる設計とするか（要件としては `install.sh` 単体実行で動くことのみを必須とする）
