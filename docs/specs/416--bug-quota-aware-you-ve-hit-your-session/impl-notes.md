# Implementation Notes — Issue #416

## 概要

quota-aware モジュールが claude CLI の平文 `You've hit your session limit · resets
<time>` を検出できず `claude-failed` に誤分類していた Bug を修正した。`qa_detect_rate_limit`
に第 4 検出経路 `session_limit_plain_v1` を追加し、既存 JSON 経路（rate_limit_event_v2 /
v1 / synthetic_429_result）と同じ deferral 経路（exit 99 + reset 永続化）に合流させる。

## 設計判断（Open Questions の確定）

requirements.md の 3 つの Open Questions について、以下の方針で確定した。

### 1. マッチ粒度: `You've hit your session limit` substring のみで判定

- **採用**: 「`resets` 部分まで含めて判定」よりも substring 一致を採用
- **理由**: Claude Code のバージョン差で `resets` の有無や記号（中黒 `·` / TZ 括弧表記）が
  変わるリスクの方が、誤検出リスクより高い。本文言は claude CLI が session 上限到達時に
  特定的に出力するエラーメッセージであり、一般のユーザー出力と衝突する確率は低い
- **副次効果**: reset 部分が抽出できなくても detection_path だけは観測でき、reset 欠落
  fallback（既存 JSON 経路と同等の安全側）に倒せる（Req 2.5 担保）
- **実装**: `grep -F` で fixed-string 検索（regex escape 不要、quote 済み入力）

### 2. 直近の該当時刻決定ロジック: 過去なら翌日 +86400 秒

- **採用**: 解決された epoch が現在 epoch より過去なら +86400 して翌日同時刻を採用、
  未来ならそのまま採用
- **理由**: GNU `date -d "7:40pm"` は常に「今日の 19:40」を返す。実運用では quota メッセージは
  reset の **未来時刻**を示しているはずだが、日付境界をまたいだ場合や処理タイミングの揺らぎで
  「今日の 19:40 が現在より過去」になるケースがあるため、その場合は翌日を採用する
- **24 時間以内の最近未来時刻**を一意に決定でき、`qa_persist_reset_time` に渡せる numeric
  epoch が必ず未来になる
- **trade-off**: 仮に CLI が「数日前の reset 時刻」を出した場合、本ロジックは「今日 or 翌日」に
  解釈してしまう。ただしそのケースは現実には起き得ない（claude CLI が「過ぎた reset」を出す
  意味がない）ため許容する

### 3. detection_path 識別子: `session_limit_plain_v1`

- **採用**: 既存 JSON 経路の `rate_limit_event_v2` / `rate_limit_event_v1` /
  `synthetic_429_result` と同じ snake_case + 検出元の意味 + `_v1` サフィックスの命名規約に
  従い `session_limit_plain_v1` とした
- **理由**: 将来 claude CLI が文言を変えた場合に `session_limit_plain_v2` を追加する余地を
  残せる（既存 `_v2` 命名が JSON スキーマバージョン拡張の前例）

## 変更ファイル

| ファイル | 種別 | 主な変更 |
|---|---|---|
| `local-watcher/bin/modules/quota-aware.sh` | 修正 | `qa_parse_session_limit_reset` 純粋関数新設 / `qa_detect_rate_limit` を 2 pass 構造（JSON + 平文）に拡張 |
| `local-watcher/test/qa_detect_rate_limit_test.sh` | 修正 | `qa_parse_session_limit_reset` を extract source リストに追加 / 平文経路と純粋関数のテスト 13 件追加 |
| `local-watcher/test/qa_run_claude_stage_test.sh` | 修正 | `qa_parse_session_limit_reset` を extract source リストに追加 / 平文経路の統合テスト 11 件追加 |
| `local-watcher/test/fixtures/qa_detect_rate_limit/session-limit-plain-*.txt` | 新規 | 平文 / 複数行混在 / TZ 揺れ / reset 欠落 / JSON+平文混在の 7 fixture |

## AC Traceability

