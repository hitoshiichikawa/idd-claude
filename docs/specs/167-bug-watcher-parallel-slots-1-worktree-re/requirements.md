# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` の `_worktree_reset()` は各 slot worker が起動時に呼び出し、当該 slot worktree を `origin/$BASE_BRANCH` の最新状態へ強制リセットする。現状この関数は内部で `git fetch origin --prune` を実行するが、複数 slot worktree は同一 `$REPO_DIR` の `.git` オブジェクト DB / refs を共有するため、`PARALLEL_SLOTS>1` で複数 slot がほぼ同時に fetch すると ref ロック（`refs/remotes/origin/<branch>.lock` / `packed-refs.lock`）の取得競争が起き、競合に負けた側の fetch が非 0 終了し得る。`set -euo pipefail` 下では `_worktree_reset` が失敗扱いとなり、呼び出し元が無実の Issue に偽陽性の `claude-failed` ラベルとエラーコメントを付与する。

本要件は、人間が確定した修正方針（per-slot fetch を削除し、親プロセスがサイクル冒頭で実行する fetch に依拠する）に基づき、並列実行時の偽陽性失敗を解消しつつ、`_worktree_reset` の契約（exit code、reset 後の worktree 状態）と直列実行時の挙動を後方互換に保つことを目的とする。

## Requirements

### Requirement 1: 並列実行時の偽陽性 claude-failed の解消

**Objective:** As an idd-claude 運用者, I want PARALLEL_SLOTS>1 で複数 slot を同時実行しても ref ロック競合起因の偽陽性失敗が起きないこと, so that 無実の Issue に誤った `claude-failed` ラベルとエラーコメントが付かないようにする

#### Acceptance Criteria

1. While PARALLEL_SLOTS が 2 以上に設定されている状態で複数 slot worker が同時に worktree リセットを実行している間, the Watcher shall ref ロック競合に起因する worktree リセットの失敗を発生させない
2. If 複数 slot worker が同一サイクル内でほぼ同時に worktree リセットを実行する, the Watcher shall いずれの slot にも ref ロック競合のみを理由とした `claude-failed` ラベルを付与しない
3. If 複数 slot worker が同一サイクル内でほぼ同時に worktree リセットを実行する, the Watcher shall いずれの Issue にも ref ロック競合のみを理由とした失敗エラーコメントを投稿しない

### Requirement 2: worktree リセットによる clean 起点状態の確保

**Objective:** As an idd-claude 運用者, I want per-slot fetch 削除後も各 slot worktree が origin/$BASE_BRANCH を起点とした clean な状態でリセットされること, so that 各 slot が前回 Issue の残存変更や成果物に影響されず新規 Issue を処理できる

#### Acceptance Criteria

1. When slot worker が worktree リセットを実行する, the Watcher shall 当該 worktree の HEAD を origin/$BASE_BRANCH の最新コミットへ強制的に一致させる
2. When slot worker が worktree リセットを実行する, the Watcher shall 当該 worktree から tracked / untracked / ignored のすべての変更を消去し作業ツリーを clean な状態にする
3. While 親プロセスがサイクル冒頭で origin の fetch を完了している状態で, the Watcher shall slot worktree が共有する origin/$BASE_BRANCH 参照を起点として worktree リセットを実行する

### Requirement 3: _worktree_reset の契約維持と後方互換性

**Objective:** As an idd-claude メンテナ, I want _worktree_reset の exit code 契約と直列実行時の挙動が本修正導入前と同一であること, so that 既稼働の cron / launchd 運用と直列ユーザーが影響を受けない

#### Acceptance Criteria

1. When worktree リセットが HEAD 一致と作業ツリー clean 化に成功する, the Watcher shall 成功を示す exit code 0 を返す
2. If worktree リセットの過程で worktree パス不在・reset 失敗・clean 失敗のいずれかが発生する, the Watcher shall 失敗を示す exit code 1 を返す
3. While PARALLEL_SLOTS が未設定または 1 に設定されている状態で, the Watcher shall 本修正導入前と同一の worktree リセット結果（origin/$BASE_BRANCH 最新かつ clean）を確保する

## Non-Functional Requirements

### NFR 1: ref stale の許容範囲

1. Where 親プロセスのサイクル冒頭 fetch 完了後に slot worker の起動が遅延した状況において, the Watcher shall slot worktree の origin 参照がやや古い状態であっても worktree リセットを clean 起点確保の目的において成功として扱う

### NFR 2: 後方互換性

1. The Watcher shall `_worktree_reset` の戻り値の意味（0=成功 / 1=失敗）を本修正導入前後で変更しない
2. The Watcher shall リセット完了後の worktree 状態（origin/$BASE_BRANCH 最新コミット + clean）を本修正導入前後で変更しない

## Out of Scope

- 方針 (b) retry-with-backoff（fetch リトライ）による解決
- 方針 (c) flock による per-slot fetch の直列化による解決
- 親プロセスがサイクル冒頭（issue-watcher.sh:527）で実行する `git fetch origin --prune` のロジック変更
- `_worktree_reset` 以外の `git fetch` 呼び出し箇所の変更
- ref stale を解消するための slot 起動時 fetch の再導入・stale 検出機構の追加
- worktree 作成（`git worktree add`）ロジックの変更

## Open Questions

- なし（修正方針は Issue コメントで人間が「方針 (a) を採用」と確定済み。per-slot fetch 削除後の origin 参照は親プロセスのサイクル冒頭 fetch に依拠し、ref stale は許容範囲とする方針も合意済み）
