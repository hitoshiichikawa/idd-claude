# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-359-impl-feat-watcher-failed-recovery-sh-claude-f
- HEAD commit: e90edddcd8ce95f60094c1f413a7c019c517fd9f
- Compared to: main..HEAD
- Feature Flag Protocol: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節は不在のため、通常の 3 カテゴリ判定（AC 未カバー / missing test / boundary 逸脱）のみ適用

## Verified Requirements

- 1.1 — `fr_is_enabled` 厳密 `=true` AND 評価（modules/failed-recovery.sh:58-62）、call site が `process_pr_iteration` 直後に追加（issue-watcher.sh:1409）。`fr_is_enabled_test.sh` 両 ON 経路で 0 を返す（Section 6）
- 1.2 — `fr_is_enabled` で `FAILED_RECOVERY_ENABLED!=true` のとき return 1、`process_failed_recovery` 冒頭で `return 0`（modules/failed-recovery.sh:1338-1340）。`fr_process_test.sh` Section 1
- 1.3 — `fr_is_enabled` で `FULL_AUTO_ENABLED!=true` のとき return 1（modules/failed-recovery.sh:60）。`fr_is_enabled_test.sh` で確認
- 1.4 — gate OFF 時 `process_failed_recovery` が gh API を呼ばず即 return（`fr_process_test.sh` Section 1）。既存 claude-failed 手動運用と等価
- 1.5 — Config 正規化 case で `=true` 厳密一致以外を `false` に倒す（issue-watcher.sh:506-509）。`fr_is_enabled_test.sh` で `True` / `TRUE` / `1` / `on` / `yes` / typo を OFF として検証
- 2.1 — `fr_fetch_failed_issues` の `--search 'label:"claude-failed" label:"auto-dev"'`（modules/failed-recovery.sh:275）。`fr_fetch_test.sh` 検索クエリ verify
- 2.2 — `claude-failed + auto-dev` のラベル組み合わせのみで対象化しており、付与経緯（reviewer-reject か mark_issue_failed か）を区別しない実装。impl-notes 確認済み
- 2.3 — `fr_fetch_failed_prs` で `claude-failed` PR を server-side で抽出し、`autoMergeRequest != null` AND CI rollup に FAILURE/TIMED_OUT を client-side filter（modules/failed-recovery.sh:391-404）
- 2.4 — `-label:"needs-decisions" -label:"needs-quota-wait" -label:"blocked" -label:"awaiting-slot"` を server-side filter で除外（modules/failed-recovery.sh:275, 326）。Req 2.4 が言及する `hold` ラベルはラベルセット未定義のため除外対象に含まず、`needs-decisions` で代替（design.md / impl-notes の確認事項参照）
- 2.5 — `label:"auto-dev"` を必須条件として AND 結合（Issue 経路、modules/failed-recovery.sh:275）。`fr_fetch_test.sh` verify
- 3.1 — `fr_collect_issue_context` + `fr_invoke_claude`（fresh session）で claude-failed Issue を解析（modules/failed-recovery.sh:557-595, 736-782）。`fr_run_recovery_attempt` が orchestrate
- 3.2 — `fr_collect_pr_ci_context` で `gh pr checks` + `gh run view --log-failed`、`fr_invoke_claude` で修正コミット push（modules/failed-recovery.sh:614-697）
- 3.3 — `fr_run_recovery_attempt` が着手コメント + 結果コメント（success/quota/failure それぞれ 1 件）を投稿（modules/failed-recovery.sh:1052-1103）。`fr_attempt_test.sh` Section 4 で件数検証
- 3.4 — `fr_finalize_success` が `gh issue/pr edit --remove-label`（modules/failed-recovery.sh:909-914）。`fr_attempt_test.sh` Section 5
- 3.5 — `jq --arg` / `--argjson` 経由展開、`^[0-9]+$` / `^[0-9a-f]{40}$` ガード（modules/failed-recovery.sh:561, 618, 902, 1037）
- 4.1 — `total_attempts` フィールドを `FAILED_RECOVERY_MAX_ATTEMPTS` 上限で管理（modules/failed-recovery.sh:139-228, 816-820）
- 4.2 — `fr_run_recovery_attempt` が `new_total = prev + 1` を計算し、着手直後に `fr_save_state` で in-progress 永続化（modules/failed-recovery.sh:1051-1062）。`fr_attempt_test.sh` Section 2 で順序検証
- 4.3 — `fr_load_state` は独自 JSON のみ読み、Reviewer / pr-iteration marker を一切読まない。`gh pr view` の用途は head_sha 取得のみ（modules/failed-recovery.sh:1027-1030）。`fr_attempt_test.sh` Section 6 で trace 全体に該当文字列が出ないこと検証
- 4.4 — `fr_should_recover` の `[ "$total" -lt "$FAILED_RECOVERY_MAX_ATTEMPTS" ]` 判定（modules/failed-recovery.sh:816-820）
- 4.5 — `fr_run_recovery_attempt` が上限到達時 return 2、`_fr_dispatch_candidate` が `fr_terminate_max_attempts` を呼ぶ。`claude-failed` ラベルは除去しない（modules/failed-recovery.sh:1139-1178）。`fr_terminate_test.sh` 確認
- 4.6 — `fr_terminate_max_attempts` で `rs_set_result "claude-failed"` を 1 度呼び、terminate コメント 1 件投稿（modules/failed-recovery.sh:1162-1175）。`fr_terminate_test.sh` Section 7
- 4.7 — `FAILED_RECOVERY_STATE_DIR` 既定 `$HOME/.issue-watcher/failed-recovery/$REPO_SLUG`（issue-watcher.sh:530）、`fr_state_path` でファイル指定（modules/failed-recovery.sh:90-93）
- 4.8 — Config 正規化で非整数 / 0 以下を 4 に正規化（issue-watcher.sh:512-519）。`fr_state_test.sh` Section 11 で 9 ケース間接検証
- 5.1 — `fr_run_recovery_attempt` で `fr_compute_failure_signature` 計算 → `fr_detect_no_progress` 判定（modules/failed-recovery.sh:1020-1047）
- 5.2 — `fr_detect_no_progress` が signature 一致 + (PR 経路は head_sha 一致 / Issue 経路は signature のみ) で no-progress 判定（modules/failed-recovery.sh:488-529）。`fr_no_progress_test.sh` 5 ケース
- 5.3 — `fr_terminate_no_progress` で `claude-failed` 据え置き + コメント 1 件投稿（modules/failed-recovery.sh:1218-1225）。`fr_terminate_test.sh`
- 5.4 — `fr_terminate_no_progress` で `rs_set_result "claude-failed"` を 1 度呼ぶ（modules/failed-recovery.sh:1230）
- 5.5 — `fr_save_state` で `last_failure_signature` / `last_head_sha` を JSON 永続化（modules/failed-recovery.sh:139-228）
- 6.1 — `fr_finalize_success` が `FR_PROCESSED_THIS_CYCLE` に "<kind>:<number>" を append、`fr_run_recovery_attempt` 冒頭で case match check（modules/failed-recovery.sh:918-925, 982-988）。`fr_attempt_test.sh` Section 5
- 6.2 — `fr_finalize_success` で `fr_save_state` に `last_status="succeeded"` を渡す（modules/failed-recovery.sh:929）
- NFR 1.1 — 既存 env var (`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `FULL_AUTO_ENABLED` 等) の名称・意味に変更なし。新規 env のみ追加（issue-watcher.sh:489-530）
- NFR 1.2 — 既存ラベル (`claude-failed` / `auto-dev` / `needs-quota-wait` / `needs-decisions`) の付与契約に変更なし。新規ラベル追加なし
- NFR 1.3 — gate off で外部副作用ゼロ（`fr_process_test.sh` Section 1 で gh / claude stub が呼ばれないことを assertion）
- NFR 2.1 — `FR_PROCESSED_THIS_CYCLE` in-memory set + 既存 flock 境界で同一サイクル重複起動を防止（modules/failed-recovery.sh:982-988, 916-925）
- NFR 2.2 — `$HOME/.issue-watcher/failed-recovery/<repo-slug>/<N>.json` で永続化、`fr_load_state` で次サイクル resume（modules/failed-recovery.sh:102-118）
- NFR 2.3 — `mktemp` 同一 dir + `mv -f` atomic rename で TOCTOU 安全（modules/failed-recovery.sh:212-226）。`fr_state_test.sh` で検証
- NFR 3.1 — すべての `jq` 呼び出しが `--arg` / `--argjson` 経由、ID / SHA を `^[0-9]+$` / `^[0-9a-f]{40}$` で使用直前検証（modules/failed-recovery.sh:561, 618, 850, 902, 974, 1037）
- NFR 3.2 — コメント本文は `printf '%s'` で値埋め込み、env 値（`$GH_TOKEN` 等）を本文に出さない。prompt にも secrets を含めず（modules/failed-recovery.sh:1052-1103）
- NFR 4.1 — `fr_log` が `[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery:` 3 段 prefix（core_utils.sh:148-150）。terminate ログに `kind=#N reason=...` 形式（modules/failed-recovery.sh:1175, 1238）
- NFR 4.2 — terminate 両経路で `rs_set_result "claude-failed"` を 1 度呼ぶ（modules/failed-recovery.sh:1170, 1230）。`fr_terminate_test.sh` Section 7 で count=1 検証
- NFR 5.1 — `shellcheck local-watcher/bin/modules/failed-recovery.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh` が warning ゼロ（reviewer 再実行で確認済み）
- NFR 5.2 — 8 件の近接テスト（fr_is_enabled / fr_state / fr_fetch / fr_no_progress / fr_invoke / fr_attempt / fr_terminate / fr_process）すべて PASS（reviewer 再実行で確認済み: PASS=40+51+42+12+43+56+63+62=369, FAIL=0）
- NFR 6 — design.md / impl-notes の設計上の注記により `repo-template/local-watcher/` は未配置、root local-watcher/ のみで管理し install.sh 経由で配布。`.claude/{agents,rules}` には追加変更なし、新規 agent / rule / workflow / labels なし

## Boundary 検査

tasks.md の `_Boundary:_` 宣言と HEAD の変更ファイル群が一致:

- `issue-watcher.sh:Config` → issue-watcher.sh の Config ブロック追加（行 489-530）
- `issue-watcher.sh:CallSite` → REQUIRED_MODULES 末尾追記（行 889）+ call site 1 行追加（行 1409）
- `modules/failed-recovery.sh:Gate / State / CandidateSelection / Decision / Execution / Orchestrator / Termination` → 新規ファイル
- `core_utils.sh`（task 1）→ `fr_log` / `fr_warn` / `fr_error` 3 関数追加（13 行）
- 既存の他 module / processor のロジックに touch なし
- README.md / docs/specs/359-.../{impl-notes.md, tasks.md} は task 8 詳細項目で明示要求された companion update

`_Boundary:_` 逸脱なし。

## Findings

なし

## Summary

全 numeric AC（1.1〜6.2 + NFR 1.1〜5.2 + NFR 6）が実装 + 近接テストで充足を確認した。shellcheck warning ゼロ、近接テスト 8 件すべて PASS（合計 369 assertion）。tasks.md の `_Boundary:_` 宣言に対する逸脱なし。Feature Flag Protocol は対象 repo で未宣言のため細目チェックは適用外。

RESULT: approve
