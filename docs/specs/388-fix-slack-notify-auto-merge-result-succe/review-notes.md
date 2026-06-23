# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-388-impl-fix-slack-notify-auto-merge-result-succe
- HEAD commit: 0bc2e5c97f24e03184b0801c3d3a20f307bad297
- Compared to: main..HEAD
- 変更ファイル: README.md / impl-notes.md / requirements.md / local-watcher/bin/issue-watcher.sh / local-watcher/bin/modules/auto-merge-design.sh / local-watcher/bin/modules/auto-merge-merged.sh (新規) / local-watcher/bin/modules/auto-merge.sh / local-watcher/bin/modules/slack-notify.sh / local-watcher/test/auto-merge-design_test.sh / local-watcher/test/auto-merge-merged_test.sh (新規) / local-watcher/test/auto-merge_test.sh / local-watcher/test/sn_build_payload_388_test.sh (新規)
- tasks.md / design.md は存在せず（単一実装パス。Architect 起動なし）。`_Boundary:_` アノテーション無しのため、boundary 逸脱判定は impl-notes.md 採用判断の「Slack 通知 emitter + auto-merge 関連 module + 補助 processor 新設」スコープに対して行う。
- CLAUDE.md に `## Feature Flag Protocol` 節は存在しない（line 328 の rule index 内の表記述のみ）。標準 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）で判定。

## Verified Requirements

