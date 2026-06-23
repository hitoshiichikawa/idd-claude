# impl-notes: fix(stage-a-verify) verify コマンドの timeout 不発によるデッドロック修正（#377）

## 1. 実装サマリ

| ファイル | 変更概要 |
|---|---|
| `local-watcher/bin/modules/stage-a-verify.sh` | `_sav_exec_with_timeout` ヘルパー新設（setsid + timeout 二段防御 + tempfile 直書き）/ `stage_a_verify_run` の Execute ブロックを当該ヘルパー経由に書き換え / 新規 env `STAGE_A_VERIFY_KILL_AFTER`（既定 10）を追加 / TIMEOUT WARN ログに `elapsed=<秒>s kill_after=<秒>s` を追加 / SUCCESS / EXEC ログにも `elapsed`・`kill_after` を併記 |
| `local-watcher/test/stage_a_verify_timeout_pgkill_test.sh` | 新規。`_sav_exec_with_timeout` の単体テスト 4 ケース + `stage_a_verify_run` 統合 3 ケース（核心 AC は `sleep infinity` / 孫 hang / 大量出力で wall-clock 復帰 + pgid kill 検証） |
| `README.md` | `STAGE_A_VERIFY_KILL_AFTER` を env テーブルに追記 / TIMEOUT 説明節を新実装に整合（setsid + pgid kill + tempfile / WARN ログフォーマット明記） / Stage A Verify Gate 行に `KILL_AFTER` を併記 |

## 2. 設計判断ログ

### 2.1 setsid + pgid kill の二段防御を採用した理由（Req 2.1, 2.4, 2.5）

- 旧実装: `timeout --kill-after=10 "$_timeout" bash -c "$cmd"` は `timeout` の直接の子（bash）にしか SIGTERM/SIGKILL を送らない。bash が spawn した孫（shellcheck、`sleep infinity` 等）は signal を受け取らない経路があり、孫が pipe write-end を握ったまま残ると親の wait が永久にブロックされる事象を #374 で観測（watcher が 1h21m hang）。
- 新実装: `setsid timeout ... bash -c "..."` で verify cmd を新規 session（pgid leader）として起動し、復帰後（rc=124 / 137）に `kill -KILL -- -<pgid>` を best-effort で broadcast する。setsid 直後の child pid が session leader 兼 pgid と一致するため、`kill -- -$_child_pid` で session 配下を一括 kill 可能。
- 代替案として `timeout --foreground` を検討したが、`--foreground` は親 session 内で signal forwarding する設計で、setsid と組み合わせるとむしろ kill-after の SIGKILL が届かないケースがあるため不採用。「setsid で session 切り離し + 自己責任で pgid kill broadcast」が最も堅牢。

### 2.2 出力経路を process substitution → tempfile 方式へ変更した理由（Req 3.1〜3.4）

- 旧実装: `> >(tee -a "$LOG" >/dev/null) 2> >(tee -a "$LOG" "$_stderr_path" >/dev/null)` の process substitution は subshell が pipe の read-end を握り続けるため、孫が write-end を握ったまま残ると tee が EOF を受け取れず subshell が `wait` に入って永久ブロック。これが #374 デッドロックの直接原因（要件 §Introduction の (B)）。
- 新実装: stdout / stderr 両方を `>"$_stdout_path"` `2>"$_stderr_path"` の **直接 redirect** に変更。一時ファイル経由なら write block が起きず、timeout signal の伝播が一切阻害されない。verify 完了後（rc 確定後）に両 tempfile を `cat >> "$LOG"` で append して既存 grep 経路（`grep '\[.*\] stage-a-verify:'` / FAILED / TIMEOUT 行抽出）を温存（Req 3.3）。
- stderr_text は #364 のパス不在 WARN 降格判定（`_sav_is_path_missing_diff_failure` / `_sav_extract_missing_path`）が必要とするため、tempfile から `cat` で読み込んで既存変数経路へ流す。上流の純粋関数は無修正で済む（Req 3.4）。
- tempfile は `mktemp` で予測不能名（NFR 4.2 / CLAUDE.md §5/§6）。verify 後に `rm -f` で確実に削除。

