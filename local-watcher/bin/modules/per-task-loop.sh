#!/usr/bin/env bash
# per-task-loop.sh — watcher の Per-task TDD Implementation Loop モジュール（family orchestrator）
#
# family: per-task-loop / prefix: pt_
#   #500 で本モジュールを責務単位の module family へ分割した。orchestrator（本ファイル）と
#   3 つの sub-file が同一 prefix `pt_`（+ 非 prefix `build_per_task_*` / `run_per_task_*`）を
#   共有する（family 全体で 1 prefix）。分割マニフェスト（どの関数がどのファイルにあるか）:
#     - per-task-loop.sh           … 本ファイル: dispatcher + ロガー + 抽出・判定系純粋ヘルパー
#         run_per_task_loop（dispatcher / Stage A 代替の入口）/ pt_log / pt_warn /
#         pt_extract_pending_tasks / pt_check_task_completed / pt_extract_learnings /
#         pt_extract_findings_block / pt_extract_debugger_section / pt_snapshot_review_notes /
#         pt_has_subtasks / pt_should_skip_reviewer
#     - per-task-loop-prompt.sh    … prompt builders
#         build_per_task_implementer_prompt / build_per_task_reviewer_prompt
#     - per-task-loop-diffrange.sh … diff-range 解決・fail-fast・post-marker 判定ヘルパー
#         pt_resolve_diff_range / pt_check_fail_fast / pt_detect_post_marker_commits /
#         pt_classify_post_marker_paths / pt_handle_post_marker_commits /
#         pt_is_parent_checkbox_only_diff
#     - per-task-loop-exec.sh      … 実行 + escalation
#         run_per_task_implementer / run_per_task_implementer_redo / run_per_task_reviewer /
#         pt_mark_fail_fast_failed / pt_mark_diff_range_resolve_failed /
#         pt_mark_post_marker_commits_detected / pt_post_docs_only_auto_refresh_comment /
#         pt_mark_no_progress_failed
#
#   build_per_task_* / run_per_task_* は pt_ 命名ではないが、per-task loop 固有の責務のため
#   family 内に同居させる（#470 pr_ の process_* 同居例に倣う非 prefix 例外）。
#
#   注: issue #500 本文の当初案は per-task-loop-exec.sh 1 ファイルだったが、実測 1,602 行で
#   1,200 行上限を超えるため、#469 pi_ 前例（4 ファイル）に倣い「実行 + escalation」(exec) と
#   「diff-range・fail-fast・post-marker 判定ヘルパー」(diffrange) の 2 系統へ責務分割し、
#   4 ファイル構成に調整した（振り分け根拠は #500 PR 本文参照）。
#
# 用途:
#   `PER_TASK_LOOP_ENABLED=true` のときに `run_impl_pipeline` の Stage A 内で起動される
#   per-task loop の本体。`PER_TASK_LOOP_ENABLED` が未指定 / `=true` 以外の場合、
#   本 family の関数群はどこからも呼ばれないため、本機能導入前と外形挙動は完全一致する
#   （NFR 1.1 / Req 1.1）。
#   - 入口: run_per_task_loop（未完了 task を numeric ID 順に 1 件ずつ Implementer + Reviewer
#     で消化する dispatcher。per-task-loop-exec.sh の runner 群と
#     per-task-loop-diffrange.sh の判定ヘルパーを呼び出す）
#
#   詳細: docs/specs/21-phase-2-per-task-tdd-implementation-loop/design.md
#
# 配置先:
#   $HOME/bin/modules/per-task-loop*.sh（install.sh が local-watcher/bin/modules/ から *.sh を
#   glob 配布するため、family の全ファイルが同時に配布される）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - family の sub-file は REQUIRED_MODULES で orchestrator より前に登録する（bash の遅延束縛
#     により source 順は不問だが、規約に従い sub → orchestrator の順に並べる）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pt_log / pt_warn は本ファイルに定義する（`[YYYY-MM-DD HH:MM:SS] per-task: <msg>`
#     形式。既存 rv_log / sc_log と同形式）。
#   - dbg_log / run_debugger_stage（debugger-gate.sh）を run_per_task_loop の BLOCKED 経路から呼ぶ。
#   - mark_issue_failed（issue-watcher.sh 本体）/ publish_terminal_failure_artifacts
#     （impl-pipeline.sh）/ cm_enabled（context-map.sh）を run_per_task_loop から呼ぶ。
#   - family 内の cross-file 呼び出し（run_per_task_loop → per-task-loop-exec.sh の runner 群 /
#     per-task-loop-diffrange.sh の判定ヘルパー）も遅延束縛で解決される（loader が main loop 前に
#     全 module を source）。
#   - グローバル変数（$PER_TASK_LOOP_ENABLED / $REPO_DIR / $SPEC_DIR_REL / $BASE_BRANCH /
#     $NUMBER / $LOG 等）は watcher-config.sh / 本体 main loop で定義される。
#   - 外部 CLI: gh / jq / git。
# shellcheck shell=bash

# ─── pt_log ───
# per-task ロガー。`[YYYY-MM-DD HH:MM:SS] per-task: <msg>` 形式で stdout に出力。
# 呼び出し側で `>> "$LOG"` する規約（既存 rv_log / sc_log と同じ）。
# NFR 2.1, NFR 2.2 を満たす。
pt_log() {
  echo "[$(date '+%F %T')] per-task: $*"
}
pt_warn() {
  echo "[$(date '+%F %T')] per-task: WARN: $*" >&2
}

# ─── pt_extract_pending_tasks <tasks_md_path> ───
#
# tasks.md から未完了 task の numeric 階層 ID を numeric 階層昇順で抽出して stdout に出力。
#
# - 抽出対象: 行頭が `- [ ] <numeric_id>(\.)? ` で始まる行（deferrable `- [ ]*` は除外）
#   - 親タスク慣習: `- [ ] 1. <title>`（ID の後ろに `.` + 空白）
#   - 子タスク慣習: `- [ ] 1.1 <title>`（ID の後ろに空白のみ、末尾 `.` なし）
#   - tasks-generation.md の規約と既存 tasks.md の実例（本リポジトリ含む）の双方を満たす
# - 抽出した ID は親タスク末尾の `.` を除去した numeric 階層 ID（例: `1`, `1.1`, `1.10`）
# - 出力順序は `sort -V`（version sort）で numeric 階層昇順を保証（`1.2` < `1.10`）
# - tasks.md 不在時は return 1
#
# Requirements: 2.1, 2.3, 5.1
pt_extract_pending_tasks() {
  local tasks_md="$1"
  if [ ! -f "$tasks_md" ]; then
    return 1
  fi
  # `- [ ] N. <title>` (親タスク) または `- [ ] N.M(.K...) <title>` (子タスク) を抽出。
  # `- [ ]*` (deferrable) は除外（`\[ \]` の直後に空白を要求するため自然に除外される）。
  # 親タスクの末尾 `.` は sed の置換で剥がして numeric 階層 ID のみ取り出す。
  grep -E '^- \[ \] [0-9]+(\.[0-9]+)*\.? ' "$tasks_md" \
    | sed -E 's/^- \[ \] ([0-9]+(\.[0-9]+)*)\.? .*/\1/' \
    | sort -V
  return 0
}

