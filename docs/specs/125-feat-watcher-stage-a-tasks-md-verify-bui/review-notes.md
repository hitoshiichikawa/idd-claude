# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-21T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-125-impl-feat-watcher-stage-a-tasks-md-verify-bui
- HEAD commit: 3a5385909ce83be0e73413ed73d8bf204553f05c
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out として解釈。3 カテゴリ判定のみ実施（flag 観点の細目は適用しない）

## Verified Requirements

- 1.1 — `stage_a_verify_extract_command`（issue-watcher.sh L3836-）awk 1 パスで全行を走査し、keyword 一致行を `last` に保持して END で出力（末尾走査と等価）。fixture `tasks-gradlew.md` で `./gradlew assembleDebug` を抽出 → driver pass
- 1.2 — 同 awk が「最後の一致を上書き保持」する設計のため、複数候補時は末尾を選択。fixture `tasks-npm.md`（`npm run lint` + `npm test` 末尾選択）と `tasks-mixed.md`（`npm run build` + `./gradlew assembleDebug && ./gradlew test` 末尾選択）で driver pass
- 1.3 — `stage_a_verify_run` (L5240) で `bash -c "$cmd"` を `timeout` 経由実行。複合演算子は shell に委ねる。fixture `tasks-cargo.md`（`cargo build && cargo test`）/ `tasks-shellcheck.md`（`shellcheck ... && actionlint ...`）で抽出確認
- 1.4 — `stage_a_verify_run` Gate 2 (L5228-L5230): resolve 失敗時 `SKIPPED reason=no-verify-task-in-tasks-md` + return 0。fixture `tasks-no-verify.md` / `tasks-empty.md` で driver pass（期待値は空文字 = 抽出関数 exit 1）
- 1.5 — `_SAV_KEYWORDS` (L3851-L3879) は文字列リテラルの配列のみ。AST/parser 解析なし、`command -v <runtime>` 呼び出しなし
- 2.1 — `(cd "$REPO_DIR" && timeout --kill-after=10 "$_timeout" bash -c "$cmd") >> "$LOG" 2>&1 || rc=$?` (L5242-L5243)
- 2.2 — `case 0)` で `stage_a_verify_reset_round` + `return 0`、`run_impl_pipeline` 挿入ブロックの `case 0) :` で続行（L5398-L5409）
- 2.3 — `case *)` → `_sav_handle_failure` → return 1/2、`run_impl_pipeline` 側で両 case とも `return 1`（Stage B に進まない）
- 2.4 — `case 124)` で `TIMEOUT timeout=Ss exit=124` ログ + `_sav_handle_failure "timeout" "$_timeout"`。`timeout --kill-after=10` で SIGKILL（NFR 5.2 と整合）
- 2.5 — subshell `(cd "$REPO_DIR" && ...)` で cwd 隔離、env を新規 export しない
- 3.1 — `_sav_handle_failure` (L5151-) round=1 case で sidecar bump + `gh issue comment` で差し戻しコメント + return 1。次 tick で Stage Checkpoint resume 経路 (START_STAGE=B|C) でも gate が走るよう Stage B 開始直前位置に挿入済
- 3.2 — round=2 case で `mark_issue_failed "stageA-verify" "$extra_body"` + `stage_a_verify_reset_round` + return 2。`run_impl_pipeline` 側で `return 1` 退出
- 3.3 — 専用 env を増やさず round counter で固定 max 1 回差し戻し（design.md の整合方針通り）
- 4.1 — Gate 1 (L5220-L5223): `[ "${STAGE_A_VERIFY_ENABLED:-true}" = "false" ]` で `DISABLED reason=env-opt-out` + return 0
- 4.2 — Config ブロック L233: `STAGE_A_VERIFY_ENABLED="${STAGE_A_VERIFY_ENABLED:-true}"`
- 4.3 — Config ブロック L234: `STAGE_A_VERIFY_TIMEOUT="${STAGE_A_VERIFY_TIMEOUT:-600}"`、`timeout "$_timeout"` で適用
- 4.4 — `stage_a_verify_resolve_command` (L3931-L3939) 冒頭で `STAGE_A_VERIFY_COMMAND` 非空時に最優先採用
- 4.5 — diff 上で既存 env 行に変更なし、新 env 3 種を独立節で追加のみ
- 5.1 — `sav_log` (L3813) `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify: <body>` 形式、全 5 分岐で 1 行以上出力
- 5.2 — `sav_log` 実装で `[$REPO]` prefix を 3 段 prefix の 2 段目に固定（Issue #119 規約）
- 5.3 — Gate 2 で `sav_log "SKIPPED reason=no-verify-task-in-tasks-md"`
- 5.4 — Gate 1 で `sav_log "DISABLED reason=env-opt-out"`。impl-notes.md「確認事項 1」で README L2693 (Stage Checkpoint) との微妙な不整合を明示しているが、Req 5.4 の文面は「結果行を 1 件記録する」と明示しており実装は requirements に厳密準拠
- 5.5 — `SUCCESS exit=0` / `FAILED exit=$rc` / `TIMEOUT timeout=${_timeout}s exit=124` で exit code / timeout 識別可能
- 6.1 — `.claude/agents/reviewer.md` を変更していない（diff stat に含まれない）
- 6.2 — `.claude/agents/project-manager.md` を変更していない
- 6.3 — `.claude/agents/developer.md` を変更していない
- NFR 1.1 — opt-out 時は DISABLED 1 行のみ（運用上の観測点として 1 行残るが、Req 5.4 を優先する設計判断、user-observable な Stage A 完了挙動は本機能導入前と同一）
- NFR 1.2 — 既存ラベル名・遷移契約に変更なし。`needs-iteration` は Issue 側に付与せず Issue コメントのみ
- NFR 1.3 — `stage_a_verify_run` 内部の 0/1/2 を `run_impl_pipeline` 側で 0/1 にマップ
- NFR 2.1 — keyword 集合のみで認識、特定言語ランタイム依存なし
- NFR 2.2 — `STAGE_A_VERIFY_COMMAND` escape hatch を Req 4.4 経路と統合
- NFR 3.1 — awk 1 パス O(N)
- NFR 3.2 — `timeout "$_timeout"` で制限
- NFR 3.3 — env で秒単位上書き可
- NFR 4.1 — 全 5 分岐 + EXEC ログで `[$REPO] stage-a-verify:` 1 行以上出力
- NFR 4.2 — 固定 prefix で `grep '\[.*\] stage-a-verify:'` 抽出可能
- NFR 5.1 — subshell `(cd "$REPO_DIR" && ...)` で隔離
- NFR 5.2 — `timeout --kill-after=10` で子孫プロセス SIGKILL
- NFR 6.1 — `tests/local-watcher/stage-a-verify/extract-driver.sh` + 12 fixture で回帰検出（実行結果 12/12 pass を本レビューでも再現確認）
- NFR 6.2 — 既存 watcher の Stage A/B/C テストは unit framework なしの規約上存在せず、本機能の Req 1-5 を fixture と impl-notes.md の 9 ケース手動検証でカバー（CLAUDE.md「テスト・検証」節と整合）

## Findings

なし。

## Summary

Issue #125 の全 numeric AC（Req 1.1-1.5 / 2.1-2.5 / 3.1-3.3 / 4.1-4.5 / 5.1-5.5 /
6.1-6.3 / NFR 1.1-1.3 / NFR 2.1-2.2 / NFR 3.1-3.3 / NFR 4.1-4.2 / NFR 5.1-5.2 /
NFR 6.1-6.2）が tasks.md の境界内（issue-watcher.sh / tests/local-watcher/stage-a-verify /
README.md）に観測可能な実装またはテストとして揃っており、boundary 逸脱・missing
test も検出されなかった。fixture テスト 12/12 pass を Reviewer 側でも再現確認済み。
impl-notes.md の「確認事項 1」で言及されている README L2693 (Stage Checkpoint
opt-out 説明) との表現上の不整合は、requirements の Req 5.4 が「DISABLED 結果行を
1 件記録する」と明示しているため Reviewer 判定範囲外（AC 未カバー / missing test /
boundary 逸脱のいずれにも該当しない）。

RESULT: approve