### 2.3 新規 env `STAGE_A_VERIFY_KILL_AFTER` の既定値と後方互換性（Req 5.1, 5.2）

- 既定値 `10` は現行ハードコード `--kill-after=10` と完全同値。未設定時の挙動は本機能導入前と byte-equivalent に等価。
- 既存 env（`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND` / `STAGE_A_VERIFY_STATE_DIR`）は名称・既定値・解釈すべて据え置き（Req 5.1 / NFR 1.1）。
- `_SAV_LAST_OUTCOME` の値域（`success` / `skip` / `disabled` / `round1` / `round2` / `warn-skipped`）と `stage_a_verify_run` の return code 契約（0/1/2）も完全保持（Req 5.3, 5.4）。
- ログ prefix `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` も保持（Req 5.5）。

### 2.4 `_sav_exec_with_timeout` ヘルパー切り出しの理由（NFR 3.1, 3.3）

- 既存 `stage_a_verify_run` は call site 依存（`REPO_DIR` / `LOG` / `STAGE_A_VERIFY_*` / cross-module `mark_issue_failed`）が多く、隔離テストが困難。Execute ブロックの timeout/pgkill ロジックだけを純粋に検証可能な形で切り出すため `_sav_exec_with_timeout(cmd, timeout, kill_after, stdout_path, stderr_path)` を独立関数として配置。
- 結果は `_SAV_LAST_EXEC_RC` / `_SAV_LAST_EXEC_ELAPSED` の global で露出（命名は `_SAV_RESOLVED_SOURCE` / `_SAV_LAST_OUTCOME` の既存規約と整合）。caller は `|| rc=$?` で戻り値も同時取得可能。
- テストは `_sav_exec_with_timeout` の単体ケース（正常系 / hang / 孫 hang / 大量出力）+ `stage_a_verify_run` 統合ケース（TIMEOUT WARN ログ / 既定 KILL_AFTER / SUCCESS elapsed）の 2 段構成で AC を網羅。

### 2.5 観測性ログ拡張（Req 4.1〜4.3）

- TIMEOUT WARN: `TIMEOUT timeout=${_timeout}s kill_after=${_kill_after}s elapsed=${_elapsed}s exit=124 cmd=$(printf '%q' "$cmd")` の 1 行に拡張。事後解析で「設定値に対して実際何秒で kill されたか」「どの cmd が hang したか」が即座に特定可能。
- SUCCESS: `SUCCESS exit=0 elapsed=${_elapsed}s` に変更し、verify 所要時間の定常観測を容易化。
- EXEC: `EXEC issue=#... timeout=...s kill_after=...s cmd=...` に `kill_after` を追加し、起動時パラメータの完全可視化。
- 経過秒は `date +%s` 差分で計測（`$SECONDS` は subshell 越えで巻き戻る可能性があるため不採用）。

## 3. テスト結果

### 3.1 静的解析

```
$ shellcheck local-watcher/bin/modules/stage-a-verify.sh \
             local-watcher/test/stage_a_verify_timeout_pgkill_test.sh \
             local-watcher/test/stage_a_verify_path_missing_test.sh \
             local-watcher/test/stage_a_verify_round1_defer_test.sh
shellcheck OK ALL

$ bash -n local-watcher/bin/modules/stage-a-verify.sh
$ bash -n local-watcher/test/stage_a_verify_timeout_pgkill_test.sh
bash -n OK
```

### 3.2 既存テスト（回帰なし）

- `bash local-watcher/test/stage_a_verify_path_missing_test.sh` → **PASS=43 FAIL=0**（#364 の WARN 降格判定が新実装下でも全件 pass）
- `bash local-watcher/test/stage_a_verify_round1_defer_test.sh` → **PASS=8 FAIL=0**

### 3.3 新規テスト

