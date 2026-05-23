# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` には、非同期プロセス置換 `tee` と Dispatcher のシグナル trap 欠如に起因する 3 件のシェル堅牢化課題がある。第一に、SLOT_INIT_HOOK の stderr 捕捉が `2> >(tee -a "$stderr_tmp" >&2)` という非同期プロセス置換で行われており、フック終了直後の `tail -c 2000` 読み出しと flush の間にレースが生じ、失敗時のログ末尾が欠落しうる。第二に、slot ログの `exec > >(tee -a "$SLOT_LOG") 2>&1` も同じ非同期性を持ち、表示順序が乱れうる（機能影響はない）。第三に、Dispatcher 本体に SIGINT/SIGTERM の trap が無く、cron/launchd からの中断や手動 Ctrl-C 時に fork 済み slot worker が孤立し、`.broken-*` worktree の蓄積要因になる。idd-claude は self-hosting（dogfooding）で稼働し、このスクリプト自身が次回 cron で自分を動かすため、後方互換性（exit code・ログ出力先・既存 env var 名）と冪等性を最優先に、優先度を明確に切り分けて改善する。

## Requirements

### Requirement 1: SLOT_INIT_HOOK stderr 捕捉の同期化（最優先）

**Objective:** As a 運用者, I want SLOT_INIT_HOOK 失敗時の stderr 末尾が確実にログへ転記されること, so that フック失敗の原因をログだけで追える

#### Acceptance Criteria

1. If SLOT_INIT_HOOK が非ゼロ exit code で終了したとき, the Hook Invoker shall フック実行中に発生した stderr の末尾 2000 バイトを slot ログへ転記する
2. While SLOT_INIT_HOOK の stderr を一時ファイルへ捕捉する間, the Hook Invoker shall フック終了を待ってから一時ファイルを読み出す（非同期プロセス置換による flush レースを生じさせない）
3. When SLOT_INIT_HOOK が正常終了したとき, the Hook Invoker shall 一時ファイルを削除し、追加のエラー出力を行わない
4. The Hook Invoker shall SLOT_INIT_HOOK の stderr を従来どおり運用者から観測可能な形で保持する（捕捉化により stderr を握り潰さない）
5. The Hook Invoker shall SLOT_INIT_HOOK の exit code を従来と同一の意味（0=成功 / 非ゼロ=失敗）で呼び出し元へ返す

### Requirement 2: slot ログ出力の堅牢化（低優先・表示品質）

**Objective:** As a 運用者, I want slot ログの行が cron mailer 出力とログファイルの双方に欠落なく現れること, so that 並行 slot 実行時もログの可読性が保たれる

#### Acceptance Criteria

1. The Slot Runner shall slot 運用ログを標準出力（cron mailer 経路）と slot ログファイルの両方へ書き出す
2. When slot worker が処理を完了したとき, the Slot Runner shall その時点までに書き出した slot ログ行をログファイルへ欠落なく確定させる
3. The Slot Runner shall slot ログファイルの出力先パス命名規約（`slot-<slot番号>-<Issue番号>-<タイムスタンプ>.log`）を従来と同一に保つ

### Requirement 3: Dispatcher のシグナル捕捉（低優先・最小実装）

**Objective:** As a 運用者, I want Dispatcher が中断シグナルを受けたとき fork 済み slot worker を孤立させずに終了すること, so that 中断のたびに `.broken-*` worktree が蓄積しない

#### Acceptance Criteria

1. When Dispatcher が SIGINT または SIGTERM を受信したとき, the Dispatcher shall fork 済みの slot worker 子プロセスへ終了シグナルを送る
2. When Dispatcher が中断シグナルにより終了処理を行うとき, the Dispatcher shall worktree の prune（孤立 worktree の整理）を 1 回実行する
3. While Dispatcher が中断シグナルを処理する間, the Dispatcher shall 多重起動防止ロック（fd 200 の flock）の解放契約を従来どおり維持する
4. While Dispatcher が中断シグナルを処理する間, the Dispatcher shall 既存のサブシェル内ローカル trap（rebase/revert/checkout の base branch 復帰）の挙動を変更しない
5. The Dispatcher shall 中断シグナルを受けない通常完了時の挙動・exit code を本変更導入前と同一に保つ

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher script shall 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `SLOT_INIT_HOOK` / `PARALLEL_SLOTS` 等）の名前と意味を変更しない
2. The watcher script shall 正常完了 exit 0 / 致命的失敗 exit 1 / 他インスタンス実行中スキップ exit 0 という既存 exit code の意味を変更しない
3. The watcher script shall ログ出力先（`LOG_DIR` 配下の Issue ログおよび slot ログのパス命名規約）を変更しない

### NFR 2: 冪等性と self-hosting 安全性

1. The watcher script shall 本変更後も再 cron 実行で破壊的副作用を生じさせない（複数回連続実行で状態が悪化しない）
2. Where Dispatcher のシグナル捕捉が追加される場合, the Dispatcher shall 同一シグナルが処理中に再送されても worktree prune を二重実行して状態を破壊しない

### NFR 3: 静的解析

1. The watcher script shall 変更箇所が `shellcheck local-watcher/bin/issue-watcher.sh` で新規警告を発生させない

## Out of Scope

- `_hook_invoke` の stderr 一時ファイルリーク（補足報告書 1.3）は既に対処済みのため本 Issue の対象外とする
- Requirement 3 のシグナル捕捉は最小実装（子プロセス kill + worktree prune）に限定し、graceful shutdown の段階的待機・タイムアウト・進行中 Issue のラベル巻き戻し等の高度な終了処理は扱わない（スコープが膨らむ場合は別 Issue へ分割する）
- 並列 slot 数の上限変更・slot ロック方式（fd 210+N）の見直しは扱わない
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）の同等修正は扱わない
- README / CLAUDE.md の挙動説明更新は、本変更で運用者可視の挙動が変わる範囲に限って行い、ドキュメント全面改訂は扱わない

## Open Questions

- なし（Issue 本文・コメントは watcher の自動開始メッセージのみで、人間による追加決定事項は確認されなかった。Requirement 3 のスコープ膨張時に別 Issue 分割を提案する判断は、Architect / 人間レビューに委ねる）
