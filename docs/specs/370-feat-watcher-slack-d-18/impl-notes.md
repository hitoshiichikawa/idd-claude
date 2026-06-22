# Implementation Notes

## 実装概要

watcher の重要 5 イベント（auto-merge / auto-merge-design / failed-recovery 3 終端 /
needs-decisions auto-continue / promote 完了）を Slack Incoming Webhook 経由で push 通知する
補助的観測チャネル（D-18 / 低優先）を完全 opt-in で追加した。実装は design.md の File Structure
Plan と Component Contracts に従い、新規 module 1 件 + 既存 5 module への 1 行 hook 追加 +
Config ブロック / 起動ログ / README 更新で完結。

### 追加した module / 関数 / env

- **新規 module**: `local-watcher/bin/modules/slack-notify.sh`
  - `sn_log` / `sn_warn` / `sn_error`: 3 段 prefix ロガー（`[YYYY-MM-DD HH:MM:SS] [$REPO] slack-notify: ...`）
  - `sn_is_enabled`: `SLACK_NOTIFY_ENABLED=true` 厳密一致 gate（純粋関数）
  - `sn_scrub_secrets`: `ghp_/gho_/ghu_/ghs_/ghr_` token / Slack webhook URL / 32 桁以上連続英数字を `[REDACTED]` 置換
  - `sn_build_payload`: `jq --arg` で sanitize した Slack Block Kit JSON 構築（event_type enum + number `^[0-9]+$` 検証）
  - `sn_post_webhook`: `curl --max-time` で有限タイムアウト POST（rc=0/1/2 で HTTP 2xx / 4xx5xx / transport-error を区別）
  - `sn_notify`: 5 callsite が呼ぶ public entry point（常に rc=0 / fail-open）
- **新規 env**: `SLACK_NOTIFY_ENABLED` (既定 `false`) / `SLACK_WEBHOOK_URL` (既定 空) / `SLACK_NOTIFY_TIMEOUT` (既定 `5`)
- **起動ログ拡張**: cycle startup ログに `slack-notify=<on|off>` の解決値を追加
- **REQUIRED_MODULES**: 末尾に `slack-notify.sh` を登録（install.sh の glob 配布で自動配布）

### 既存 5 module への hook 追加（全 `|| true` で fail-open）

| Callsite | event_type | result |
|---|---|---|
| `am_enable_auto_merge_for_pr` rc=0 path | `auto-merge` | `success` |
| `amd_enable_auto_merge_for_pr` rc=0 path | `auto-merge-design` | `success` |
| `fr_finalize_success` return 直前 | `failed-recovery` | `recovered` |
| `fr_terminate_max_attempts` return 直前 | `failed-recovery` | `max-attempts` |
| `fr_terminate_no_progress` return 直前 | `failed-recovery` | `no-progress`（signature 値は detail に含めず） |
| `nda_auto_continue` return 直前 | `needs-decisions-auto-continue` | `auto-continued`（recommendation 本文は detail に含めず） |
| `pp_do_promote` 親シェル rc=0 分岐 | `promote` | `promote-success`（number sentinel `0`） |

## 動作確認

### Verify ブロック（tasks.md 末尾の構造化 verify）

```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh && \
  bash -n local-watcher/bin/modules/slack-notify.sh && \
  bash local-watcher/test/sn_is_enabled_test.sh && \
  bash local-watcher/test/sn_build_payload_test.sh && \
  bash local-watcher/test/sn_notify_test.sh && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```

結果: **全てクリア（exit 0）**。

### 追加した近接テスト + 既存テストへの assertion 追加

- 新規 4 ファイル: `sn_is_enabled_test.sh` (25) / `sn_build_payload_test.sh` (44) /
  `sn_notify_test.sh` (23) / `sn_callsite_promote_test.sh` (15) = **計 107 ケース**
- 既存 5 ファイルへの assertion 追加: `auto-merge_test.sh` (+4) / `auto-merge-design_test.sh`
  (+5) / `fr_terminate_test.sh` (+13) / `fr_attempt_test.sh` (+4) / `needs_decisions_auto_test.sh`
  (+5) = **計 +31 assertion**
- 全テスト最終結果: **TOTAL PASS=932 FAIL=0**（全 watcher test スイート / regression なし）