- `bash local-watcher/test/stage_a_verify_timeout_pgkill_test.sh` → **PASS=23 FAIL=0**
  - 核心 AC: `sleep infinity` を timeout=2s/kill_after=1s で起動 → wall-clock 2 秒で rc=124 復帰、`_SAV_LAST_EXEC_ELAPSED=2`
  - 孫 hang: `sleep infinity & wait` → wall-clock 2 秒復帰、テスト pid 配下に `sleep infinity` 残存ゼロ（pgid kill 機能確認）
  - 大量出力: `yes | head -n 100000` → deadlock せず wall-clock 0 秒で完走、100000 行 stdout 確保
  - TIMEOUT WARN ログに `timeout=2s` / `kill_after=1s` / `elapsed=` の 3 要素含有を grep で確認
  - 既定 `STAGE_A_VERIFY_KILL_AFTER` 未設定で `kill_after=10s` が EXEC ログに記録（後方互換）

### 3.4 二重管理同期

```
$ diff -r .claude/agents repo-template/.claude/agents
agents diff empty
$ diff -r .claude/rules repo-template/.claude/rules
rules diff empty
```

`local-watcher/bin/modules/stage-a-verify.sh` は consumer 配布物ではなく local-watcher 専用のため、root↔repo-template 同期対象外（NFR 2.1 該当外）。

## 4. AC 充足マッピング

| 要件 ID | 充足箇所 | 検証 |
|---|---|---|
| Req 1.1〜1.4（通常系維持） | `stage_a_verify_run` の Gate 1/2/3 + Execute 結果分岐ロジック非変更 | path_missing test Section 3 / timeout_pgkill test Case 2.2, 2.3 / round1_defer test 全 8 件 |
| Req 2.1（孫 hang を wall-clock 内で kill） | `_sav_exec_with_timeout` の setsid + `kill -KILL -- -<pgid>` | timeout_pgkill test Case 1.2, 1.3, 2.1 |
| Req 2.2（有限時間内に復帰、flock 解放） | tempfile 直書き + pgid kill | timeout_pgkill test Case 1.2/1.3/2.1 で wall-clock <= 8s 検証 |
| Req 2.3（rc=124 として既存経路） | `stage_a_verify_run` の `case "$rc" in 124)` 分岐維持 | timeout_pgkill test Case 2.1 で rc=1 (round1) outcome |
| Req 2.4（grace 後 SIGKILL） | `timeout --kill-after="${_kill_after}" --signal=TERM` を維持 | timeout_pgkill test Case 1.2 rc=124 |
| Req 2.5（復帰時点で残存プロセスなし） | rc=124/137 時の pgid broadcast kill | timeout_pgkill test Case 1.3 で `ps -A` 残存検査 |
| Req 3.1〜3.4（パイプ deadlock 回避） | process substitution 完全廃止、tempfile 直書き + `cat >> "$LOG"` で append | timeout_pgkill test Case 1.4（100000 行出力で wall-clock 0s 復帰）/ path_missing test Section 3 で stderr 解析経路継続動作確認 |
| Req 4.1（診断 1 行に issue/cmd/timeout/kill_after 含む） | `sav_warn "TIMEOUT timeout=...s kill_after=...s elapsed=...s exit=124 cmd=..."` | timeout_pgkill test Case 2.1 で 3 要素 grep 確認 |
| Req 4.2（既存 prefix 維持 + `TIMEOUT` キーワード grep 抽出可） | `sav_warn` 経由で既存 prefix 保持 | timeout_pgkill test Case 2.1 で `stage-a-verify: WARN: TIMEOUT` grep |
| Req 4.3（cmd を `printf '%q'` でエスケープ） | `cmd=$(printf '%q' "$cmd")` を WARN ログに直接埋め込み | shell エスケープ目視確認 |
| Req 5.1（既存 env 名・既定値・解釈不変） | Config ブロック非変更（`STAGE_A_VERIFY_TIMEOUT` 既定 600 含む） | path_missing test 全件 + round1_defer test 全件 |
| Req 5.2（新規 env 未設定時の従来挙動再現） | `STAGE_A_VERIFY_KILL_AFTER="${...:-10}"` 既定 10 | timeout_pgkill test Case 2.2 で `kill_after=10s` 確認 |
| Req 5.3（outcome 値域不変） | `_SAV_LAST_OUTCOME` 設定箇所すべて維持 | path_missing test Req 4.4 全件 / timeout_pgkill test Case 2.1 outcome=round1 |
| Req 5.4（return code 契約不変） | case 分岐の return rc/_hf_rc 維持 | path_missing test 各 case rc 検証 / timeout_pgkill test Case 2.1 rc=1 |
| Req 5.5（ログ prefix 不変） | `sav_log` / `sav_warn` / `sav_error` の prefix 形式非変更 | grep 経路（`stage-a-verify:`）で抽出継続 |
| NFR 1.1（shellcheck 警告ゼロ） | `if`-then-else 構造で SC2015 解消 | `shellcheck` クリーン |
| NFR 1.2（bash -n） | 構文 OK | `bash -n` クリーン |
| NFR 2.1（root↔repo-template 同期） | agents/rules 未変更（local-watcher のみ） | `diff -r` 空 |
| NFR 2.2（README 同 PR 反映） | env 表 / TIMEOUT 説明 / 機能一覧表を本 PR で更新 | README L1341 / L5050 / L5267 周辺 |
| NFR 3.1（hang cmd の有限時間復帰 + 残存無し 1 件以上） | timeout_pgkill test Case 1.2, 1.3, 2.1 | 3 ケースで充足 |
| NFR 3.2（大量出力 + hang の有限時間復帰 1 件以上） | timeout_pgkill test Case 1.4 | 100000 行出力で 0 秒復帰 |
| NFR 3.3（extract_function イディオム / 副作用 stub） | `source` + `gh` / `mark_issue_failed` stub | timeout_pgkill test Section 2 |
| NFR 4.1（未信頼 cmd の quote / `printf '%q'`） | WARN ログ・EXEC ログとも `printf '%q' "$cmd"` を維持 | コード目視確認 |
| NFR 4.2（mktemp 採用） | `_stdout_path=$(mktemp)` / `_stderr_path=$(mktemp)` | コード目視確認 |
| NFR 5.1（運用手順を impl-notes に明記） | 本ファイル §5 | 下記 §5 参照 |

