# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-05-26T14:28:00Z -->

## Reviewed Scope

- Branch: claude/issue-238-impl-feat-watcher-scaffolding-health-gate-wor
- HEAD commit: eca95c4d49496767f070284e331ca1e0ab12527b
- Compared to: main..HEAD
- 実質スコープ補足: 本ブランチは main から分岐後 main が先行（merge-base `6fcbec0`）して
  おり、`main..HEAD` 2-dot diff には他 spec の差分が「巻き戻し」として混入する。本レビューは
  本ブランチが実際に追加した変更（3-dot diff `main...HEAD`）を正本として判定した。実追加は
  `.shellcheckrc`（新規）/ `scaffolding-health.sh`（新規 368 行）/ `issue-watcher.sh`（48 行差分）/
  `README.md` / `test-fixtures/test-scaffolding-health.sh`（新規 206 行）/ `impl-notes.md` /
  `tasks.md`（全 task を done に更新）の 7 件。
- Feature Flag Protocol: CLAUDE.md 宣言値 `opt-out`。flag 観点（boundary 逸脱細目）は適用外。

## Verified Requirements

| AC | 判定 | 根拠 |
|---|---|---|
| 1.1 | カバー | `sh_preflight_gate "$WT"` が `_slot_run_issue` 内 `_worktree_inject_claude`（issue-watcher.sh:6848）直後・`_hook_invoke`（:6869）直前に挿入（:6855）。reset+注入完了直後・agent stage 前に検査 |
| 1.2 | カバー | `scaffolding-health.sh:203` missing 分岐で loud `sh_warn "足場欠落を検出: ${summary}"`（欠落内容含む >&2 出力）。test「missing で loud WARN を出力」PASS |
| 1.3 | カバー | `_sh_emit_visibility_signal`（:132-167）が `gh issue comment` で Issue 上に可視シグナルを残す。test「missing で可視シグナルを呼ぶ」PASS |
| 1.4 | カバー | 全分岐で `sh_log "outcome=..."` を出力し silent 握りつぶしを禁止（:198/210/214/223）。test full の outcome=pass PASS |
| 1.5 | カバー | full（rc=0）は NO-OP・WARN/コメント 0 で return 0（:196-200）。test「full は WARN なし・コメントなし」PASS |
| 2.1 | カバー | missing + `off` 等は `outcome=continue` で return 0（:213-216）。test「missing + HALT=off → 0(継続)」PASS |
| 2.2 | カバー | `on` 厳密一致で return 1（HALT）、call site で claim 系ラベル除去＋`return 0`（issue-watcher.sh:6855-6866、`claude-failed` 不付与）。test「HALT=on → 1(HALT)」PASS |
| 2.3 | カバー | 未設定/空/`On`/`true`/typo はすべて `*)` で continue。test 5 ケース（未設定/空/On/true/off）全 PASS |
| 3.1 | カバー | indeterminate（rc=2）は warn 残して return 0（:219-225）。test「indeterminate + HALT=on → 0」PASS |
| 3.2 | カバー | indeterminate 分岐で `sh_warn "足場検査が確定不能..."` ＋ `sh_log "outcome=continue scaffolding=indeterminate"` を可視出力（:222-223） |
| 3.3 | カバー | indeterminate は HALT opt-in でも停止に倒さず常に return 0。test「HALT=on でも 0」PASS |
| 4.1 | カバー | `sh_doctor_run` が env REPO/REPO_DIR で点検実施・レポート出力（:353-368）。doctor smoke で full レポート exit 0 を実機確認 |
| 4.2 | カバー | `sh_doctor_check_scaffolding`（:248-266）が `.claude/agents,rules` 到達性を点検。smoke「scaffolding: ok」 |
| 4.3 | カバー | `sh_doctor_check_clis`（:271-285）が gh/jq/flock/git/claude を `command -v` で点検。smoke「required CLIs: ok」 |
| 4.4 | カバー | `sh_doctor_check_labels`（:297-323）が `gh label list`（read-only）で必須ラベル集合点検。smoke「required labels: ok」 |
| 4.5 | カバー | `sh_doctor_check_base_branch`（:330-338）が `git rev-parse --verify`（read-only）で点検。smoke で degraded 経路（nonexistent-zzz）も確認 |
| 4.6 | カバー | `sh_doctor_run` がヘッダ＋各項目＋`RESULT: <full|degraded>` 一覧を出力。1 項目 degraded で全体 degraded（smoke 両経路確認） |
| 4.7 | カバー | 全点検 read-only。doctor smoke 実行前後で `git status --porcelain` 不変を実機確認。書き込み API 不使用 |
| 5.1 | カバー | tracked 運用（full）は gate NO-OP・WARN 0。test「full は WARN なし」PASS |
| 5.2 | カバー | 追加は `SCAFFOLDING_HEALTH_HALT` env 1 個＋`scaffolding-health.sh` の新 prefix のみ。既存 env 名/ラベル/exit code/ログ書式不変（diff で確認）。shellcheck クリーン |
| 5.3 | カバー | 可視シグナルはマーカー既存確認で重複抑止。test「既存マーカー検出で投稿抑止（冪等）」PASS。`sh_inspect_scaffolding` は純関数 |
| NFR 1.1 | カバー | full は NO-OP 通過・false positive WARN 0 件（test PASS） |
| NFR 2.1 | カバー | 全分岐 `outcome=pass|continue|halt` ログで分岐を事後判別可能 |
| NFR 3.1 | カバー | doctor はローカル検査主体・repo 1 件線形。smoke が数秒以内に完了 |
| NFR 4.1 | カバー | doctor 実行前後 git status 不変を実機確認、書き込み API 不使用 |
| NFR 5.1 | カバー | `sh_inspect_scaffolding` 純関数＋可視シグナル冪等。test PASS |

