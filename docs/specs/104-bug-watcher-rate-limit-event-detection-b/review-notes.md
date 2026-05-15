# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-15T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-104-impl-bug-watcher-rate-limit-event-detection-b
- HEAD commit: fb267b0
- Compared to: main..HEAD
- Round: 1 (PREV_RESULT: none — 前 Reviewer は HTTP 529 で即落ち、review-notes.md 未作成)
- Feature Flag Protocol: opt-out（対象 repo idd-claude `CLAUDE.md` で宣言確認。flag 観点の細目チェックは適用しない）
- Architect 不起動につき `tasks.md` / `design.md` なし。`_Boundary:_` 制約は適用対象外
- 変更ファイル: `local-watcher/bin/issue-watcher.sh` / `local-watcher/test/qa_detect_rate_limit_test.sh` (新規) / `local-watcher/test/qa_run_claude_stage_test.sh` (新規) / `local-watcher/test/stagec_pr_verify_test.sh` (新規) / `local-watcher/test/fixtures/qa_detect_rate_limit/*.jsonl` (新規 9 件) / `docs/specs/104-.../requirements.md` / `docs/specs/104-.../impl-notes.md`

## Verified Requirements

- **1.1** — `qa_detect_rate_limit` jq filter に `rate_limit_event_v2` 経路（`type=="rate_limit_event"` かつ `rate_limit_info.status=="rejected"`）を実装。`qa_run_claude_stage` で epoch 付き検出時に exit 99 を返す（`local-watcher/bin/issue-watcher.sh:362-411, 442-486`）。検証: `qa_detect_rate_limit_test.sh` `v2-rate-limit-event-rejected (all)` / `qa_run_claude_stage_test.sh` rc=99
- **1.2** — `qa_run_claude_stage` の epoch 採用ブランチで `printf '%s\n' "$_epoch" > "$reset_file"`（`issue-watcher.sh:474`）。検証: `qa_run_claude_stage_test.sh` `v2-rate-limit-event-rejected reset_file == 1778821200`
- **1.3** — jq filter で `$nested = .rate_limit_info | (.resetsAt // .resets_at // .reset_at)` を top-level より優先（`issue-watcher.sh:381-388`）。検証: `v2-numeric-epoch` (ネスト位置 numeric epoch 1747375200) / `v2-rate-limit-event-rejected` (ネスト位置 ISO 8601)
- **1.4** — 検出 TSV に epoch なし行のみある場合、`qa_warn "stage detected without reset ..."` を出力し `claude_rc` 透過、`reset_file` を空に戻す（`issue-watcher.sh:481-487`）。検証: `v2-no-reset` rc=0 / reset_file=""
- **2.1** — `rate_limit_event_v1` 経路（`status=="exceeded"` top-level）が jq filter の elif 分岐に存在（`issue-watcher.sh:368-371`）。検証: `v1-rate-limit-event-exceeded` rc=99 + epoch=1778821200
- **2.2** — top-level 探索順 `.resetsAt // .reset_at // .resets_at` が保持される（`issue-watcher.sh:389-392`）。検証: `v1-reset-at-snake` (`reset_at` snake_case) rc=99 + epoch=1778821200
- **3.1** — `synthetic_429_result` 経路（`type=="result"` かつ `is_error==true` かつ `api_error_status==429`）を jq filter に追加（`issue-watcher.sh:372-376`）。検証: `synthetic-429-result` rc=99 + epoch=1778821200（同居 `rate_limit_info` から epoch 抽出）
- **3.2** — synthetic 429 単独で reset 欠落時は detect TSV に path のみ残り、`qa_warn ... path=synthetic_429_result` 経由で既存フロー透過（`issue-watcher.sh:482-484`）。検証: `synthetic-429-no-reset` rc=0 / reset_file=""
- **3.3** — quota 検出 / fallback のいずれの経路でも `qa_log` / `qa_warn` に `path=${_path}` および `label=$stage_label` を含むログ行を出力（`issue-watcher.sh:475, 484`）。grep 可能な経路名 `rate_limit_event_v2` / `rate_limit_event_v1` / `synthetic_429_result` のいずれかが付与される
- **3.4** — 通常 result（`is_error:false`）+ `allowed` only の rate_limit_event は jq filter の selector いずれにも match せず detect TSV 空 → `claude_rc` 透過。検証: `normal-success` rc=0 / detect 出力空
- **4.1** — Stage C `case 0)` 内に `gh pr view --repo "$REPO" --head "$BRANCH" --json url --jq '.url'` を実装（`issue-watcher.sh:3450-3454`）。検証: `stagec_pr_verify_test.sh` PR 実在ケース rc=0
- **4.2** — `_stagec_pr_url` が空 / `_stagec_verify_rc != 0` の場合 `mark_issue_failed "stageC-pr-missing" ...` を呼ぶ（`issue-watcher.sh:3461-3463`）。検証: `stagec_pr_verify_test.sh` 空 URL ケース `mark_issue_failed == "stageC-pr-missing"`
- **4.3** — PR 実在時のみ `echo "✅ ... Stage C 完了 / PR 作成済み (${_stagec_pr_url})"` + `return 0`（`issue-watcher.sh:3455-3458`）。検証: `stagec_pr_verify_test.sh` `mark_issue_failed 未呼出`
- **4.4** — `gh` rc != 0 ケースも同じ false-success 防止経路（`_stagec_verify_rc -eq 0 && -n "$_stagec_pr_url"` の AND 条件）でカバー。検証: `stagec_pr_verify_test.sh` `gh rc=1` / `gh rc=124` 両ケースで `stageC-pr-missing` mark + rc=1
- **5.1** — `local-watcher/test/fixtures/qa_detect_rate_limit/v2-rate-limit-event-rejected.jsonl` 配置済
- **5.2** — `v1-rate-limit-event-exceeded.jsonl` 配置済
- **5.3** — `synthetic-429-result.jsonl` 配置済
- **5.4** — 上記 3 種 fixture + `qa_run_claude_stage_test.sh` wrapper 経由でいずれも exit 99 相当を観測（PASS）
- **5.5** — 既存 `parse_review_result_test.sh` を実行し 19 PASS / 0 FAIL を確認
- **NFR 1.1** — `qa_run_claude_stage` 冒頭で `QUOTA_AWARE_ENABLED != "true"` 時の opt-out 早期 return 経路は保持（diff の `qa_run_claude_stage()` 関数頭部は変更外、`local-watcher/bin/issue-watcher.sh` 既存実装）。検証: `qa_run_claude_stage_test.sh` opt-out セクション全 3 PASS（rc=0 透過 / reset_file untouched / claude rc=7 透過）
- **NFR 1.2** — `QUOTA_AWARE_ENABLED` 名・exit code 契約（0/99/その他）変更なし。`return "$claude_rc"` で claude 非 0 rc を透過。検証: `qa_run_claude_stage_test.sh` `normal-success with claude rc=2`
- **NFR 2.1** — 経路名 + stage_label を含むログ行（`qa_log "stage detected exceeded label=$stage_label path=${_path} reset_epoch=$_epoch"` / `qa_warn "stage detected without reset label=$stage_label path=${_path} ..."`）が grep 可能
- **NFR 2.2** — Stage C 不在 verify 時 `qa_warn "stageC PR verify failed issue=#$NUMBER branch=$BRANCH verify_rc=$_stagec_verify_rc pr_url='${_stagec_pr_url:-(empty)}'"` + Issue コメント本文に branch / verify_rc を含める（`issue-watcher.sh:3464-3465`）
- **NFR 3.1** — 全テストはローカル `bash + jq + awk` のみで完結。`fake_claude` / `fake gh` で外部 API を遮断（`qa_run_claude_stage_test.sh:95-100` / `stagec_pr_verify_test.sh:71-72`）