# ─── pt_check_task_completed <tasks_md_path> <task_id> ───
#
# tasks.md 上で指定 task_id の checkbox 状態を判定し、戻り値で表現する。Issue #263 の
# 「per-task Implementer が rc=0 で抜けたが対象 task が `- [ ]` のまま放置される」無限
# リトライループ検出のために使用する。
#
# 戻り値:
#   0 = `- [x]` 済み（完了マーカー存在 / 進捗ありの正常系）
#   1 = `- [ ]` のまま（未完了 / 進捗ゼロ）
#   2 = tasks.md 不在、または該当 task_id の checkbox 行が一切存在しない（fail-safe）
#
# 判定パターン（pt_extract_pending_tasks の regex と整合）:
#   - 親タスク慣習: `- [x] 1. <title>` / `- [ ] 1. <title>`（ID 後ろに `.` + 空白）
#   - 子タスク慣習: `- [x] 1.1 <title>` / `- [ ] 1.1 <title>`（ID 後ろに空白のみ）
#   - deferrable `- [ ]*` は pt_extract_pending_tasks 側で除外されているため、本関数の
#     ループ呼出ルートには到達しない（Req 3.3 / Req 5.3 / Out of Scope と整合）
#   - 1 件の task_id が複数行に出現する spec は想定外（tasks.md は numeric ID 一意）。
#     重複時は「いずれかの行に `[x]` があれば完了扱い」とせず、未完了行優先で 1 を返す
#     方が安全側に倒れるが、本実装では grep の出現順で先勝ち判定とする（重複時の
#     挙動は spec 外）。
#
# set -euo pipefail 配下で grep no-match による失敗を関数全体に伝播させないため、
# `|| true` で吸収する。
#
# Requirements: 1.1, 5.3, NFR 3.1
pt_check_task_completed() {
  local tasks_md="$1"
  local task_id="$2"

  if [ ! -f "$tasks_md" ]; then
    return 2
  fi

  # task_id を正規表現リテラルとして安全にエスケープ（`.` のみ含む想定だが防御的に処理）
  local task_id_re
  # shellcheck disable=SC2016  # sed の置換式は単引用符内で完結（シェル展開は意図的に行わない）
  task_id_re=$(printf '%s' "$task_id" | sed -E 's/[][\\.*^$()+?{|/]/\\&/g')

  # `- [x] <task_id>(\.)? ` で完了済みを優先確認（親 / 子両慣習をカバー）
  if grep -qE "^- \[x\] ${task_id_re}\.? " "$tasks_md" 2>/dev/null; then
    return 0
  fi

  # `- [ ] <task_id>(\.)? ` で未完了行の存在を確認（進捗ゼロ判定）
  if grep -qE "^- \[ \] ${task_id_re}\.? " "$tasks_md" 2>/dev/null; then
    return 1
  fi

  # checkbox 行自体が見つからない → fail-safe（Req 5.3: silent fail で resumable
  # return 0 に倒さず、呼び出し側で claude-failed 化する）
  return 2
}

# ─── pt_extract_learnings <impl_notes_path> ───
#
# impl-notes.md の `## Implementation Notes` 見出しから「次の `## ` 見出しが現れる直前まで」
# を stdout に出力。learnings を後続 task の Implementer prompt に inline 注入するために
# 使用する。
#
# - セクション不在 / impl-notes.md 自体が無い場合は空文字を返し常に return 0
#   （Req 4.5: 単一 task の Issue で learnings 空を許容、を構造的に保証）
# - 出力には見出し `## Implementation Notes` 自体も含む（Implementer が prompt から
#   そのままセクションを参照できるようにするため）
# - `## Implementation Notes` 以外のセクションには触れない（Req 4.4）
#
# Requirements: 4.3, 4.4, 4.5, 5.4
pt_extract_learnings() {
  local impl_notes="$1"
  if [ ! -f "$impl_notes" ]; then
    return 0
  fi
  # awk で `## Implementation Notes` セクションを抽出。
  # - `## Implementation Notes` 行を見つけたら print 開始
  # - print 開始後に別の `## ` 見出しが来たら print 停止
  # - 末尾まで他の `## ` が来なければファイル末尾まで print
  awk '
    /^## Implementation Notes[[:space:]]*$/ { in_section = 1; print; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$impl_notes"
  return 0
}

# ─── pt_extract_findings_block <review_notes_path> ───
#
# review-notes.md の `## Findings` セクション（次の `## ` 見出し直前まで）を
# stdout に出力する。per-task retry 経路で Developer prompt に直前 round の
# Reviewer Findings を inline 注入するために使用する（Issue #305 Req 1.1, 1.3,
# 1.5, NFR 4.1）。
#
# - 抽出成功時: 0 を返し、stdout に `## Findings` 見出しを含む本文を出力
# - ファイル不在 or `## Findings` 見出し不在: 1 を返し、stdout は空
# - 末尾の RESULT 行や他セクション（`## Summary` 等）には触れない（次の `## `
#   見出し直前で停止する）
#
# `pt_extract_learnings` の awk pattern を踏襲しているため、テスト容易性と
# 実装方針を揃えている。
#
# Requirements: 1.1, 1.3, 1.5, 5.1, 5.5, NFR 4.1
pt_extract_findings_block() {
  local review_notes="$1"
  if [ ! -f "$review_notes" ]; then
    return 1
  fi
  # `## Findings` 見出しが存在するかを先に確認（不在なら return 1）。
  if ! grep -qE '^## Findings[[:space:]]*$' "$review_notes"; then
    return 1
  fi
  # awk で `## Findings` セクションを抽出。
  # - `## Findings` 行を見つけたら print 開始
  # - print 開始後に別の `## ` 見出しが来たら print 停止
  # - 末尾まで他の `## ` が来なければファイル末尾まで print
  awk '
    /^## Findings[[:space:]]*$/ { in_section = 1; print; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$review_notes"
  return 0
}

