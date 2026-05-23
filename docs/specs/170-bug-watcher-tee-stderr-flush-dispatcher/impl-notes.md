# 実装ノート（Issue #170）

`local-watcher/bin/issue-watcher.sh` のシェル堅牢化 3 件（SLOT_INIT_HOOK stderr 同期捕捉 /
slot ログ堅牢化 / Dispatcher シグナル trap）の実装記録。

## 変更サマリ

| Requirement | 対応 | 変更内容 |
|---|---|---|
| Req 1（最優先） | 実装 | `_hook_invoke` の stderr 捕捉を非同期 `tee` プロセス置換から同期リダイレクト `2>"$stderr_tmp"` に変更し、フック終了後に `cat "$stderr_tmp" >&2` で stderr を運用者へ転記 |
| Req 2（低優先・表示品質） | 現状維持＋判断記録 | 確実な低リスク同期手法が無いため現状維持。後述の判断理由を参照 |
| Req 3（低優先・最小実装） | 実装 | Dispatcher トップレベルに SIGINT/SIGTERM trap を追加（子プロセス kill + worktree prune 1 回、再入ガード付き） |

## Requirement 1: SLOT_INIT_HOOK stderr 捕捉の同期化

### 変更内容
- 旧: `"$SLOT_INIT_HOOK" 2> >(tee -a "$stderr_tmp" >&2) || rc=$?`
  - 非同期プロセス置換のため、フック終了直後の `tail -c 2000` 読み出しと tee の flush の間に
    レースが生じ、失敗ログ末尾が欠落しうる
- 新: `"$SLOT_INIT_HOOK" 2>"$stderr_tmp" || rc=$?`
  - 同期リダイレクト。フック終了時点で一時ファイルが確定する
  - フック終了後に `if [ -s "$stderr_tmp" ]; then cat "$stderr_tmp" >&2 || true; fi` で
    stderr を従来どおり運用者へ流す（Req 1.4: stderr 観測性維持）
  - `set -euo pipefail` 下で `cat` 失敗が `_hook_invoke` を誤って致命化しないよう `|| true` でガード
- 既存の `tail -c 2000` 転記（rc != 0 時）/ `rm -f`（正常時の一時ファイル削除）/ exit code 取得
  （`|| rc=$?`）の意味は変更していない

### AC 対応
- **AC 1.1**（非ゼロ exit 時に stderr 末尾 2000 バイトをログ転記）: 既存の `tail -c 2000 "$stderr_tmp"`
  ロジックを温存。同期化により一時ファイルが完全に確定した状態で読むため末尾欠落しない
- **AC 1.2**（フック終了を待ってから一時ファイル読み出し / flush レースを生じさせない）:
  同期リダイレクト `2>"$stderr_tmp"` でフック終了 = ファイル確定。非同期 tee を排除
- **AC 1.3**（正常終了時は一時ファイル削除・追加エラー出力なし）: 既存の `rm -f "$stderr_tmp"` を温存。
  `rc == 0` のとき ERROR ログを出さない既存挙動を変更していない
- **AC 1.4**（stderr を従来どおり運用者から観測可能に保持）: 同期捕捉後に `cat "$stderr_tmp" >&2`
  で stderr へ転記。旧実装の `tee >&2` と同じく運用者から観測可能
- **AC 1.5**（exit code を 0=成功/非ゼロ=失敗で呼び出し元へ返す）: `|| rc=$?` と末尾の
  `return 1 / return 0` を変更せず温存

### スモーク検証（Req 1）
即異常終了し 200 行（>2000 バイト）の stderr を吐くフックを `2>"$tmp"` で捕捉 →
`tail -c 2000` で末尾を読む再現テストを実施:
- 末尾行 `ERRLINE-200` が捕捉 tail に含まれる（**TAIL_OK**: 末尾欠落なし）
- exit code 7 が保持される（**RC_OK**）
- 検証用スクリプトはリポジトリにコミットせず削除済み

## Requirement 2: slot ログ出力の堅牢化（現状維持＋判断記録）

### 判断: 現状維持
`exec > >(tee -a "$SLOT_LOG") 2>&1`（11086 行付近）は **変更しない**。理由:

1. **dual-write には tee が構造上必要**: stdout（cron mailer 経路）と slot ログファイルの
   双方へ同時に書き出す要件（AC 2.1）は、1 ストリームを 2 宛先へ複製する `tee` でのみ実現できる。
   同期リダイレクト単独では dual-write を代替できない
2. **確実な低リスク同期手法が無い**: tee 子プロセスの flush 同期は、
   `exec > >(tee ...)` 直後の `$!` で tee PID を捕捉し subshell 終了時に `wait` する方法が
   考えられるが、(a) `$!` の挙動が bash バージョン依存で脆い、(b) `_slot_run_issue` subshell に
   新規 EXIT trap を追加すると、ネストした helper 関数内の既存サブシェル trap（rebase/revert/checkout
   復帰）との相互作用が非自明になり、Req 3.4「既存サブシェル trap の挙動を変更しない」制約への
   リスクが生じる。タスク指示の「過剰修正リスク警戒」に従い、確実な低リスク手法が無いと判断
