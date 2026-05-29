# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-270-impl--bug-checkbox-flip-per-task-reviewer
- HEAD commit: 7154ae9803d0182b0d88cb7b3493cd0691956de8
- Compared to: main..HEAD
- Note: 本 spec は design-less impl 経路（`tasks.md` / `design.md` 不在）であり、Reviewer は
  requirements.md と impl-notes.md と実装 diff のみを根拠に AC 判定を行う。

## Verified Requirements

### Requirement 1（親タスク + checkbox-only diff の Reviewer 起動スキップ）

- 1.1 — `run_per_task_loop` 内 `local rev_rc=0` 直前で `pt_should_skip_reviewer "$task_id"` を呼び、
  rc=0 のとき `run_per_task_reviewer` を起動せず `rev_rc=0` のまま続行
  （`local-watcher/bin/issue-watcher.sh:3389-3394`）
- 1.2 — スキップ成立時は `rev_rc=0` で続行し、続く `case "$rev_rc" in 0)` 分岐（approve 経路）に
  そのまま乗る（`local-watcher/bin/issue-watcher.sh:3395-3398`）
- 1.3 — スキップ成立時は `review-notes.md` の有無を判定する `parse_review_result` 経路を一切
  通らないため `claude-failed` 付与は構造的に発生しない（同上 case 分岐により approve 直結）
- 1.4 — `pt_should_skip_reviewer` 内で `pt_log "task=${task_id} reviewer skipped reason=parent-task-checkbox-only-diff range=..."`
  を stdout に出力し、call site 側で `>> "$LOG"` リダイレクト
  （`local-watcher/bin/issue-watcher.sh` `pt_should_skip_reviewer` 末尾 / 呼び出し L3390）
  smoke test C-6 で grep 可能性を検証
- 1.5 — dispatcher は対象 task のみに対する判定であり、後続 pending task はループ次反復で
  通常処理される（コード上、while ループ構造は変更されていない）
- 1.6 — Stage B Reviewer / PR 作成等の後続フェーズへの遷移は本変更で触れていない（per-task
  ループの脱出条件は変更なし）

### Requirement 2（「親タスク」の判定方法）

- 2.1 — `pt_has_subtasks` が `^- \[[ x]\]\*? <task_id_re>\.[0-9]+(\.[0-9]+)*\.? ` の正規表現で
  numeric 階層 prefix 子タスク行を検出。`task_id_re` は `sed -E 's/[][\\.*^$()+?{|/]/\\&/g'` で
  安全にエスケープ。smoke test A-1, A-2 で検証
- 2.2 — 子タスクが 0 件のとき rc=1 を返し、`pt_should_skip_reviewer` で skip 対象外として早期 return
  （`pt_has_subtasks` 末尾 `return 1`）。smoke test A-3, A-5 で検証
- 2.3 — 子タスク自身（例 `1.1`）に対する判定では孫タスクが無いため rc=1。smoke test A-4 で検証
- 2.4 — regex の checkbox 部分 `\[[ x]\]\*?` で `- [ ]` / `- [x]` / `- [ ]*` / `- [x]*` の
  4 種すべてマッチ。smoke test A-9（完了済み子で親判定成立）で検証
- 2.5 — 同上 regex の `\*?` で deferrable 印を許容。smoke test A-2（`- [ ]* 3.1` で `3` が親判定成立）
  で検証
- false positive 防止（task_id `1` が `11.` を誤検出しない）も regex の `\.` 連結により担保され、
  smoke test A-8 で明示的に検証

### Requirement 3（「tasks.md only diff」の判定方法）

- 3.1 — `pt_is_parent_checkbox_only_diff` の第 1 段で `git diff --name-only "${range_start}..${range_end}"`
  → 行数 1 件 + 文字列一致 `$SPEC_DIR_REL/tasks.md` を要求。smoke test B-1 で検証
- 3.2 — 同上判定で行数 != 1 または別ファイルを含むと rc=1。smoke test B-5（tasks.md + src.txt 混入）
  で検証