## 副次修正（PIPESTATUS preservation / impl-notes.md 確認事項 1）

`qa_run_claude_stage` で `... | tee | qa_detect_rate_limit ... || true` が PIPESTATUS を 0 で上書きする latent bug を `set +e` / `_qa_pipestatus=("${PIPESTATUS[@]}")` / `set -e` パターンに置換（`issue-watcher.sh:451-455`）。これは Issue #66 由来の既存欠陥で、本 Issue のテスト導入時に露見した。Req に直接対応する項目ではないが、Req 1.4 / 3.2 の「claude_rc 透過」を実際に正しく動作させる前提条件であり、修正範囲としては合理的。

## テスト実行結果（Reviewer 環境で再実行）

```
$ bash local-watcher/test/qa_detect_rate_limit_test.sh
PASS: 10, FAIL: 0

$ bash local-watcher/test/qa_run_claude_stage_test.sh
PASS: 23, FAIL: 0

$ bash local-watcher/test/stagec_pr_verify_test.sh
PASS: 8, FAIL: 0

$ bash local-watcher/test/parse_review_result_test.sh
PASS: 19, FAIL: 0
```

Total 60 PASS / 0 FAIL。impl-notes.md 記載の結果と一致。

## Findings

なし

## Summary

Requirements 1.1〜1.4 / 2.1〜2.2 / 3.1〜3.4 / 4.1〜4.4 / 5.1〜5.5 / NFR 1.1〜3.1 のすべての numeric ID に対して、対応する実装（`local-watcher/bin/issue-watcher.sh` の jq filter 3 経路統合・detect TSV 解釈ロジック・Stage C PR verify 分岐）とテスト（新規 3 ファイル 41 ケース + 既存 1 ファイル 19 ケース）が紐づけられ、Reviewer 環境での再実行も green。副次の PIPESTATUS 修正は Req 1.4 / 3.2 の動作前提として合理的かつ後方互換性ありで、Out of Scope の Stage A/B verify 強化や opt-in / opt-out 既定値変更には踏み込んでいない。境界逸脱・AC 未カバー・missing test のいずれも検出されず。

RESULT: approve
