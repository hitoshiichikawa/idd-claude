# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-27T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-416-impl--bug-quota-aware-you-ve-hit-your-session
- HEAD commit: 36a12b9047c020bfa92dd63e92f11b7631394a6c
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `qa_detect_rate_limit` Pass 2（`grep -F -- "You've hit your session limit"`）で平文行を substring 検出。test: `qa_detect_rate_limit_test.sh: session-limit-plain-tokyo-pm path`
- 1.2 — 検出時 `qa_run_claude_stage` が exit 99 を返却。test: `qa_run_claude_stage_test.sh: session-limit-plain-tokyo-pm rc=99`
- 1.3 — exit 99 経路が既存の `qa_handle_quota_exceeded`（`needs-quota-wait` 付与）に合流（既存契約温存）。test: 同上 rc=99 通過で担保
- 1.4 — Pass 1 (JSON) と Pass 2 (平文) が両方出力されても epoch を持つ最新検出が採用され二重 escalation なし。test: `qa_detect_rate_limit_test.sh: mixed JSON+plain both paths emitted` / `qa_run_claude_stage_test.sh: mixed JSON+plain rc=99 + reset_file numeric`
- 1.5 — 平文文言が含まれない場合 Pass 2 は無出力。test: `qa_detect_rate_limit_test.sh: normal-success does not trigger session_limit_plain_v1`
- 2.1 — `qa_parse_session_limit_reset` が GNU `date -d` で epoch 解決し、過去なら +86400 で「直近未来時刻」を保証。test: `resolved epoch is >= now` / `session-limit-plain-tokyo-pm epoch >= now`
- 2.2 — 既存 `qa_run_claude_stage` の reset_file atomic 書込ロジックを変更せず透過。test: `session-limit-plain-tokyo-pm reset_file numeric`
- 2.3 — 正規表現で `(<tz>)` を `BASH_REMATCH[4]` 抽出し `TZ=<tz>` 付き `date -d` で解決。test: `parse Asia/Tokyo == UTC equiv` / `session-limit-plain Asia/Tokyo == UTC equiv epoch`
- 2.4 — `7:40pm` と `19:40` が同一 epoch を返す。test: `parse 12h/24h same epoch` / `session-limit-plain 12h/24h equal epoch`
- 2.5 — reset 抽出 / epoch 解決失敗時は `qa_parse_session_limit_reset` return 1 → epoch 空で path のみ出力 → 呼び出し側で claude_rc 透過。test: `session-limit-plain-no-reset` / `session-limit-plain-no-reset rc passthrough` / `parse without 'resets' returns rc != 0`
- 2.6 — Pass 2 は `grep` で行を走査するため複数行入力でも単一行検出で成立。test: `session-limit-plain-multiline path` / `session-limit-plain-multiline rc=99`
- 3.1 — Pass 1 の jq フィルタ本文（v2 / v1 / synthetic_429 検出）は byte 等価で温存。既存 10 件のテスト（`v2-rate-limit-event-rejected` 等）が全件 PASS
- 3.2 — `qa_run_claude_stage` 冒頭 `QUOTA_AWARE_ENABLED != "true"` 早期 return は未変更。test: `opt-out session-limit-plain rc=1` / `opt-out session-limit-plain reset_file untouched`
- 3.3 — exit code 契約（0 / 99 / その他透過）を変更せず。既存 23 件のテストが全件 PASS で担保
- 3.4 — 新規 env var なし。`QUOTA_AWARE_ENABLED` / `QUOTA_RESUME_GRACE_SEC` / `QUOTA_RESET_STATE_FILE` / `LOG_DIR` の名前・既定値とも未変更
- 3.5 — 既存ラベル契約（`needs-quota-wait` / `claude-failed` / `claude-claimed` / `claude-picked-up`）は呼び出し側 `qa_handle_quota_exceeded` で温存
- 4.1 — `qa_run_claude_stage` 内の `qa_log "stage detected exceeded label=$stage_label path=${_path} reset_epoch=$_epoch"` が `path=session_limit_plain_v1` を含めて出力（既存ログフォーマット流用）
- 4.2 — reset 欠落時 `qa_warn "stage detected without reset label=$stage_label path=${_path}"` が同形式で warn 出力（既存パス流用）
- 4.3 — `qa_build_escalation_comment` テンプレートは未変更。検出経路差は呼び出し側に吸収
- NFR 1.1 — Pass 2 は `grep -F` 1 段 + bash function のみ。sleep / ブロッキング新規導入なし
- NFR 1.2 — sleep / wait の新規導入なし（diff で確認）
- NFR 2.1 — opt-out 早期 return パス未変更。test `opt-out session-limit-plain` 2 件で確認
- NFR 2.2 — `quota-aware.sh` 単体修正で完結、`repo-template/` ミラー対象外（既存配布構造）
- NFR 3.1 — `qa_detect_rate_limit_test.sh` に平文単独ケース追加（`session-limit-plain-tokyo-pm` 等）
- NFR 3.2 — JSON + 平文混在ケース追加（`mixed JSON+plain` 2 件）
- NFR 3.3 — 複数行分割ケース追加（`session-limit-plain-multiline` 2 件）
- NFR 3.4 — TZ 揺れ（Asia/Tokyo / UTC）と 12h/24h を test 4 件でカバー
- NFR 3.5 — 既存 10 + 23 件のテストは reviewer 環境でも全件 PASS（23 + 34 各テストファイル合計）

## Findings

なし

## Summary

Issue #416 で要求された全 numeric ID（Req 1.1〜1.5 / 2.1〜2.6 / 3.1〜3.5 / 4.1〜4.3 / NFR 1.1〜1.2 / 2.1〜2.2 / 3.1〜3.5）が実装と新規テストで観測可能にカバーされている。既存 JSON 検出経路は Pass 構造分離により byte 等価で温存され、両テストファイル合計 57 件（23 + 34）が PASS。変更範囲は quota-aware モジュールとその近接テストおよび fixture / spec docs に限定され、boundary 逸脱なし。

RESULT: approve
