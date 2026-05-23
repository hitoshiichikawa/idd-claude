# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-05-23T03:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-160-impl-bug-stage-a-verify-verify-exit-127-stage
- HEAD commit: 5685c6724880575318a7e47c1286b32f231748fe
- Compared to: main..HEAD（および round=1 HEAD `91988c7..5685c67` の追加差分を重点確認）
- 変更ファイル（全 9 ファイル / 706 行 insertions）:
  - `local-watcher/bin/issue-watcher.sh`（+138 行 / -3 行：`_sav_cmd_starts_with_keyword` ヘルパ追加 / awk script の `index(..., kw) > 0` → `== 1` 厳格化 / `stage_a_verify_run` に Gate 3 追加 / inline code span 抽出 / fenced code block state machine）
  - `tests/local-watcher/stage-a-verify/extract-driver.sh`（+16 行：期待値テーブルに 5 fixture 追加）
  - 新規 fixture 5 ファイル（`tasks-backtick-with-prose.md` / `tasks-backtick-multi.md` / `tasks-fenced-only.md` / `tasks-backtick-and-bare-mix.md` / `tasks-backtick-prefix-prose.md`）
  - `docs/specs/160-bug-stage-a-verify-verify-exit-127-stage/requirements.md`（PM 起票時）
  - `docs/specs/160-bug-stage-a-verify-verify-exit-127-stage/impl-notes.md`（Developer 補足、Round 2 是正対応セクション含む）
- Round=2 重点確認: Round=1 で Reviewer が出した Finding 1（Req 5.3 の AC 未カバー）が解消されているか
- boundary: 変更は `local-watcher/bin/issue-watcher.sh`（Stage A verify module）と `tests/local-watcher/stage-a-verify/` 配下の test driver / fixture、および `docs/specs/160-*/` のみ。Stage A verify の責務境界（#125 / #122 で確定）内に収まる。
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため **opt-out 既定**として解釈し、flag 観点の細目チェックは適用しない。

## Verified Requirements