### 静的解析

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` → exit 0
- `bash -n local-watcher/bin/modules/slack-notify.sh` → OK
- `actionlint .github/workflows/*.yml` → exit 0

### root ↔ repo-template 同期確認

| コマンド | 結果 |
|---|---|
| `diff -r .claude/agents repo-template/.claude/agents` | exit 0（差分なし） |
| `diff -r .claude/rules repo-template/.claude/rules` | exit 0（差分なし） |

本機能は `.claude/agents` / `.claude/rules` / `.github/workflows` / `.github/scripts/idd-claude-labels.sh` の
いずれも touch しない方針で実装したため、byte 一致対象成果物のドリフトは発生していない。
`repo-template/local-watcher/` は存在しないため新 module の repo-template 配布は不要。

## AC Traceability（requirements.md numeric ID → カバーテスト）

| AC グループ | カバーテスト |
|---|---|
| Req 1.1〜1.3 / NFR 4.3 (env 正規化) | `sn_is_enabled_test.sh`（25 ケース / 19 typo 含む） |
| Req 1.4〜1.6 / NFR 1.1〜1.3 (URL 未設定 + 後方互換) | `sn_notify_test.sh` Section 1/2 + 既存 932 test regression なし |
| Req 2.1 (auto-merge 完了通知) | `auto-merge_test.sh` Section 3（sn_notify 1 回 + event_type/number 検証） |
| Req 2.2 (failed-recovery 終端 3 種) | `fr_terminate_test.sh` Section 1/2/3 + `fr_attempt_test.sh` Section 11 |
| Req 2.3 (needs-decisions auto-continue) | `needs_decisions_auto_test.sh` Case C |
| Req 2.4 (promote 完了) | `sn_callsite_promote_test.sh` Section 1 |
| Req 2.5 (routine では発火しない) | 各 callsite test の失敗 path で 0 回 assertion（auto-merge/needs-decisions/promote 各 1〜3 path） |
| Req 2.6 (同一 tick 複数発火で各 1 通) | `sn_notify_test.sh` Section 3（3 回呼び出しで curl 3 回） |
| Req 3.1〜3.5 (payload 必須 5 field) | `sn_build_payload_test.sh` Section 2/3/4 + 各 callsite test の event_type / number / result 検証 |
| Req 3.6 / NFR 3.2〜3.4 (secret scrub + URL 全体不在) | `sn_build_payload_test.sh` Section 1/5/6 + `sn_notify_test.sh` Section 8 |
| Req 4.1〜4.5 / NFR 2.2 (fail-open + 有限 timeout) | `sn_notify_test.sh` Section 5/6/7/9/10 |
| Req 5.1〜5.5 / NFR 5.1 (監査ログ) | `sn_notify_test.sh` Section 1/2/3/5/6/7/8 |
| Req 6.1〜6.4 / NFR 1.2 (配布範囲 + 同期 + README) | File Structure Plan 通り / README.md 更新 + diff -r 確認（task 7 commit） |
| NFR 2.1 (gate OFF で payload 構築・curl ゼロ) | `sn_notify_test.sh` Section 1 |
| NFR 2.3 (新規 CLI 依存追加なし) | curl / jq のみ使用 / install.sh 改修不要 |
| NFR 3.1 (URL は env のみ取得) | コードベース全体に webhook URL 実値なし |
| NFR 4.1 (shellcheck / bash -n クリーン) | exit 0（verify ブロック実行結果） |
| NFR 4.2 (近接テスト 4 種カバー) | 4 種 sn_*_test.sh + 5 既存 test への assertion 追加 |
| NFR 4.4 (curl stub による外部依存ゼロ) | `sn_notify_test.sh` の curl stub harness |

## 実装上の判断（要点のみ）

- **task 1 で sn_* 5 関数を一括実装**: bash の遅延束縛のおかげで前方参照が許され、module
  内整合性が取りやすいため task 1 commit に `sn_log` / `sn_is_enabled` / `sn_scrub_secrets` /
  `sn_build_payload` / `sn_post_webhook` / `sn_notify` を全て含めた。task 2.1 / 3.1 / 3.2 は
  対応する近接テスト追加と marker のみ。AC traceability は task 単位で別途検証済（task-test
  境界整合には抵触しない / tasks-generation.md「task-test 境界整合の規約」）。
- **既存 callsite test への sn_notify stub 追加**: 各 callsite test は `extract_function` で
  関数本体を isolated に抽出する既存 harness。新規 `sn_notify` 呼び出しの unbound 回避と
  callsite hook 観測のためにローカル stub（call counter + 引数記録）を inline 追加した。
- **fr_finalize_success の hook 位置**: `fr_save_state` 失敗時の `rc=1` 経路でも recovered
  通知を発火させるため `return "$rc"` の **直前** に hook を置いた（observable な挙動として
  `rc=1` 伝播自体は変えない / 運用者は fr_warn ログと併せて判断できる）。
- **promote の number sentinel "0"**: branch 単位イベントだが payload schema 固定維持の
  ため `^[0-9]+$` 最小値 `0` を sentinel として使用（design.md Slack Payload Schema 確定済）。
- **stub への SC2034 抑止**: 遅延束縛で参照される env / 関数引数は shellcheck から未使用に
  見えるため inline `# shellcheck disable=SC2034` で抑止（既存 test ファイルの parity に従う）。

## 確認事項

なし。design.md / tasks.md の指示通りに実装でき、AC traceability も全て埋まった。

STATUS: complete