# ─── pt_extract_debugger_section <debugger_notes_path> <task_id> ───
#
# debugger-notes.md の `## Task <task_id>` セクション（次の `## ` 見出し直前まで）を
# stdout に出力する。per-task retry の Debugger Gate 経由 round=3 経路で
# Developer prompt に当該 task の Fix Plan を inline 注入するために使用する
# （Issue #305 Req 1.2, 1.5, NFR 4.2）。
#
# - 抽出成功時: 0 を返し、stdout に `## Task <task_id>` 見出しを含む本文を出力
# - ファイル不在 or 当該 `## Task <task_id>` 見出し不在: 1 を返し、stdout は空
# - 他 task の `## Task <other_id>` セクションには触れない（NFR 4.2 を構造保証）
# - task_id の `.` は awk 正規表現メタを避けるため shell 側で `[.]` にエスケープして
#   から awk pattern に埋め込む（例: `1.2` → `1[.]2`）
#
# 既存 `detect_debugger_already_invoked` の `^## Task <id>$` 行頭マッチ regex と
# 整合させているため、Debugger が書き出すセクション規約を共有する。
#
# Requirements: 1.2, 1.5, 5.2, NFR 4.2
pt_extract_debugger_section() {
  local debugger_notes="$1"
  local task_id="$2"
  if [ ! -f "$debugger_notes" ]; then
    return 1
  fi
  # task_id 内の `.` を `[.]` にエスケープして awk 正規表現メタを無効化する。
  # numeric 階層 ID（例: `1`, `1.2`, `2.1.3`）以外の入力は本関数の責務外
  # （呼び出し側で validated される前提）。
  local escaped_id="${task_id//./[.]}"
  local heading_pattern="^## Task ${escaped_id}$"
  # 該当見出しが存在するかを先に確認（不在なら return 1）。
  if ! grep -qE "$heading_pattern" "$debugger_notes"; then
    return 1
  fi
  # awk で `## Task <task_id>` セクションを抽出。
  # - 該当見出し行を見つけたら print 開始
  # - print 開始後に別の `## ` 見出しが来たら print 停止
  # - 末尾まで他の `## ` が来なければファイル末尾まで print
  awk -v pat="$heading_pattern" '
    $0 ~ pat { in_section = 1; print; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$debugger_notes"
  return 0
}

# ─── pt_snapshot_review_notes <task_id> <round> ───
#
# round=2 redo / Debugger 経路 redo 起動の **直前** に現在の review-notes.md を
# 一時ファイルに退避し、redo 後の Reviewer が同名ファイルを上書きしても
# fail-fast inspector が「直前 round の Findings」を参照できるようにする
# （Issue #305 Req 3.1）。
#
# - 退避先: `/tmp/idd-claude-${REPO_SLUG}-${NUMBER}-pt-snapshot-${task_id}-round${round}-${ts}.md`
# - 退避元が存在しない場合は退避せず stdout に空文字 + return 0
#   （fail-fast 判定側で prev snapshot 不在を非マッチとして扱う / Req 3.4）
# - REPO_SLUG / NUMBER / task_id / round / ts の 5 要素で隔離して衝突回避
# - stdout: 退避先 path（空文字なら退避なし）
#
# Requirements: 3.1
pt_snapshot_review_notes() {
  local task_id="$1"
  local round="$2"
  local review_notes="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ ! -f "$review_notes" ]; then
    # 退避元不在 → 空文字を返す（fail-fast 判定側で「snapshot 不在」として扱う）
    return 0
  fi
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local snapshot_path="/tmp/idd-claude-${REPO_SLUG}-${NUMBER}-pt-snapshot-${task_id}-round${round}-${ts}.md"
  if cp "$review_notes" "$snapshot_path" 2>/dev/null; then
    printf '%s\n' "$snapshot_path"
  fi
  return 0
}

# ─── pt_has_subtasks <tasks_md_path> <task_id> ───
#
# tasks.md 上で指定 task_id を numeric 階層 prefix とする子タスク行が 1 件以上存在するか
# 判定する（Issue #270 / Req 2.1, 2.4, 2.5）。
#
# 判定パターン（checkbox enforcement の判定パターンに整合 / .claude/rules/tasks-generation.md）:
#   - 行頭が `- [ ]` / `- [ ]*` / `- [x]` / `- [x]*` のいずれかで開始
#   - 続けて `<task_id>.<下位 ID>(<.下位 ID>)* `（末尾 `.` あり / なしを許容）
#   - 例: 親 task_id=`4` に対し `- [ ] 4.1 <title>` / `- [x] 4.2.1 <title>` / `- [ ]* 4.3 <title>`
#
# 戻り値:
#   0 = 子タスクが 1 件以上存在する（= 親タスクとして扱える）
#   1 = 子タスクが 1 件も存在しない（= 通常タスク / 階層末端）
#   2 = tasks.md 不在 / その他 fail-safe（NFR 1.3）
#
# Req 2.4: 子タスクの完了 / 未完了状態（`- [x]` か `- [ ]` か）に関わらず、子タスクの
# 存在のみで親タスク判定を成立させる
# Req 2.5: deferrable 印 `- [ ]*` も子タスク存在判定の対象に含める
#
# Requirements (Issue #270): 2.1, 2.4, 2.5, NFR 1.3
pt_has_subtasks() {
  local tasks_md="$1"
  local task_id="$2"
  if [ ! -f "$tasks_md" ]; then
    return 2
  fi
  if [ -z "$task_id" ]; then
    return 2
  fi
  # task_id を正規表現リテラルとして安全にエスケープ
  local task_id_re
  # shellcheck disable=SC2016
  task_id_re=$(printf '%s' "$task_id" | sed -E 's/[][\\.*^$()+?{|/]/\\&/g')
  # 子タスク行: `- [ ]` / `- [ ]*` / `- [x]` / `- [x]*` + ` <task_id>.<下位 ID>(...)? `
  if grep -qE "^- \[[ x]\]\*? ${task_id_re}\.[0-9]+(\.[0-9]+)*\.? " "$tasks_md" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ─── pt_should_skip_reviewer <task_id> ───
#
# per-task Reviewer 起動直前のスキップ判定 dispatcher（Issue #270 / Req 1.1, 1.2, 1.3）。
#
# 以下を順に判定し、すべて成立した場合のみ「Reviewer 起動をスキップ可能」として stdout に
# 判定根拠ログを 1 行残し、return 0。いずれか不成立 / fail-safe なら return 1。
#
#   1. 当該 task_id が「子タスクを 1 件以上持つ親タスク」である（pt_has_subtasks rc=0）
#   2. pt_resolve_diff_range が成功する（marker commit が見つかる）
#   3. 当該 task の diff range が `tasks.md` のみ + checkbox flip のみで構成される
#      （pt_is_parent_checkbox_only_diff rc=0）
#
# 戻り値:
#   0 = スキップ条件成立（Reviewer 起動不要 / approve 扱い）
#   1 = スキップ条件不成立（通常通り Reviewer を起動すべき / fail-safe 含む）
#
# NFR 2.1: スキップ成立時のみ単一行ログを stdout に出力（呼び出し側で `>> "$LOG"` する規約）。
# NFR 2.3: スキップ不成立時は新規ログを出さない（既存ログ量を増やさない後方互換）。
#
# Requirements (Issue #270): 1.1, 1.2, 1.3, 1.4, 2.x, 3.x, NFR 1.3, NFR 2.1, NFR 2.3
pt_should_skip_reviewer() {
  local task_id="$1"
  local tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"

  # (1) 親タスク判定（子タスクが 1 件以上存在するか）
  local _has_rc=0
  pt_has_subtasks "$tasks_md" "$task_id" || _has_rc=$?
  if [ "$_has_rc" != "0" ]; then
    # 子タスク不在 or fail-safe → スキップ対象外（既存ログを増やさない）
    return 1
  fi

  # (2) diff range 解決
  local range_line range_start range_end
  if ! range_line=$(pt_resolve_diff_range "$task_id" 2>/dev/null); then
    return 1
  fi
  range_start=$(printf '%s' "$range_line" | cut -f1)
  range_end=$(printf '%s' "$range_line" | cut -f2)
  if [ -z "$range_start" ] || [ -z "$range_end" ]; then
    return 1
  fi

  # (3) tasks.md only + checkbox flip only 判定
  if ! pt_is_parent_checkbox_only_diff "$task_id" "$range_start" "$range_end"; then
    return 1
  fi

  # スキップ成立。NFR 2.1 / Req 1.4 に従い grep 可能な単一行ログを stdout に出力。
  pt_log "task=${task_id} reviewer skipped reason=parent-task-checkbox-only-diff range=${range_start:0:7}..${range_end:0:7}"
  return 0
}

# ─── run_per_task_loop ───
#
# Stage A の代替実体。未完了 task を numeric ID 順に 1 件ずつ Implementer + Reviewer で
# 消化する dispatcher。
#
# 戻り値:
#   0  = 全 task 消化成功（Stage A 完了相当）/ pending 0 件で no-op /
#        tasks.md 不在の防御ガード（呼び出し側で Stage A fallback 済みの想定 / #166）
#   1  = Implementer / Reviewer 失敗で claude-failed 付与済み（呼び出し側は伝搬 return 1）
#
# 副作用:
#   - 成功時: 全 task が `- [x]` 化 + `docs(tasks): mark <id> as done` commit が積まれる
#   - 失敗時: `mark_issue_failed` 経由で claude-failed 付与済
#   - quota 超過時: 呼び出し側に return 99 相当で伝搬する代わりに return 0（既存 Stage A
#     の quota パスと同じく watcher は正常終了し、Resume Processor が次 tick で再開）
#
# Requirements: 2.1, 2.6, 2.7, 3.4, 3.5, 3.6, 3.7, 5.1, 5.2
run_per_task_loop() {
  local tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  # tasks.md 不在の事前分岐は呼び出し側 run_impl_pipeline() の Stage A 分岐で実施済み
  # （#166: tasks.md 不在なら per-task ループへ入らず従来 Stage A へフォールバックする）。
  # 本ブロックは万一直接呼び出し等で到達した場合の防御ガード。Issue を失敗扱いせず
  # （claude-failed を付けず）no-op return 0 で抜け、メッセージと実装の乖離を作らない。
  if [ ! -f "$tasks_md" ]; then
    pt_warn "tasks.md が存在しません: $tasks_md → per-task ループを起動せず no-op return 0（呼び出し側で Stage A fallback 済みの想定）"
    return 0
  fi

  # pending タスク一覧
  local pending
  pending=$(pt_extract_pending_tasks "$tasks_md" || true)
  if [ -z "$pending" ]; then
    pt_log "pending tasks=0 → no-op return 0 (Stage A 完了相当)" >> "$LOG"
    return 0
  fi

  local pending_count
  pending_count=$(printf '%s\n' "$pending" | wc -l | tr -d '[:space:]')
  pt_log "pending tasks=$pending_count" >> "$LOG"

  # PER_TASK_MAX_TASKS 超過チェック（暴走防止）
  local max_tasks="${PER_TASK_MAX_TASKS:-0}"
  if [ -n "$max_tasks" ] && [ "$max_tasks" != "0" ] && [ "$pending_count" -gt "$max_tasks" ]; then
    pt_warn "pending tasks=$pending_count が PER_TASK_MAX_TASKS=$max_tasks を超過 → claude-failed"
    mark_issue_failed "per-task-max-tasks-exceeded" "per-task ループの安全装置: 未完了 task 件数（${pending_count}）が \`PER_TASK_MAX_TASKS=${max_tasks}\` を超過したため、暴走防止のためループ起動前に停止しました。tasks.md を縮小するか \`PER_TASK_MAX_TASKS\` を引き上げてください。"
    return 1
  fi

  # 各 task をループで消化
  local task_id
  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue

    # ─── #313: Context Map 生成（標準機能 / Req 2.1, 1.4） ───
    # per-task ループ配下（`PER_TASK_LOOP_ENABLED=true`）では `cm_enabled` が常に
    # rc=0 を返し、各 task で context-map.md を生成する。失敗は `cm_warn` で吸収し
    # per-task ループは継続
    # させる（NFR 2.3「per-task ループを止めない」）。call site をループ冒頭に置く
    # ことで Implementer / Reviewer の双方が同じ context-map.md を参照できる。
    if cm_enabled; then
      cm_generate "$task_id" || cm_warn "task=$task_id context-map.md 生成で警告（per-task ループは継続）"
    fi

    # Issue #305 task 6: 当該 task の前 cycle 残骸 snapshot を防御的に削除
    # （/tmp の OS cleanup を待たず冒頭で除去。新規 snapshot 取得時は ts で
    # 名前衝突を回避するため実害はないが、長期 watcher 稼働で /tmp が肥大化
    # するのを抑止する）
    rm -f "/tmp/idd-claude-${REPO_SLUG}-${NUMBER}-pt-snapshot-${task_id}-"* 2>/dev/null || true

    # ── round=1: Implementer + Reviewer ──
    local impl_rc=0
    run_per_task_implementer "$task_id" || impl_rc=$?
    case "$impl_rc" in
      0)
        # Issue #263: 進捗ゼロ検出。Implementer が rc=0 を返したが対象 task の checkbox が
        # `- [ ] → - [x]` に遷移していない場合、次 tick で同じ Issue が再 pickup されて
        # 同じ Implementer 失敗を rc=0 で繰り返す無限リトライループに陥るため、ここで
        # claude-failed 化して停止する。tasks.md 不在は run_per_task_loop 冒頭で防御済み
        # だが、grep no-match や該当行不在を fail-safe として捕捉する（Req 1.1, 1.3, 5.3）。
        local _pt_check_rc=0
        pt_check_task_completed "$tasks_md" "$task_id" || _pt_check_rc=$?
        if [ "$_pt_check_rc" != "0" ]; then
          echo "❌ #$NUMBER: per-task Implementer (task=$task_id, phase=initial) rc=0 だが進捗ゼロ検出 (check_rc=$_pt_check_rc) → claude-failed (per-task-implementer-no-progress)" | tee -a "$LOG"
          pt_mark_no_progress_failed "$task_id" "initial" "$_pt_check_rc"
          return 1
        fi
        ;;
      99)
        # quota 超過: 既存 #66 規約に従い watcher は正常終了。Resume Processor が次 tick で再開
        echo "⏸️ #$NUMBER: per-task Implementer (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
        return 0
        ;;
      *)
        echo "❌ #$NUMBER: per-task Implementer (task=$task_id) 失敗 → claude-failed" | tee -a "$LOG"
        mark_issue_failed "per-task-implementer-failed" "per-task ループの Implementer が task=\`${task_id}\` で失敗しました（claude 非 0 exit）。残りの未完了 task は処理しません。\`$LOG\` を確認してください。"
        return 1
        ;;
    esac

    # ── Phase 3 (#22) Debugger Gate: per-task Implementer 完了直後 BLOCKED 検出 ──
    # `DEBUGGER_ENABLED=true` 時のみ、当該 task の Implementer が impl-notes.md に
    # `BLOCKED: <reason>` を出力していたら task 単位で Debugger を 1 回起動して
    # Implementer 再起動 → 通常 Reviewer Round 1 サイクルに合流する（Req 6.2, 6.3）。
    # 既起動なら直行 claude-failed（Req 5.2）。OFF 時は本ブロックが構造的に skip。
    if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
      local _pt_blocked_reason=""
      if _pt_blocked_reason=$(detect_blocked_marker "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"); then
        if detect_debugger_already_invoked "$task_id"; then
          dbg_log "trigger=blocked issue=#${NUMBER} task=${task_id} reason=\"${_pt_blocked_reason}\" result=skipped reason=debugger-already-invoked" >> "$LOG"
          echo "❌ #$NUMBER: per-task BLOCKED 宣言検出 (task=$task_id) だが Debugger 既起動 → claude-failed (Req 5.2)" | tee -a "$LOG"
          mark_issue_failed "per-task-debugger-blocked-but-invoked" "per-task ループの Developer が task=\`${task_id}\` で \`BLOCKED:\` 行を出力しましたが、本 task では既に Debugger が 1 回起動済みのため再起動を抑止し人間判断に委ねます（Req 5.1, 5.2, 6.3）。