| AC ID | カバー方法 |
|---|---|
| 1.1 | `qa_detect_rate_limit` の Pass 2 が `grep -F` で平文 substring 検出。`qa_detect_rate_limit_test.sh: session-limit-plain-tokyo-pm path` |
| 1.2 | `qa_run_claude_stage` の検出 TSV 解釈ロジックは既存のまま動作（epoch を持つ最新検出を採用）。`qa_run_claude_stage_test.sh: session-limit-plain-tokyo-pm rc=99` |
| 1.3 | `qa_run_claude_stage` が exit 99 を返すことで呼び出し側が `qa_handle_quota_exceeded` 経路（needs-quota-wait 付与 / claude-failed 不付与）へ分岐する既存契約に合流（design.md の Stage Wrapping Pattern 通り）。テスト: `qa_run_claude_stage_test.sh: session-limit-plain-tokyo-pm rc=99` |
| 1.4 | epoch 持ち検出が 1 件以上あれば 1 つを採用する既存 TSV 解釈で二重 escalation を抑止。`qa_run_claude_stage_test.sh: mixed JSON+plain rc=99` / `qa_detect_rate_limit_test.sh: mixed JSON+plain both paths emitted` |
| 1.5 | grep `-F` で session limit 平文が含まれない入力では Pass 2 が無出力。`qa_detect_rate_limit_test.sh: normal-success does not trigger session_limit_plain_v1` |
| 2.1 | `qa_parse_session_limit_reset` が GNU date で「直近の該当時刻」を解決し、過去なら +86400。`qa_detect_rate_limit_test.sh: resolved epoch is >= now` / `qa_run_claude_stage_test.sh: session-limit-plain-tokyo-pm epoch >= now` |
| 2.2 | `qa_run_claude_stage` 既存ロジックが reset_file に epoch を atomic 書込（変更なし）。`qa_run_claude_stage_test.sh: session-limit-plain-tokyo-pm reset_file numeric` |
| 2.3 | `qa_parse_session_limit_reset` が `(<tz>)` 部を `BASH_REMATCH[4]` で抽出し `TZ=<tz>` 付き `date -d` で解決。`qa_detect_rate_limit_test.sh: parse Asia/Tokyo == UTC equiv` |
| 2.4 | `7:40pm` と `19:40` は GNU date が同一として扱う。`qa_detect_rate_limit_test.sh: parse 12h/24h same epoch` / `session-limit-plain 12h/24h equal epoch` |
| 2.5 | reset 抽出 / epoch 解決失敗時は `qa_parse_session_limit_reset` が return 1、`qa_detect_rate_limit` は detection_path のみ epoch 空で出力。`qa_run_claude_stage` 既存ロジックが reset 欠落 fallback（claude_rc 透過 + warn）に倒す。`qa_run_claude_stage_test.sh: session-limit-plain-no-reset rc passthrough` |
| 2.6 | `qa_detect_rate_limit` Pass 2 は `grep -F` で行をまたいで判定。`qa_detect_rate_limit_test.sh: session-limit-plain-multiline path` / `qa_run_claude_stage_test.sh: session-limit-plain-multiline rc=99` |
| 3.1 | 既存 jq fold（Pass 1）は変更していない。既存 10 件のテスト（qa_detect_rate_limit_test.sh）すべて pass、既存 23 件のテスト（qa_run_claude_stage_test.sh）すべて pass |
| 3.2 | `qa_run_claude_stage` 冒頭の `QUOTA_AWARE_ENABLED != "true"` 早期 return は変更なし。`qa_run_claude_stage_test.sh: opt-out session-limit-plain rc=1` / `opt-out session-limit-plain reset_file untouched` |
| 3.3 | `qa_run_claude_stage` の戻り値（0 / 99 / N≠0,99）契約は変更なし。既存 23 件のテストで担保 |
| 3.4 | 既存 env var（`QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC` / `QUOTA_RESET_STATE_FILE` / `LOG_DIR`）の Config 節は変更していない。新規 env var を追加していない |
| 3.5 | `qa_handle_quota_exceeded` のラベル付け替えロジック（`claude-claimed` → `needs-quota-wait`）は変更なし。`qa_run_claude_stage` が exit 99 で抜けた後の挙動は detection_path に依存しないため、既存ラベル契約は不変 |
| 4.1 | `qa_run_claude_stage` の `qa_log "stage detected exceeded label=$stage_label path=${_path} reset_epoch=$_epoch"` 既存ログが `path=session_limit_plain_v1` を含めて出力される |
| 4.2 | `qa_run_claude_stage` の `qa_warn "stage detected without reset label=$stage_label path=${_path}"` 既存ログが平文経路でも同形式で出力される |
| 4.3 | `qa_handle_quota_exceeded` の escalation コメントテンプレート（`qa_build_escalation_comment`）は変更していない。検出経路の差異は呼び出し側ロジックに吸収される |
| NFR 1.1 | 平文 pass は `grep -F` 1 段 + bash function 呼び出しのみで sleep / 追加同期は無し。既存 stream-json throughput（数 KB/s）に対するオーバーヘッドは無視可能 |
| NFR 1.2 | sleep / wait などのブロッキング待機を新規導入していない |
| NFR 2.1 | `qa_run_claude_stage` 冒頭の opt-out 早期 return パスは未変更。テスト `opt-out session-limit-plain rc=1` で確認 |
| NFR 2.2 | `repo-template/` 側にモジュールは配布されないため re-install は不要。`install.sh` 再実行で `~/bin/modules/quota-aware.sh` が更新される（既存配布ロジック流用） |
| NFR 3.1 | `qa_detect_rate_limit_test.sh` に平文単独ケースを追加 |
| NFR 3.2 | `qa_detect_rate_limit_test.sh: mixed JSON+plain both paths emitted` / `qa_run_claude_stage_test.sh: mixed JSON+plain rc=99` |
| NFR 3.3 | `qa_detect_rate_limit_test.sh: session-limit-plain-multiline path` / `qa_run_claude_stage_test.sh: session-limit-plain-multiline rc=99` |
| NFR 3.4 | TZ 揺れ: `qa_detect_rate_limit_test.sh: parse Asia/Tokyo == UTC equiv` / 12h・24h: `parse 12h/24h same epoch` |
| NFR 3.5 | 既存テスト `qa_detect_rate_limit_test.sh` 10 件・`qa_run_claude_stage_test.sh` 23 件すべて pass を確認 |

