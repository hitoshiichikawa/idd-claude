# 実装ノート: Issue #295

## 概要

`_worktree_reset()` が root 所有 docker 生成物（`frontend/node_modules/` / `frontend/.next/` 等）を
削除できず偽陽性 `claude-failed` を引き起こす問題を、以下 3 段の改修で解決する:

1. **stderr 保全**（Req 1）: `git reset --hard` / `git clean -fdx` の stderr を `/dev/null` に
   握り潰さず SLOT_LOG に残す
2. **opt-in docker cleanup**（Req 2 / Req 3）: `WORKTREE_DOCKER_CLEANUP_ENABLED=true` 宣言時のみ、
   EACCES 検出を契機に一時 docker コンテナ（busybox）で worktree 配下の root 所有 artifact を削除
3. **worktree 再作成 fallback**（Req 4）: docker 経路が使えない／失敗したとき、
   `git worktree remove --force` + `git worktree add --detach` で worktree を作り直す

## 変更ファイル

| ファイル | 変更概要 |
|---|---|
| `local-watcher/bin/modules/core_utils.sh` | `_worktree_reset` の stderr 保全 + escalated cleanup フロー追加。`_worktree_reset_docker_cleanup` / `_worktree_reset_recreate` を新規追加 |
| `docs/specs/295-bug-watcher-worktree-reset-root-docker-c/test-fixtures/smoke-worktree-reset.sh` | 通常ケースの smoke test（既存挙動非変更を最小再現で検証） |
| `docs/specs/295-bug-watcher-worktree-reset-root-docker-c/impl-notes.md` | 本ファイル |

呼び出し元 `local-watcher/bin/issue-watcher.sh` の `_worktree_reset "$WT"` 呼び出しは **変更なし**
（Req 5.4: 関数シグネチャと戻り値セマンティクスを保持）。

## 設計上の判断

### 1. stderr 保全方法

呼び出し元サブシェル `_slot_run_issue` が `exec > >(tee -a "$SLOT_LOG") 2>&1` で stdout/stderr を
両方とも SLOT_LOG に tee している（issue-watcher.sh:7587）。したがって `_worktree_reset` 内では
`2>/dev/null` を **外すだけ** で stderr が自動的に SLOT_LOG に流れる。明示的な SLOT_LOG パス受け
渡しは不要。Req 1.4（成功時は標準出力量を増やさない）も `git reset --hard` / `git clean -fdx` が
成功時に stderr へ書かない既存挙動で自然に満たされる。

### 2. EACCES 検出のため一時 stderr capture

ただし、`clean -fdx` の stderr を SLOT_LOG に流すだけだと escalated cleanup の起動判断に
使えない（grep 対象が無い）。そこで `mktemp` で一時ファイルに stderr を捕捉し、`grep -qE
'EACCES|Permission denied|Operation not permitted'` で permission 失敗かを判定してから
SLOT_LOG（>&2）へも転写する方式を採用。`mktemp` 失敗時は従来同様の挙動（return 1）に
fail-safe する。

### 3. opt-in 判定: lowercase の `true` のみ有効

`feature-flag.md` 規約に準拠し、`[ "${WORKTREE_DOCKER_CLEANUP_ENABLED:-false}" = "true" ]` の
**厳密一致**のみを opt-in 扱いとする。`True` / `TRUE` / `1` / `yes` / `enabled` 等の typo は
すべて無効解釈（NFR 4.1 安全側設計）。

### 4. docker イメージは busybox 既定 + `WORKTREE_DOCKER_CLEANUP_IMAGE` で差し替え可

`busybox` は数 MB 級の最小イメージで広く流通しており、`docker pull` キャッシュも軽い。
社内 registry / airgap 環境向けに `WORKTREE_DOCKER_CLEANUP_IMAGE` で差し替えられるよう env で
gate。コンテナは `--network=none --rm` で起動し、worktree の `.` のみを bind-mount。
`.git` を巻き込まないよう `find . -mindepth 1 -maxdepth 1 ! -name ".git"` で最上位エントリを
列挙して `rm -rf` する。

### 5. worktree 再作成は `git worktree remove --force` → `rm -rf` → `git worktree add --detach`

