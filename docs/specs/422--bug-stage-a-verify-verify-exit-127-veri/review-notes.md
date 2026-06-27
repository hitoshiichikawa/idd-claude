# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-27T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-422-impl--bug-stage-a-verify-verify-exit-127-veri
- HEAD commit: 130e1fc6f46c8277b96f9387bab34d775a45292f
- Compared to: main..HEAD

## Verified Requirements

### Req 1: exit 127 を実 verify 失敗から区別する

- **1.1** — `stage-a-verify.sh` L1159〜1182 の新規 `127)` 分岐: `_sav_is_tool_missing_failure` 通過後に round counter を bump せず `return 0`。`stage_a_verify_round_path` への書き込みなし。Test: `stage_a_verify_tool_missing_test.sh` Case 3.1（`round counter=0 のまま` / `mark_issue_failed 呼ばれない`）
- **1.2** — 同分岐の `return 0` により Stage A 続行契約（既存 SUCCESS / warn-skipped と同じ rc=0）。Test: Case 3.1 `rc=0` assertion
- **1.3** — 127 分岐は `_sav_handle_failure` を呼ばない（gh issue comment 経路を bypass）。Test: Case 3.1 `gh issue comment` 不在検証（`GH_ARGS_FILE` grep）
- **1.4** — `_SAV_LAST_OUTCOME="warn-tool-missing"` を設定（L1180）。値域コメント（L412）にも追記。Test: Case 3.1〜3.4, 3.9 で outcome 検証
- **1.5** — `STAGE_A_VERIFY_COMMAND` env 経路でも同じ `case "$rc"` block を通る（`stage_a_verify_run` 単一実装）。Test: Case 3.9（env 経路で `exit 127` 設定）

### Req 2: 連結コマンドの境界条件

- **2.1** — 連結先頭 exit 127 の短絡で `bash -c` 全体 rc=127 → 同分岐へ。Test: Case 3.4（`exit 127 && true`）
- **2.2** — 連結末尾/途中位置の exit 127 → 全体 127 → 同分岐へ。Test: Case 3.3（`true && exit 127`）。実装上 `case "$rc"` は位置非依存のため head/middle/tail すべて等価
- **2.3** — 単独 exit 127 と連結全体 exit 127 は同経路。Test: Case 3.1（単独）/ Case 3.3, 3.4（連結）
- **2.4** — real fail と 127 混在で最終 rc=1 → default `*` 分岐に落ちる（127 分岐に到達しない）。Test: Case 3.5（`exit 1 && exit 127` → round1 / `reason=verify-tool-missing` 不在検証）
- **2.5** — `case "$rc"` 順序 `0` → `124` → `127` → `*` で 124（timeout）は専用分岐へ先行。Test: 既存 `stage_a_verify_timeout_pgkill_test.sh` 23 件 PASS

### Req 3: 既存の結果分岐挙動の維持

- **3.1** — `0)` 分岐は未変更（L1139〜1144）。Test: Case 3.7（`true` → success / WARN 不在）
- **3.2** — `124)` 分岐は未変更（L1145〜1158）。Test: timeout_pgkill 23 件 PASS
- **3.3** — `*)` 分岐内の path-missing 判定（`_sav_is_path_missing_diff_failure`）は未変更。Test: 既存 `stage_a_verify_path_missing_test.sh` 43 件 PASS / Case 3.8（path-missing → warn-skipped / tool-missing と混在しない）
- **3.4** — exit=1 → `*)` 分岐の `_sav_handle_failure` 経路維持。Test: Case 3.6（`exit 1` → round1）
- **3.5** — exit=130 等は `*)` 分岐へ落ちる（127 と 124 以外）。Test: Section 1 Case 1.6（`_sav_is_tool_missing_failure 130 → rc=1`）

### Req 4: 観測性 / ログ出力

- **4.1** — `sav_warn` 経由で `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify: WARN:` prefix を維持（L1177）。Test: Case 3.1 `grep '\[.*\] stage-a-verify: WARN'` 抽出検証
- **4.2** — WARN 行に `reason=verify-tool-missing` 固定文字列を埋め込み。Test: Case 3.1, 3.3, 3.4, 3.9 で含有検証
- **4.3** — `_sav_extract_tool_name_from_cmd` で stderr → cmd 先頭 token の優先順抽出 → `tool=<name>`。Test: Section 2 Case 2.1〜2.7（stderr 抽出 / fallback / 空入力）
- **4.4** — `_SAV_LAST_OUTCOME="warn-tool-missing"` で `warn-skipped`（path-missing）と 1 対 1 区別。Test: Case 3.8 で `warn-skipped` 設定時に `warn-tool-missing` が混在しないこと
- **4.5** — WARN 行に `exit=127` と `cmd=$(printf '%q' "$cmd")` を含む（L1177）。Test: Case 3.1 で `exit=127` / `cmd=exit` 含有検証

### Non-Functional Requirements

- **NFR 1.1** — `STAGE_A_VERIFY_ENABLED=false` 経路の DISABLED 早期 return は本変更で未触。Test: Case 3.10（disabled → exit 127 cmd であっても `outcome=disabled` / WARN 不在）
- **NFR 1.2** — 既存 env var 名 / exit code 意味（0=続行 / 1=round1 / 2=round2）契約を本変更で破壊せず。Test: Case 3.5, 3.6 で round1 経路維持
- **NFR 1.3** — 既存 outcome 値（success / disabled / skip / warn-skipped / round1 / round2）の発生条件は不変。新規 `warn-tool-missing` は別軸として追加。Test: 既存 3 本（path_missing 43 / round1_defer 8 / timeout_pgkill 23）が PASS
- **NFR 2.1〜2.3** — 既存 3 テストファイル全 PASS を reviewer 環境で再現確認: path_missing PASS=43 / round1_defer PASS=8 / timeout_pgkill PASS=23
- **NFR 3.1** — `_sav_is_tool_missing_failure` は `case "$rc"` だけの純粋関数（副作用なし、stderr 引数も非破壊参照）。Test: Section 1 Case 1.1〜1.8（8 ケースで全て純粋関数として隔離テスト成立）
- **NFR 3.2** — `_sav_extract_tool_name_from_cmd` も同様に純粋関数。Test: Section 2 Case 2.1〜2.7
- **NFR 4.1** — `sav_warn` 経由で既存 prefix 維持。Test: Case 3.1 prefix 含む grep 抽出成功
- **NFR 4.2** — `sav_warn` を 1 回呼ぶだけで 1 行記録。Test: Case 3.1 grep 抽出が単一行ヒット

## Findings

なし

## Summary

Issue #422 の 4 Requirements / 4 NFR Group をすべて新規実装 `_sav_is_tool_missing_failure`
`_sav_extract_tool_name_from_cmd` と `case "$rc"` の `127)` 分岐追加でカバー。新規テスト
60 件（Section 1+2+3）と既存 3 テスト（43+8+23 件）すべて reviewer 環境で再実行 PASS。
変更ファイルは `stage-a-verify.sh` / 新規テスト / README（CLAUDE.md 指針に従う同期更新）の
3 ファイルで境界逸脱なし。`STAGE_A_VERIFY_ENABLED=false` 後方互換も Case 3.10 で実証済み。
CLAUDE.md に `## Feature Flag Protocol` 採否宣言なしのため flag 観点細目は適用外。

RESULT: approve
