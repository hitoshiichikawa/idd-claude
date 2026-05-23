# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T11:24:37Z -->

## Reviewed Scope

- Branch: claude/issue-170-impl-bug-watcher-tee-stderr-flush-dispatcher
- HEAD commit: 0d6066d2842fbf959d5bc9e14077bfbe380f7981
- Compared to: HEAD~1..HEAD（実装差分は `local-watcher/bin/issue-watcher.sh` のみ。spec 2 ファイルは docs）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節なし → opt-out 扱い。flag 観点の確認は行わない（通常 3 カテゴリ判定）

## Verified Requirements

- 1.1 — 非ゼロ exit 時の `tail -c 2000 "$stderr_tmp"` 転記（issue-watcher.sh:10231）を温存。同期リダイレクト化でファイル確定後に読むため末尾欠落なし
- 1.2 — `2>"$stderr_tmp"`（10212）で非同期プロセス置換 `2> >(tee ...)` を排除。フック終了 = ファイル確定で flush レースを解消
- 1.3 — 正常時の `rm -f "$stderr_tmp"`（10241）温存。ERROR ログは `rc -ne 0` 時のみ出力（10228）で追加エラー出力なし
- 1.4 — フック終了後 `if [ -s "$stderr_tmp" ]; then cat "$stderr_tmp" >&2 || true; fi`（10216-10218）で stderr を運用者へ転記。観測性維持
- 1.5 — `... 2>"$stderr_tmp" || rc=$?`（10212）と末尾 `return 1 / return 0`（10245-10247）を変更せず exit code 意味を保持
- 2.1 — 既存 `exec > >(tee -a "$SLOT_LOG") 2>&1` の dual-write を温存（現状維持判断、informational）
- 2.2 — 親 Dispatcher 終端 `wait`（11786）で subshell + tee 終了を待ち合わせ、ファイル内容を最終確定。表示順序乱れは機能影響なし
- 2.3 — `SLOT_LOG` のパス命名規約 `slot-<slot>-<NUMBER>-<TS>.log` を未変更
- 3.1 — `_dispatcher_on_signal` が `_DISPATCHER_SLOT_PIDS` 各 PID へ `kill -TERM`（11592-11599）。`kill -0` で生存確認後に送信
- 3.2 — `git -C "$REPO_DIR" worktree prune`（11604）を 1 回実行（既存 idiom と同一）
- 3.3 — fd 200 flock（489-490）は未変更。ハンドラ末尾 `exit` でメインプロセス終了時に OS が解放（解放契約維持）
- 3.4 — trap はトップレベル（11614-11615）にのみ配置。既存サブシェル内ローカル trap（1174/1515/3128/3461/4748 行付近）の差分は diff hunk（@@ 10197 / @@ 11566 のみ）に含まれず未変更
- 3.5 — シグナル未受信時は trap 不発。既存 `_dispatcher_run` → `exit 0`（11803）/ `exit $DISPATCHER_RC`（11800）経路を温存
- NFR 1.1/1.2/1.3 — env var 名 / exit code 意味（0/1） / ログ命名規約 すべて未変更
- NFR 2.1 — 追加処理は trap 発火時のみ。通常 cron 再実行で副作用なし（冪等）
- NFR 2.2 — `_DISPATCHER_SIGNAL_HANDLED` ガード（11586-11589）で再入時 prune 二重実行を防止
- NFR 3.1 — shellcheck 非 SC2317 findings 件数 1→1 で不変（既存 SC2012 のみ、変更箇所外の 4448 行）。SC2317 件数 40→40 で不変（新規ハンドラへ `# shellcheck disable=SC2317` を 1 行付与）。`bash -n` SYNTAX_OK

## Findings

なし

## Summary

Req 1（stderr 同期捕捉）/ Req 3（Dispatcher シグナル trap）は全 AC を実装で充足し、exit code 取得（`|| rc=$?`）・stderr 観測性（cat 転記）・flock fd 200 解放契約・既存サブシェル trap・通常完了経路のいずれも非破壊で温存されている。重点確認項目 (A)(B)(C) はすべて問題なし: 同期リダイレクト化で exit code 取得と stderr 観測性は保たれ、trap はトップレベル限定で既存サブシェル trap と fd 200 に未介入、`_DISPATCHER_SIGNAL_HANDLED` で prune 二重実行を防止。Req 2 は「dual-write に tee が構造上必須・親終端 wait で内容確定・機能影響なし」を理由とする現状維持判断で AC 2.1〜2.3 を充足とみなせる（残る表示順序の同期化は別 Issue 候補として記録済み、本判定の reject 対象外）。shellcheck 新規 findings ゼロ・bash -n クリーンで NFR 3.1 も満たす。

RESULT: approve
