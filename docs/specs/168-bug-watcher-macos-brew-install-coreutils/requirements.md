# Requirements Document

## Introduction

macOS には GNU coreutils の `timeout` が標準搭載されておらず、`brew install coreutils` で導入しても
通常 `gtimeout` という名前でインストールされる。一方 `issue-watcher.sh` の前提ツールチェックは
`timeout` を必須コマンドとしてハードコードしているため、`gtimeout` が利用可能な macOS 環境でも
watcher が「`timeout` が見つかりません」で起動できない。本要件は、`timeout` 不在かつ `gtimeout`
利用可能な環境で `gtimeout` を透過的に `timeout` として使えるようにし、いずれも無い場合は明示的に
エラー終了させ、Linux など `timeout` が存在する既存環境では挙動を一切変えないことを定義する。

## Requirements

### Requirement 1: gtimeout 透過フォールバック

**Objective:** As a macOS で watcher を運用する運用者, I want `brew install coreutils` で導入した `gtimeout` を `timeout` として透過的に使えること, so that 追加のシンボリックリンク作成や PATH 調整なしに watcher を起動できる

#### Acceptance Criteria

1. While `timeout` コマンドが PATH 上に存在せず `gtimeout` コマンドが PATH 上に存在する状態のとき, the watcher shall 以降のスクリプト内で `timeout` という呼び出しが `gtimeout` の実行に解決されるよう設定する
2. When 前提ツールチェックが実行されたとき and `timeout` が不在で `gtimeout` が利用可能なとき, the watcher shall `timeout` 必須チェックを通過させ起動を継続する
3. The watcher shall フォールバック設定を前提ツールチェックの実行より前に確立する

### Requirement 2: 全 timeout 呼び出しパスでのフォールバック有効性

**Objective:** As a watcher の保守者, I want すべての `timeout` 呼び出し箇所でフォールバックが一貫して効くこと, so that サブシェルやバックグラウンド実行を含むどの実行経路でも macOS 環境で同一に動作する

#### Acceptance Criteria

1. While gtimeout フォールバックが有効な状態のとき, the watcher shall コマンド置換（`$( timeout ... )`）内の `timeout` 呼び出しを `gtimeout` に解決する
2. While gtimeout フォールバックが有効な状態のとき, the watcher shall サブシェル（`( ... )`）およびバックグラウンド fork（`( ... ) &`）内の `timeout` 呼び出しを `gtimeout` に解決する
3. While gtimeout フォールバックが有効な状態のとき, the watcher shall `bash -c` 経由で起動される検証コマンド内の `timeout` 呼び出しを `gtimeout` に解決する
4. While gtimeout フォールバックが有効な状態のとき, the watcher shall `--kill-after` 等のオプション付き `timeout` 呼び出しでもオプションを `gtimeout` にそのまま引き渡す

### Requirement 3: timeout/gtimeout いずれも不在時の明示エラー停止

**Objective:** As a watcher を初回セットアップする運用者, I want `timeout` も `gtimeout` も無い環境では曖昧に進行せず明示的に停止すること, so that 設定不備を silent fail させず原因を即座に把握できる

#### Acceptance Criteria

1. If `timeout` コマンドと `gtimeout` コマンドのいずれも PATH 上に存在しないとき, the watcher shall 前提ツールチェック段階で不在を理由とするエラーメッセージを標準エラー出力に出す
2. If `timeout` コマンドと `gtimeout` コマンドのいずれも存在せず watcher が起動できないとき, the watcher shall 非ゼロの exit code で終了する
3. If `timeout` 系コマンドの不在でエラー終了するとき, the watcher shall エラーメッセージに macOS では `brew install coreutils` で導入する旨の解決手順を含める

### Requirement 4: README への自動検出の明文化

**Objective:** As a 初めて macOS で watcher を導入する運用者, I want gtimeout が自動検出される旨がドキュメントに記載されていること, so that 手動シンボリックリンク作成が不要であることを事前に理解できる

#### Acceptance Criteria

1. Where README の macOS 依存に関する記述が存在するとき, the README shall `timeout` 不在時に `gtimeout` を自動検出してフォールバックする旨を記載する
2. The README shall macOS で `timeout` 系を導入する手段として `brew install coreutils` を案内する記述を含める

## Non-Functional Requirements

### NFR 1: Linux など既存環境での後方互換性

1. While `timeout` コマンドが PATH 上に存在する状態のとき, the watcher shall gtimeout フォールバックを設定せず `timeout` をそのまま呼び出す
2. The watcher shall 既存環境（`timeout` が存在する環境）での起動可否・exit code・ログ出力・ラベル遷移契約を本変更導入前と同一に保つ
3. The watcher shall 既存の env var 名（`MERGE_QUEUE_GIT_TIMEOUT` / `STAGE_A_VERIFY_TIMEOUT` 等の timeout 関連変数を含む）を変更せず後方互換を維持する

### NFR 2: 依存コマンドの非追加

1. The watcher shall 本変更により新規の外部依存コマンドを必須化しない（macOS 任意導入の `gtimeout` 利用は coreutils 既導入時のみ）

## Out of Scope

- `timeout` / `gtimeout` 以外の GNU coreutils 系コマンド（`gtimeout` 以外への `g` プレフィックス汎用フォールバック）への対応
- macOS の `flock`（`brew install util-linux`）や bash 4.3+ 導入手順の変更（本 Issue の対象外、既存記述を維持）
- `gtimeout` を自動インストールする処理の追加（`install.sh` / `setup.sh` での coreutils 自動導入は行わない）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）側の timeout 取り扱い変更
- 既に `timeout` が存在する環境におけるタイムアウト秒数・リトライ挙動のチューニング

## Open Questions

- なし（Issue 本文の「確認事項」4 点はすべて要件化済み。export -f の要否など実装手段の選択は design.md / Developer の領分とし、本要件では「全 timeout 呼び出しパスでフォールバックが有効であること」を Requirement 2 として観測可能な形で規定した）