- **Req 1.1**（backtick 中身を優先抽出） — `issue-watcher.sh` の awk inline code span 走査ループ（L5615-L5640）で実装。`tasks-backtick-with-prose.md` fixture で `./gradlew :app:lintDebug` のみが抽出されることを Reviewer 側で再現確認（散文「lint 緑:」「で新規 error なし」が結果に含まれない）。
- **Req 1.2**（同一行内 複数 span → 最初の keyword 一致を採用） — `tasks-backtick-multi.md` fixture で `echo skip` を skip し `npm test` を採用（`pytest -q` ではない）ことを再現確認。
- **Req 1.3**（複数行存在 → 末尾最も近い） — 既存 `last` 上書きロジック（L5638 / L5660）を温存。`tasks-backtick-with-prose.md` の 3 行 backtick 中で末尾の `./gradlew :app:lintDebug` が採用される動作で確認。
- **Req 1.4**（スパン外の散文を含めない） — `span_content = candidate`（backtick 内文字列のみ採用）で、装飾・散文・日本語を含まない。`tasks-backtick-with-prose.md` fixture の期待値に「lint 緑:」「で新規 error なし」が含まれていないことで固定。
- **Req 2.1**（backtick 不在の行は装飾除去後の行全体採用） — line fallback パス（L5656-L5663）を温存。既存 fixture `tasks-gradlew.md` / `tasks-mixed.md` / `tasks-deferrable.md` ほか 12 件が継続 pass で確認。
- **Req 2.2**（backtick 不在 verify 行が複数 → 末尾採用） — 既存挙動温存（last 上書き）。`tasks-mixed.md` / `tasks-npm.md` 既存 fixture が継続 pass。
- **Req 2.3**（混在時 ファイル末尾最近行に Req1/Req2 切替） — `tasks-backtick-and-bare-mix.md` fixture で bare 行（assembleDebug）の後の backtick 行（lint）が採用されることを再現確認（期待値 `./gradlew :app:lintDebug`）。
- **Req 3.1**（fenced のみ → SKIPPED） — `in_fence` state machine（L5587, L5593-L5597）。`tasks-fenced-only.md` fixture の期待値 = 空文字列で SKIPPED 動作を再現確認。
- **Req 3.2**（fenced 内行を誤抽出しない） — 同上。`tasks-fenced-only.md` 内の `./gradlew assembleDebug` / `./gradlew test` / `shellcheck` が抽出されないことを期待値で固定。
- **Req 4.1**（`STAGE_A_VERIFY_COMMAND` env 優先） — `stage_a_verify_resolve_command` に変更なし。Gate 3（L8791）は `[ -z "${STAGE_A_VERIFY_COMMAND:-}" ]` 条件付きで escape hatch 経路を bypass する形になっており、env 値が非空なら抽出 + Gate 3 双方を bypass する契約を温存。
- **Req 4.2**（`STAGE_A_VERIFY_ENABLED=false` で完全 opt-out） — `stage_a_verify_run` Gate 1（L8775-L8778）に変更なし。
- **Req 4.3**（env 名・既定値不変） — config ブロック差分 0 行。`STAGE_A_VERIFY_COMMAND` / `STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` の意味・既定値を変更していない。
- **Req 5.1**（規則不該当時 SKIPPED） — `[ -n "$result" ] || return 1` 経路を温存。fenced-only / no-verify / empty fixture が空文字列を返すことで確認。
- **Req 5.2**（SKIPPED 時 cron.log 出力） — `sav_log "SKIPPED reason=no-verify-task-in-tasks-md"`（L8783）の出力を温存。Gate 3 経路も `sav_log "SKIPPED reason=cmd-does-not-start-with-keyword cmd=..."`（L8793）で同じ prefix で 1 行出力する（NFR 3.1 整合）。ログ prefix `[$REPO] stage-a-verify:` 不変。
- **Req 5.3**（実行前 chk: 非空 + 行頭 keyword 開始） — **Round=1 Finding 1 完全解消を確認**。以下 2 重対応:
  - (b) 抽出関数側の strict 化（L5628 / L5659）: inline code span 走査と line fallback の双方で `index(..., kw) > 0` を `index(..., kw) == 1` に厳格化。行頭一致しない候補は抽出段階で除外される。
  - (a) `stage_a_verify_run` Gate 3（L8787-L8796）: Gate 2 通過直後に `_sav_cmd_starts_with_keyword` で再確認。keyword で始まらない cmd は `SKIPPED reason=cmd-does-not-start-with-keyword` で正規 SKIPPED 経路に倒す（`STAGE_A_VERIFY_COMMAND` 経由は bypass）。
  - fixture 回帰固定: `tasks-backtick-prefix-prose.md`（backtick 内 = `cd app && ./gradlew test`）の期待値 = 空文字列で SKIPPED 動作を期待値固定。Reviewer 側で `bash tests/local-watcher/stage-a-verify/extract-driver.sh` 実行 → **pass=17 fail=0** を再現確認。