- 3.3 — `pt_should_skip_reviewer` 内で `pt_resolve_diff_range` 失敗時に rc=1 を return し既存経路へ
  fallback。smoke test C-5（存在しない marker '99'）で検証
- 3.4 — 第 2 段で `^-- \[ \] <task_id_re>\.? ` と `^\+- \[x\] <task_id_re>\.? ` の対が
  ぴったり 1+1 件であることを `minus_match`/`plus_match` で要求、かつ `minus_count`/`plus_count`
  （file header 除外後の総数）も 1+1 件であることを要求。smoke test B-1 で検証
- 3.5 — `minus_count` / `plus_count` が 1+1 件を超えるケース（他編集混入）では rc=1。
  smoke test B-6（task_id=1 を渡すが diff は 1.1 の flip のみ）/ B-7（空 diff）で検証

### Requirement 4（回帰互換性）

- 4.1 — 子タスク（自身は子を持たない）は `pt_has_subtasks` rc=1 で skip 対象外、`run_per_task_reviewer`
  を従来通り起動。smoke test C-2, C-3 で検証
- 4.2 — 単独タスク（最上位 ID + 子なし）も同様に skip 対象外。smoke test C-4 で検証
- 4.3 — 親タスクだが他ファイル変更を含むケースは `pt_is_parent_checkbox_only_diff` rc=1 で
  skip 対象外。smoke test B-5 で検証
- 4.4 — round=2 / round=3 経路（`run_per_task_reviewer "$task_id" 2` / Debugger Gate / round=3）の
  コードブロックは diff 上一切変更されていない（`git diff main..HEAD` で確認済み）
- 4.5 — 既存挙動と等価。skip 経路に入らない場合は call site も `run_per_task_reviewer "$task_id" 1 || rev_rc=$?`
  に従来通り倒れる（L3393）

### Non-Functional Requirements

- NFR 1.1 — env var による opt-in なし。dispatcher は直接呼び出しで動作（既定で有効）
- NFR 1.2 — `tasks.md` の既存 `- [x]` / 既存 marker commit を読み取るのみで破壊操作なし
- NFR 1.3 — `pt_has_subtasks` rc=2（fail-safe）/ `pt_resolve_diff_range` 失敗 /
  `pt_is_parent_checkbox_only_diff` rc=1 のいずれでも skip 対象外として既存経路へ倒す。
  smoke test A-6, A-7, C-5 で検証
- NFR 2.1 — `pt_log "task=<id> reviewer skipped reason=parent-task-checkbox-only-diff range=..."`
  を stdout 出力 → `>> "$LOG"` で集約。grep 可能。smoke test C-6 で検証
- NFR 2.2 — ログに task ID + 判定経路識別子（`reason=parent-task-checkbox-only-diff`）+
  range short SHA を含む
- NFR 2.3 — skip 不成立時は dispatcher 内で新規ログを出さない（各 fail-safe 経路で素直に return 1）。
  smoke test C-7 で検証
- NFR 3.1 — 判定は `git diff` 2 回（`--name-only` + 本体）+ grep のみで構成され、軽量
- NFR 3.2 — skip 成立時は `run_per_task_reviewer` 起動を完全に bypass（call site の if/else 分岐）

## Findings

なし

## Summary

requirements.md の全 numeric ID（Req 1.1〜1.6 / 2.1〜2.5 / 3.1〜3.5 / 4.1〜4.5 / NFR 1.1〜1.3 /
NFR 2.1〜2.3 / NFR 3.1〜3.2）に対応する実装が `local-watcher/bin/issue-watcher.sh` の 3 つの
新規関数（`pt_has_subtasks` / `pt_is_parent_checkbox_only_diff` / `pt_should_skip_reviewer`）
および `run_per_task_loop` の Reviewer 起動直前の分岐で確認できた。23 件の smoke test
（`docs/specs/270--bug-checkbox-flip-per-task-reviewer/test-fixtures/test-skip-logic.sh`）が
全 PASS、shellcheck 警告ゼロも reviewer 側で再現確認済み。boundary 逸脱・AC 未カバー・
missing test のいずれも検出されない。

RESULT: approve
