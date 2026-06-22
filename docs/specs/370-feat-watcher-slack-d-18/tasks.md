# Implementation Plan

- [x] 1. slack-notify module の骨格 + opt-in gate + ロガー
  - 新規ファイル `local-watcher/bin/modules/slack-notify.sh` を追加（ファイル冒頭コメントで用途 / 配置先 / 依存 / セットアップ参照先を明記、関数定義のみでトップレベル副作用なし）
  - `sn_log` / `sn_warn` / `sn_error` を既存 `fr_log` / `am_log` と同形式の 3 段 prefix
    （`[YYYY-MM-DD HH:MM:SS] [$REPO] slack-notify: ...`）で実装
  - `sn_is_enabled` を実装（`${SLACK_NOTIFY_ENABLED:-false}` の `true` 厳密一致のみ rc=0、それ以外は rc=1）
  - `local-watcher/bin/issue-watcher.sh` の Config ブロックに `SLACK_NOTIFY_ENABLED` (既定 `false`) /
    `SLACK_WEBHOOK_URL` (既定 空) / `SLACK_NOTIFY_TIMEOUT` (既定 5) の 3 env を追加
  - `REQUIRED_MODULES` 配列に `slack-notify.sh` を登録
  - cycle startup ログ行に `slack-notify=<on|off>` の解決値出力を追加（既存 `auto-merge=` / `full-auto=` と同列）
  - 近接テスト `local-watcher/test/sn_is_enabled_test.sh` を追加（env 未設定 / 空 / `true` /
    `True` / `TRUE` / `1` / `on` / `false` / `yes` / 前後空白付き / typo の各ケースで rc を検証）
  - _Requirements: 1.1, 1.2, 1.3, 5.5, 6.1, NFR 1.2, NFR 4.1, NFR 4.3_
  - _Boundary: slack-notify.sh (新規), issue-watcher.sh (Config ブロック追加のみ), local-watcher/test/sn_is_enabled_test.sh (新規)_
  - _Depends: none_

- [x] 2. payload 構築（jq --arg sanitize + secret scrub）
- [x] 2.1 sn_build_payload 関数の実装
  - `sn_build_payload <event_type> <number> <url> <result> <detail>` を実装
  - jq `--arg` で全フィールドを sanitize（フィルタ文字列に未信頼値を inline 展開しない）
  - Slack Block Kit `section` 1 ブロック + フォールバック `text` フィールドの payload schema を採用
    （design.md「Slack Payload Schema」§ 参照）
  - event_type の enum 検証（`auto-merge` / `auto-merge-design` / `failed-recovery` /
    `needs-decisions-auto-continue` / `promote` の 5 値）
  - number の `^[0-9]+$` 検証（promote の sentinel `0` は許容）
  - secret scrub: GitHub token prefix（`ghp_` / `gho_` / `ghu_` / `ghs_` / `ghr_` + 36 文字以上） /
    Slack webhook prefix（`hooks.slack.com/services/`） / 32 桁以上連続英数字を `[REDACTED]` に置換
  - jq 失敗時は rc=1 を返す（呼出側で WARN + fail-open）
  - 近接テスト `local-watcher/test/sn_build_payload_test.sh` を追加（well-formed JSON 検証 / 必須フィールド存在 / secret 候補の `[REDACTED]` 置換）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, NFR 3.2, NFR 3.3, NFR 4.2_
  - _Boundary: slack-notify.sh (sn_build_payload 関数追加), local-watcher/test/sn_build_payload_test.sh (新規)_
  - _Depends: 1_

- [x] 3. HTTP POST と fail-open 制御（sn_post_webhook + sn_notify entry point）
- [x] 3.1 sn_post_webhook の実装
  - `curl -X POST -H 'Content-Type: application/json' --max-time "$SLACK_NOTIFY_TIMEOUT" --silent --show-error -d @- -- "$SLACK_WEBHOOK_URL"` 相当を実装
  - payload は stdin (`-d @-`) で渡し、コマンドライン引数化を避ける（process listing からの漏洩防止）
  - HTTP status を `-w '%{http_code}'` で取得し、curl exit code と合わせて rc を判定
    （curl=0 + 2xx → 0 / curl=0 + 4xx5xx → 1 / curl 非ゼロ → 2）
  - 失敗時 sn_warn 1 行（reason / status / curl_exit を含む。webhook URL のホスト部のみを含めて全体は含めない）
  - `SLACK_NOTIFY_TIMEOUT` が非数値 / 負数の場合は既定 5 に正規化（WARN 1 行）
  - _Requirements: 4.1, 4.2, 4.5, 5.4, 5.5, NFR 2.2, NFR 3.4_
  - _Boundary: slack-notify.sh (sn_post_webhook 関数追加)_
  - _Depends: 2.1_

