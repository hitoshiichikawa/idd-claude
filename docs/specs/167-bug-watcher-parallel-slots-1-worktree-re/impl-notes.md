# 実装ノート (#167)

## 概要

`local-watcher/bin/issue-watcher.sh` の `_worktree_reset()`（per-slot worktree を
`origin/$BASE_BRANCH` の最新へ強制リセットする関数）から、ステップ 1 の per-slot
`git -C "$wt" fetch origin --prune` を削除した（人間が確定した方針 (a)）。

origin 参照の最新化は、親プロセスがサイクル冒頭（`issue-watcher.sh:527` の
`cd "$REPO_DIR"; git fetch origin --prune`）で 1 回だけ実行済みであり、複数 slot worktree は
同一 `$REPO_DIR` の `.git` オブジェクト DB / refs を共有してその `origin/$BASE_BRANCH` 参照を
読むため、per-slot fetch なしでも reset 起点を確保できる。これにより `PARALLEL_SLOTS>1` で
複数 slot がほぼ同時に fetch して発生していた ref ロック（`refs/remotes/origin/<branch>.lock`
/ `packed-refs.lock`）の取得競争が解消され、競合に負けた側の fetch 非 0 終了起因の偽陽性
`claude-failed` が起きなくなる。

## 変更内容（行レベル）

対象: `local-watcher/bin/issue-watcher.sh` の `_worktree_reset()`（変更前 10114-10132 行目）

- **削除**: ステップ 1 の `if ! git -C "$wt" fetch origin --prune >/dev/null 2>&1; then return 1; fi`
  と直前のコメント `# 1. 最新の origin を取得`
- **追加**: per-slot fetch を削除した理由・並行 ref ロック競合回避の意図・親プロセス
  サイクル冒頭 fetch（527 行目）への依拠・ref stale 許容を説明する `NOTE (Issue #167)`
  コメントブロック
- **温存**: `if [ ! -d "$wt" ]; then return 1; fi` ガード、`git reset --hard origin/$BASE_BRANCH`
  とその失敗時 `return 1`、`git clean -fdx` とその失敗時 `return 1`、末尾 `return 0`
- 残った reset / clean ステップのコメント番号を 1./2. に振り直し（挙動変更なし）

`_worktree_reset` 以外の `git fetch` 呼び出し（527 / 1546 / 2072 / 3492 / 4779 行目等）には
一切触れていない（Out of Scope 準拠）。

## 検証結果

| 検証 | 実施 | 結果 |
|---|---|---|
| `bash -n local-watcher/bin/issue-watcher.sh`（構文） | 実施 | OK（`BASH_N_OK`） |
| `shellcheck local-watcher/bin/issue-watcher.sh` | 実施 | 新規警告なし。コード別件数は変更前後で完全一致（SC2012 x1, SC2317 x40）。いずれも本変更領域(10106-10140行)外の既存 info 警告 |
| CLAUDE.md 記載 dry run（`REPO=owner/test REPO_DIR=...`） | 試行（部分） | 完了せず。詳細は下記 |
| `_worktree_reset` ロジック単体検証（実 git worktree） | 実施 | 全 4 ケース期待通り（下記） |

### dry run について