- **1.1** — `local-watcher/bin/modules/auto-merge.sh` L180 で `sn_notify auto-merge "$pr_number" "$pr_url" armed "armed (squash on green checks) head=... sha=..."` に変更。テスト: `auto-merge_test.sh`「#388 Req 1.1: armed callsite は result=armed を渡す」/ `sn_build_payload_388_test.sh` Section 4「armed text field に result=armed」
- **1.2** — `local-watcher/bin/modules/auto-merge-design.sh` L194 で同形 (`auto-merge-design` 版)。テスト: `auto-merge-design_test.sh`「#388 Req 1.2: design armed callsite は result=armed」
- **1.3** — detail 文言 `armed (squash on green checks) head=<ref> sha=<sha>` を impl/design 両 callsite で固定。Slack 上で「status checks が green になった後に GitHub が merge する」運用者向け表現として観測可能。テスト: `auto-merge_test.sh` / `auto-merge-design_test.sh` の `case "$SN_NOTIFY_LAST_DETAIL"` ブロック + `sn_build_payload_388_test.sh` Section 4「Req 1.3: armed blocks[0].text に「armed (squash on green checks)」」
- **1.4** — `slack-notify.sh` の `sn_build_payload` の引数検証 (event_type enum / 数値検証 / fail-open) は無変更で新 enum を 1 行追加するのみ（diff L117-127）。テスト: `sn_build_payload_388_test.sh` Section 1 (新 enum 受理) / Section 3 (不正値 rejection)
- **2.1** — `auto-merge-merged.sh` の `amm_check_one_pending` (L221-263) で `state=MERGED` かつ `mergedAt!=null` のときに `sn_notify auto-merge-merged ... merged "merged via auto-merge at ${merged_at}"` を 1 回発火 + `amm_remove_pending`。armed 成功直後に `auto-merge.sh` L189-191 から `amm_save_pending` で pending state を積む。テスト: `auto-merge-merged_test.sh` Section 6 / Section 11 Case B + `auto-merge_test.sh`「#388 Req 2.1: amm_save_pending event_type=auto-merge-merged」
- **2.2** — `auto-merge-design.sh` L198-201 で `amm_save_pending` を `auto-merge-design-merged` event_type で呼ぶ。`amm_check_one_pending` 側は state file の event_type を読んで通知する。テスト: `auto-merge-merged_test.sh` Section 6 design 経路 + `auto-merge-design_test.sh`「#388 Req 2.2」
- **2.3** — `amm_check_one_pending` は通知発火直後に `amm_remove_pending` を呼び state file を削除。次サイクル以降は state file 不在のため何も発火しない。テスト: `auto-merge-merged_test.sh` Section 6「Req 2.3 / NFR 1.2: 同一 PR の 2 回目観測で sn_notify は呼ばれない」
- **2.4** — state file は `amm_save_pending` でしか書かれず、これは `auto-merge.sh` / `auto-merge-design.sh` の armed 成功 path のみが呼ぶ。人間が `gh pr merge` で手動 merge した PR は state file に積まれていないため `process_auto_merge_merged` の対象外。テスト: `auto-merge-merged_test.sh` Section 8 (CLOSED 観測で通知なし) / Section 11 (state を積まないと通知が出ないことを統合検証)
- **2.5** — `amm_resolve_gate_enabled` が `SLACK_NOTIFY_ENABLED!=true` で rc=1 → `process_auto_merge_merged` / `amm_check_one_pending` / `amm_save_pending` 全てが副作用ゼロで return。テスト: `auto-merge-merged_test.sh` Section 1 + Section 11 Case A「merged gate OFF で gh ゼロ呼び出し」
- **2.6** — armed 通知側は既存 `sn_notify` の URL preflight (WARN 1 行 + fail-open) を継承。新 merged 通知も `sn_notify` 経由なので同等。既存 `sn_notify_test.sh` Section 2 で担保（変更なし）
- **3.1** — `SLACK_NOTIFY_ENABLED` 未設定 / `false` 時に新 `process_auto_merge_merged` も `amm_save_pending` も副作用ゼロ。既存 `sn_notify` の挙動も変えていない。テスト: `auto-merge-merged_test.sh` Section 1 / Section 3 / Section 11 Case A
- **3.2** — 既存 env var (`SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` / `SLACK_NOTIFY_TIMEOUT`) は意味と既定値を変更せず diff で確認可能。新規 env (`SLACK_NOTIFY_MERGED_ENABLED` 等) は追加のみ
- **3.3** — `failed-recovery` / `needs-decisions-auto-continue` / `promote` の callsite は今回 diff に含まれず文面・event_type に変化なし
- **3.4** — README.md (diff line 1371 + 2362 直後) に Slack 通知 emitter 行の「Migration Note (#388)」段落と Auto-Merge Processor (#352) 節の「用語整理 (#388)」段落を同一 PR (commit `d1586ae`) で追加。`SLACK_NOTIFY_ENABLED=true` 既存ユーザ向け armed result 値変化 + 新 merged 通知 opt-in 情報を明記
- **3.5** — `slack-notify.sh` sn_build_payload の event_type enum 検証は既存 `case ... in ... ;; *) sn_warn + return 1 ;;` を保持したまま新 2 値を追加するのみ。テスト: `sn_build_payload_388_test.sh` Section 3 で typo / 大文字 / 空文字列が rejection されることを確認
- **4.1** — `amm_log` で MERGED 観測時に 1 行構造化ログ。`sn_notify` 側の既存 `sn_log` で event/number/result/http_status/host を含む 1 行ログを継承。テスト: `auto-merge-merged_test.sh` Section 6 / 既存 `sn_notify_test.sh` Section 3
- **4.2** — `amm_check_one_pending` の gh 失敗時は `amm_warn` 1 行 + state file 維持 + return 0（次サイクル再試行）。テスト: `auto-merge-merged_test.sh` Section 9「NFR 4.2: gh 失敗で sn_notify 呼ばれない / state file 維持」
- **4.3** — `sn_build_payload` の既存 `sn_scrub_secrets` 適用は新 event_type でも共通 payload 経路を通る。テスト: `sn_build_payload_388_test.sh` Section 6「Req 4.3: ghp_ token が [REDACTED] 置換」
- **4.4** — `amm_log` / `amm_warn` は webhook URL を引数に取らず、ログにも出力しない。既存 `sn_notify` の host のみログ規約を継承
- **NFR 1.1, 1.2** — state file 削除を重複抑止フラグとして使用。テスト: `auto-merge-merged_test.sh` Section 6 (2 回目 check で発火なし) + Section 11 Case B (全 MERGED 観測後に pending 0 件)
- **NFR 2.1** — `amm_log` は 1 行のみ出力。冗長 debug なし
- **NFR 2.2** — `amm_warn` は `>&2` 出力（diff 確認）
- **NFR 3.1** — 新規 CLI 依存ゼロ（gh / jq / mktemp / mv / ls / rm のみ。既存 module で使用済）
- **NFR 3.2** — `AUTO_MERGE_MERGED_MAX_CHECKS` (既定 50 / 不正値は 50 にフォールバック) で `gh pr view` 呼び出し件数に上限あり。テスト: `auto-merge-merged_test.sh` Section 11 Case C「MAX_CHECKS=2 / =-1 (既定 50 へ正規化)」
- **NFR 3.3** — `SLACK_NOTIFY_TIMEOUT` は既存 `sn_post_webhook` で適用（無変更）。新 `gh pr view` 側は `AUTO_MERGE_MERGED_GH_TIMEOUT` (既定 60 / 0 以下は 60 へ正規化) を `timeout` コマンドで適用
- **NFR 4.1** — `SLACK_NOTIFY_MERGED_ENABLED` 未設定 / `=true` 厳密一致以外で全副作用関数が外部副作用ゼロで return。テスト: `auto-merge-merged_test.sh` Section 1 / Section 3 / Section 11 Case A
- **NFR 4.2** — MERGED but mergedAt 空のとき偽陽性通知を発火させず state 維持で次サイクル再試行。テスト: `auto-merge-merged_test.sh` Section 9 (gh 失敗ケース + MERGED but mergedAt 空ケース)

## Boundary 確認

tasks.md / design.md は存在せず（Architect 未起動の単一実装パス）、formal な `_Boundary:_` アノテーションは無い。impl-notes.md「採用した設計判断」が宣言した実装スコープ (auto-merge.sh / auto-merge-design.sh / slack-notify.sh / 新 auto-merge-merged.sh / issue-watcher.sh の config + entry point / README / 関連テスト) と、CLAUDE.md「機能追加ガイドライン」の方針 (新規 processor は `modules/<name>.sh` に切り出し、新 prefix namespace、opt-in gate、root↔repo-template 同期) に照合:

- 新 module `auto-merge-merged.sh` は新 prefix `amm_` で切り出し（既存 `am_` / `amd_` と非衝突）。本体 inline ではなく独立 module 設計を遵守
- 新 env (`SLACK_NOTIFY_MERGED_ENABLED` / `AUTO_MERGE_MERGED_*`) は既定 false / 未設定で本機能導入前と等価 (NFR 4.1)。既存 env 名・既定値・exit code 意味は不変
- 既存 callsite (`auto-merge.sh` / `auto-merge-design.sh`) への変更は armed result 値変更 + `declare -F amm_save_pending` ガード越しの 1 行 hook 追加のみ。両 module の責務範囲を逸脱せず
- `repo-template/local-watcher/` は存在しない（impl-notes.md 確認済）ため二重管理対象外。`repo-template/.claude/{agents,rules}` の変更も無く byte 一致は保たれている
- README 同期は同一 PR (commit `d1586ae`) で実施済

stage-checkpoint / promote-pipeline / pr-iteration 等の他 processor への変更は無く、本 Issue スコープ外コンポーネントへの逸脱なし。

## テスト実行確認

reviewer 側で以下を再実行し、すべて PASS を確認（impl-notes.md 集計と整合）:

- `bash local-watcher/test/sn_build_payload_388_test.sh` → PASS=23 FAIL=0
- `bash local-watcher/test/auto-merge-merged_test.sh` → PASS=54 FAIL=0
- `bash local-watcher/test/auto-merge_test.sh` → PASS=65 FAIL=0
- `bash local-watcher/test/auto-merge-design_test.sh` → PASS=70 FAIL=0

## Findings

なし

## Summary

すべての numeric AC (Req 1.1–1.4 / 2.1–2.6 / 3.1–3.5 / 4.1–4.4) および NFR (1.1–1.2 / 2.1–2.2 / 3.1–3.3 / 4.1–4.2) について実装と単体テストの両方を確認できた。新 module は CLAUDE.md「機能追加ガイドライン」の方針（独立 module / 新 prefix namespace / opt-in gate / 既定値で本機能導入前と等価）に整合し、boundary 逸脱なし。README migration note も同一 PR で追加済。reviewer 側で 4 テストスイートを再実行し全 green。

RESULT: approve
