# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-27T11:35:00Z -->

## Reviewed Scope

- Branch: claude/issue-417-impl--bug-failed-recovery-processor-attempt-c
- HEAD commit: cca9b7025a3cff24b0928f3dfab37e8b6054656b
- Compared to: main..HEAD

変更ファイル（4 件）:

- `local-watcher/bin/modules/failed-recovery.sh`（+186/−2）
- `local-watcher/test/fr_terminate_idempotent_test.sh`（新規 +625 行 / 64 ケース）
- `local-watcher/test/fr_fetch_test.sh`（+24 行 / pass-through stub 追加）
- `docs/specs/417--.../impl-notes.md`（新規）

設計判断（仮案 C 両刀）:

1. `fr_is_terminated` 純粋関数を追加し state JSON の既存 `last_status` enum
   (`max-attempts` / `no-progress`) を判定
2. `fr_filter_terminated_candidates` を `fr_fetch_failed_issues` / `fr_fetch_failed_prs`
   末尾で適用（fetch 段階で物理除外 / Req 2.1〜2.6）
3. `fr_terminate_max_attempts` / `fr_terminate_no_progress` 冒頭にべき等ガード + 末尾に
   `fr_save_state` 永続化（Req 1.5 / 1.6 / 3.1〜3.3）

検証実行（reviewer 自身が確認）:

- `bash local-watcher/test/fr_terminate_idempotent_test.sh` → PASS=64 / FAIL=0
- `bash local-watcher/test/fr_fetch_test.sh` → PASS=42 / FAIL=0
- `bash local-watcher/test/fr_terminate_test.sh` → PASS=77 / FAIL=0
- `shellcheck` 警告ゼロ（failed-recovery.sh + 新規 / 改修 test 2 本）

## Verified Requirements

- 1.1 — `fr_terminate_max_attempts` 冒頭 `fr_is_terminated` ガード（failed-recovery.sh:1685〜1696）/ Section 3 (count=0 for gh issue comment / rs_set_result / sn_notify)
- 1.2 — `fr_terminate_no_progress` 冒頭 `fr_is_terminated` ガード（failed-recovery.sh:1781〜1791）/ Section 4
- 1.3 — cross-status ガード（last_status が max-attempts/no-progress いずれでも no-op）/ Section 5-A + 3 で生涯 1 件契約担保
- 1.4 — 同上 / Section 5-B + 4
- 1.5 — `fr_terminate_max_attempts` 末尾 `fr_save_state ... "max-attempts" ...`（failed-recovery.sh:1733〜1736）/ Section 2 で state JSON last_status 検証
- 1.6 — `fr_terminate_no_progress` 末尾 `fr_save_state ... "no-progress" ...`（failed-recovery.sh:1824〜1827）/ Section 9
- 2.1 — `fr_filter_terminated_candidates` で fetch 段階除外 → `fr_run_recovery_attempt` 自体不発火 / Section 7-B/7-G
- 2.2 — 同上（PR 経路 / Section 7-G）
- 2.3 — fetch 除外 + terminate ガード両方で抑止 / Section 3, 4, 7
- 2.4 — Section 3, 4 で `sn_notify` count=0 を assertion
- 2.5 — fetch 除外で `fr_run_recovery_attempt` → `fr_save_state` の attempt 加算経路自体起動しない / Section 7-B で除外確認
- 2.6 — Section 3, 4 で `rs_set_result` count=0 を assertion
- 3.1 — `fr_is_terminated` 純粋関数の 3 状態判定（max-attempts / no-progress / それ以外）/ Section 1-A〜1-H
- 3.2 — `fr_save_state` の atomic write が `$FAILED_RECOVERY_STATE_DIR`（`$HOME` 配下既定）で動作 / 既存 fr_state_test.sh + Section 2/9 で間接担保
- 3.3 — terminate 関数末尾で `fr_save_state` 呼び出し（同一サイクル内確定）/ Section 2/9 で state file 即時存在を検証
- 4.1 — `--remove-label claude-failed` 呼び出しを追加していない / Section 8-A で assert_not_grep
- 4.2 — 同上（既存 fr_terminate_test.sh + 本変更で remove-label 追加なし）
- 4.3 — Section 8-B（2 サイクル目でも remove-label 呼ばれず）
- 4.4 — 本変更は server-side filter `label:"claude-failed"` に手を入れず、人間がラベル除去すれば既存挙動で除外される
- 5.1 — `fr_is_terminated` が jq parse 失敗で rc=1 / Section 1-H + 6-B + 7-F
- 5.2 — `fr_load_state` が不在で `{}` を返す既存挙動を継承 / Section 6-A
- 5.3 — terminate 関数の return は 0 / `fr_save_state` 失敗時は `fr_warn` で記録のみ（failed-recovery.sh:1737, 1828）
- 6.1 — gate チェックは `process_failed_recovery` 冒頭で行われ early return（本変更で gate 外の経路追加なし。既存 fr_process_test.sh / fr_is_enabled_test.sh で間接担保）
- 6.2 — 同上（`FULL_AUTO_ENABLED` gate）
- 6.3 — 同上
- NFR 1.1 — Section 10 で `immediate_failure_streak` / `last_failure_signature` / `last_head_sha` / `total_attempts` の前回値継承検証
- NFR 1.2 — terminate コメント本文の `max-attempts` / `no-progress` 識別子据え置き（既存 fr_terminate_test.sh 継続 PASS）
- NFR 1.3 — Section 6-C で旧 schema（last_status 不在）を未終端扱いで fail-open
- NFR 1.4 — 新 env var 追加なし（diff 確認済）
- NFR 1.5 — terminate コメント本文未変更（既存 fr_terminate_test.sh PASS）
- NFR 2.1 — `fr_log` で `failed-recovery: <kind>=#<n> terminated reason=<status> suppressed=<...>` 1 行ログ / Section 3 (3 件), 4 (3 件), 7-B/7-G で assertion
- NFR 2.2 — 同上（reason 識別子文字列を含む）
- NFR 3.1 — `$FAILED_RECOVERY_STATE_DIR` 既存配置を継承（新規 path 追加なし）
- NFR 3.2 — terminate ログ / コメント / Slack detail に secrets / signature 全文を含めない（既存実装維持）
- NFR 3.3 — `fr_filter_terminated_candidates` 内で `[[ "$number" =~ ^[0-9]+$ ]]` 数値検証実装（failed-recovery.sh:347）

## Findings

なし。

## Summary

採用方針（仮案 C: terminate ガード + fetch 段階除外の二重防御）は AC の Req 2.x
（claude session 起動・着手コメント・attempt 加算・Slack 通知・run-summary 確定の全副作用
抑止）を満たすために必要であり、設計判断が妥当。既存 schema を変更せず last_status enum
を流用して NFR 1.1 後方互換を保ち、state 破損 / 欠落時は `fr_load_state` の `{}` 返却で
自然に fail-open する fail-continue 設計も Req 5.1〜5.3 と整合。524 tests 全 PASS、shellcheck
警告ゼロ。境界は failed-recovery.sh + その近接テスト + impl-notes に限定されており逸脱なし。

RESULT: approve