- [x] 3.2 sn_notify public entry point の実装
  - 評価順序を design.md「sn_notify Service Interface」§ の通り実装
    （gate → URL preflight → 引数検証 → build → post → log）
  - 戻り値は **常に rc=0**（fail-open / Req 4.4）
  - `SLACK_NOTIFY_ENABLED=true` かつ `SLACK_WEBHOOK_URL` 未設定時は sn_warn 1 行
    （`reason=url-unset`） + no-op return（Req 1.4 / 5.3）
  - 成功時に sn_log で構造化 1 行（`event=... number=... result=... http_status=... host=hooks.slack.com`）
  - 近接テスト `local-watcher/test/sn_notify_test.sh` を追加（curl stub を用いて以下を検証）:
    - `SLACK_NOTIFY_ENABLED=false` で curl stub が一度も呼ばれない（gate OFF / NFR 1.1, 2.1）
    - `=true` + URL 未設定で sn_warn 1 行 + curl stub 不呼出（Req 1.4 / 5.3）
    - `=true` + URL 設定済で curl stub が 1 回呼ばれ HTTP 200 stub 時 sn_log 成功行が出る（Req 2.x / 5.1）
    - HTTP 500 stub 時 / curl 非ゼロ exit stub 時に WARN が出るが sn_notify は rc=0（Req 4.1 / 4.2 / 4.4）
    - sn_log / sn_warn に webhook URL 全体が含まれないことを grep で検証（Req 5.5 / NFR 3.4）
  - _Requirements: 1.4, 1.5, 2.6, 4.3, 4.4, 5.1, 5.2, 5.3, 5.4, 5.5, NFR 1.1, NFR 2.1, NFR 3.4, NFR 4.2, NFR 4.4, NFR 5.1_
  - _Boundary: slack-notify.sh (sn_notify 関数追加), local-watcher/test/sn_notify_test.sh (新規)_
  - _Depends: 3.1_

- [x] 4. auto-merge / auto-merge-design callsite への hook 追加
  - `local-watcher/bin/modules/auto-merge.sh` の `am_enable_auto_merge_for_pr` rc=0 path
    （既存 `am_log "PR #${pr_number}: auto-merge enabled ..."` 行の直後）に
    `sn_notify auto-merge "$pr_number" "$pr_url" success "head=$head_ref sha=$head_sha" || true` を 1 行追加
  - `local-watcher/bin/modules/auto-merge-design.sh` の `amd_enable_auto_merge_for_pr` 同位置に
    event_type を `auto-merge-design` に切り替えて同様の 1 行を追加
  - 既存テスト `local-watcher/test/auto-merge_test.sh` / `auto-merge-design_test.sh` に
    「`SLACK_NOTIFY_ENABLED=false` での既存挙動 byte 一致」「`=true` + URL 設定済で curl stub が 1 回呼ばれ event_type が `auto-merge` / `auto-merge-design`」の assertion を追加
  - _Requirements: 2.1, 2.5, 2.6, 4.4, NFR 1.1, NFR 4.2_
  - _Boundary: auto-merge.sh (rc=0 path に 1 行), auto-merge-design.sh (rc=0 path に 1 行), local-watcher/test/auto-merge_test.sh, auto-merge-design_test.sh_
  - _Depends: 3.2_

- [x] 5. failed-recovery callsite への hook 追加（3 終端遷移）
  - `local-watcher/bin/modules/failed-recovery.sh` の以下 3 関数末尾（`return` 直前）に
    `sn_notify failed-recovery ...` を 1 行ずつ追加:
    - `fr_finalize_success`: `result=recovered`, detail に `kind=$kind attempts=$total_attempts`
    - `fr_terminate_max_attempts`: `result=max-attempts`, detail に `kind=$kind attempts=$total_attempts max=$FAILED_RECOVERY_MAX_ATTEMPTS`
    - `fr_terminate_no_progress`: `result=no-progress`, detail に `kind=$kind attempts=$total_attempts`
  - signature 値は detail に含めない（NFR 3.3）。既存 `fr_log` は変更しない（先頭 8 桁を残す既存規約を維持）
  - 既存テスト `local-watcher/test/fr_terminate_test.sh` 等に「`SLACK_NOTIFY_ENABLED=true` + URL 設定済で curl stub が 1 回呼ばれ event_type が `failed-recovery` で result が想定値」の assertion を追加
  - `SLACK_NOTIFY_ENABLED=false` での既存挙動 byte 一致も assertion で検証（NFR 1.1）
  - _Requirements: 2.2, 2.5, 2.6, 3.5, 4.4, NFR 1.1, NFR 3.3, NFR 4.2_
  - _Boundary: failed-recovery.sh (3 callsite に 1 行ずつ), local-watcher/test/fr_terminate_test.sh, fr_state_test.sh 等_
  - _Depends: 3.2_

