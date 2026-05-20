# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-20T11:50:00Z -->

## Reviewed Scope

- Branch: claude/issue-122-impl-feat-watcher-pr-iteration-max-rounds-kin
- HEAD commit: ed360e1ac755ef43d5add09f70683a84e5d6a794
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh` / `local-watcher/test/pi_max_rounds_kind_test.sh` (新規) / `README.md` / `docs/specs/122-feat-watcher-pr-iteration-max-rounds-kin/{requirements.md,impl-notes.md}`
- 注記: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため flag 観点は適用せず、通常の 3 カテゴリ判定のみ実施。`tasks.md` / `design.md` は本 spec 配下に存在せず（Triage で architect スキップ経路）、`_Boundary:_` の機械的照合は不可だが、変更ファイルは watcher / その test / README に閉じており要件の意図と整合。

## Verified Requirements

- 1.1 — `pi_resolve_max_rounds` の impl 分岐 (`local-watcher/bin/issue-watcher.sh:1281-1326`) が `PR_ITERATION_MAX_ROUNDS_IMPL` を採用。`pi_max_rounds_kind_test.sh` Req 1.1 ケース PASS
- 1.2 — 同関数の design 分岐が `PR_ITERATION_MAX_ROUNDS_DESIGN` を採用。同テスト Req 1.2 / 1.2+2.1 ケース PASS
- 1.3 — `PR_ITERATION_MAX_ROUNDS_LEGACY_SET` を `${VAR+x}` イディオムで判別し、legacy env のみ設定時に両 kind の fallback として旧 `PR_ITERATION_MAX_ROUNDS` を返す。テスト Req 1.3 ケース PASS
- 1.4 — kind 固有・旧 env すべて未設定時に impl=3 / design=0 を返す `default_value` 分岐。テスト Req 1.4 ケース PASS
- 1.5 — `process_pr_iteration` の `pi_log "サイクル開始 ... max_rounds_impl=... max_rounds_design=... no_progress_limit=..."`（`issue-watcher.sh:2618` 周辺）が impl / design 別に解決値を出力
- 1.6 — `pi_post_processing_comment` (`new_round/${max_display}`)、`pi_run_iteration` の round 着手 / escalate ログ、`pi_build_iteration_prompt` の `max_rounds_param` で解決値を伝播
- 2.1 — `pi_run_iteration` の `if [ "$max_rounds" != "0" ] && [ "$round" -ge "$max_rounds" ]` 条件で `0` 時は round 上限超過 escalate をスキップ（design）
- 2.2 — no-progress streak 加算 / escalate は `if [ $rc -eq 0 ]` 内で max_rounds とは独立に走るため、design max=0 でも常時有効
- 2.3 — 同上の条件は kind に依存しないため impl=0 でも round 数超過 escalate がスキップされる
- 2.4 — `max_display="無制限"` で 着手表明コメント・round 着手ログに無制限表現を出力
- 3.1 — `pi_run_iteration` 末尾の `new_streak=$((prev_streak + 1))`（commit_pushed=false 時）
- 3.2 — 同 `new_streak=0`（commit_pushed=true 時）
- 3.3 — `if [ "$new_streak" -ge "$PR_ITERATION_NO_PROGRESS_LIMIT" ]` で `pi_escalate_to_failed ... "no-progress"` を呼び出し
- 3.4 — env 解決ブロック冒頭の `PR_ITERATION_NO_PROGRESS_LIMIT="${PR_ITERATION_NO_PROGRESS_LIMIT:-3}"`
- 3.5 — `pi_escalate_to_failed` 内の `if [ "$reason" = "no-progress" ]` 分岐で reason / streak / limit を本文に明示
- 3.6 — `pi_read_no_progress_streak` は kind 引数を持たず PR body のみから抽出。テスト Req 3.6 系ケース PASS
- 4.1 — `pi_write_marker` で marker に `no-progress-streak=${streak}` を必ず含める形に変更
- 4.2 — `pi_read_no_progress_streak` が key 不在時に `${streak:-0}` で `0` を返す。テスト Req 4.4 / Req 4.2 ケース PASS
- 4.3 — marker prefix `<!-- idd-claude:pr-iteration ` と `round=` / `last-run=` キーは無変更（diff で確認）
- 4.4 — sed regex `last-run=[^>]*-->` が旧・新両形式を吸収。テスト「旧 marker を新 marker で置換」「streak 付き marker からも last-run を正しく抽出」PASS
- 4.5 — `pi_read_no_progress_streak` / round 抽出ともに `tail -1` で末尾 marker を採用。テスト「複数 marker は末尾値（4）を採用」「旧 + 新 marker 混在」PASS
- 5.1 / 5.2 — `recover_status=soft-fail-commit:ok/fail` 分岐で `pi_write_marker` を呼ばずに `return 1`（`issue-watcher.sh:2472-2483`）
- 5.3 — `if [ $rc -eq 0 ]` 外（claude crash）と `post-round-commit:fail` 分岐の双方で marker 書き込みを行わない経路
- 5.4 — `pi_write_marker` 失敗時に `pi_error ... marker 書き込みに失敗` を出力した上で `return 1`（needs-iteration 残置）
- 5.5 — 失敗 path で marker を書き込まないため、次サイクル `gh pr view --json body` で旧 round / streak が読み取られて再開する設計
- 6.1 — `process_pr_iteration` のサイクル開始ログに `max_rounds_impl=${_resolved_max_impl} max_rounds_design=${_resolved_max_design} no_progress_limit=${PR_ITERATION_NO_PROGRESS_LIMIT}` を含める
- 6.2 — `pi_run_iteration` の `pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT}"`
- 6.3 — `pi_log "... no-progress-streak=${new_streak} reason=no-progress escalate"`
- 6.4 — `pi_log "... round=${round} max=${max_rounds} reason=max-rounds escalate"`
- 6.5 — 既存の `pi_log` / `pi_warn` / `pi_error` 経由（タイムスタンプ書式変更なし）
- 7.1 — `README.md` の環境変数表に `PR_ITERATION_MAX_ROUNDS_IMPL` / `PR_ITERATION_MAX_ROUNDS_DESIGN` / `PR_ITERATION_NO_PROGRESS_LIMIT` を追加
- 7.2 — README「#122 で追加された env 変数」節および環境変数表の `PR_ITERATION_MAX_ROUNDS` 行に migration note を記載（kind 別未設定時の fallback）
- 7.3 — README「hidden marker の後方互換性（#122）」節で `no-progress-streak` キーの存在と「既存 marker しか持たない PR は streak=0 として自動的に読み込まれ、次 round 終了時に新形式で書き換えられる」ことを明示
- NFR 1.1 — 旧 `PR_ITERATION_MAX_ROUNDS:-3` の defaulting は維持しつつ `_LEGACY_SET` フラグで「未設定 vs default 値」を区別、両 kind の fallback 経路として温存
- NFR 1.2 — marker prefix / `round` / `last-run` key 名は diff で変更なしを確認
- NFR 1.3 — `pi_log` / `pi_warn` / `pi_error` の関数本体は無変更（grep で確認）
- NFR 1.4 — 既存の `PR_ITERATION_ENABLED` / `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_HEAD_PATTERN` / `PR_ITERATION_DESIGN_HEAD_PATTERN` / `PR_ITERATION_MAX_TURNS` / `PR_ITERATION_MAX_PRS` / `PR_ITERATION_GIT_TIMEOUT` / `PR_ITERATION_DEV_MODEL` の名前・既定値・意味は変更なし
- NFR 2.1 — `pi_max_rounds_kind_test.sh` が Req 1.1〜1.4 の 4 通り（kind 固有 / 旧 env のみ / 全未設定 / 両方設定の優先）をそれぞれ独立 fixture で検証
- NFR 2.2 — 同テストが `pi_read_no_progress_streak` の正常 / 境界 / 旧 marker / 複数 marker / streak=0 を独立に検証（24 ケース全 PASS）。Req 5 の「失敗 round 据え置き」は `pi_run_iteration` の制御フロー上 `pi_write_marker` が呼ばれない経路として impl-notes 内で明示
- NFR 2.3 — 既存 11 テスト + 新規 1 テスト = 12 テスト全 PASS（reviewer 環境でも再実行確認済み）
- NFR 3.1 — `max_rounds_impl=` / `max_rounds_design=` / `no-progress-streak=` / `reason=no-progress` / `reason=max-rounds` / `limit=` がすべて grep 抽出可能な `key=value` 形式

## Findings

なし

## Summary

requirements.md の全 numeric AC（Req 1〜7 と NFR 1〜3）に対応する実装が `local-watcher/bin/issue-watcher.sh` に存在し、新規テスト `pi_max_rounds_kind_test.sh`（24 ケース）と既存テスト 11 件がすべて PASS。後方互換性（旧 `PR_ITERATION_MAX_ROUNDS` fallback / 既存 marker の `no-progress-streak` 不在許容 / marker prefix・既存 key 名不変）も diff・テスト両面で確認できた。README にも env 表・migration note・hidden marker 後方互換性が記載されており Req 7 を満たす。boundary 逸脱（watcher 以外への副作用混入）は無し。

RESULT: approve