## Findings

なし（approve）。

## 前 round（round=1）指摘の解消状況

| 前 round Finding | 対象 AC | 解消状況 |
|---|---|---|
| Finding 1 | 1.1-1.4 | 解消。`sh_preflight_gate` / `_sh_emit_visibility_signal` を実装し call site（`_worktree_inject_claude` 直後・`_hook_invoke` 直前）へ結線済み |
| Finding 2 | 2.1-2.3 | 解消。`SCAFFOLDING_HEALTH_HALT="${...:-off}"` を Config に追加、`on` 厳密一致分岐を実装。HALT 値正規化 6 ケース test PASS |
| Finding 3 | 3.1-3.3 | 解消。indeterminate fail-open 分岐を gate に実装。HALT opt-in でも継続を test で確認 |
| Finding 4 | 4.1-4.7 | 解消。doctor 点検 4 関数＋`sh_doctor_run`＋`--doctor` dispatch を実装。full/degraded・read-only を実機 smoke で確認 |
| Finding 5 | 5.2, NFR 2.1 | 解消。`REQUIRED_MODULES` に `"scaffolding-health.sh"` 追加で source 済み。全分岐で `outcome=...` ログ出力 |
| Finding 6 | tasks.md 進捗 | 解消。task 1〜4.1 を `[x]`、deferrable test 5 も実装し `[x]*`→done。STATUS: complete |

## 検証実行ログ（reviewer 再実行）

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh`（tasks.md 構造化 verify ブロックと一致）→ 警告ゼロ
- `bash test-fixtures/test-scaffolding-health.sh` → PASS=21 FAIL=0（exit 0）
- doctor smoke（full）→ `RESULT: full` exit 0、git status 不変（read-only）
- doctor smoke（base 解決不能）→ `RESULT: degraded`

## Summary

Round 1 reject の Finding 1〜6 はすべて解消済み。preflight gate / 可視シグナル / HALT 切替 /
fail-open / doctor 一式 / 本体結線（task 2/3/4）が実装され、全 numeric AC（Req 1〜5・NFR 1〜5）が
実装またはテストでカバーされている。shellcheck 警告ゼロ、スモークテスト 21/21 PASS、doctor の
read-only を実機確認。boundary 逸脱なし。

RESULT: approve