- `git worktree remove --force` は git 側の登録解除。既存登録が無い場合は warn 扱いで
  `git worktree prune` に fallback して継続
- root 所有 artifact が残ったままだと `rm -rf` も EACCES で失敗し得る。その場合は明示エラー
  を SLOT_LOG に残して return 1（Req 4.4）
- 成功時は `git worktree add --detach <wt> origin/$BASE_BRANCH` で再登録し return 0

## 後方互換性

- 通常ケース（permission 失敗が起きない普通の worktree）では `reset --hard` → `clean -fdx` の
  2 ステップが従来どおり通って return 0。docker 経路 / 再作成経路は起動しない（Req 5.1）
- `WORKTREE_DOCKER_CLEANUP_ENABLED` 未設定の既存 cron 環境は **escalated cleanup フロー自体は
  起動するが、docker 経路を skip して worktree 再作成 fallback に直行する**。これは従来の
  「return 1 で終了」よりは挙動が変わるが、permission 失敗ケースは従来 100% 偽陽性
  `claude-failed` を起こしていたため、worktree を作り直して救済する方向の挙動変化は
  運用改善に倒している。**通常ケース（permission 失敗なし）の挙動は完全に同一**（Req 5.1, 5.2,
  NFR 1.1）
- 既存 env var 名・呼び出し元契約はすべて維持（Req 5.3, 5.4）

## 検証

### 静的解析

```sh
shellcheck local-watcher/bin/modules/core_utils.sh \
  local-watcher/bin/issue-watcher.sh \
  docs/specs/295-bug-watcher-worktree-reset-root-docker-c/test-fixtures/smoke-worktree-reset.sh
# → 警告ゼロ（NFR 3.1）

bash -n local-watcher/bin/modules/core_utils.sh \
  local-watcher/bin/issue-watcher.sh
# → 構文 OK
```

### Smoke test（通常ケース）

```sh
bash docs/specs/295-bug-watcher-worktree-reset-root-docker-c/test-fixtures/smoke-worktree-reset.sh
# → [smoke] ALL PASS
#   - 通常ケースで _worktree_reset が origin/main の clean 状態に戻す
#   - opt-in 判定が lowercase 完全一致のみ true（NFR 4.1）
```

### 二重管理ドリフトなし

`.claude/{agents,rules}/` は触っていないため `diff -r .claude/agents repo-template/.claude/agents`
と `diff -r .claude/rules repo-template/.claude/rules` は空のまま（既存通り）。

### 確認できなかった検証

- 実 docker 環境での EACCES 再現テストは本 PR 内では実施していない（CI / 運用 repo 側で
  `WORKTREE_DOCKER_CLEANUP_ENABLED=true` opt-in した状態のドッグフーディングで確認するのが現実的）
- root 所有 artifact を `setfacl` 等で模擬した re-creation fallback の挙動は未テスト（本 PR の
  スコープ外と判断）

## 要件カバレッジ表

