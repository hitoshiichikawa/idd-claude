# 要件定義 (requirements.md) - feat-watcher-issue-watcher-sh-modularization

本ドキュメントは、巨大化したローカル Issue 監視スクリプト `issue-watcher.sh` を機能ごとにモジュール分割し、保守性と AI による自律開発効率を向上させるための要件を定義します。

---

## 1. インストーラーによるモジュール配置の拡張

### 1.1 `modules` サブディレクトリの配置
The Installer shall `local-watcher/bin/modules/` 配下の全モジュールスクリプトを、ユーザーのホームディレクトリ配下の実行可能パスにある `modules/` サブディレクトリ（`$HOME/bin/modules/`）に再帰的かつ冪等にコピーする。

### 1.2 コピー動作の Dry-run / Force 整合
When `--dry-run` or `--force` options are passed to the Installer, the Installer shall 既存のファイル配置ルールと完全に同じ判定基準を用いて、モジュールファイルに対しても Dry-run（擬似実行）または Force（強制上書き・退避）の処理を適用する。

---

## 2. エントリポイントにおけるモジュールの動的インポート

### 2.1 モジュール動的インポートの実施
When the Watcher starts, the Watcher shall 自身のカレント配置ディレクトリに対する相対パス（`./modules/`）から、必要な機能モジュールを自動的に `source` 命令で読み込む。

### 2.2 必須モジュール欠落時の安全終了
If any required module script is missing or unreadable at startup, the Watcher shall 標準エラー出力にエラーメッセージを出力し、非ゼロの終了コード（exit code 1）で即座に安全終了する。

---

## 3. 後方互換性の維持

### 3.1 起動コマンド・環境変数の互換性維持
The Watcher shall 既存の `cron` 設定や `launchd` plist に登録された起動コマンド（`$HOME/bin/issue-watcher.sh`）および引数・環境変数の仕様を変更せず、本機能導入前と完全に等価な振る舞いを維持する。

### 3.2 設定パラメータの一元管理
The Watcher Entrypoint shall すべての設定パラメータ（環境変数デフォルト値、モデル ID、ポーリング上限等）の初期化および引数解析をエントリポイント側で一元的に行い、各モジュールに引き継ぐ。

---

## 4. 既存テストの通過と信頼性担保

### 4.1 テストコードの正常通過
The Testing Suite shall モジュール分割されたスクリプト構成においても、既存のユニットテスト・統合テスト（`tests/` および `local-watcher/test/` 配下）を一切変更せずに、すべてクリーンに通過する。

---

## 5. 静的解析警告の排除

### 5.1 Shellcheck 警告ゼロの達成
The Watcher Entrypoint and Modules shall `shellcheck` による静的解析において、警告（Warning）およびエラー（Error）がゼロであることを保証する。
*(注: `source` 先で宣言された変数の未定義警告等については、適正な `shellcheck` ディレクティブを用いて抑制・対処する)*

---

## 6. 確認事項

- 特になし
