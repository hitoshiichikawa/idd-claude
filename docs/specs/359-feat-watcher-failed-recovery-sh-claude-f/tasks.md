# Implementation Plan

- [x] 1. core_utils.sh に Failed Recovery ロガーを追加
  - `local-watcher/bin/modules/core_utils.sh` に `fr_log` / `fr_warn` / `fr_error` を
    既存 `pi_log` / `pr_log` と同パターンで追加（prefix `failed-recovery:`、warn/error は stderr）
  - shellcheck warning ゼロを維持
  - 近接テストはロガー単独では追加せず、後続 task の `fr_*_test.sh` で間接検証する
  - _Requirements: NFR 4.1, NFR 5.1_

- [x] 2. issue-watcher.sh Config ブロックに FAILED_RECOVERY_* env を追加
- [x] 2.1 Config ブロックに env 受け取り + 値正規化を追加
  - `FAILED_RECOVERY_ENABLED` / `FAILED_RECOVERY_MAX_ATTEMPTS` / `FAILED_RECOVERY_MAX_TURNS` /
    `FAILED_RECOVERY_DEV_MODEL` / `FAILED_RECOVERY_GIT_TIMEOUT` / `FAILED_RECOVERY_MAX_PRS` /
    `FAILED_RECOVERY_STATE_DIR` の宣言と既定値を `issue-watcher.sh` の Config ブロック（PR
    Iteration / Auto-Merge 隣接位置）に追加
  - `FAILED_RECOVERY_ENABLED` は `=true` 厳密一致以外を `false` に正規化する case を追加
  - `FAILED_RECOVERY_MAX_ATTEMPTS` は非整数 / `<=0` を `4` に正規化（Req 4.8）
  - 既存「デフォルト有効化フラグの値正規化」ループには加えない（opt-in 制）
  - 本 task は env 宣言のみで挙動が gate に直結する単位テストは task 3.1 / 3.2 の
    `fr_is_enabled_test.sh` / `fr_state_test.sh` に集約する（partial 解消の deferred 先を明示）
  - _Requirements: 1.1, 1.5, 4.1, 4.8, NFR 1.1_
  - _Requirements_partial: 1.5, 4.8_
  - _Boundary: issue-watcher.sh:Config_

- [ ] 3. modules/failed-recovery.sh 新規モジュールを追加（gate + state 永続化レイヤ）
- [ ] 3.1 module 雛形と gate 関数を実装
  - `local-watcher/bin/modules/failed-recovery.sh` を新規作成。ファイル冒頭コメントで用途・
    配置先・依存・prefix `fr_` を明記し、function 定義のみを置く（トップレベル副作用なし）
  - `fr_is_enabled` を実装（`FAILED_RECOVERY_ENABLED=true` AND `FULL_AUTO_ENABLED=true`
    厳密一致のみで 0 を返す純粋関数）
  - `local-watcher/test/fr_is_enabled_test.sh` を `extract_function` イディオムで追加し、
    二重 opt-in / 不正値正規化（typo / 空 / `1` / `True`）/ 片方 only / 両方 OFF / 両方 ON
    のマトリクスを検証（task 2.1 の `_Requirements_partial:_` 1.5 を本 task でカバー）
  - shellcheck warning ゼロ
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, NFR 1.3, NFR 5.1, NFR 5.2_
  - _Boundary: modules/failed-recovery.sh:Gate_

- [ ] 3.2 状態永続化レイヤ（fr_state_path / fr_load_state / fr_save_state）を実装
  - `fr_state_path` / `fr_load_state` / `fr_save_state` を `modules/failed-recovery.sh` に追加
  - 配置: `$FAILED_RECOVERY_STATE_DIR/<issue>.json`、`mkdir -p` 冪等化
  - `fr_save_state` は `mktemp -p` で同一 dir に temp file 作成 → `jq` で組み立て → `mv -f`
    で atomic rename（TOCTOU 安全）
  - `fr_load_state` はファイル不在 / parse 失敗で `{}` を返す fail-open
  - schema: `issue`, `total_attempts`, `last_status`, `last_failure_signature`,
    `last_head_sha`, `last_attempt_at`, `history`（design.md Data Model 節）
  - `local-watcher/test/fr_state_test.sh` で atomic write / 既存 schema / 不在ファイル
    fail-open / `last_status` enum / `MAX_ATTEMPTS` 不正値 fallback を `extract_function`
    で検証（task 2.1 の `_Requirements_partial:_` 4.8 を本 task でカバー）
  - _Requirements: 4.1, 4.2, 4.7, 4.8, 6.2, NFR 2.2, NFR 2.3, NFR 5.2_
  - _Boundary: modules/failed-recovery.sh:State_
  - _Depends: 3.1_