## 静的解析・テスト結果

- `shellcheck local-watcher/bin/modules/quota-aware.sh local-watcher/test/qa_detect_rate_limit_test.sh local-watcher/test/qa_run_claude_stage_test.sh`: clean
- `bash -n` syntax check: clean
- `bash local-watcher/test/qa_detect_rate_limit_test.sh`: PASS 23 / FAIL 0（既存 10 + 新規 13）
- `bash local-watcher/test/qa_run_claude_stage_test.sh`: PASS 34 / FAIL 0（既存 23 + 新規 11）

## 二重管理同期確認

- `diff -r .claude/agents repo-template/.claude/agents`: 空（変更なし）
- `diff -r .claude/rules repo-template/.claude/rules`: 空（変更なし）
- `local-watcher/bin/modules/quota-aware.sh` は `install.sh` 経由でユーザーホームに配布される
  ファイルであり、`repo-template/` 側にミラー対象は無い（既存配布構造に従う）

## 確認事項（人間判断を仰ぎたい点）

- **GNU date 依存**: `qa_parse_session_limit_reset` は GNU `date -d` の `7:40pm` 形式と
  `TZ=...` env による解決に依存している。watcher 全体は CLAUDE.md「技術スタック」で
  Linux / macOS / WSL 動作と謳っているが、macOS BSD date は本パスを満たさない。失敗時は
  return 1 で reset 欠落 fallback に倒れるため macOS 実行環境でも regression にはならないが、
  macOS 環境で quota 自動 resume が機能しないことになる。必要なら BSD date の `-jf` 形式
  fallback を別 Issue で追加検討（既存の `qa_format_iso8601` には GNU / BSD 両対応があるため
  同等の対応は可能）
- **平文 substring の文言依存**: `You've hit your session limit` を fixed string match
  しているため、claude CLI が文言を `You have reached your session limit` 等に変えた場合
  検出できなくなる。バージョンアップ時の観測責務として、運用側で `$LOG_DIR/issue-*.log` に
  `session_limit_plain_v1` 検出ログが残るかをモニタリングすることを推奨
- **「直近の該当時刻」採用ロジック**: 解決 epoch が過去なら +86400（翌日）採用としたが、
  仮に CLI が「数時間後の reset」ではなく「数日後の reset」を出すケースが将来現れた場合
  本ロジックでは正しく解釈できない。現状の claude CLI 観測サンプルは「今日 or 翌日の中の
  時刻」を返すため許容したが、要件側で前提が変わった場合は別 Issue で再設計が必要
