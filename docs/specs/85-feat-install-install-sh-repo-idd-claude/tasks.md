# Tasks

> Developer self-managed work plan for Issue #85.
> Architect was not invoked for this Issue, so this tasks.md is a lightweight working plan.

## 設計判断（Open Questions への暫定回答）

- **対象 repo `owner/repo` の特定**: 第 1 候補 = `gh repo view --json nameWithOwner -q .nameWithOwner` を REPO_PATH の中で実行（fail-soft）。第 2 候補 = `git -C "$REPO_PATH" remote get-url origin` から正規表現で `owner/repo` を抽出。env var `REPO` は将来導入余地として残し、本 Issue では使用しない（install.sh 既存の `--repo` 引数とは別軸の env var を増やすと混乱するため）
- **`IDD_CLAUDE_SKIP_LABELS` env**: 採用する。`--no-labels` と同様 opt-out として扱う（NFR 1.1 の cron-safe 性に有用）
- **既存「手動でラベル一括作成」README 節**: 残す + 自動実行が走る旨と fallback 関係を明示（Req 7.4）

## タスク

- [ ] 1. `install.sh` に `--no-labels` 引数パースを追加
  - 引数パース部に `--no-labels` を追加し、bool flag `SKIP_LABELS` を導入
  - `IDD_CLAUDE_SKIP_LABELS=true` env でも opt-out 可能にする
  - ヘルプ文（先頭コメント）を更新
  - _Requirements: 4.1, 4.2, 4.3, 4.4_

- [ ] 2. ラベルセットアップ実行ヘルパー関数 `run_label_setup_for_repo` を実装
  - 対象 repo を `gh repo view` → `git remote` 順で解決（fail-soft）
  - `gh` 不在 / 未認証 / 権限不足 / API 失敗 → skip + 手動コマンド案内（Req 3.1〜3.6）
  - `--dry-run` 時は LABELS_DRY_RUN_PLAN を表示し API 呼び出ししない
  - 既存 `idd-claude-labels.sh` を `--repo owner/name` で呼び出す（既存 interface 不変）
  - skip 理由はカテゴリを区別したログ書式で stdout に出力（grep 可能）
  - _Requirements: 1.1, 1.5, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 5.1, 5.2, 5.3, 5.4, 6.3, NFR 2.3, NFR 3.1_

- [ ] 3. 配置完了直後にラベルセットアップを呼び出す
  - `INSTALL_REPO=true` のとき、配置完了後・`REPO_HINT` 出力後に run_label_setup_for_repo
  - `INSTALL_LOCAL=true` のみのときは呼ばない（Req 1.3, 1.5）
  - `SKIP_LABELS=true` のときは opt-out 旨の skip ログのみ出力（Req 4.2）
  - 対話モードで対象リポジトリを選んだ場合も自動的に走る（Req 1.4）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 4.2, 4.3, 5.1, 5.3, 6.1, 6.2_

- [ ] 4. README.md にラベル自動セットアップの記載を追加
  - install.sh 経由のセットアップ手順節に自動実行の旨を追記（Req 7.1）
  - `--no-labels` の opt-out 説明と推奨ユースケース（Req 7.2）
  - skip 時の手動 fallback 案内（Req 7.3）
  - 既存「ラベル一括作成（推奨）」節は残し、自動と手動の関係を注記（Req 7.4）
  - _Requirements: 7.1, 7.2, 7.3, 7.4_

- [ ] 5. 手動スモークテストと impl-notes.md 記録
  - shellcheck install.sh / idd-claude-labels.sh
  - `/tmp/idd85-test` で配置 + ラベル成功・skip・冪等再実行
  - `--local` でラベル処理が走らないこと
  - `--no-labels` で opt-out 経路
  - `--dry-run` で API 呼び出しなしの plan 表示
  - 結果を impl-notes.md に記録
  - _Requirements: 全要件のテスト確認_