- [ ] 4. 候補選定レイヤ（fr_fetch_failed_issues / fr_fetch_failed_prs）を実装
  - `fr_fetch_failed_issues` を実装。`gh issue list --search 'label:"claude-failed"
    label:"auto-dev" -label:"needs-decisions" -label:"needs-quota-wait" -label:"blocked"
    -label:"awaiting-slot"' --json number,labels,body,title,url --limit "$FAILED_RECOVERY_MAX_PRS"`
    を呼ぶ。reviewer-reject 由来も label 付与経緯非依存で含む（Req 2.2）
  - `fr_fetch_failed_prs` を実装。`gh pr list` + `gh pr view --json mergeStateStatus,
    autoMergeRequest,statusCheckRollup` の組み合わせで auto-merge 有効かつ CI error の PR を
    client-side filter で抽出。head pattern `^claude/` で fork 除外
  - 取得失敗時は空 JSON `[]` を返し `fr_warn` で警告（fail-continue）
  - 未信頼入力（branch 名 / PR 本文）を `jq --arg` で扱う（NFR 3.1）
  - 近接テスト `local-watcher/test/fr_fetch_test.sh` を追加し、`gh` を stub にして検索クエリ
    引数列を verify（除外ラベル群 / `auto-dev` 必須 / `--` 区切り）
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, NFR 3.1, NFR 5.2_
  - _Boundary: modules/failed-recovery.sh:CandidateSelection_
  - _Depends: 3.1_

- [ ] 5. 失敗解析 + no-progress 検出 + Claude 起動 wrapper を実装
- [ ] 5.1 失敗 signature 計算と no-progress 判定を実装
  - `fr_compute_failure_signature` を実装。`sed -E` で timestamp / SHA / URL / 行番号 /
    `Run #` を除去 → `sha1sum` で hash 化
  - `fr_detect_no_progress` を実装。直前 state の signature と一致 + （PR 経路時は head_sha
    も同一）の AND で no-progress 判定。prev state なし → progress、Issue 経路は signature
    一致のみで判定
  - `local-watcher/test/fr_no_progress_test.sh` を追加し、(a) signature 一致 + head 同一 →
    no-progress、(b) signature 異 → progress、(c) Issue 経路（head_sha なし）の挙動、
    (d) prev state なし → progress、(e) signature 一致 + head 進捗 → progress を検証
  - _Requirements: 5.1, 5.2, 5.5, NFR 5.2_
  - _Boundary: modules/failed-recovery.sh:Decision_
  - _Depends: 3.2_

- [ ] 5.2 Context 収集と Claude 起動 wrapper を実装
  - `fr_collect_issue_context` を実装。`gh issue view --json comments,body,title,labels`
    で直近 5 件のコメント + `git show` 経由で spec dir 配下を集約
  - `fr_collect_pr_ci_context` を実装。`gh pr checks --json` で failing check 特定 → `gh run
    view --log-failed` でログ tail（200 行）を取得
  - `fr_invoke_claude` を実装。`claude -p ... --max-turns "$FAILED_RECOVERY_MAX_TURNS"
    --model "$FAILED_RECOVERY_DEV_MODEL" --permission-mode bypassPermissions
    --output-format stream-json` を起動し、stream を `qa_detect_rate_limit` で fold（quota
    検出時は exit 99 で `qa_handle_quota_exceeded` 経路へ）
  - すべての未信頼入力を `jq --arg`、`gh --` / `git --` で sanitize（NFR 3.1）
  - PR 番号 / Issue 番号は `^[0-9]+$`、SHA は `^[0-9a-f]{40}$` で使用直前検証
  - secrets を prompt 本文に埋め込まない（NFR 3.2）
  - 本 task で context 収集と claude 起動の最小 regression test
    `local-watcher/test/fr_invoke_test.sh` を追加（`gh` / `claude` を stub、quota 検出時に
    exit 99 が伝播することを検証 / API failure handling / 未信頼入力 sanitize を検証）
  - _Requirements: 3.1, 3.2, 3.5, NFR 3.1, NFR 3.2, NFR 5.2_
  - _Boundary: modules/failed-recovery.sh:Execution_
  - _Depends: 3.1_