3. **機能影響が無い**: Req 2 は表示順序の乱れ（display quality）であり機能影響なし。
   親 Dispatcher は終端で全 subshell を `wait`（11738 行付近）するため、ファイル内容は
   subshell とその tee 子プロセスが終了した後に最終的に完全な状態になる

### AC 対応（現状維持で充足）
- **AC 2.1**（stdout と slot ログファイル両方へ書き出す）: 既存 `tee -a "$SLOT_LOG"` で充足。変更不要
- **AC 2.2**（完了時にログ行を欠落なく確定）: 親の終端 `wait` で subshell + tee の終了を待ち合わせ、
  ファイル内容は最終的に確定する。表示順序の乱れは機能影響なし
- **AC 2.3**（パス命名規約 `slot-<slot番号>-<Issue番号>-<タイムスタンプ>.log` を従来と同一に保つ）:
  `SLOT_LOG="$LOG_DIR/slot-${IDD_SLOT_NUMBER}-${NUMBER}-${TS}.log"` を変更していない

## Requirement 3: Dispatcher のシグナル捕捉（最小実装）

### 変更内容
Dispatcher トップレベル（`_DISPATCHER_SLOT_PIDS` 宣言の直後）に以下を追加:
- `_DISPATCHER_SIGNAL_HANDLED` ガードフラグ（初期値 0）
- `_dispatcher_on_signal()` ハンドラ関数
  - 再入ガード: 既に処理済みなら即 `return 0`（NFR 2.2）
  - fork 済み slot worker（`_DISPATCHER_SLOT_PIDS` の各 PID）へ `kill -TERM`（Req 3.1）
  - `wait` で子プロセス回収（孤立防止）
  - `git -C "$REPO_DIR" worktree prune` を 1 回実行（Req 3.2、既存コードと同じ idiom）
  - exit code は bash 慣例の 128+signal（SIGINT=130 / SIGTERM=143）
- `trap '_dispatcher_on_signal INT' INT` / `trap '_dispatcher_on_signal TERM' TERM`

### 設計判断
- **trap はトップレベルに配置**: メインスクリプト本体に置く。サブシェル `( _slot_run_issue ... ) &`
  には trap は伝播しない（bash はサブシェルで trap をリセットする）ため、既存のサブシェル内
  ローカル EXIT trap（1174/1515/3128/3461/4748 行付近の rebase/revert/checkout 復帰）の挙動は
  一切変更されない（Req 3.4）
- **flock fd 200 の解放契約を維持**: fd 200 の flock はメインプロセスが保持し、プロセス終了時に
  OS が自動解放する。ハンドラは最後に `exit` するため、多重起動防止ロックの解放契約は従来どおり
  （Req 3.3）。per-slot lock（fd 210+N）方式も触れていない
- **kill -TERM を使用**: 子へ SIGTERM を送る。子 subshell 側は SIGTERM で素直に終了する
  （子に独自 trap を仕込む graceful shutdown は本 Issue のスコープ外 / Out of Scope）

### AC 対応
- **AC 3.1**（SIGINT/SIGTERM 受信時に fork 済み slot worker 子プロセスへ終了シグナルを送る）:
  `_DISPATCHER_SLOT_PIDS` の各 PID へ `kill -TERM`
- **AC 3.2**（中断終了時に worktree prune を 1 回実行）: `git -C "$REPO_DIR" worktree prune`
- **AC 3.3**（flock fd 200 の解放契約を従来どおり維持）: fd 200 は触れず、ハンドラ末尾 `exit` で
  OS が解放
- **AC 3.4**（既存サブシェル内ローカル trap の挙動を変更しない）: trap はトップレベルのみ。
  既存 trap 行（1174/1515/3128/3461/4748）は未変更
- **AC 3.5**（通常完了時の挙動・exit code を導入前と同一に保つ）: シグナル未受信時は trap が
  発火せず、既存の `_dispatcher_run` → `exit 0`（11743 行付近）/ `exit $DISPATCHER_RC` の経路を
  そのまま通る
- **NFR 2.2**（同一シグナル再送で prune 二重実行しない）: `_DISPATCHER_SIGNAL_HANDLED` ガードで
  1 回に制限。スモークで再送 3 回でも prune 1 回のみを確認（**GUARD_OK**）

### スモーク検証（Req 3）
- 再入ガードのユニットスモーク: ハンドラを 3 回（TERM/TERM/INT）呼んでも prune 相当処理が
  1 回のみ実行されることを確認（**GUARD_OK**）

## テスト・検証結果

