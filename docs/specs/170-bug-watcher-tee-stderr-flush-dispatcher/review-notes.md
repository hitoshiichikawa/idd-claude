# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-23T11:40:00Z -->

## Reviewed Scope

- Branch: claude/issue-170-impl-bug-watcher-tee-stderr-flush-dispatcher
- HEAD commit: dddf78a7fba421fd527749f6128be2127ccc4a96
- Compared to: main..HEAD（実装差分は `local-watcher/bin/issue-watcher.sh` のみ。spec 3 ファイルは docs）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節なし → opt-out 扱い。flag 観点の確認は行わない（通常 3 カテゴリ判定）
- tasks.md: 本 Issue には存在しない（requirements.md のみ）。`_Boundary:_` 制約は無く、変更ファイルは watcher script に限定されることを diff で確認

## Verified Requirements

- 1.1 — 非ゼロ exit 時の `tail -c 2000 "$stderr_tmp"` 転記（issue-watcher.sh:10231）を温存。同期リダイレクト化により一時ファイル確定後に読むため末尾欠落なし
- 1.2 — `"$SLOT_INIT_HOOK" 2>"$stderr_tmp"`（10212）で非同期プロセス置換 `2> >(tee ...)` を排除。フック終了 = ファイル確定で flush レースを解消（diff hunk @@10197 で旧 tee 行が新リダイレクト行に置換されたことを確認）
- 1.3 — 正常終了時の `rm -f "$stderr_tmp"`（10241）を温存。ERROR ログは `rc -ne 0` 時のみ（10228-10238）で正常時に追加エラー出力なし
- 1.4 — フック終了後 `if [ -s "$stderr_tmp" ]; then cat "$stderr_tmp" >&2 || true; fi`（10216-10218）で stderr を運用者へ転記。旧 `tee >&2` と同等の観測性を維持
- 1.5 — `... 2>"$stderr_tmp" || rc=$?`（10212）と末尾 `return 1 / return 0`（10245-10247）を未変更。exit code 意味（0=成功/非ゼロ=失敗）を保持
- 2.1 — 既存 `exec > >(tee -a "$SLOT_LOG") 2>&1`（11098）の dual-write を温存（現状維持判断）。stdout（cron mailer）+ slot ログファイルの両書き出しを維持
- 2.2 — 親 Dispatcher 終端 `wait` で subshell + tee 子プロセス終了を待ち合わせ、ファイル内容を最終確定。表示順序の乱れは requirements 記載どおり機能影響なし（display quality）
- 2.3 — `SLOT_LOG="$LOG_DIR/slot-${IDD_SLOT_NUMBER}-${NUMBER}-${TS}.log"`（11096）の命名規約を未変更
- 3.1 — `_dispatcher_on_signal` が `_DISPATCHER_SLOT_PIDS` 各 PID へ `kill -0` 生存確認後に `kill -TERM`（11589-11598）
- 3.2 — `git -C "$REPO_DIR" worktree prune`（11604 付近）を 1 回実行（既存 idiom と同一）
- 3.3 — fd 200 flock（489-490）は未変更。ハンドラ末尾 `exit`（11608 付近）でメインプロセス終了時に OS が解放（解放契約維持）
- 3.4 — trap はトップレベル（`trap '_dispatcher_on_signal INT' INT` / `... TERM` 11614-11615 付近）のみ配置。既存サブシェル内ローカル trap（1174/1515/3128/3461/4748 行付近の rebase/revert/checkout 復帰）は diff hunk（@@10197 / @@11566 のみ）に含まれず未変更
- 3.5 — シグナル未受信時は trap 不発。既存 `_dispatcher_run`（11795）→ `exit $DISPATCHER_RC`（11800）/ `exit 0`（11804）経路を温存
- NFR 1.1 — 既存 env var 名（REPO / REPO_DIR / LOG_DIR / LOCK_FILE / SLOT_INIT_HOOK / PARALLEL_SLOTS）の名前・意味は未変更
- NFR 1.2 — 正常完了 exit 0 / 致命的失敗 exit 1 / 他インスタンス実行中スキップ exit 0（490-493）の意味を未変更。シグナル中断時の 130/143 は trap 不在時に bash デフォルトと整合する追加で既存規約に抵触しない
- NFR 1.3 — Issue ログ / slot ログのパス命名規約を未変更
- NFR 2.1 — 追加処理は trap 発火時のみ。通常 cron 再実行で副作用なし（冪等）
- NFR 2.2 — `_DISPATCHER_SIGNAL_HANDLED` ガード（11586-11589）で再入時 prune 二重実行を防止
- NFR 3.1 — 独立再実行で確認: `shellcheck` findings は main と HEAD で同一（SC2012 1 件 + SC2317 40 件、いずれも変更箇所外 or trap false positive）。新規ハンドラへの `# shellcheck disable=SC2317` 付与で件数増を回避。`bash -n` SYNTAX_OK

## Findings

なし

## Summary

Req 1（stderr 同期捕捉）と Req 3（Dispatcher シグナル trap）は全 AC を実装で充足し、独立に diff・該当行・shellcheck・bash -n を再検証した結果、exit code 取得 / stderr 観測性 / flock fd 200 解放契約 / 既存サブシェル trap / 通常完了経路のいずれも非破壊で温存されている。Req 2 は dual-write に tee が構造上必須・親終端 wait で内容確定・機能影響なし（display quality）を理由とする現状維持判断で、観測可能挙動を定める AC 2.1〜2.3（既存挙動の保持）は充足。shellcheck 新規 findings ゼロ・bash -n クリーンで NFR 3.1 も満たす。boundary 制約（tasks.md）は本 Issue に存在せず、変更は watcher script に限定されており逸脱なし。

RESULT: approve