| Req ID | 内容 | 実装箇所 |
|---|---|---|
| 1.1 | `git reset --hard` 失敗時 stderr を SLOT_LOG に追記 | `reset --hard` から `2>/dev/null` を除去し、失敗時に時刻 prefix 付きで `>&2` に echo（呼び出し元 tee が SLOT_LOG に流す） |
| 1.2 | `git clean -fdx` 失敗時 stderr を SLOT_LOG に追記 | tmp file に capture → 失敗時に `cat >&2` で SLOT_LOG へ転写 |
| 1.3 | stderr を `/dev/null` に握り潰さない | reset 側は素通し、clean 側は tmp file 経由で必ず SLOT_LOG に出力 |
| 1.4 | 成功時に標準出力量を増やさない | stdout は `>/dev/null` で抑止、git 成功時 stderr は空、tmp file の空チェックで no-op |
| 2.1 | env var で gate | `${WORKTREE_DOCKER_CLEANUP_ENABLED:-false}` で参照 |
| 2.2 | 未設定時の既定は false | `:-false` |
| 2.3 | false / 未設定で docker 経路を起動しない | `[ "$WORKTREE_DOCKER_CLEANUP_ENABLED" = "true" ]` 厳密比較 |
| 2.4 | true 宣言時のみ EACCES 検出で docker cleanup | `is_perm_fail=1` 時のみ docker 分岐 |
| 2.5 | docker 不在時 fallback に進む | `command -v docker` 失敗時の分岐 |
| 3.1 | EACCES / Permission denied 検出 | `grep -qE 'EACCES\|Permission denied\|Operation not permitted'` |
| 3.2 | docker 起動で root 所有 artifact 削除 | `docker run --rm --network=none -v $wt:/wt busybox sh -c 'find ...'` |
| 3.3 | docker 失敗 / 利用不可で再作成 fallback へ | docker 失敗ブランチで `_worktree_reset_recreate` を呼ぶ |
| 3.4 | 全経路失敗時は明示エラーを残し非 0 終了 | 最終 `return 1` 直前に時刻 prefix 付き ERROR メッセージ |
| 3.5 | permission 起因でない失敗は従来どおり非 0 終了 | `is_perm_fail != 1` で early `return 1` |
| 4.1 | docker 失敗 / skip で worktree 再作成 fallback | `_worktree_reset_recreate` を呼ぶフロー |
| 4.2 | 既存 worktree 登録解除 + 同一パスに再作成 | `git worktree remove --force` → `git worktree add --detach $wt origin/$BASE_BRANCH` |
| 4.3 | 再作成成功で `_worktree_reset` を 0 終了 | `_worktree_reset_recreate` が 0 を返したら `_worktree_reset` も 0 を返す |
| 4.4 | 再作成失敗時は明示ログ + 非 0 終了 | rm 失敗 / worktree add 失敗で ERROR ログ + return 1 |
| 4.5 | 再作成が走った事実を SLOT_LOG に残す | 開始時 / 完了時 / 復旧成立時にそれぞれ時刻 prefix 付き message |
| 5.1 | 通常ケース（permission 失敗なし）で追加経路を起動しない | clean 成功時に即 return 0、失敗時も permission 起因でなければ即 return 1 |
| 5.2 | 既存 exit code セマンティクス（0=ok / 非 0=失敗）を変更しない | return 0 / 1 のみ |
| 5.3 | 既存 env var 名を改名・削除しない | 既存 var には触れていない |
| 5.4 | 呼び出し元契約（引数=worktree 絶対パス / 戻り値=0 or 1）を変更しない | 関数シグネチャ変更なし |
| NFR 1.1 | 未宣言の既存 cron 環境で導入前と同一挙動を維持 | 通常ケースで追加処理を起動しない |
| NFR 1.2 | docker 未使用 repo で追加の外部コマンド呼び出しを発生させない | 通常パスで docker / sudo を呼ばない |
| NFR 2.1 | escalated cleanup の各段階を SLOT_LOG から追跡可能 | 開始 / docker 成否 / 再作成 / 最終失敗の各段で時刻 prefix 付き log |
| NFR 2.2 | 対象 slot 番号 / worktree パスを log に含める | `(wt=$wt)` を全 message に付与（呼び出し元 `slot_warn` も既存通り slot 番号 prefix） |
| NFR 3.1 | shellcheck 警告ゼロ | 確認済み |
| NFR 3.2 | 安全な変数展開 + `command -v` 規約 | クォート徹底、`command -v docker` 使用 |
| NFR 3.3 | エラーは `>&2` に出力 | すべての error メッセージは `>&2` |
| NFR 4.1 | lowercase `true` 以外を無効解釈 | `= "true"` 厳密比較 |

## 確認事項

- 運用 repo 側で実際に `WORKTREE_DOCKER_CLEANUP_ENABLED=true` を宣言する判断は人間オーナーに
  委ねる（README の Troubleshooting 節への追記が望ましいが、本 Issue のスコープ外と判断して
  本 PR では実施せず）
- `WORKTREE_DOCKER_CLEANUP_IMAGE` の env var は要件で明示されていないが、airgap / 社内 registry
  環境のための差し替え機構として追加した。要件側でこの env var の追加が不要・不適切と
  判断される場合は削除可能（既定 `busybox` のみで運用してもよい）
