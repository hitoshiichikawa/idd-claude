# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-25T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-228-impl-feat-watcher-dispatch-path-overlap-overl
- HEAD commit: a69053d
- Compared to: main(4ca90fc)..HEAD

CLAUDE.md に `## Feature Flag Protocol` 節は **存在しない**ため opt-out 扱い。flag 観点の細目は
適用せず、通常の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）でのみ判定した。
Reviewer 起動時点で impl-notes.md は `STATUS: complete`（partial 経路ではない）。

## Verified Requirements

### Requirement 1（path-overlap 見送り時の可視化コメント）— 既存実装で成立（無変更を確認）
- 1.1 — `po_apply_awaiting_slot`（promote-pipeline.sh:524-602）が sticky comment（marker `awaiting-slot:v1`）を post/update。本 PR で無変更。`po_check_dispatch_gate`（同 801-）の overlap 検出経路から呼ばれる。
- 1.2 — `po_apply_awaiting_slot` が `--add-label "$LABEL_AWAITING_SLOT"` を付与（promote-pipeline.sh:534-535）。無変更。
- 1.3 — `po_format_holders_table_md` による重複 top-level path × holder Issue 番号の表形式表示（promote-pipeline.sh:546-548）。無変更。
- 1.4 — ラベル付与失敗でも early return せず sticky comment 投稿を継続（promote-pipeline.sh:530-539 のコメント方針）。本 PR の busy-wait 側も同方針（po_apply_busy_wait_signal:691-697）。

### Requirement 2（prefix 欠落 overlap 検出の頑健性 / 回帰検証）— #221 normalize で成立、回帰テストで担保
- 2.1 — `po_compute_overlap` の normalize（先頭 `./` 剥がし → 連続スラッシュ正規化 → top-level 抽出。promote-pipeline.sh:496-507）。test-dispatch-visibility.sh:79-91（full path / ルート直下ファイルの top-level 一致）でカバー。
- 2.2 — overlap 非空 → 既存 `po_check_dispatch_gate` が Req 1 経路を発火。test-dispatch-visibility.sh:99-101（#221 回帰: prefix 欠落 `modules/` 不一致でも共通 `README.md` が overlap として残り見送り成立）でカバー。
- 2.3 — candidate / holder 双方を同一 normalize で突合（promote-pipeline.sh:504-506）。test-dispatch-visibility.sh:84-86, 108-111 でカバー。
- 2.4 — candidate 空配列は overlap 空 → 阻止しない。test-dispatch-visibility.sh:104-106 でカバー。

### Requirement 3（多忙サイクル待ちの可視化）— 本 PR で新規実装
- 3.1 — `po_check_busy_wait`（promote-pipeline.sh:719-748）が連続見送り tick を加算し閾値到達で `po_apply_busy_wait_signal` を発火。dispatcher の `if [ -z "$slot" ]` 経路（issue-watcher.sh:7504-7513）に配線。test:121-159（tick 単調増加 / 閾値到達でシグナル発生）でカバー。
- 3.2 — 全 slot lock 中（`slot=""` 持ち越し。issue-watcher.sh:7493-7499）も同一 `if [ -z "$slot" ]` 経路に到達し busy-wait を発火。理由文字列に「別インスタンス稼働」を含む（issue-watcher.sh:7512）。README に flock skip 時の対象範囲を明記。
- 3.3 — dispatch 成功見込み時に `po_busy_wait_reset`（issue-watcher.sh:7519-7521 / promote-pipeline.sh:704-710）で tick state を削除。ラベル除去は既存 `po_clear_awaiting_slot`（無変更）が担う。test:130-132 でカバー。
- 3.4 — 閾値未満は無音（promote-pipeline.sh:744-746）。test:135-146（4 回見送りで gh 呼び出しゼロ）でカバー。

### Requirement 4（見送りシグナルの冪等性）
- 4.1 — `po_apply_busy_wait_signal` が marker `busy-wait:v1` 付きコメントを検索 → PATCH/create で 1 件集約（promote-pipeline.sh:721-737）。既存 `po_apply_awaiting_slot` と同一の sticky パターン。
- 4.2 — 1 見送り状態 = sticky 1 件。state ファイルも 1 件に収束。test:205-217（state ファイル 1 件 / tick 累積）でカバー。
- 4.3 — 解消時ラベル除去は既存 `po_clear_awaiting_slot`（無変更。promote-pipeline.sh:609-617）。
- 4.4 — busy-wait sticky comment は事後監査用に残置（既存 `po_clear_awaiting_slot` 方針と整合）。README 明記。