- 対象 task ID: ${task_id}
- BLOCKED reason: ${_pt_blocked_reason}
- 既存 Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\` の \`## Task ${task_id}\` セクション
- impl-notes.md: \`${SPEC_DIR_REL}/impl-notes.md\`

\`$LOG\` を確認し、Fix Plan の追加修正 / 別 Issue 切り出し等を判断してください。"
          return 1
        fi

        echo "🐛 #$NUMBER: per-task Developer BLOCKED 宣言検出 (task=$task_id) → Debugger Gate 起動" | tee -a "$LOG"
        dbg_log "trigger=blocked issue=#${NUMBER} task=${task_id} reason=\"${_pt_blocked_reason}\" start" >> "$LOG"
        local _pt_dbg_bl_rc=0
        run_debugger_stage "blocked" "$task_id" "" || _pt_dbg_bl_rc=$?
        case "$_pt_dbg_bl_rc" in
          99)
            echo "⏸️ #$NUMBER: Debugger (task=$task_id / BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          0)
            echo "✅ #$NUMBER: Debugger (task=$task_id / BLOCKED 経路) 完了 → per-task Implementer 再起動" | tee -a "$LOG"
            ;;
          *)
            return 1
            ;;
        esac

        # Implementer 再起動（task 単位 / Fix Plan は impl-notes.md / debugger-notes.md を Implementer が読む）
        local impl_bl_rc=0
        run_per_task_implementer "$task_id" || impl_bl_rc=$?
        case "$impl_bl_rc" in
          0)
            # Issue #263: BLOCKED 経路再実行後も進捗ゼロのまま rc=0 で抜けるケースを検出。
            # 通常の Reviewer Round 1 に合流させる前に、対象 task の `- [ ] → - [x]` 遷移を
            # 機械検証する（Req 1.3 / 全 4 箇所適用）。
            local _pt_check_bl_rc=0
            pt_check_task_completed "$tasks_md" "$task_id" || _pt_check_bl_rc=$?
            if [ "$_pt_check_bl_rc" != "0" ]; then
              echo "❌ #$NUMBER: per-task Implementer (BLOCKED 経路再実行 / task=$task_id, phase=blocked-redo) rc=0 だが進捗ゼロ検出 (check_rc=$_pt_check_bl_rc) → claude-failed (per-task-implementer-no-progress)" | tee -a "$LOG"
              pt_mark_no_progress_failed "$task_id" "blocked-redo" "$_pt_check_bl_rc"
              return 1
            fi
            ;;
          99)
            echo "⏸️ #$NUMBER: per-task Implementer (BLOCKED 経路再実行 / task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          *)
            echo "❌ #$NUMBER: per-task Implementer (BLOCKED 経路再実行 / task=$task_id) 失敗 → claude-failed" | tee -a "$LOG"
            mark_issue_failed "per-task-implementer-blocked-redo-failed" "per-task ループの BLOCKED 経路 Implementer 再実行が task=\`${task_id}\` で失敗しました（claude 非 0 exit）。\`$LOG\` を確認してください。"
            return 1
            ;;
        esac
      fi
    fi

    # Issue #270: 親タスク完了マーク commit のみで構成される task の Reviewer 起動を抑止する。
    # 親タスク（子タスクを 1 件以上持つ task）かつ diff range の変更が `tasks.md` のみ かつ
    # その変更が当該 task ID の checkbox flip のみ なら、Reviewer は本来レビュー対象を持たず
    # `review-notes.md` を書き出さないため `parse-failed` → `claude-failed` を引き起こす。
    # 該当する場合のみ Reviewer 起動をスキップし approve 扱い（rev_rc=0）で続行する。
    # 通常タスク / 子タスク / 異常系（diff range 解決失敗等）は本判定を bypass し従来経路へ。
    local rev_rc=0
    if pt_should_skip_reviewer "$task_id" >> "$LOG"; then
      rev_rc=0
    else
      run_per_task_reviewer "$task_id" 1 || rev_rc=$?
    fi
    case "$rev_rc" in
      0)
        # approve → 次 task へ
        # Issue #349 Req 3.1: per-task Reviewer round=1 approve → claude-review=success を publish
        publish_claude_review_status 1 || true
        ;;
      99)
        echo "⏸️ #$NUMBER: per-task Reviewer (task=$task_id, round=1) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
        return 0
        ;;
      1)
        # reject 1 回目 → Implementer 再起動 + Reviewer round=2
        # Issue #349 Req 3.2: per-task Reviewer round=1 reject → claude-review=failure を publish
        publish_claude_review_status 1 || true
        echo "🔁 #$NUMBER: per-task Reviewer (task=$task_id, round=1) reject → Implementer 再実行" | tee -a "$LOG"

        # Issue #305 task 6: 連続 reject fail-fast 用の prev snapshot 取得 +
        # round=2 redo Implementer 起動直前の HEAD SHA を記録（Req 3.1）。
        # snapshot 取得失敗時は空文字が返り、pt_check_fail_fast 側で
        # prev-snapshot-missing として不成立扱いとなる（Req 3.4 安全側）。
        # git rev-parse 失敗時も `|| echo ""` で空文字に倒し、pt_check_fail_fast
        # 側で git-diff-failed 経由 return 1（既存 Debugger Gate 経路に進む）。
        local _pt_ff_prev_snapshot _pt_ff_sha_before
        _pt_ff_prev_snapshot="$(pt_snapshot_review_notes "$task_id" 1)"
        _pt_ff_sha_before="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "")"

        local impl2_rc=0
        run_per_task_implementer_redo "$task_id" "after-round1" || impl2_rc=$?
        case "$impl2_rc" in
          0)
            # Issue #263: Reviewer reject 後の Implementer 再実行も rc=0 で抜けたが進捗ゼロ
            # のままだと、後段 Reviewer round=2 が同じ未完了状態を再 reject → 同じ無限
            # ループに陥る。round=2 起動前にここで停止する（Req 1.3）。
            local _pt_check_r2_rc=0
            pt_check_task_completed "$tasks_md" "$task_id" || _pt_check_r2_rc=$?
            if [ "$_pt_check_r2_rc" != "0" ]; then
              echo "❌ #$NUMBER: per-task Implementer 再実行 (task=$task_id, phase=round2-redo) rc=0 だが進捗ゼロ検出 (check_rc=$_pt_check_r2_rc) → claude-failed (per-task-implementer-no-progress)" | tee -a "$LOG"
              pt_mark_no_progress_failed "$task_id" "round2-redo" "$_pt_check_r2_rc"
              return 1
            fi
            ;;
          99)
            echo "⏸️ #$NUMBER: per-task Implementer 再実行 (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          *)
            echo "❌ #$NUMBER: per-task Implementer 再実行 (task=$task_id) 失敗 → claude-failed" | tee -a "$LOG"
            mark_issue_failed "per-task-implementer-redo-failed" "per-task ループの Implementer 再実行が task=\`${task_id}\` で失敗しました（Reviewer reject 後の再起動 / claude 非 0 exit）。\`$LOG\` を確認してください。"
            return 1
            ;;
        esac

        local rev2_rc=0
        run_per_task_reviewer "$task_id" 2 || rev2_rc=$?
        case "$rev2_rc" in
          0)
            # round=2 approve → 次 task へ
            # Issue #349 Req 3.1: per-task Reviewer round=2 approve → claude-review=success
            publish_claude_review_status 2 || true
            ;;
          99)
            echo "⏸️ #$NUMBER: per-task Reviewer (task=$task_id, round=2) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          1)
            # Issue #305 task 6: 連続 reject + テスト差分なしの fail-fast 判定
            # （Debugger Gate 判定の前 / Req 3.2 / 3.3）。成立時は Debugger Gate
            # 経由 round=3 redo に進まず即 claude-failed 化して turn 予算消費を
            # 停止する。不成立時は既存 Debugger Gate / per-task-reviewer-reject2
            # 経路へ進む（Req 3.4 / 既存挙動温存）。
            local _pt_ff_sha_after _pt_ff_out _pt_ff_rc=0
            _pt_ff_sha_after="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "")"
            _pt_ff_out="$(pt_check_fail_fast "$task_id" \
              "$_pt_ff_prev_snapshot" \
              "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" \
              "$_pt_ff_sha_before" \
              "$_pt_ff_sha_after" 2>&1)" || _pt_ff_rc=$?
            # pt_check_fail_fast の stdout（grep 可能 1 行）を LOG に転記
            # （Physical Data Model 行 528-530 / NFR 3.1）
            if [ -n "$_pt_ff_out" ]; then
              printf '[%s] [%s] per-task: %s\n' "$(date '+%F %T')" "$REPO" "$_pt_ff_out" >> "$LOG"
            fi
            if [ "$_pt_ff_rc" = "0" ]; then
              # fail-fast 成立 → category / target を stdout から再抽出して
              # pt_mark_fail_fast_failed に渡し claude-failed 化
              local _pt_ff_cat _pt_ff_tgt
              _pt_ff_cat="$(printf '%s' "$_pt_ff_out" | sed -n 's/.*category=\([^ ]*\).*/\1/p')"
              _pt_ff_tgt="$(printf '%s' "$_pt_ff_out" | sed -n 's/.*target=\([^ ]*\).*/\1/p')"
              echo "❌ #$NUMBER: per-task fail-fast 検出 (task=$task_id, category=${_pt_ff_cat:-unknown}, target=${_pt_ff_tgt:-unknown}) → claude-failed (per-task-implementer-fail-fast-loop)" | tee -a "$LOG"
              pt_mark_fail_fast_failed "$task_id" "${_pt_ff_cat:-unknown}" "${_pt_ff_tgt:-unknown}"
              return 1
            fi
            # fail-fast 不成立 → 既存 Debugger Gate 経路にそのまま進む（Req 3.4）
            # Issue #349 Req 3.2: per-task Reviewer round=2 reject → claude-review=failure
            # （fail-fast 成立時は既に return 1 済 / 不成立時のみここに到達）
            publish_claude_review_status 2 || true

            # 再 reject → Phase 3 (#22) Debugger Gate に分岐 (Req 6.1, 6.3)、
            # 未対応なら claude-failed + Issue コメント
            if [ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked "$task_id"; then
              echo "🐛 #$NUMBER: per-task Reviewer (task=$task_id, round=2) reject → Debugger Gate 起動（task scope）" | tee -a "$LOG"
              local _pt_dbg_rc=0
              run_debugger_stage "round2-reject" "$task_id" "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" || _pt_dbg_rc=$?
              case "$_pt_dbg_rc" in
                99)
                  echo "⏸️ #$NUMBER: Debugger (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                  return 0
                  ;;
                0)
                  echo "✅ #$NUMBER: Debugger (task=$task_id) 完了 → per-task Implementer 再起動 + Reviewer round=3" | tee -a "$LOG"
                  ;;
                *)
                  # Debugger 異常終了 → mark_issue_failed 既発射
                  return 1
                  ;;
              esac

              # Implementer 再起動（Issue #305 task 4 で `run_per_task_implementer_redo` に置換。
              # `redo_mode=after-debugger` で review-notes.md の Findings と debugger-notes.md
              # の `## Task <id>` セクションを prompt に inline 注入する。これにより従来
              # `### Task <id>` の自発参照に依拠していた弱い情報注入を、prompt 内 inline 運搬に
              # 切り替える）
              local impl3_rc=0
              run_per_task_implementer_redo "$task_id" "after-debugger" || impl3_rc=$?
              case "$impl3_rc" in
                0)
                  # Issue #263: Debugger 経由 Implementer 再実行も rc=0 で抜けたが進捗ゼロ
                  # のままだと、Reviewer round=3 が同じ未完了状態を reject 確定し、結果として
                  # Debugger Gate 終端の round=3 経路で `per-task-reviewer-reject3` を出すが、
                  # 進捗ゼロが原因であることを stage 識別子で区別できないため、ここで
                  # `per-task-implementer-no-progress` として停止する（Req 1.3）。
                  local _pt_check_r3_rc=0
                  pt_check_task_completed "$tasks_md" "$task_id" || _pt_check_r3_rc=$?
                  if [ "$_pt_check_r3_rc" != "0" ]; then
                    echo "❌ #$NUMBER: per-task Implementer 3 回目 (task=$task_id, phase=round3-redo / Debugger 経由) rc=0 だが進捗ゼロ検出 (check_rc=$_pt_check_r3_rc) → claude-failed (per-task-implementer-no-progress)" | tee -a "$LOG"
                    pt_mark_no_progress_failed "$task_id" "round3-redo" "$_pt_check_r3_rc"
                    return 1
                  fi
                  ;;
                99)
                  echo "⏸️ #$NUMBER: per-task Implementer 3 回目 (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                  return 0
                  ;;
                *)
                  echo "❌ #$NUMBER: per-task Implementer 3 回目 (task=$task_id / Debugger 経由) 失敗 → claude-failed" | tee -a "$LOG"
                  mark_issue_failed "per-task-implementer-pp-failed" "per-task ループの Debugger 経由 Implementer 再実行が task=\`${task_id}\` で失敗しました（claude 非 0 exit）。\`$LOG\` を確認してください。"
                  return 1
                  ;;
              esac

              # Reviewer Round 3（task 単位）
              local rev3_rc=0
              run_per_task_reviewer "$task_id" 3 || rev3_rc=$?
              case "$rev3_rc" in
                0)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=approve" >> "$LOG"
                  # approve → 次 task へ
                  # Issue #349 Req 3.1: per-task Reviewer round=3 approve → claude-review=success
                  publish_claude_review_status 3 || true
                  ;;
                99)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=quota-exceeded" >> "$LOG"
                  echo "⏸️ #$NUMBER: per-task Reviewer (task=$task_id, round=3) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                  return 0
                  ;;
                1)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=reject" >> "$LOG"
                  # Issue #349 Req 3.2: per-task Reviewer round=3 reject → claude-review=failure
                  publish_claude_review_status 3 || true
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) reject → claude-failed (Req 3.5)" | tee -a "$LOG"
                  local parsed3pt cat3pt tgt3pt
                  parsed3pt=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                  cat3pt=$(echo "$parsed3pt" | cut -f2)
                  tgt3pt=$(echo "$parsed3pt" | cut -f3)
                  publish_terminal_failure_artifacts "per-task-reviewer-reject3" "per-task ループの Debugger 経由 Reviewer (task=\`${task_id}\`, round=3) も reject を出したため、自動 iteration を打ち切り人間判断に委ねます（Debugger は 1 task あたり 1 回のみ起動するため再起動しません / Req 3.5, 6.3）。