1. **shellcheck**（NFR 3.1）: `shellcheck local-watcher/bin/issue-watcher.sh`
   - 変更前後で findings コード件数の diff を取得 → **NO_CODE_DIFF（新規 findings ゼロ）**
   - 既存 findings は SC2317（info 級、trap ハンドラ false positive）41 件のみ。本 repo は従来
     これらを許容（disable directive 不使用）
   - 新規追加した `_dispatcher_on_signal` も trap 経由 = SC2317 info を誘発するため、新規関数に
     `# shellcheck disable=SC2317` を 1 行付与して件数増を回避（warning/error/style 級の findings は
     変更前後とも 0 件）
2. **cron-like 最小 PATH 依存解決**: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git'`
   - `gh` / `jq` / `flock` / `git` は解決（exit 0）。`claude` は本検証環境の最小 PATH に不在
     （スクリプト冒頭 37 行の `export PATH="$HOME/.local/bin:..."` prepend で実 cron 環境では解決される。
     本変更は PATH prepend ロジックを触っていない）
3. **構文チェック**: `bash -n local-watcher/bin/issue-watcher.sh` → **SYNTAX_OK**
   - dry run（`$HOME/bin/issue-watcher.sh` の実行）は実環境を汚すため指示どおり実行せず
4. **Req 1 レース解消スモーク**: 即異常終了フックの stderr 末尾が同期捕捉で欠落しないこと
   （**TAIL_OK** / **RC_OK**）。検証スクリプトは削除済み（コミットせず）

## 受入基準カバレッジ一覧

| AC | 担保方法 |
|---|---|
| 1.1 | 既存 `tail -c 2000` 温存 + 同期化で末尾欠落解消（Req 1 スモーク TAIL_OK） |
| 1.2 | 同期リダイレクト `2>"$stderr_tmp"`（非同期 tee 排除） |
| 1.3 | 既存 `rm -f` / 正常時 ERROR 非出力を温存 |
| 1.4 | フック終了後 `cat "$stderr_tmp" >&2`（stderr 観測性維持） |
| 1.5 | `|| rc=$?` / `return 1\|0` 温存（exit code 意味不変） |
| 2.1 | 既存 `tee -a "$SLOT_LOG"` dual-write 温存 |
| 2.2 | 親終端 `wait` で確定（表示順序乱れは機能影響なし / 現状維持判断） |
| 2.3 | `SLOT_LOG` パス命名規約 未変更 |
| 3.1 | `_DISPATCHER_SLOT_PIDS` 各 PID へ `kill -TERM` |
| 3.2 | `git -C "$REPO_DIR" worktree prune` 1 回 |
| 3.3 | fd 200 flock 未変更（ハンドラ末尾 exit で OS 解放） |
| 3.4 | trap はトップレベルのみ（既存サブシェル trap 未変更） |
| 3.5 | シグナル未受信時は trap 不発（既存 exit 経路温存） |
| NFR 1.1/1.2/1.3 | env var 名 / exit code 意味 / ログ命名規約 すべて未変更 |
| NFR 2.1 | 冪等性: 追加処理は trap 発火時のみ。通常 cron 再実行で副作用なし |
| NFR 2.2 | `_DISPATCHER_SIGNAL_HANDLED` ガードで prune 二重実行防止（スモーク GUARD_OK） |
| NFR 3.1 | shellcheck 新規 findings ゼロ（NO_CODE_DIFF） |

## 確認事項（レビュワー判断ポイント）

1. **Req 2 を現状維持とした判断**: 上記「Requirement 2」の判断理由のとおり、確実な低リスク同期
   手法が無く機能影響も無いため現状維持とした。tee flush の同期化を将来別 Issue で扱うべきか、
   本判断で AC 2.1〜2.3 を充足とみなせるかはレビュワー / 人間の判断に委ねる
2. **shellcheck disable=SC2317 の新規導入**: 本 repo は従来 SC2317（trap ハンドラ false positive）を
   disable directive 無しで許容していたが、新規 trap ハンドラの件数増を「新規警告ゼロ」要件
   （NFR 3.1）に照らして避けるため、新規関数 1 か所のみに disable directive を付与した。既存
   コードのスタイル（directive 不使用）からの逸脱だが影響は新規関数に限定される
3. **Req 3 の exit code（130/143）**: 中断由来の終了は bash 慣例の 128+signal とした。NFR 1.2 の
   既存 exit code（0/1）は「シグナルを受けない通常完了時」の話であり、シグナル中断時の exit code は
   従来定義が無かった（trap 不在で bash デフォルト動作）。130/143 は bash デフォルトと整合する

## 設計成果物の有無
- design.md / tasks.md は本 Issue には存在しない（requirements.md のみ）。番号順タスク消化ではなく
  requirements.md の Requirement 1→3 を優先度順に実装した

STATUS: complete