### Requirement 5（後方互換 / opt-in gate）
- 5.1 — `po_check_busy_wait` は `[ "${PATH_OVERLAP_CHECK:-off}" = "true" ]` 厳密一致のみ通過（promote-pipeline.sh:733）。dispatcher の reset も同 gate（issue-watcher.sh:7519）。test:188-199（off / 空 / false / 0 / True / 1 / enabled の 7 値で gh 呼び出しゼロ・state 非生成）でカバー。
- 5.2 — off 時は state も作らず GitHub 状態も変更しない（即 return 0）。dispatch 挙動・ログ書式・exit code は無変更（`if [ -z "$slot" ]` の `continue` 経路に呼び出しを 1 行追加しただけで、off では即 return）。test:197-198 でカバー。
- 5.3 — 新 marker `busy-wait:v1` を別管理。既存 `awaiting-slot:v1` / `edit-paths:v1` marker への変更行は diff に存在しないことを確認。`LABEL_AWAITING_SLOT` を流用（新ラベル追加なし）。
- 5.4 — 既存 env var 名・ラベル名は無変更。新 env var `PATH_OVERLAP_BUSY_WAIT_THRESHOLD` を `"${VAR:-default}"` 形式で追加（issue-watcher.sh:347）。
- 5.5 — `po_compute_overlap` / holder 集合ロジックは無変更。#221 回帰テスト（test-holder-labels.sh）PASS=8 で search_query ゼロ差分を独立に再確認。

### Non-Functional Requirements
- NFR 1.1 / 1.2 — 閾値未満は無音（transient 抑制）。1 見送り状態 = sticky 1 件（marker 集約 + PATCH 更新で連投しない）。test:135-176 でカバー。
- NFR 2.1 / 2.2 — state ファイル 1 件収束 / 投稿失敗時は marker 検索で次 tick 再試行・重複生成なし。test:205-217 でカバー。
- NFR 3.1 / 3.2 — `po_log`（`path-overlap:` prefix + stdout）で tick / threshold / reason を含む 1 行ログ出力（promote-pipeline.sh:741, 745）。
- NFR 4.1 / 4.2 — tick カウントはローカル state ファイルのみで GitHub API 不使用（promote-pipeline.sh:619-664）。in-flight 列挙・edit_paths 読み出しは既存経路のまま増やさない。test:119-127（tick カウント時の gh 呼び出しゼロ）でカバー。

## Boundary 検証

- 変更ファイルは `local-watcher/bin/modules/promote-pipeline.sh`（po_busy_wait_* / po_apply_busy_wait_signal / po_check_busy_wait の追加。既存 po_* 関数は無変更）、`local-watcher/bin/issue-watcher.sh`（Config 1 行 + dispatcher 配線 2 箇所）、`README.md`、spec 配下のみ。Out of Scope（#221 正規化再実装 / Triage 精度向上 / multi-branch holder ロジック変更 / 多忙の根本解消）への踏み込みなし。
- 既存契約（env var 名・ラベル名・exit code・ログ書式 `path-overlap:` prefix）の破壊なし。

## 独立検証結果

- `shellcheck -S warning`（3 ファイル）: 警告・エラー 0 件
- `test-dispatch-visibility.sh`: PASS=29 FAIL=0
- `test-holder-labels.sh`（#221 回帰）: PASS=8 FAIL=0

いずれも Developer 報告（shellcheck 0 件 / PASS=29 / 既存回帰 PASS=8）を独立に再現。

## Findings

なし

## Summary

Requirement 1〜5・NFR 1〜4 のすべてに対応する実装またはテストを確認した。Req 1/2/4 は既存
実装（#187 / #221）の無変更踏襲を回帰テストで担保し、Req 3 の多忙サイクル待ち可視化を opt-in
gate 配下で新規実装。既存マーカー・ラベル・env var・ログ書式の契約破壊なし。boundary 逸脱なし。
shellcheck 0 件・スモーク PASS=29・回帰 PASS=8 を独立に再現確認。

RESULT: approve
