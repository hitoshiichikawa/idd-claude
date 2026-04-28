# Implementation Notes — Phase C (Issue #16)

## 概要

`local-watcher/bin/issue-watcher.sh` の入口（auto-dev Issue 処理ループ）を Dispatcher /
Slot Worker パターンに置換し、`PARALLEL_SLOTS` 環境変数で並列度を制御できるようにした。
既存運用の cron / launchd 登録文字列・env var 名・ラベル契約・exit code は不変。
`PARALLEL_SLOTS=1`（既定）の場合、本機能導入前と外形的に同一の挙動を保つ。

## 実装サマリ

| Task | 概要 | 主要な追加 |
|---|---|---|
| 1.1 | Config Block 拡張 | `PARALLEL_SLOTS` / `SLOT_INIT_HOOK` / `WORKTREE_BASE_DIR` / `SLOT_LOCK_DIR` |
| 1.2 | 入力検証 | `_parallel_validate_slots`、不正値で ERROR ログ + `exit 1` |
| 2.1 | Worktree Manager | `_worktree_path` / `_worktree_is_registered` / `_worktree_ensure` / `_worktree_reset` |
| 2.2 | Slot Lock Manager | `_slot_lock_path` / `_slot_acquire` / `_slot_release`（fd 210+N で per-slot 非ブロッキング flock） |
| 2.3 | Hook Layer | `_hook_invoke`（絶対パス起動、eval 不使用、stderr 末尾転記） |
| 3.1 | Slot Runner | `_slot_run_issue`（既存 Issue 処理ループ本体を関数化） |
| 3.2 | Dispatcher | `_dispatcher_run`（claim atomicity + slot 探索 + wait -n ベースの fork-join） |
| 4.1 | README | 「並列実行 (Phase C, #16)」節を追加 |
| 5.1 | 静的解析 | shellcheck warning ゼロ、`bash -n` クリア |

## 受入基準（AC）対応マッピング

本リポジトリには unit test フレームワークがないため、AC は **shellcheck + 手動スモークテスト**
で検証する（CLAUDE.md「テスト・検証」節準拠）。各 AC が実装上どこで満たされているかと、
スモークテスト結果を以下に記載する。

### Requirement 1: 並列度設定と既定値

| AC | 担保 | スモーク結果 |
|---|---|---|
| 1.1 | `PARALLEL_SLOTS="${PARALLEL_SLOTS:-1}"` を Config Block に追加 | env 読み取り OK |
| 1.2 | デフォルト値 `1` で直列動作 | `PARALLEL_SLOTS` 未設定時に `1` として動作することを確認 |
| 1.3 | `_parallel_validate_slots` で正の整数以外を拒否、ERROR ログ + exit 1 | `PARALLEL_SLOTS=abc` / `0` で `dispatcher: ERROR:` + `rc=1` を確認 |
| 1.4 | `PARALLEL_SLOTS=1` で外形互換 | "処理対象の Issue なし" + "完了" 行が本機能導入前と完全一致することを確認 |
| 1.5 | README 並列実行節を追加（推奨値・ディスク量・運用上限） | README #並列実行-phase-c-16 を参照 |

### Requirement 2: 単一プロセス内 Dispatcher と claim atomicity

| AC | 担保 | スモーク結果 |
|---|---|---|
| 2.1 | `_dispatcher_run` が 1 サイクル中 1 度起動 | サイクル内で 1 ログ行 `dispatcher: 対象 Issue X 件...` のみを観測 |
| 2.2 | claim → slot 投入の順序 | スモークログで `dispatcher: dispatched #N -> slot-M` 行が `_slot_run_issue` 起動前に出ることを確認 |
| 2.3 | label 付与失敗で WARN + 次 Issue へ | gh edit 失敗パスを構造的に保証（コードパス review）、実 API 失敗のスモークは未実施（gh モックは固定値返却のため） |
| 2.4 | 同一 Issue 二重投入なし | jq 出力を 1 度だけ消費（while-read）、Dispatcher 自身が単一プロセスのため構造的に保証 |
| 2.5 | 空き slot を継続投入 | 4 Issue / 2 slot の dispatcher fork-join スモークで slot 完了 → 再投入を確認 |
| 2.6 | サイクル終端 wait | キュー枯渇後の `wait` で全 PID 終了まで待機することを確認（最終ログ `dispatcher: サイクル完了` 出力前に全 worker 完了） |
| 2.7 | dispatcher 異常終了で再ピックなし | 既存 `gh issue list` の `-label:claude-picked-up` フィルタが構造的にガード（コード変更なし） |

### Requirement 3: Per-slot 永続 Worktree

| AC | 担保 | スモーク結果 |
|---|---|---|
| 3.1 | `$HOME/.issue-watcher/worktrees/<slug>/slot-N/` を割当 | `_worktree_path` が想定パスを返すことを確認 |
| 3.2 | 未初期化なら 1 度作成 | 初回サイクルで `worktree 作成: ... (detached @ origin/main)` ログを観測 |
| 3.3 | 既存なら再利用 | 2 回目サイクルで `worktree 確保 OK` のみ（`worktree 作成` なし）を観測 |
| 3.4 | Issue 投入時に reset --hard | `worktree reset OK (origin/main 最新化 + clean -fdx)` ログを観測 |
| 3.5 | 他 slot ツリー書き込み禁止 | Slot Runner はサブシェル `( ) &` で fork され、内部 `cd "$WT"` は親に伝播しない（構造的保証） |
| 3.6 | 初期化失敗で claude-failed 化 | `_slot_mark_failed "worktree-ensure" ...` パスをコード review で確認、実失敗のスモークは未実施 |
| 3.7 | `<repo-slug>` で worktree 隔離 | `_worktree_path` が `$REPO_SLUG` を含むことを確認 |

### Requirement 4: Per-slot ロックと多重起動防止

| AC | 担保 | スモーク結果 |
|---|---|---|
| 4.1 | `$HOME/.issue-watcher/<slug>-slot-N.lock` | `_slot_lock_path` が想定パスを返すことを確認、スモークで `owner-test-repo-slot-1.lock` ファイル生成を確認 |
| 4.2 | 非ブロッキング acquire (`flock -n`) | スモーク（fd 211 を別プロセスで保持中に再 acquire）で「OK rejected (as expected)」を観測 |
| 4.3 | 取得失敗で skip + INFO ログ | `dispatcher_warn "全 slot がロック中..."` パスを review で確認 |
| 4.4 | slot 間別ファイル lock | `_slot_lock_path` が slot 番号を path に埋めるため別ファイル、fd も per-slot に別番号 |
| 4.5 | repo 単位 LOCK_FILE 維持 | 既存 `exec 200>"$LOCK_FILE"; flock -n 200` を変更していないことを確認 |

### Requirement 5: SLOT_INIT_HOOK

| AC | 担保 | スモーク結果 |
|---|---|---|
| 5.1 | `SLOT_INIT_HOOK="${SLOT_INIT_HOOK:-}"` 読み取り | Config Block で env 読み取りを確認 |
| 5.2 | 未設定でフック非起動 | スモーク: SLOT_INIT_HOOK 未設定で hook 関連ログが一切出ないことを確認 |
| 5.3 | reset 後・claude 前に 1 度起動 | スモーク: `worktree reset OK` 後・`SLOT_INIT_HOOK 完了` の順序を確認 |
| 5.4 | env var 引き継ぎ | スモーク: hook 内の echo で `slot=1 wt=... PARALLEL_SLOTS=2 REPO=...` を観測 |
| 5.5 | eval せず直接 exec | コード review: `"$SLOT_INIT_HOOK"` を直接起動、`bash -c` / `eval` 不使用を確認 |
| 5.6 | 不在 / 非実行可能で claude-failed 化 | スモーク: `SLOT_INIT_HOOK=/nonexistent/...` で `ERROR: 存在しないか実行可能ではありません` + `WARN: SLOT_INIT_HOOK の起動に失敗` を観測 |
| 5.7 | 非ゼロ exit でログ転記 + claude-failed 化 | スモーク: `exit 9` の hook で `ERROR: ... exit code 9` + `hook stderr (tail): ...` + `WARN: SLOT_INIT_HOOK の起動に失敗` を観測 |
| 5.8 | README 責任分界 | README 「`SLOT_INIT_HOOK`（依存セットアップ用 opt-in フック）」節に明記済 |

### Requirement 6: 並列実行時の可観測性

| AC | 担保 | スモーク結果 |
|---|---|---|
| 6.1 | slot 番号 + Issue 番号 prefix | `slot_log` が `slot-N: #M:` prefix を付与、スモークログで確認 |
| 6.2 | slot 別ログファイル | スモークで `slot-1-101-TS.log` / `slot-2-102-TS.log` の 2 ファイル生成を確認 |
| 6.3 | サイクル開始ログ | スモークで `dispatcher: 対象 Issue 2 件 / 利用可能 slot 2 件` を確認 |
| 6.4 | 投入時刻・完了時刻 | スモークで `dispatched #M -> slot-N` (start) と `slot-N: completed (pid=...)` (end) の 2 行を確認 |
| 6.5 | timestamp 書式維持 | 全 dispatcher / slot ログで `[YYYY-MM-DD HH:MM:SS]` 書式を維持 |

### Requirement 7: 既存運用との後方互換性

| AC | 担保 | スモーク結果 |
|---|---|---|
| 7.1 | 既存 env var 名維持 | 追加のみ。`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / モデル系の env 名・意味・既定は不変 |
| 7.2 | 既存 cron 文字列維持 | エントリポイント `$HOME/bin/issue-watcher.sh` のまま |
| 7.3 | 既存ラベル契約維持 | 新ラベル追加なし。`run_impl_pipeline` / `mark_issue_failed` / `_slot_mark_failed` が既存ラベルセットのみで遷移 |
| 7.4 | 終端ラベル除外維持 | `gh issue list --search` の `-label:` フィルタを変更していない |
| 7.5 | exit code 維持 | 正常 0、`PARALLEL_SLOTS` 不正値で 1（既存 ERROR と整合）、cron 多重起動で 0（既存と整合） |
| 7.6 | `=1` で他 slot 資源を不生成 | スモーク（PARALLEL_SLOTS=1 / 1 Issue）で `slot-2/` および `slot-2.lock` が生成されないことを確認 |

### Requirement 8: DoD 検証可能性

| AC | 担保 | スモーク結果 |
|---|---|---|
| 8.1 | `=1` 同等性をログから観察可能 | "処理対象の Issue なし" 行は本機能導入前と完全一致（prefix なし） |
| 8.2 | `=2` で 2 件並列観察可能 | スモーク: `dispatched #101 -> slot-1` と `dispatched #102 -> slot-2` の timestamp が同一秒内に観察可能 |
| 8.3 | 同一 Issue 重複なし | スモーク: 各 slot ログに別 Issue 番号が現れることを確認、ローカルキューが 1 度だけ消費される |
| 8.4 | worktree 干渉なし観察可能 | per-slot worktree は別 path に配置、`git worktree list` で別 entry を確認 |
| 8.5 | hook 起動可観測 | スモーク: hook 実行で `SLOT_INIT_HOOK 完了` ログが各 slot で 1 度ずつ出ることを確認 |

### Non-Functional Requirements

| NFR | 担保 | 補足 |
|---|---|---|
| 1.1 | 並列短縮率 | スモーク（fake claude sleep 1s × 2 件）で 2 件並列処理が ~2s で完了することを確認、直列なら ~4s。50%-70% を上回る短縮率（実測 ~50%） |
| 1.2 | 投入オーバーヘッド ≤ 5s | スモークで dispatch 時刻 → worker `Worker 起動` の差が同一秒内（~0s）であることを確認 |
| 2.1 | 1 slot 失敗で他に伝播せず | 各 worker はサブシェル `( ) &` で隔離、`set -e` の影響もサブシェル内に閉じ込められる |
| 2.2 | label のみで claim 成立 | Dispatcher は worker の戻り値・stdout に依存せず、`gh issue edit --add-label` の成否のみで claim を成立させる |
| 2.3 | hook eval 禁止 | `_hook_invoke` 内では `"$SLOT_INIT_HOOK"` の絶対パス起動のみ、`bash -c` / `eval` 不使用 |
| 3.1 | slot prefix 出力 | `slot-N: #M:` prefix で grep 可能 |
| 3.2 | ログ分離 | per-slot file (`slot-N-M-TS.log`) で混入なし |
| 4.1 | 未使用 slot 資源不生成 | `=1` 時に `slot-2.lock` / `slot-2/` を作らないことをスモークで確認 |
| 4.2 | ディスク量目安を README 明記 | README 「ディスク容量の前提」節に記載 |

## 設計上の判断とトレードオフ

### claim タイミング変更（既存挙動への小影響）

**問題**: design.md / requirements (Req 2.2) は「Dispatcher が pop → claude-picked-up 付与 →
slot 投入」という claim atomicity を要求する。一方、本機能導入前のコードは Triage 後に
claim していた。これにより `PARALLEL_SLOTS=1` でも以下の挙動差が発生する:

| シナリオ | 本機能導入前 | Phase C |
|---|---|---|
| Triage 結果が `needs-decisions` | `claude-picked-up` は **未付与** のまま `needs-decisions` を付与 | `claude-picked-up` を **一度付与した後に除去** + `needs-decisions` 付与 |
| Triage 自体が失敗（Claude crash） | ラベル変更なし、次サイクルで再 Triage | `claude-picked-up` → `claude-failed` に遷移、人間判断に委ねる |

**判断**: design.md に従い claim-before-fork を採用。`needs-decisions` の場合は Slot Runner
内で `claude-picked-up` を除去してから `needs-decisions` を付与することで、次サイクルで人間が
`needs-decisions` を外したときに正しく再ピックアップされるようにした。Triage 失敗時は claim
済 Issue を放置すると永久に再ピックアップ不可（claude-picked-up が付いたまま）になるため、
明示的に `claude-failed` に遷移する。

**影響**: GitHub の Issue activity log には `claude-picked-up` ラベルの付与・除去の 2 イベントが
残るが、最終的な Issue ラベルは従来と同じ集合に収束する。Req 1.4「外形的に同一」の解釈として
許容範囲と判断（README の Migration Note に明記）。

### Worktree を `--detach` で作成

**問題**: 各 slot の worktree が独立していても、後段の `git checkout -B <branch> main` は同じ
local branch（`main`）が他 slot の worktree でチェックアウト済だと弾かれる。

**判断**: `git worktree add --detach <path> origin/main` で detached HEAD として作成し、
各 slot は `git checkout -B <branch> origin/main` で新規 branch に切り替える。これにより
local branch 共有による衝突を構造的に回避。

### `wait -n` 採用（bash 4.3+ 前提）

**判断**: design.md の指示通り `wait -n`（任意の 1 子プロセス完了まで待機）を採用。bash 4.3+
が前提だが、CLAUDE.md に bash 4+ と既に記載済で、macOS 標準 bash 3.2 を使う場合は別途
`brew install bash` が必要。これは Phase C 導入の必要前提として README に明記した。

### Slot Lock の fd 番号

**判断**: 既存 `LOCK_FILE` が fd 200 を使うため、衝突回避で `210 + slot_number` を採用。
fd の上限を考えると `PARALLEL_SLOTS` は実質数十程度を想定（一般的に bash の fd 上限は数百〜
数千なので問題なし）。

### Dispatcher の fd 解放（claim atomicity の保証）

**問題**: `_slot_acquire` は親 dispatcher の fd を開いて flock を取得する。この fd を親で
保持したまま subshell を fork し、subshell が終わる前に親が再度 `_slot_acquire` を呼ぶと、
flock advisory locking は per-fd ベースなので親が同じ slot を再取得できてしまう（claim
atomicity 破綻）。

**判断**: dispatcher は subshell fork 直後に `_slot_release` を呼んで自身の fd を閉じる。
subshell は fd 継承で同じファイル lock を保持し続けるため、親が同 slot を再 acquire しよう
とすると flock が失敗する（subshell が握っているため）。検証は smoke test で確認済。

### 既存 `--limit 5` を据え置き

`gh issue list --limit 5` を変更せず、`PARALLEL_SLOTS` の値に応じた limit 拡張は行わない。
これは既存運用との互換性を最大化するため。`PARALLEL_SLOTS=2` でも 1 サイクルでは最大 5 件
（直列でも並列でも）。バーストが必要なら次サイクルで残りを処理する設計。

## 確認事項（PR 本文へ転記する想定）

1. **Triage 失敗時の遷移変更について**: 本機能導入前は Triage 失敗で `continue`（ラベル変更
   なし、次サイクルで再 Triage）だったが、Phase C では claim 済のため `claude-failed` に遷移
   する設計とした。これは「人間判断に委ねる」という設計に倒した結果だが、再 Triage 自動継続を
   優先したい運用があれば PM への差し戻しを提案する余地あり（design.md / requirements に
   明示記載はない暗黙の振る舞い）。

2. **`wait -n` の bash 4.3+ 依存**: macOS 標準の bash 3.2 では動作しない。CLAUDE.md には
   bash 4+ と記載済だが、`wait -n` のために 4.3+ が必要な点は README の Migration Note に
   明記した。既存ユーザーの中に bash 3.x で運用している人がいるかは確認していない。

3. **`actionlint` の確認は手元未実施**: 当該環境に `actionlint` がインストールされていないため、
   Phase C で `.github/workflows/*.yml` を変更していないことを `git diff main..HEAD --
   .github/workflows/` で確認するに留めた（変更なし）。

4. **claim 済 worktree-ensure / worktree-reset / hook 失敗時の Issue コメント**: 既存
   `mark_issue_failed` を再利用せず、Phase C 独自の `_slot_mark_failed` を導入した（理由:
   `mark_issue_failed` は `MODE` / `LOG` 等のグローバル変数を要求するため、worktree 段階の
   早期失敗時はまだ `MODE` が決まっていない）。表示メッセージは互換だが、`hostname` の
   括弧書きが微妙に異なる（`/ slot=N` 等の追加情報を含む）。

5. **第一サイクル遅延**: 既存 `$REPO_DIR` を流用しないため、PARALLEL_SLOTS=2 以上の初回
   サイクルは worktree 新規作成のため通常より遅い（数 GB の repo では数分）。README に明記
   したが、実 cron 環境での観測は別途 dogfooding で確認する必要がある。

## 検証結果

### 静的解析

- `shellcheck --severity=warning local-watcher/bin/issue-watcher.sh install.sh setup.sh
  .github/scripts/*.sh` → **rc=0（warning なし）**
- `bash -n local-watcher/bin/issue-watcher.sh` → **構文 OK**
- `actionlint .github/workflows/*.yml` → **未実施**（actionlint がローカルに無い、
  Phase C で workflow 変更なし）

### 手動スモークテスト

| シナリオ | 結果 |
|---|---|
| `PARALLEL_SLOTS=1`、Issue なし | "処理対象の Issue なし" + "完了"、slot 資源生成なし |
| `PARALLEL_SLOTS=1`、1 Issue（skip-triage） | slot-1 worktree / slot-1 lock 生成、`slot-2.*` 未生成 |
| `PARALLEL_SLOTS=2`、2 Issue（skip-triage） | slot-1 / slot-2 並列実行、各別 worktree / lock / log ファイル生成、timestamp 重なり確認 |
| `PARALLEL_SLOTS=abc`（不正値） | `dispatcher: ERROR: ...` + rc=1 |
| `PARALLEL_SLOTS=0`（不正値） | `dispatcher: ERROR: ...` + rc=1 |
| `SLOT_INIT_HOOK=/path/to/ok-hook.sh` | hook 実行・env var 受け渡し OK、`SLOT_INIT_HOOK 完了` ログ |
| `SLOT_INIT_HOOK=/path/to/exit9-hook.sh` | `ERROR: exit code 9` + stderr 末尾転記 + `WARN: 起動に失敗` |
| `SLOT_INIT_HOOK=/nonexistent/path` | `ERROR: 存在しないか実行可能ではありません` + `WARN: 起動に失敗` |
| 2 サイクル目（worktree 既存） | `worktree 確保 OK`（再作成なし）→ 冪等性確認 |

### 未実施スモーク

以下は実 GitHub API / 実 Claude / 実 cron が必要なため、本実装では未検証（dogfooding で確認すべき）:

- claim 競合（手動で `gh issue edit --add-label claude-picked-up` 先回り → server-side
  filter で除外されることの実環境確認）
- worktree 破損リカバリ（`slot-1/.git` を破壊して次サイクルで自動再作成、broken-TS への退避）
- 真の並列処理時間短縮（実 Claude を起動する dogfooding test）
- 複数 repo の同時運用（`REPO` / `REPO_DIR` 別エントリでの worktree path 衝突なし）

## Feature Flag Protocol

本リポジトリの `CLAUDE.md` に `## Feature Flag Protocol` 節は存在せず、規約は **opt-out
扱い**（既定）。よって本実装では flag 裏の二重実装パターンを採用せず、通常の単一実装パスで
完了している（`PARALLEL_SLOTS=1` を flag-off と等価な役割で使う運用）。

## 派生タスク候補

実装中に発見した、別 Issue として切り出すべき項目:

1. **dogfooding cron での初回サイクル遅延の実測**: `PARALLEL_SLOTS=2` 初回起動時の worktree
   新規作成にかかる時間を計測し、必要に応じて事前 fetch スクリプトを `install.sh` に追加する
   ことを検討。
2. **claim 競合の server-side filter 検証**: 実 GitHub API で `gh issue list` の
   `-label:claude-picked-up` フィルタが手動付与の race condition を構造的に防ぐかの実環境テスト。
3. **slot worktree のディスク使用量モニタリング**: `$HOME/.issue-watcher/worktrees/` の総容量を
   定期報告するログを追加するか検討（運用観測のため）。
4. **dispatcher 内 timeout の検討**: 各 slot worker の暴走（claude が長時間 hung up）に備えた
   per-slot timeout は本フェーズでは未実装。Phase E（hot file 予防）と合わせて別 Issue で検討。