## 5. 運用復帰手順（merge & deploy 後）

本 PR を main に merge し、`install.sh --local` 等で `$HOME/bin/modules/stage-a-verify.sh` へ反映後、以下を実施:

1. **暫定 opt-out の撤去**: idd-claude の cron / launchd で暫定的に `STAGE_A_VERIFY_ENABLED=false` を入れている場合、当該 env を削除（または `true` に明示）して stage-a-verify を再有効化する。
2. **動作確認**: 次回 cron tick 以降のログで以下を確認:
   - `grep '\[.*\] stage-a-verify: SUCCESS exit=0 elapsed=' $HOME/.issue-watcher/log/cron.log` が成功 verify ごとに 1 行記録されている
   - `grep '\[.*\] stage-a-verify: WARN: TIMEOUT' $HOME/.issue-watcher/log/cron.log` がない（hang が発生していない）
   - 万一 TIMEOUT が出ても `elapsed=` が `STAGE_A_VERIFY_TIMEOUT + STAGE_A_VERIFY_KILL_AFTER` 以内（既定なら 610 秒以内）に収まっている
3. **flock 健全性**: `ls -la /tmp/issue-watcher-*-idd-claude.lock` で lock が長時間保持されていないことを確認。watcher が hang していなければ lock は短時間で解放される。
4. **必要に応じて `STAGE_A_VERIFY_KILL_AFTER` 調整**: 既定 10 秒で SIGKILL 到達しない希少ケース（巨大 fork 木 / 大量孫プロセス）が確認できれば env で延長可能（通常変更不要）。

## 6. 確認事項

なし（要件は明確で、本実装はそのまま満たしている）。

設計判断 §2.1〜§2.5 はすべて要件本文の Open Questions（出力経路の具体実装 / setsid invocation 形式 / grace 値据え置きの選択）に Developer 判断として委ねられた範囲内。grace 値は既定 10 を据え置き（env 化のみ実施）した。
