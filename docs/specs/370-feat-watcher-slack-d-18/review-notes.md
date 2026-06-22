# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-370-impl-feat-watcher-slack-d-18
- HEAD commit: 681c2ef4c3ef3f97a20fc0e4f0493718d4a0b952
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh` の Config ブロックに `SLACK_NOTIFY_ENABLED="${SLACK_NOTIFY_ENABLED:-false}"` を宣言（既定 `false`）
- 1.2 — `slack-notify.sh:sn_is_enabled` の `case "$SLACK_NOTIFY_ENABLED" in true) return 0` で `=true` 厳密一致時のみ emitter を起動可能化
- 1.3 — `sn_is_enabled` の `*) return 1` 分岐 + `sn_is_enabled_test.sh`（25 ケース、`True` / `TRUE` / `1` / `on` / `yes` / typo / 前後空白等を含む）で OFF 正規化を検証
- 1.4 — `sn_notify` の step 2（URL preflight）で空文字検知 → `sn_warn "reason=url-unset"` + `return 0`。`sn_notify_test.sh` Section 2 で検証
- 1.5 — `sn_notify` の step 1 早期 return + 既存テストの regression なし（既存 932 ケース全 PASS）
- 1.6 — 既存 env / ラベル / exit code を一切改変せず、Config ブロックへの追加（additive）のみ
- 2.1 — `auto-merge.sh:am_enable_auto_merge_for_pr` rc=0 path / `auto-merge-design.sh:amd_enable_auto_merge_for_pr` rc=0 path に `sn_notify auto-merge`(-design) hook 追加。`auto-merge_test.sh` / `auto-merge-design_test.sh` で検証
- 2.2 — `failed-recovery.sh` の `fr_finalize_success` / `fr_terminate_max_attempts` / `fr_terminate_no_progress` の 3 callsite に hook 追加。`fr_terminate_test.sh` / `fr_attempt_test.sh` で検証
- 2.3 — `needs-decisions-auto.sh:nda_auto_continue` に hook 追加。`needs_decisions_auto_test.sh` で検証
- 2.4 — `promote-pipeline.sh:pp_do_promote` の `PP_PROMOTE_SUCCESS_COUNT++` 直後に hook 追加。`sn_callsite_promote_test.sh` Section 1 で検証
- 2.5 — `sn_callsite_promote_test.sh` Section 3/4 の failure path で sn_notify が呼ばれないことを確認
- 2.6 — `sn_notify` がステートレス（dedup なし）。`sn_notify_test.sh` Section 3 で 3 回呼び出し時に curl が 3 回呼ばれることを検証
- 3.1〜3.5 — `sn_build_payload_test.sh` Section 2/3 で event_type / repo / number / URL / result の全フィールド存在を well-formed JSON 検証 + `jq -r` field 抽出で確認
- 3.6 — `sn_scrub_secrets` で GitHub token / Slack webhook URL / 32 桁以上連続英数字を `[REDACTED]` 置換。`sn_build_payload_test.sh` Section 1/5 で検証
- 4.1 — `sn_post_webhook` の `case "$http_status" in 4*) ... return 1` で HTTP 4xx を fail-open（sn_warn 1 行 + sn_notify は rc=0 維持）。`sn_notify_test.sh` Section 5/6 で検証
- 4.2 — `sn_post_webhook` の curl 非ゼロ exit 経路で `transport-error` warn + return 2、sn_notify は rc=0。`sn_notify_test.sh` Section 7 で検証
- 4.3 — `sn_build_payload` の jq 失敗 / event_type enum 違反 / number 非数値時に rc=1、`sn_notify` step 4 で受けて return 0
- 4.4 — `sn_notify` は 6 ステップ全てを通過した場合も失敗した場合も常に最終行 `return 0` を返す + callsite 側は `|| true` で二重ガード
- 4.5 — `sn_post_webhook` で `curl --max-time "$timeout"` を強制 + 非数値 / 負数 / 空文字は既定 5 秒に正規化。`sn_notify_test.sh` Section 10 で 4 ケース検証
- 5.1 — `sn_notify` step 6 で `sn_log "event=... number=... result=... http_status=... host=hooks.slack.com"` の構造化 1 行。`sn_notify_test.sh` Section 3 で検証
- 5.2 — `sn_notify` step 1 早期 return（gate OFF）でログ出力ゼロ。`sn_notify_test.sh` Section 1 で検証
- 5.3 — URL 未設定で `sn_warn "reason=url-unset ..."` 1 行。`sn_notify_test.sh` Section 2 で検証
- 5.4 — HTTP 4xx/5xx / curl 非ゼロ exit 時に `sn_warn` で `reason=http-4xx status=... host=hooks.slack.com` 等の理由付き 1 行
- 5.5 — `sn_warn` メッセージは `host=hooks.slack.com` のみで URL 全体不在。`sn_notify_test.sh` Section 8 で grep 検証
- 6.1 — 変更は `local-watcher/bin/{issue-watcher.sh,modules/*.sh}` と `local-watcher/test/`、`README.md`、`docs/specs/370-*` に限定（git diff --stat で確認）
- 6.2 — `README.md` の opt-in 機能一覧表に Slack 通知行を追加（`SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` / `SLACK_NOTIFY_TIMEOUT` / 通知対象 5 イベント記載）
- 6.3 — コードベース / README / impl-notes に webhook URL 実値を含まず、テストフィクスチャも明らかな placeholder（`hooks.slack.com/services/T123/B456/abcdefghijklmnop`）のみ
- 6.4 — `diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` 空（exit 0）
- NFR 1.1 — gate OFF で外部副作用ゼロ。`sn_notify_test.sh` Section 1 で curl stub の 0 回呼び出しを検証 + 既存 932 ケース regression なし
- NFR 1.2 — 既存 env / label / exit code / cron registration string 不変（additive only）
- NFR 1.3 — `run-summary.sh` は touch していない（git diff で確認）
- NFR 2.1 — `sn_notify` step 1 で `sn_is_enabled` OFF 時に payload 構築・curl 呼び出しを一切実行せず即 return
- NFR 2.2 — `curl --max-time "$timeout"` で有限 timeout 強制（既定 5 秒）
- NFR 2.3 — 新規 CLI 依存追加なし（既存の `curl` / `jq` のみ使用）
- NFR 3.1 — `SLACK_WEBHOOK_URL` は env 経由のみ取得、コード・ログ・test fixture に実値なし
- NFR 3.2 — `sn_build_payload` で全フィールドを `jq -n -c --arg` で sanitize（フィルタ文字列に未信頼値の inline 展開なし）+ event_type enum / number `^[0-9]+$` 検証 + curl 引数に `--` 付与
- NFR 3.3 — `sn_scrub_secrets` で GitHub token / Slack webhook / 32 桁以上連続英数字を `[REDACTED]` 置換 + callsite 側は短い既知メタデータ（head_ref / kind / attempts / mode 等）のみ detail に渡す方針
- NFR 3.4 — `sn_warn` 全箇所で `host=hooks.slack.com` のみを含み、URL 全体は出力しない（grep 検証 + sn_notify_test.sh Section 8）
- NFR 4.1 — `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` exit 0
- NFR 4.2 — 近接テスト 4 種（`sn_is_enabled_test.sh` 25 / `sn_build_payload_test.sh` 44 / `sn_notify_test.sh` 23 / `sn_callsite_promote_test.sh` 15）+ 既存 5 ファイルへの assertion 追加で要求項目を全カバー
- NFR 4.3 — `sn_is_enabled_test.sh` で env 正規化（typo / 大小文字 / 前後空白）を 25 ケース検証
- NFR 4.4 — `sn_notify_test.sh` は curl stub harness で外部 HTTP 呼び出しゼロ
- NFR 5.1 — 構造化ログは `event=... number=... result=... http_status=...` の key=value 形式で grep 抽出可能

## Findings

なし

## Summary

5 callsite すべてに `sn_notify` hook が `|| true` 二重ガード付きで適切な位置（既存 success ログ直後 / return 直前）に挿入されている。新規 module `slack-notify.sh` は opt-in gate（`SLACK_NOTIFY_ENABLED=true` 厳密一致）/ URL preflight / jq `--arg` sanitize / secret scrub / 有限 timeout / fail-open（常に rc=0）/ URL 全体マスキングを完備し、tasks.md の `_Boundary:_` を逸脱する変更は無い。requirements.md の全 numeric ID（Req 1.1〜6.4 + NFR 1.1〜5.1）が実装または近接テストでカバーされ、shellcheck / bash -n / 全 watcher テストスイート（PASS=932 / FAIL=0）/ diff -r byte 一致確認も clean。

RESULT: approve