- 対象 task ID: ${task_id}
- 対象 requirement ID: ${tgt3pt:-(unknown)}
- reject カテゴリ: ${cat3pt:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照
- Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\` を参照

### 次の手順
1. review-notes.md / debugger-notes.md / watcher ログ \`$LOG\` を読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                  return 1
                  ;;
                3)
                  # diff-range-resolve-failed (Issue #164) → 専用の復旧手順付き失敗ハンドラ
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=diff-range-resolve-failed" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) diff range 解決失敗 → claude-failed (diff-range-resolve-failed)" | tee -a "$LOG"
                  pt_mark_diff_range_resolve_failed "$task_id" 3
                  return 1
                  ;;
                4)
                  # Issue #296 Req 2.3 / Req 4.2, 4.3 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
                  # → `per-task-reviewer-missing-file` カテゴリで `claude-failed`（round=3 / Debugger 経由）。
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=missing-file-after-retry" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) ファイル不在（リトライ後も未生成）→ claude-failed (per-task-reviewer-missing-file)" | tee -a "$LOG"
                  publish_terminal_failure_artifacts "per-task-reviewer-missing-file" "per-task ループの Debugger 経由 Reviewer (task=\`${task_id}\`, round=3) が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
                  return 1
                  ;;
                5)
                  # per-task-post-marker-commits-detected (Issue #304) → marker 後の未レビュー
                  # commit を検出し fail-with-diagnostic で停止（Debugger 経由 round=3）。
                  # `run_per_task_reviewer` 内で `pt_mark_post_marker_commits_detected` 済み。
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=per-task-post-marker-commits-detected" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) marker 後の未レビュー commit を検出 → claude-failed (per-task-post-marker-commits-detected)" | tee -a "$LOG"
                  return 1
                  ;;
                6)
                  # Issue #442 Req 3.1, 3.2, 3.4, 3.5: 拡張リトライ後も turn 切れ枯渇 →
                  # `per-task-reviewer-max-turns-exhausted` カテゴリで `claude-failed`（Debugger 経由 round=3）。
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=max-turns-exhausted" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (per-task-reviewer-max-turns-exhausted)" | tee -a "$LOG"
                  publish_terminal_failure_artifacts "per-task-reviewer-max-turns-exhausted" "per-task ループの Debugger 経由 Reviewer (task=\`${task_id}\`, round=3) が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
                  return 1
                  ;;
                *)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=error" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) 異常終了 → claude-failed" | tee -a "$LOG"
                  publish_terminal_failure_artifacts "per-task-reviewer-error" "per-task ループの Debugger 経由 Reviewer (task=\`${task_id}\`, round=3) が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
                  return 1
                  ;;
              esac
            else
              # DEBUGGER_ENABLED != "true" もしくは task sentinel 既起動 → 既存 per-task-reviewer-reject2 経路
              if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
                dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} result=skipped reason=debugger-already-invoked" >> "$LOG"
              fi
              echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) reject → claude-failed" | tee -a "$LOG"
              local parsed2 cat2 tgt2
              parsed2=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
              cat2=$(echo "$parsed2" | cut -f2)
              tgt2=$(echo "$parsed2" | cut -f3)
              publish_terminal_failure_artifacts "per-task-reviewer-reject2" "per-task ループの Reviewer が task=\`${task_id}\` で 2 回連続 reject を出したため、残りの未完了 task の処理を停止し人間判断に委ねます。

- 対象 task ID: ${task_id}
- 対象 requirement ID: ${tgt2:-(unknown)}
- reject カテゴリ: ${cat2:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照

### 次の手順
1. review-notes.md と watcher ログ \`$LOG\` を読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
              return 1
            fi
            ;;
          3)
            # diff-range-resolve-failed (Issue #164) → 専用の復旧手順付き失敗ハンドラ
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) diff range 解決失敗 → claude-failed (diff-range-resolve-failed)" | tee -a "$LOG"
            pt_mark_diff_range_resolve_failed "$task_id" 2
            return 1
            ;;
          4)
            # Issue #296 Req 2.3 / Req 4.2 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
            # → `per-task-reviewer-missing-file` カテゴリで `claude-failed`（round=2）。
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) ファイル不在（リトライ後も未生成）→ claude-failed (per-task-reviewer-missing-file)" | tee -a "$LOG"
            publish_terminal_failure_artifacts "per-task-reviewer-missing-file" "per-task ループの Reviewer (task=\`${task_id}\`, round=2) が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
            return 1
            ;;
          5)
            # per-task-post-marker-commits-detected (Issue #304) → marker 後の未レビュー commit
            # を検出し fail-with-diagnostic で停止。`run_per_task_reviewer` 内で
            # `pt_mark_post_marker_commits_detected` 済みのため追加の Issue コメントは行わない。
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) marker 後の未レビュー commit を検出 → claude-failed (per-task-post-marker-commits-detected)" | tee -a "$LOG"
            return 1
            ;;
          6)
            # Issue #442 Req 3.1, 3.2, 3.4, 3.5: 拡張リトライ後も turn 切れ枯渇 →
            # `per-task-reviewer-max-turns-exhausted` カテゴリで `claude-failed`（round=2）。
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (per-task-reviewer-max-turns-exhausted)" | tee -a "$LOG"
            publish_terminal_failure_artifacts "per-task-reviewer-max-turns-exhausted" "per-task ループの Reviewer (task=\`${task_id}\`, round=2) が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
            return 1
            ;;
          *)
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) 異常終了 → claude-failed" | tee -a "$LOG"
            publish_terminal_failure_artifacts "per-task-reviewer-error" "per-task ループの Reviewer (task=\`${task_id}\`, round=2) が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
            return 1
            ;;
        esac
        ;;
      3)
        # diff-range-resolve-failed (Issue #164) → 専用の復旧手順付き失敗ハンドラ
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) diff range 解決失敗 → claude-failed (diff-range-resolve-failed)" | tee -a "$LOG"
        pt_mark_diff_range_resolve_failed "$task_id" 1
        return 1
        ;;
      4)
        # Issue #296 Req 2.3 / Req 4.2 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
        # → `per-task-reviewer-missing-file` カテゴリで `claude-failed`（round=1）。
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) ファイル不在（リトライ後も未生成）→ claude-failed (per-task-reviewer-missing-file)" | tee -a "$LOG"
        publish_terminal_failure_artifacts "per-task-reviewer-missing-file" "per-task ループの Reviewer (task=\`${task_id}\`, round=1) が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
        return 1
        ;;
      5)
        # per-task-post-marker-commits-detected (Issue #304) → marker 後の未レビュー commit
        # を検出し、`POST_MARKER_RECOVERY_MODE=fail-with-diagnostic`（default）で停止。
        # `run_per_task_reviewer` 内で `pt_mark_post_marker_commits_detected` 済みのため、
        # ここでは追加の Issue コメント投稿は行わず、stdout / log 出力のみで停止する。
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) marker 後の未レビュー commit を検出 → claude-failed (per-task-post-marker-commits-detected)" | tee -a "$LOG"
        return 1
        ;;
      6)
        # Issue #442 Req 3.1, 3.2, 3.4, 3.5: 拡張リトライ後も turn 切れ枯渇 → 区別された
        # `per-task-reviewer-max-turns-exhausted` カテゴリで `claude-failed`（round=1）。
        # per-task-reviewer-error（claude crash）/ per-task-reviewer-missing-file（ファイル不在）/
        # code reject のいずれとも grep 区別可能。run-summary degraded は呼び出し側 Stage A の
        # rs_scan_degraded_log で反映される（単発経路と非対称だが既存実装に合わせる）。
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (per-task-reviewer-max-turns-exhausted)" | tee -a "$LOG"
        publish_terminal_failure_artifacts "per-task-reviewer-max-turns-exhausted" "per-task ループの Reviewer (task=\`${task_id}\`, round=1) が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
        return 1
        ;;
      *)
        # round=1 reviewer error → claude-failed
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) 異常終了 → claude-failed" | tee -a "$LOG"
        publish_terminal_failure_artifacts "per-task-reviewer-error" "per-task ループの Reviewer (task=\`${task_id}\`, round=1) が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
        return 1
        ;;
    esac
  done <<<"$pending"

  pt_log "all pending tasks completed (count=$pending_count) → return 0" >> "$LOG"
  return 0
}