- [ ] 6. attempt orchestrator + finalize_success を実装
  - `fr_should_recover` を実装（`total_attempts < FAILED_RECOVERY_MAX_ATTEMPTS` の純粋判定）
  - `fr_run_recovery_attempt` を実装。pre-attempt の `fr_should_recover` → no-progress 判定
    → 着手コメント投稿 → **試行開始時に attempt++**（Req 4.2、quota 燃焼上界保証）→
    `fr_invoke_claude` → 結果コメント投稿（解析した失敗原因の概要・適用した修正の概要・
    attempt 回数 / Req 3.3）→ `fr_save_state`
  - `fr_finalize_success` を実装。`claude-failed` ラベルを `gh issue/pr edit --remove-label`
    で除去、in-memory set `FR_PROCESSED_THIS_CYCLE` に記録（Req 6.1）、state JSON に
    `last_status="succeeded"`（Req 6.2）
  - `fr_post_attempt_comment` を実装。secrets 不出力（NFR 3.2）、`printf '%s'` で値埋め込み
  - `local-watcher/test/fr_attempt_test.sh` を追加し、(a) 試行開始時の attempt++ 順序、
    (b) `claude-failed` 除去が success path でのみ呼ばれること、(c) 結果コメントが 1 件
    投稿されること、(d) `FR_PROCESSED_THIS_CYCLE` の重複起動防止、(e) Reviewer marker /
    pr-iteration marker（`idd-claude:pr-iteration round=N`）を **読まない**こと（D-19b /
    Req 4.3 の唯一カウンタ独立性）を `gh` stub の call trace で検証
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 4.2, 4.3, 4.4, 6.1, 6.2, NFR 2.1, NFR 3.2, NFR 5.2_
  - _Boundary: modules/failed-recovery.sh:Orchestrator_
  - _Depends: 3.2, 4, 5.1, 5.2_

- [ ] 7. 終端処理（max-attempts / no-progress）と run-summary 連携を実装
  - `fr_terminate_max_attempts` を実装。`claude-failed` 据え置き（Req 4.5）、終端理由コメント
    1 件投稿（通算試行回数 + 上限値含む / Req 4.6）、`rs_set_result claude-failed` 呼び出し
    （NFR 4.2）、`fr_log` でログ記録（NFR 4.1）
  - `fr_terminate_no_progress` を実装。`claude-failed` 据え置き（Req 5.3）、終端理由（同原因
    再発 + 無進捗）コメント 1 件投稿、`rs_set_result claude-failed` 呼び出し（Req 5.4）
  - `local-watcher/test/fr_terminate_test.sh` を追加し、(a) max-attempts 経路で
    `rs_set_result` / `gh issue/pr comment` が 1 件発火し `claude-failed` 除去**されない**
    こと、(b) no-progress 経路で同様、(c) コメント本文に通算回数 / 終端理由が含まれること、
    (d) `fr_log` 出力に `failed-recovery:` prefix + Issue/PR 番号が含まれること（NFR 4.1）
    を stub で検証
  - _Requirements: 4.5, 4.6, 5.3, 5.4, NFR 4.1, NFR 4.2, NFR 5.2_
  - _Boundary: modules/failed-recovery.sh:Termination_
  - _Depends: 3.2, 6_

- [ ] 8. process_failed_recovery エントリ + watcher 本体配線 + README 追記
  - `process_failed_recovery` を `modules/failed-recovery.sh` に実装。冒頭で
    `fr_is_enabled || return 0`、Issue 候補と PR 候補を列挙 → 各 candidate を直列実行 →
    重複起動防止 in-memory set、例外は `fr_warn` 吸収（fail-continue）
  - `issue-watcher.sh` の `REQUIRED_MODULES`（行 846 付近）に `"failed-recovery.sh"` を追記
  - call site を `process_pr_iteration` の直後（`process_design_review_release` の前、
    行 1358 付近）に `process_failed_recovery || fr_warn "process_failed_recovery が想定外
    のエラーで終了しました（後続 Issue 処理は継続）"` で 1 行追加
  - `README.md` に「Failed Recovery Processor (#359)」節を追加（env var 一覧 / 二重 opt-in
    手順 / 通算 4 回上限 / Reviewer 2/2・pr-iteration 3R との独立性 = D-19b / 既存
    `claude-failed` 手動運用との関係 / state ファイル配置）
  - `local-watcher/test/fr_process_test.sh` を追加し、(a) gate off 時に副作用ゼロ（`gh` /
    `claude` stub が呼ばれない / NFR 1.3 / safety-side fallback）、(b) gate on 時に Issue +
    PR 双方の候補列挙が走ること、(c) 候補 0 件で no-op、(d) `fr_warn` で例外が吸収される
    こと（fail-continue / failure path）、を検証
  - _Requirements: 1.1, 1.4, 2.1, 2.3, NFR 1.1, NFR 1.3, NFR 2.1, NFR 5.2_
  - _Boundary: issue-watcher.sh:CallSite, modules/failed-recovery.sh:Orchestrator_
  - _Depends: 1, 2.1, 3.1, 3.2, 4, 5.1, 5.2, 6, 7_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを
構造化ブロックで宣言する。shellcheck warning ゼロ（NFR 5.1）と 近接テスト 7 件
（NFR 5.2）を 1 行で実行する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/failed-recovery.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh && bash local-watcher/test/fr_is_enabled_test.sh && bash local-watcher/test/fr_state_test.sh && bash local-watcher/test/fr_fetch_test.sh && bash local-watcher/test/fr_no_progress_test.sh && bash local-watcher/test/fr_invoke_test.sh && bash local-watcher/test/fr_attempt_test.sh && bash local-watcher/test/fr_terminate_test.sh && bash local-watcher/test/fr_process_test.sh
```