CLAUDE.md 記載の `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を
使い捨て git repo で試行したが、サイクル冒頭の親プロセス側 `git fetch origin --prune`
（527 行目）が origin remote 未設定により `fatal: 'origin' does not appear to be a git
repository` で exit 128 となり、`処理対象の Issue なし` 到達前に終了した。これは origin remote
と `gh` 認証を伴う実 remote が必要なためで、本変更箇所（10114 行目以降の `_worktree_reset`）
には到達しない早期 exit であり、本修正とは無関係。完全な dry run は実 remote + `gh` 認証
環境（E2E）でのみ可能。

### `_worktree_reset` ロジック単体検証

bare repo を疑似 origin とし、`$REPO_DIR` 相当の clone から detached worktree を作って
fetch 削除後のロジックを検証（実 `git` を使用）:

- CASE1 正常系: dirty/untracked/ignored を作成 → `rc=0`、reset 後 `status --porcelain` 空、
  HEAD = `origin/main` 一致（Req 2.1 / 2.2 / 3.1）
- CASE2 worktree パス不在: `rc=1`（Req 3.2 の「worktree パス不在」）
- CASE3 reset 失敗（非 git ディレクトリ）: `rc=1`（Req 3.2 の「reset 失敗」）
- CASE4 親プロセス fetch のみで最新化: origin に新コミット push → 親相当 fetch のみ実行
  （slot 側 fetch なし）→ `rc=0`、HEAD = 新 `origin/main` 一致。per-slot fetch なしでも
  reset 起点が確保できることを実証（Req 2.3 / NFR 1.1 / 方針 (a) の妥当性）

## 受入基準と検証の対応

| AC | 担保 |
|---|---|
| 1.1 / 1.2 / 1.3（ref ロック競合起因の偽陽性失敗を発生させない） | per-slot `git fetch` 削除により、複数 slot 同時実行時の ref ロック取得競争自体が `_worktree_reset` から消える（コード差分で担保）。並列同時実行の競合発生は実環境 E2E でのみ最終確認可能 |
| 2.1（HEAD を origin/$BASE_BRANCH 最新へ強制一致） | CASE1 / CASE4（HEAD 一致確認） |
| 2.2（tracked/untracked/ignored を消去し clean 化） | CASE1（`status --porcelain` 空確認。`reset --hard` + `clean -fdx` 温存） |
| 2.3（親 fetch 完了下で共有 origin 参照を起点に reset） | CASE4（slot fetch なし・親 fetch のみで最新 origin/main へ reset 成功） |
| 3.1（成功時 exit 0） | CASE1 / CASE4（rc=0） |
| 3.2（パス不在・reset 失敗・clean 失敗で exit 1） | CASE2（パス不在）/ CASE3（reset 失敗）。clean 失敗時 return 1 はコード温存（人工再現は困難なため未実行ケース） |
| 3.3（PARALLEL_SLOTS 未設定/1 で導入前と同一結果） | reset/clean ステップを完全温存。直列時は元々競合が起きず、削除した fetch 分の最新化は親 527 行目で代替（CASE4 で代替の妥当性を実証） |
| NFR 1.1（ref stale 許容） | 削除方針自体が ref stale を許容（NOTE コメントに明記）。clean 起点確保を成功扱い |
| NFR 2.1（exit code 意味不変） | CASE1-4 で 0/1 契約維持を確認 |
| NFR 2.2（リセット後 worktree 状態不変） | CASE1（clean + HEAD 一致）で導入前と同一状態を確認 |

## 後方互換性の確認

- **exit code 契約**: 0=成功 / 1=失敗 を維持。`[ ! -d "$wt" ]` ガード、reset 失敗 return 1、
  clean 失敗 return 1、末尾 return 0 すべて温存（CASE1-4 で確認）
- **直列挙動（PARALLEL_SLOTS=1 / 未設定）**: reset/clean ロジックは無変更。直列では元々
  ref ロック競合は起きず、削除した fetch による最新化は親プロセスのサイクル冒頭 fetch
  （527 行目）で代替される。CASE4 で代替の妥当性を実証
- **他 fetch 箇所**: 親 527 行目を含む `_worktree_reset` 外の `git fetch` は未変更
- **既存 env var / ラベル / cron 登録文字列 / ログ出力**: 影響なし

## Feature Flag Protocol

CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out として解釈。通常フロー
（単一実装パス）で実装。flag 分岐は導入していない。

## 確認事項

- なし（修正方針は Issue コメントで人間が「方針 (a)」を確定済み。requirements.md の
  Open Questions も「なし」）。

STATUS: complete
