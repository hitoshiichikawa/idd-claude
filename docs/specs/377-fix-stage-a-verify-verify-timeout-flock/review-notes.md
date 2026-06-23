# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-377-impl-fix-stage-a-verify-verify-timeout-flock
- HEAD commit: 8f3a8a4ec993a757240692e2542381f092ac9055
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/stage-a-verify.sh`（+138/-29） /
  `local-watcher/test/stage_a_verify_timeout_pgkill_test.sh`（新規 346 行） /
  `README.md`（env 表 + TIMEOUT 説明節 + 機能一覧表更新） /
  `docs/specs/377-.../requirements.md`（新規） / `docs/specs/377-.../impl-notes.md`（新規）
- design.md / tasks.md は不在（Triage `needs_architect:false` 経路 = 単一実装パス）

## Verified Requirements

- **Req 1.1**（通常系 outcome 確定）— `stage_a_verify_run` の case "$rc" in 0/124/* 分岐
  （stage-a-verify.sh:1020-1069）が success / timeout / failed / warn-skipped の全 outcome を
  網羅維持。timeout_pgkill_test Case 2.1 で round1 outcome、Case 2.3 で success outcome を実測
- **Req 1.2**（exit 0 → success + reset_round）— stage-a-verify.sh:1022-1025 で
  `_SAV_LAST_OUTCOME=success` + `stage_a_verify_reset_round` を維持。Case 2.3 で確認
- **Req 1.3**（非ゼロ非 124 → `_sav_handle_failure` 経路維持）— stage-a-verify.sh:1041-1068
  の `*)` 分岐で `_sav_handle_failure "exit" "$rc"` を維持
- **Req 1.4**（`STAGE_A_VERIFY_ENABLED=false` → no-op）— Gate 1（stage-a-verify.sh:927-931）
  非変更。`_SAV_LAST_OUTCOME=disabled` 維持
- **Req 2.1**（孫プロセス hang を wall-clock 内で kill）— `_sav_exec_with_timeout` の
  `setsid timeout --kill-after=... --signal=TERM ...` + 復帰後 `kill -KILL -- -<pgid>`
  二段防御（stage-a-verify.sh:858-895）。timeout_pgkill_test Case 1.3（`sleep infinity & wait`）
  で wall-clock <= 8s を実測
- **Req 2.2**（有限時間内に呼び出し元復帰、flock 解放維持）— tempfile 直書き + pgid kill により
  process substitution 経由の永久 wait が排除。Case 1.2 / 1.3 / 2.1 で wall-clock <= 8s
- **Req 2.3**（timeout → exit 124、既存 `_sav_handle_failure "timeout"` 経路）—
  stage-a-verify.sh:1027-1040 の `124)` 分岐維持。Case 2.1 で rc=1 (round1) outcome を実測
- **Req 2.4**（SIGTERM → grace 後 SIGKILL）— `timeout --kill-after="${_kill_after}" --signal=TERM`
  で確保（stage-a-verify.sh:866-867）。Case 1.2 で rc=124/137 を確認
- **Req 2.5**（復帰時点で pgid 配下に残存プロセスなし）— stage-a-verify.sh:889-891 で
  `kill -KILL -- "-${_child_pid}"` を rc=124/137 時に best-effort broadcast。
  timeout_pgkill_test Case 1.3 で `ps -A` による残存検査 PASS
- **Req 3.1**（大量出力時に signal 伝播阻害なし）— `>"$_stdout_path" 2>"$_stderr_path"` の
  直接 redirect（stage-a-verify.sh:868）。Case 1.4（`yes | head -n 100000`）で wall-clock <= 5s
- **Req 3.2**（subshell EOF 永久 wait を不採用）— process substitution `> >(...)` を完全廃止
  し、tempfile 経由に置換（旧 stage-a-verify.sh:880-895 の `tee` 配置を削除）
- **Req 3.3**（stdout/stderr を $LOG に append、grep 経路維持）— stage-a-verify.sh:1003-1008
  で `cat "$_stdout_path" >> "$LOG"` / `cat "$_stderr_path" >> "$LOG"` を実施
- **Req 3.4**（stderr 独立捕捉で #364 path-missing 判定維持）— `_stderr_text=$(cat ...)`
  （stage-a-verify.sh:1011-1014）を維持し、`_sav_is_path_missing_diff_failure` / 
  `_sav_extract_missing_path` 経路（stage-a-verify.sh:1049-1056）非変更。
  path_missing_test PASS=43/FAIL=0 で回帰なし
- **Req 4.1**（診断 1 行に issue/cmd/timeout/kill_after/elapsed）— stage-a-verify.sh:1030
  `sav_warn "TIMEOUT timeout=${_timeout}s kill_after=${_kill_after}s elapsed=${_elapsed}s exit=124 cmd=..."`。
  Case 2.1 で 4 要素 grep 確認
- **Req 4.2**（既存 prefix `[HH:MM:SS] stage-a-verify:` 維持 + `TIMEOUT` キーワード grep 可）—
  `sav_warn` 経由で既存 prefix 保持。Case 2.1 で `stage-a-verify: WARN: TIMEOUT` grep PASS
- **Req 4.3**（cmd を `printf '%q'` でエスケープ）— stage-a-verify.sh:1030 / 969 / 1056 の
  全 cmd 埋め込み箇所で `printf '%q' "$cmd"` を維持
- **Req 5.1**（既存 env 名・既定値・解釈不変）— Config ブロック（`STAGE_A_VERIFY_ENABLED` /
  `STAGE_A_VERIFY_TIMEOUT:-600` / `STAGE_A_VERIFY_COMMAND` / `STAGE_A_VERIFY_STATE_DIR`）非変更
- **Req 5.2**（新規 env 未設定時に従来挙動再現）— `STAGE_A_VERIFY_KILL_AFTER:-10` で旧
  ハードコード `--kill-after=10` と byte-equivalent。Case 2.2 で `kill_after=10s` 確認
- **Req 5.3**（outcome 値域 success/skip/disabled/round1/round2/warn-skipped 不変）—
  各 `_SAV_LAST_OUTCOME` 代入箇所（929 / 939 / 958 / 1024 / 1036-1037 / 1058 / 1065-1066）非変更
- **Req 5.4**（return code 契約 0/1=round1/2=round2 不変）— 全 `return` 箇所維持。
  Case 2.1 で rc=1、Case 2.2/2.3 で rc=0 を実測
- **Req 5.5**（ログ prefix 不変）— `sav_log` / `sav_warn` / `sav_error` 定義非変更
- **NFR 1.1**（shellcheck 警告ゼロ）— impl-notes §3.1 で OK 確認
- **NFR 1.2**（bash -n）— impl-notes §3.1 で OK 確認
- **NFR 2.1**（agents/rules 同期）— 該当ディレクトリ非変更 / impl-notes §3.4 `diff -r` 空
- **NFR 2.2**（README 同 PR 反映）— README L1341 / L5050 / L5267 周辺に env 行追加 +
  TIMEOUT 説明節更新
- **NFR 3.1**（hang cmd の有限時間復帰 + 残存無し 1 件以上）— timeout_pgkill_test
  Case 1.2 / 1.3 / 2.1 で充足
- **NFR 3.2**（大量出力 + hang の有限時間復帰 1 件以上）— Case 1.4（100000 行出力で
  wall-clock <= 5s）で充足
- **NFR 3.3**（extract_function イディオム / 副作用 stub）— `source "$MODULE_SH"` 経由で
  関数定義のみロード、`gh` / `mark_issue_failed` を stub（test Section 2 冒頭）
- **NFR 4.1**（未信頼 cmd の quote / `printf '%q'`）— EXEC / TIMEOUT / WARN 全ログで `%q` 適用
- **NFR 4.2**（mktemp）— `_stdout_path=$(mktemp)` / `_stderr_path=$(mktemp)` で予測不能名
- **NFR 5.1**（運用復帰手順を impl-notes に明記）— impl-notes §5 で「暫定
  `STAGE_A_VERIFY_ENABLED=false` 撤去 / SUCCESS elapsed grep / flock 健全性確認」を提示

## Findings

なし

## Summary

`setsid + pgid kill` の二段防御と process substitution 廃止（tempfile 直書き）により
#374 の deadlock 根本原因 (A)(B) を構造的に解消。新規 env `STAGE_A_VERIFY_KILL_AFTER`
（既定 10）で旧ハードコードと byte-equivalent な後方互換を維持し、既存 outcome /
return code / ログ prefix 契約も完全保持。timeout_pgkill_test の 23 ケース（孫 hang /
大量出力 / WARN ログ 4 要素 grep / 既定 kill_after 確認）で全 AC を実測カバー、既存
path_missing_test (43/0) / round1_defer_test (8/0) で回帰なし。boundary 逸脱なし。

RESULT: approve
