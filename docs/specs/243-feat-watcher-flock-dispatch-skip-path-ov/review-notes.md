# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-26T07:30:00Z -->

## Reviewed Scope

- Branch: claude/issue-243-impl-feat-watcher-flock-dispatch-skip-path-ov
- HEAD commit: 084b86e18d3b06e504d3afd7980129b19f30c57b
- Compared to: main..HEAD（HEAD 全体レビュー。main が分岐後に先行 merge を取り込んでいるため、レビュー対象差分は `merge-base(6fcbec0)..HEAD` で評価。`main..HEAD` に現れる無関係削除（#238 scaffolding-health / #248 verify_pushed_or_retry / #251 stage_checkpoint 等）は本 Issue の変更ではなく main 側の advance によるノイズのためレビュー対象外）

## Feature Flag Protocol

CLAUDE.md に `## Feature Flag Protocol` 節は存在せず（`feature-flag-protocol` marker grep ヒットなし）。
opt-out として解釈し、flag 観点の細目は適用せず通常の 3 カテゴリ判定のみを実施した。

## Verified Requirements

- 1.1 — `issue-watcher.sh` flock skip 失敗ブロック内に `po_run_flock_skip_visibility` フック挿入 / 専用 flock 取得 → 候補列挙 → 評価（test Case 1,3）
- 1.2 — `po__visibility_evaluate_candidate` overlap>0 時 `po_apply_awaiting_slot` で既存ラベル付与契約を再利用
- 1.3 — 同上 `po_apply_awaiting_slot` が sticky comment（marker `awaiting-slot:v1`）を post/update
- 1.4 — フックは `flock -n 200 || { ... }` 失敗ブロック内のみ。flock 成功時の通常 dispatch 経路に到達しない（制御フローで構造保証）
- 2.1 — `po_run_flock_skip_visibility` は claim / dispatch を行わず label/comment のみ
- 2.2 — 専用 fd(201)+別ファイル `PATH_OVERLAP_VISIBILITY_LOCK_FILE` のみ取得。worktree/slot/dispatch ロック非取得（test Case 2）
- 2.3 — `po_collect_inflight_issues` / `po_compute_overlap` を read-only 再利用
- 2.4 — `vis_search_filter` に `claude-claimed` / `claude-picked-up` 等の除外句（test Case 3 で claim 除外を検証）
- 3.1 — overlap=0 かつ既付与で `po_clear_awaiting_slot` 呼び出し
- 3.2 — 通常経路と共有の `awaiting-slot` ラベル / marker。通常 dispatch サイクルが除去可能な状態を維持
- 4.1 — `flock -n 201` 非ブロッキングで同時 1 実行のみ許容（test Case 2）
- 4.2 — 抑止時 `route=flock-skip visibility skipped` 抑止ログ出力（test Case 2 で文言一致検証）
- 5.1 — `po_apply_awaiting_slot` の marker 冪等更新（既存契約再利用）
- 5.2 — 同上、sticky comment を 1 件に保つ
- 5.3 — `has_awaiting` 判定で未付与時のみ付与（重複付与回避）+ `--add-label` 冪等
- 6.1 — opt-in gate 二重防御（フック側 + 関数冒頭 `[ ... = "true" ] || return 0`）（test Case 1,5）
- 6.2 — gate 前の既存スキップログ書式不変、off で従来コードと一致（test Case 5）
- 6.3 — 既存 `po_apply/clear_awaiting_slot` を非改変再利用
- 6.4 — 既存 marker `awaiting-slot:v1` 投稿契約を非改変再利用
- 6.5 — 既存 env var / ラベル遷移 / exit 0 / スキップログ書式すべて不変（新規 env 1 行のみ追加）
- 7.1 — `po__visibility_evaluate_candidate` が dispatch 経路と同一の po_* 関数群・判定規約を共有
- 7.2 — 同一の `awaiting-slot` ラベル・sticky comment 出力形式を再利用
- NFR 1.1 — flock skip exit 0 不変。`|| true` で関数戻り値に依存しない（test Case 1,5）
- NFR 1.2 — フックは失敗ブロック内限定で flock 成功時の全ステージに非介入
- NFR 2.1 / 2.2 — marker 冪等更新で状態不変候補の新規コメント増加なし
- NFR 3.1 — 同一状態連続実行で可視化シグナル集合不変（冪等ラベル + 冪等 sticky）
- NFR 3.2 — 全エラー経路で fd close + `return 0`（fail-open）（test Case 4）
- NFR 4.1 — overlap 検出時 `route=flock-skip overlap detected candidate=#<N> paths=... holders=...` ログ出力
- NFR 4.2 — 起動ログに経路識別子 `route=flock-skip` を含む

## 検証実行結果

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/promote-pipeline.sh` → exit 0（警告ゼロ）
- `bash docs/specs/243-feat-watcher-flock-dispatch-skip-path-ov/test-fixtures/test-flock-skip-visibility.sh` → `PASS=24 FAIL=0`（exit 0）
- tasks.md の stage-a-verify 構造化ブロックのコマンドと一致。reviewer 側で再実行し green を確認

## Boundary 確認

tasks.md `_Boundary:_`: Config(issue-watcher.sh) / `po__visibility_evaluate_candidate` /
`po_run_flock_skip_visibility` / flock skip フック(issue-watcher.sh) / test-flock-skip-visibility.sh /
README.md。差分（merge-base..HEAD）は `issue-watcher.sh`(+14) / `promote-pipeline.sh`(新規 2 関数のみ追加、既存 po_* シグネチャ非改変) / 上記 test fixture / README / impl-notes / tasks。
すべて宣言境界内。`.shellcheckrc`（chore commit 9969619）は #245 と同一内容の静的解析設定で、
stage-a-verify の round=1 無限ループ解消用の build-infra unblock。watcher runtime / env var /
ラベル / exit code を一切変更せず production 境界を侵さないため boundary 逸脱に該当しない。

## Findings

なし

## Summary

全 numeric ID（Req 1.1〜7.2 / NFR 1.1〜4.2）が新規 2 関数 + flock skip フック + 既存 po_* 再利用 + スモークテストで裏打ちされ、shellcheck / smoke が green。境界逸脱・AC 未カバー・missing test なし。

RESULT: approve
