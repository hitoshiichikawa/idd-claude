# タスクリスト (tasks.md) - feat-watcher-issue-watcher-sh-modularization

本タスクリストは、`issue-watcher.sh` のモジュール化リファクタリングを段階的に実施するための実装手順を定義します。

---

- [ ] 1. インストーラー (install.sh) のモジュール配置拡張
- [ ] 1.1 install.sh のモジュール再帰コピーの実装
  * `install.sh` の `setup_local_watcher` ブロックに、`local-watcher/bin/modules/` 配下の全 `.sh` ファイルを `$HOME/bin/modules/` に再帰的・冪等にコピーするロジックを追加する。
  * _Requirements: 1.1, 1.2_

- [ ] 2. 共通ユーティリティと動的インポート基礎の構築
- [ ] 2.1 core_utils.sh の作成
  * `issue-watcher.sh` 内の共通ロガー関数（`qa_log`, `mq_log`, `ar_log`, `pi_log` 等の低レベル出力）および Git Worktree 操作関連のインフラ関数（`_worktree_ensure`, `_worktree_reset`, `_slot_acquire`, `_slot_release` 等）を `local-watcher/bin/modules/core_utils.sh` に切り出す。
  * _Requirements: 2.1, 3.2_
- [ ] 2.2 動的インポート機構の組み込み
  * `issue-watcher.sh` の Config 正規化ループの直後に、`modules/*.sh` を順次読み込む動的ロード機構を追加する。
  * いずれかの必須モジュールが存在しない場合、標準エラー出力に警告し、exit code 1 で終了する安全装置を実装する。
  * _Requirements: 2.1, 2.2_

- [ ] 3. 各プロセッサーロジックのモジュールファイル化
- [ ] 3.1 modules/quota_aware.sh の切り出し
  * クォータ検知・待機制御関連の関数群（`qa_...` および `process_quota_resume`）を `local-watcher/bin/modules/quota_aware.sh` に切り出す。
  * _Requirements: 2.1_
- [ ] 3.2 modules/merge_queue.sh の切り出し
  * マージキュー制御関連の関数群（`mq_...` および `process_merge_queue_recheck`）を `local-watcher/bin/modules/merge_queue.sh` に切り出す。
  * _Requirements: 2.1_
- [ ] 3.3 modules/auto_rebase.sh の切り出し
  * 自動 Rebase 関連の関数群（`ar_...`）を `local-watcher/bin/modules/auto_rebase.sh` に切り出す。
  * _Requirements: 2.1_
- [ ] 3.4 modules/promote_pipeline.sh の切り出し
  * 昇格パイプライン関連の関数群（`pp_...`）を `local-watcher/bin/modules/promote_pipeline.sh` に切り出す。
  * _Requirements: 2.1_
- [ ] 3.5 modules/pr_iteration.sh の切り出し
  * PR Iteration 制御関連の関数群（`pi_...`）を `local-watcher/bin/modules/pr_iteration.sh` に切り出す。
  * _Requirements: 2.1_
- [ ] 3.6 modules/path_overlap.sh の切り出し
  * Triage 時の競合制御関数群（`po_...`）を `local-watcher/bin/modules/path_overlap.sh` に切り出す。
  * _Requirements: 2.1_
- [ ] 3.7 modules/stage_a_verify.sh の切り出し
  * 検証ゲート関数群（`sav_...`）を `local-watcher/bin/modules/stage_a_verify.sh` に切り出す。
  * _Requirements: 2.1_

- [ ] 4. テスト検証と静的解析エラーの排除
- [ ] 4.1 既存テストスイートによる動作検証
  * モジュール分割後の構成で、`local-watcher/test/` および `tests/` 配下の全テストを実行し、100% 後方互換性が保たれておりデグレが生じていないことを確認する。
  * _Requirements: 4.1_
- [ ] 4.2 Shellcheck 警告ゼロの達成
  * 分割した全スクリプトに対して `shellcheck` を実行し、警告やエラーが出ないことを確認・調整する。
  * 必要に応じて、ロード先・ロード元の関係性を示す `shellcheck` ディレクティブ（`# shellcheck source=...`）を付与する。
  * _Requirements: 5.1_