- [ ] 6. needs-decisions-auto / promote callsite への hook 追加
  - `local-watcher/bin/modules/needs-decisions-auto.sh` の `nda_auto_continue` 関数末尾
    （既存 `nda_log "issue=#${NUMBER} ... action=auto-continue ..."` 行の直後、`return 0` の直前）に
    `sn_notify needs-decisions-auto-continue "$NUMBER" "https://github.com/$REPO/issues/$NUMBER" auto-continued "mode=$mode classification=$classification" || true` を追加
  - `local-watcher/bin/modules/promote-pipeline.sh` の `pp_do_promote` 親シェル側 rc=0 分岐
    （`PP_PROMOTE_SUCCESS_COUNT=$((... + 1))` の直後）に
    `sn_notify promote "0" "https://github.com/$REPO" promote-success "base=$BASE_BRANCH target=$PROMOTION_TARGET_BRANCH candidates=${#PROMOTE_CANDIDATES[@]}" || true` を追加
  - 既存テスト `local-watcher/test/needs_decisions_auto_test.sh` に「`SLACK_NOTIFY_ENABLED=true` + URL 設定済で event_type が `needs-decisions-auto-continue` の curl stub 呼び出しが 1 回」の assertion を追加
  - promote 側は既存テストが薄いため、`local-watcher/test/sn_callsite_promote_test.sh` を新規追加して `pp_do_promote` 成功 path での `sn_notify promote` 呼び出しを stub 検証（必要に応じて `extract_function` イディオムで `pp_do_promote` のサブシェルを観測可能化）
  - _Requirements: 2.3, 2.4, 2.5, 2.6, 3.5, 4.4, NFR 1.1, NFR 4.2_
  - _Boundary: needs-decisions-auto.sh (1 行), promote-pipeline.sh (1 行), local-watcher/test/needs_decisions_auto_test.sh, local-watcher/test/sn_callsite_promote_test.sh (新規)_
  - _Depends: 3.2_

- [ ] 7. README オプション機能一覧への反映と static-analysis / 同期確認
  - `README.md` の `### opt-in（既定 OFF、明示的に有効化が必要）` 表に Slack 通知行を追加:
    - 機能名: Slack 通知（重要イベント push）
    - 制御変数: `SLACK_NOTIFY_ENABLED`、既定 `false`、正規化: `=true` 厳密一致のみ有効
    - 追加 env: **必須** `SLACK_WEBHOOK_URL`（Slack Incoming Webhook URL、env 経由のみ）/ 推奨
      `SLACK_NOTIFY_TIMEOUT`（秒、既定 5）
    - 通知対象イベント 5 種を箇条書きで列挙
    - 注意: webhook URL はリポジトリにコミットしない / 通知失敗はパイプライン本体に伝播しない（fail-open）
  - 必要なら本 spec の Issue 番号（#370）を関連欄に追加
  - `shellcheck local-watcher/bin/modules/slack-notify.sh local-watcher/bin/issue-watcher.sh` で警告ゼロを確認（`.shellcheckrc` の既存 accepted baseline を踏襲）
  - `bash -n local-watcher/bin/modules/slack-notify.sh` で構文チェック
  - root ↔ repo-template 同期確認: `.claude/agents/` / `.claude/rules/` / `.github/workflows/` /
    `.github/scripts/idd-claude-labels.sh` のいずれも本機能では touch しない方針なので
    `diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` が空であることを再確認（Req 6.4 / NFR 1.2）
  - `repo-template/local-watcher/` は存在しないため新 module の repo-template 配布は不要であることを README または本 spec の確認事項で明記
  - _Requirements: 6.2, 6.3, 6.4, NFR 1.2, NFR 4.1_
  - _Boundary: README.md, （root ↔ repo-template の byte 一致対象は touch しない）_
  - _Depends: 4, 5, 6_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh && \
  bash -n local-watcher/bin/modules/slack-notify.sh && \
  bash local-watcher/test/sn_is_enabled_test.sh && \
  bash local-watcher/test/sn_build_payload_test.sh && \
  bash local-watcher/test/sn_notify_test.sh && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