- **Req 6.1**（差し戻し境界・ログ prefix・責務境界 不変） — `_sav_handle_failure` / `stage_a_verify_run` の差し戻し境界 / Reviewer-PjM-Developer フローに変更なし。Gate 3 のログも既存 `sav_log` 経由なので prefix `[$REPO] stage-a-verify:` 維持。
- **Req 6.2**（exit code 非 0 時の round=1/2 境界） — `_sav_handle_failure` の挙動不変。
- **Req 6.3**（既存 env 名 `REPO` / `REPO_DIR` / `LOG_DIR` 等不変） — diff に該当変更なし。
- **NFR 1.1**（backtick 無し既存形式の抽出結果不変） — line fallback の `index(line, kw) > 0` → `== 1` 厳格化は理論上後方互換に影響しうるが、既存 12 fixture（`tasks-gradlew.md` 〜 `tasks-empty.md`）はいずれも装飾除去後の行頭が keyword で始まる形なので継続 pass。実機で 17/17 pass を再現確認済み。
- **NFR 1.2**（`STAGE_A_VERIFY_ENABLED` 未設定/false で #125 導入前と同一動作） — Gate 1 / Gate 2 不変。Gate 3 も `STAGE_A_VERIFY_ENABLED=false` の場合は Gate 1 で early return するため到達しない。
- **NFR 1.3**（既存ラベル名・遷移契約 不変） — ラベル定義 / 遷移処理に変更なし。
- **NFR 2.1**（O(N) 線形時間） — awk 1 パス維持。内側 backtick 走査は行内 backtick ペア数 × keyword 数で打ち切るため実運用では実質 O(N)。Gate 3 の `_sav_cmd_starts_with_keyword` は case 文の固定数 keyword 比較で O(1)。
- **NFR 3.1**（cron.log への結果行出力） — `sav_log` / `sav_warn` の呼び出し位置と prefix を変更していない。Gate 3 経路も SKIPPED 行を 1 件出力する。
- **NFR 3.2**（実行コマンドを cron.log に grep 可能形式で記録） — `sav_log "EXEC ... cmd=$(printf '%q' "$cmd")"` を温存。Gate 3 SKIPPED ログも `printf '%q'` で cmd を escape して記録。
- **NFR 4.1**（4 種 fixture 保持） — (a) backtick 内 keyword: `tasks-backtick-with-prose.md` / (b) backtick 外散文 keyword 誤抽出防止: `tasks-backtick-multi.md` の `echo skip` 部 + `tasks-backtick-prefix-prose.md`（冒頭が keyword 以外） / (c) bare line: `tasks-gradlew.md` ほか既存 / (d) fenced only: `tasks-fenced-only.md`。
- **NFR 4.2**（keyword 追加削除時の回帰検出可能） — fixture が keyword 集合と独立した形で網羅。

## Findings

なし。Round=1 Finding 1（Req 5.3）が完全解消されており、Round=2 で追加の reject 理由は検出されなかった。

impl-notes.md に記載されている派生論点（keyword 集合 SSoT を design.md に反映するか / stage checkpoint 整合性メッセージ / README への fenced block escape 言及）は本 Issue スコープ外の論点であり、Reviewer の 3 カテゴリ判定（AC 未カバー / missing test / boundary 逸脱）に該当しない。

## Summary

Round=1 で唯一 reject 理由だった **Req 5.3 の AC 未カバー**（抽出した cmd が keyword で始まることを実行前に確認し、満たさない場合 SKIPPED）を Developer が以下 2 重対応で完全解消した:

1. **抽出関数の awk script で `index(..., kw) > 0` → `== 1`**（行頭一致厳格化）を inline code span 走査と line fallback の双方に適用
2. **`stage_a_verify_run` に Gate 3 を追加**（`_sav_cmd_starts_with_keyword` ヘルパで再確認、`STAGE_A_VERIFY_COMMAND` env 経由は bypass で escape hatch 温存）
3. **`tasks-backtick-prefix-prose.md` fixture 追加**（backtick 内 = `cd app && ./gradlew test`、期待 = 空文字列 SKIPPED）

Reviewer 側で `bash tests/local-watcher/stage-a-verify/extract-driver.sh` を再現実行し pass=17 fail=0 を確認。shellcheck は修正範囲（L5447-L5660 / L8787-L8796）に **新規警告ゼロ**（pre-existing SC2317 のみ）。boundary 逸脱なし。Feature Flag Protocol は CLAUDE.md に節が存在せず opt-out 既定なので flag 観点の追加チェックは適用しない。

Req 1.x / 2.x / 3.x / 4.x / 5.x / 6.x / NFR 全項の AC 充足を確認した。

RESULT: approve
