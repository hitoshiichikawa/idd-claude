#!/usr/bin/env bash
# per-task-loop.sh — Per-task TDD Implementation Loop モジュール（#21 Phase 2 / #461-462 切り出し）
#
# 用途:
#   `PER_TASK_LOOP_ENABLED=true` のときに `run_impl_pipeline` の Stage A 内で起動される
#   per-task loop の補助関数群。`PER_TASK_LOOP_ENABLED` が未指定 / `=true` 以外の場合、
#   これらの関数はどこからも呼ばれないため、本機能導入前と外形挙動は完全一致する
#   （NFR 1.1 / Req 1.1）。
#
#   関数一覧（前半 = #461 / pt_ ヘルパー + prompt builder）:
#     - pt_log / pt_warn                    : per-task 専用ロガー（rv_log / sc_log と同形式）
#     - pt_extract_pending_tasks            : tasks.md から未完了 `- [ ]` を numeric ID 昇順抽出
#     - pt_check_task_completed             : tasks.md の当該 task が `- [x]`（完了）かを判定
#     - pt_extract_learnings                : impl-notes.md の `## Implementation Notes` を抽出
#     - pt_extract_findings_block           : review-notes.md の Findings ブロックを抽出
#     - pt_extract_debugger_section         : debugger-notes.md の該当セクションを抽出
#     - pt_snapshot_review_notes            : review-notes.md をスナップショット退避
#     - pt_check_fail_fast                  : fail-fast（無進捗）条件を判定
#     - pt_mark_fail_fast_failed            : fail-fast 時に claude-failed を付与
#     - pt_resolve_diff_range               : task 単位 diff range の開始/終了 SHA を解決
#     - pt_detect_post_marker_commits       : marker commit 以降の追加 commit を検出
#     - pt_classify_post_marker_paths       : post-marker の変更パスを分類
#     - pt_handle_post_marker_commits       : post-marker commit をハンドリング
#     - pt_has_subtasks                     : 親 task が子 task を持つかを判定
#     - pt_is_parent_checkbox_only_diff     : 親 checkbox のみの diff かを判定
#     - pt_should_skip_reviewer             : Reviewer を skip すべきかを判定
#     - build_per_task_implementer_prompt   : per-task Implementer prompt を組み立て
#     - build_per_task_reviewer_prompt      : per-task Reviewer prompt を組み立て
#
#   後半（#462 で移動完了予定 / runner + escalation）:
#     - run_per_task_implementer / run_per_task_implementer_redo / run_per_task_reviewer
#     - pt_mark_diff_range_resolve_failed / pt_mark_post_marker_commits_detected
#     - pt_post_docs_only_auto_refresh_comment / pt_mark_no_progress_failed
#     - run_per_task_loop（dispatcher）
#
#   詳細: docs/specs/21-phase-2-per-task-tdd-implementation-loop/design.md
#
# 配置先:
#   $HOME/bin/modules/per-task-loop.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - 実行時に本体 / 他モジュールの関数・グローバルへ依存（bash 遅延束縛で loader が全 module
#     source 後に解決）: mark_issue_failed / rv_log（issue-watcher.sh 本体）/ sc_log
#     （stage-checkpoint.sh）/ cm_enabled / cm_render_prompt_section（context-map.sh）/
#     グローバル $LOG / $REPO_DIR / $SPEC_DIR_REL / $BASE_BRANCH 等。
#
# prefix: pt_（per-task loop 固有の非 prefix 関数 build_per_task_* / run_per_task_* を含む）

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

# ─── pt_check_fail_fast <task_id> <prev_snapshot_path> <curr_review_notes_path> <sha_before> <sha_after> ───
#
# 連続 2 round（round=1 reject + round=2 reject）の Findings が「同一カテゴリ かつ
# 同一 target」を 1 件以上共有 かつ 直近 round の Developer 再実行で
# **テストファイル**に差分が積まれていないことを検出する（Issue #305 Req 3.1, 3.2,
# 3.4, 3.5）。
#
# - 入力:
#   - $1 task_id              : 対象 task（log 出力用）
#   - $2 prev_snapshot_path   : round=1 直後に取得した review-notes.md スナップショット
#                               （空文字 / ファイル不在なら不成立）
#   - $3 curr_review_notes_path: round=2 reject 直後の review-notes.md
#                                （空文字 / ファイル不在なら不成立）
#   - $4 sha_before           : round=2 redo Developer 起動 **直前**の HEAD SHA
#   - $5 sha_after            : round=2 reject **時点**の HEAD SHA（= 現在の HEAD）
#
# - アルゴリズム:
#   1. 両 review-notes.md から `### Finding <n>` ブロックを抽出し、各 Finding の
#      `Target` 行 + `Category` 行を `<category>\t<target>` の tuple set として取得
#   2. 両 set の積集合が空ならば return 1（不成立 / Req 3.4 / stdout に
#      `task=<id> fail-fast skip reason=no-shared-finding`）
#   3. `git diff --name-only "$sha_before".."$sha_after"` で変更ファイル一覧を取得
#   4. 変更ファイル一覧に「テストファイル」が **1 件も含まれない** ならば return 0
#      （fail-fast 成立 / Req 3.2 / stdout に grep 可能 1 行
#       `task=<id> fail-fast match category=<cat> target=<tgt> test-diff-empty range=<before>..<after>`）
#   5. 1 件以上含まれるなら return 1（不成立 / stdout に
#      `task=<id> fail-fast skip reason=test-diff-present`）
#
# - テストファイル判定基準（design.md「テストファイル判定基準」節 / Req 3.5）:
#   拡張子 OR ディレクトリの 2 軸:
#   - 拡張子: `_test.sh` / `.test.ts` / `.test.tsx` / `.test.js` / `.test.jsx` /
#             `.spec.ts` / `.spec.tsx` / `.spec.js` / `.spec.jsx` /
#             `_test.go` / `_test.py` / `test_*.py`
#   - ディレクトリ: パスに `/test/` / `/tests/` / `/__tests__/` / `/spec/` のいずれかを含む
#   - 加えて `local-watcher/test/fixtures/**` も「テスト関連差分」として扱う
#
# Requirements: 3.1, 3.2, 3.4, 3.5
pt_check_fail_fast() {
  local task_id="$1"
  local prev_snapshot_path="$2"
  local curr_review_notes_path="$3"
  local sha_before="$4"
  local sha_after="$5"

  # snapshot 不在 / 読取不能なら不成立（Req 3.4 / 安全側）
  if [ -z "$prev_snapshot_path" ] || [ ! -f "$prev_snapshot_path" ]; then
    printf 'task=%s fail-fast skip reason=prev-snapshot-missing\n' "$task_id"
    return 1
  fi
  if [ -z "$curr_review_notes_path" ] || [ ! -f "$curr_review_notes_path" ]; then
    printf 'task=%s fail-fast skip reason=curr-review-notes-missing\n' "$task_id"
    return 1
  fi

  # 両 review-notes.md から (category, target) tuple set を抽出する helper
  # `### Finding <n>` ブロック配下の `**Target**: <val>` + `**Category**: <val>` を
  # pair でまとめ、`<category>\t<target>` 1 行ずつ stdout に出す。
  _pt_ff_extract_tuples() {
    local file="$1"
    awk '
      /^### / {
        # `### ` 見出しに遷移したら、直前の Finding が揃っていれば確定出力
        if (in_finding && cur_target != "" && cur_category != "") {
          print cur_category "\t" cur_target
        }
        cur_target = ""; cur_category = ""
        if ($0 ~ /^### Finding[[:space:]]/) { in_finding = 1 } else { in_finding = 0 }
        next
      }
      /^## / {
        # `## ` 見出しで Finding ブロック群終端
        if (in_finding && cur_target != "" && cur_category != "") {
          print cur_category "\t" cur_target
        }
        cur_target = ""; cur_category = ""
        in_finding = 0
        next
      }
      in_finding {
        # `**Target**: <val>` / `**Category**: <val>` （行頭 `- ` 任意）
        if (match($0, /\*\*Target\*\*:[[:space:]]*/)) {
          val = substr($0, RSTART + RLENGTH)
          sub(/[[:space:]]+$/, "", val)
          cur_target = val
        } else if (match($0, /\*\*Category\*\*:[[:space:]]*/)) {
          val = substr($0, RSTART + RLENGTH)
          sub(/[[:space:]]+$/, "", val)
          cur_category = val
        }
      }
      END {
        if (in_finding && cur_target != "" && cur_category != "") {
          print cur_category "\t" cur_target
        }
      }
    ' "$file"
  }

  local prev_tuples curr_tuples shared
  prev_tuples="$(_pt_ff_extract_tuples "$prev_snapshot_path" | sort -u)"
  curr_tuples="$(_pt_ff_extract_tuples "$curr_review_notes_path" | sort -u)"

  # 積集合の算出（両方に存在する tuple のみ）
  if [ -z "$prev_tuples" ] || [ -z "$curr_tuples" ]; then
    printf 'task=%s fail-fast skip reason=no-shared-finding\n' "$task_id"
    return 1
  fi
  shared="$(comm -12 <(printf '%s\n' "$prev_tuples") <(printf '%s\n' "$curr_tuples"))"
  if [ -z "$shared" ]; then
    printf 'task=%s fail-fast skip reason=no-shared-finding\n' "$task_id"
    return 1
  fi

  # 最初の共有 tuple を採用（log 用）
  local first_pair shared_category shared_target
  first_pair="$(printf '%s\n' "$shared" | head -n 1)"
  shared_category="$(printf '%s' "$first_pair" | cut -f1)"
  shared_target="$(printf '%s' "$first_pair" | cut -f2)"

  # テストファイル差分判定
  local diff_files
  if ! diff_files="$(git diff --name-only "${sha_before}..${sha_after}" 2>/dev/null)"; then
    # git diff 失敗時は安全側に倒して不成立扱い（不要 claude-failed を避ける / Req 3.4）
    printf 'task=%s fail-fast skip reason=git-diff-failed\n' "$task_id"
    return 1
  fi

  local has_test_file=0
  if [ -n "$diff_files" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$f" in
        # 拡張子マッチ
        *_test.sh|*.test.ts|*.test.tsx|*.test.js|*.test.jsx|\
        *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx|\
        *_test.go|*_test.py)
          has_test_file=1; break ;;
      esac
      # `test_*.py` パターン（ファイル名先頭 test_ + .py）
      case "$f" in
        */test_*.py|test_*.py)
          has_test_file=1; break ;;
      esac
      # ディレクトリマッチ
      case "$f" in
        */test/*|*/tests/*|*/__tests__/*|*/spec/*)
          has_test_file=1; break ;;
      esac
      # local-watcher/test/fixtures/** もテスト関連扱い
      case "$f" in
        local-watcher/test/fixtures/*)
          has_test_file=1; break ;;
      esac
    done <<< "$diff_files"
  fi

  if [ "$has_test_file" -eq 0 ]; then
    printf 'task=%s fail-fast match category=%s target=%s test-diff-empty range=%s..%s\n' \
      "$task_id" "$shared_category" "$shared_target" "$sha_before" "$sha_after"
    return 0
  fi

  printf 'task=%s fail-fast skip reason=test-diff-present\n' "$task_id"
  return 1
}

# ─── pt_mark_fail_fast_failed <task_id> <category> <target> ───
#
# fail-fast 検出時に `claude-failed` 化 + 運用者向け診断 Issue コメントを投稿する
# （Issue #305 Req 3.3, NFR 1.3, NFR 3.2）。
#
# 既存 `pt_mark_no_progress_failed` / `pt_mark_diff_range_resolve_failed` と
# 同パターンで `mark_issue_failed` に `per-task-implementer-fail-fast-loop`
# カテゴリで委譲する。新規カテゴリ追加であり既存カテゴリの意味は変更しない
# （NFR 1.3）。
#
# Args:
#   $1 = task_id  (例: `1.2`)
#   $2 = category (連続 reject 対象の Finding カテゴリ / AC 未カバー / missing test
#                  / boundary 逸脱 等)
#   $3 = target   (連続 reject 対象の Finding target / numeric requirement ID
#                  または `boundary:<component>`)
#
# 副作用（mark_issue_failed と等価 / NFR 1.3）:
#   1. claude-claimed / claude-picked-up を除去し claude-failed を付与
#   2. 復旧手順付き Issue コメントを 1 件投稿
#
# Requirements: 3.3, NFR 1.3, NFR 3.2
pt_mark_fail_fast_failed() {
  local task_id="$1"
  local category="$2"
  local target="$3"

  local extra_body
  extra_body=$(cat <<EOF
## 失敗カテゴリ
- カテゴリ: \`per-task-implementer-fail-fast-loop\`
- 対象 task ID: \`${task_id}\`
- 連続 reject 対象 Finding: Category=\`${category}\` / Target=\`${target}\`
- ログ: \`$LOG\`

## 検出条件
per-task ループの round=1 と round=2 の **連続 2 round**で Reviewer Findings が
「同一カテゴリ かつ 同一 target」を 1 件以上共有しており、かつ round=2 redo の
Developer 再実行（直前の \`run_per_task_implementer_redo\` 起動）で **テスト
ファイルに差分が積まれていない**ことを検出しました（Issue #305 Req 3.2 / 3.3）。

このまま Debugger Gate 経由 round=3 redo に進んでも、同一指摘が再度 reject される
構造になっており、turn 予算を無駄に消費するため自動進行を停止しました。

## 参照ファイル
- \`${SPEC_DIR_REL}/review-notes.md\` — 直近 round の Reviewer Findings
- \`${SPEC_DIR_REL}/debugger-notes.md\` — Debugger 経路を経た場合のみ存在
- \`${SPEC_DIR_REL}/impl-notes.md\` — Developer の Finding Closure Matrix と learning
- \`$LOG\` — watcher ログ全文（fail-fast 検出 1 行 + 直前の Reviewer 判定行）

## 次の手順
1. \`${SPEC_DIR_REL}/review-notes.md\` と \`${SPEC_DIR_REL}/impl-notes.md\` を読み、
   連続 reject されている Finding（Category=\`${category}\` / Target=\`${target}\`）の
   妥当性を確認する
2. **妥当な指摘**であれば、手動で修正 commit を積み、対応テストを追加した上で
   \`claude-failed\` ラベルを外す（次サイクルで watcher が当該 Issue を再 pickup）
3. **妥当でない指摘**（Reviewer の誤判定 / 要件側の曖昧さ）であれば、Architect /
   PM への差し戻しを判断し、必要なら requirements.md / design.md / tasks.md の
   再検討を実施する
EOF
)

  pt_log "task=${task_id} fail-fast → claude-failed (per-task-implementer-fail-fast-loop) category=${category} target=${target}" >> "$LOG"

  mark_issue_failed "per-task-implementer-fail-fast-loop" "$extra_body"
}

# ─── pt_resolve_diff_range <task_id> ───
#
# per-task Reviewer に渡す diff range の開始 SHA / 終了 SHA を解決して
# `<range_start_sha>\t<range_end_sha>` を stdout に出力。
#
# アルゴリズム（design.md「diff range 解決アルゴリズム」節 + Issue #164 / #421 拡張）:
#   1. `$BASE_BRANCH..HEAD` 範囲の `docs(tasks): mark ... as done` commit を SHA+subject の
#      タブ区切り pair で時系列昇順に全列挙
#   2. 当該 task_id の marker commit を以下の優先順で特定（range_end）:
#      a. 単記 marker（subject が `docs(tasks): mark <task_id> as done` に完全一致、
#         または canonical suffix 付き `docs(tasks): mark <task_id> as done (#<number>)`
#         に一致 / Issue #421 Req 1）。複数マッチ時は最後（最新）のマッチを採用
#         （既存挙動を維持 / Req 3.1）
#      b. 単記 marker が無ければ連記 marker（subject が
#         `docs(tasks): mark <ids> as done` または
#         `docs(tasks): mark <ids> as done (#<number>)` で、<ids> を `/` / `,` /
#         空白で token 化したときに task_id と完全一致する token を含む）。
#         複数マッチ時は最後のマッチを採用（NFR 2.1: 連記経由解決時は stderr ログに
#         `via=multi-id-marker` または `via=multi-id-marker-with-suffix` を残す）
#   3. 全 mark commit 列の中で range_end の直前要素を range_start とする
#   4. 直前要素が存在しない（初回 task）場合は range_start = `$BASE_BRANCH` の SHA
#   5. 当該 task の marker commit が単記でも連記でも見つからない場合は return 1
#
# 後方互換性（Req 3.1, 3.2, 3.3 / NFR 1.1）:
#   - suffix 無し単記 marker のみで構成されるリポジトリ履歴では、単記 marker が常に
#     優先採用されるため本変更前と完全に同一の SHA pair を返す
#   - suffix 無し連記 marker は単記 marker が無い場合の fallback として動作するため、
#     既存ログタグ（`via=multi-id-marker`）の文字列形式と発火条件は変更しない
#   - suffix 付き経由で解決した場合のみ、新タグ（`*-with-suffix`）を追加で出力する
#
# Suffix 許容境界（Issue #421 Req 4 / NFR 3.2）:
#   - 許容: `docs(tasks): mark <id...> as done (#<digits>)`
#     （`as done` と `(` の間に半角空白 1 つ、`#` 直後に 1 文字以上の連続 digit、
#     閉じ括弧 `)` で行終端）
#   - 拒否: 空白なし / 括弧なし / 閉じ括弧後の追加文字列 / `<number>` 部に非数字
#   - 上記境界は単記パス / 連記パス双方に同一規則で適用する（Req 4.6）
#
# False positive 防止（Issue #164 Req 2.5 / Issue #421 NFR 3.1）:
#   - <ids> 部を `/` / `,` / 空白で正規化した後 word 単位で完全一致照合するため、
#     task_id `1` が `1.1` や `11` に誤マッチしない
#   - suffix 抽出に用いる正規表現の `<number>` 部は `[0-9]+` で有界化（NFR 3.2）。
#     ReDoS リスクの無い線形時間照合
#
# Requirements (Issue #421): 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 3.1, 3.2, 3.3,
#   4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 5.1, 5.2, NFR 1.1, NFR 2.1, NFR 2.2, NFR 3.1, NFR 3.2
# 旧 Requirements (Issue #164 / #270 / #305): 3.2, 4.5, 5.4, #164 Req 2.1-2.5, 3.1, 3.2, NFR 2.1
pt_resolve_diff_range() {
  local task_id="$1"
  local base="${BASE_BRANCH:-main}"

  # 全 mark commit pair (SHA<TAB>subject) を時系列昇順で取得（--reverse で oldest 先頭）
  local all_pairs
  all_pairs=$(git log --grep="^docs(tasks): mark " --format='%H%x09%s' --reverse "${base}..HEAD" 2>/dev/null || true)
  if [ -z "$all_pairs" ]; then
    return 1
  fi

  # canonical suffix 付き 単記 subject の組み立て（task_id をリテラル文字列として扱い、
  # 正規表現メタ文字回避のため bash =~ ではなく文字列等価比較で照合する）。
  local single_canonical="docs(tasks): mark ${task_id} as done"

  # ─── (a) 単記 marker を優先検索（suffix 無し → suffix 付きの順 / Req 1, 3.1） ───
  # 同 task_id に対して suffix 無し / suffix 付き双方が混在する場合は「all_pairs を
  # 時系列順に 1 回走査し、最後にマッチした方を採用」する。これにより：
  # - 履歴上の最新 marker が採用される（Req 1.2 の「いずれか 1 つを一意に決定」）
  # - 採用された marker の via タグが選択基準（suffix 有無）の観測手段になる（Req 1.5）
  local current_mark="" via="" sha subject id_list tok found suffix_num
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if [ "$subject" = "$single_canonical" ]; then
      current_mark="$sha"
      via="single-id-marker"
    elif [[ "$subject" == "${single_canonical} (#"*")" ]]; then
      # `<canonical> (#<n>)` の形に粗くマッチしたうえで、`<n>` 部が `^[0-9]+$` を
      # 満たすかを厳密検証する（Req 1.3 / Req 4.5 / NFR 3.1）。閉じ括弧後の追加
      # 文字列は上の glob `*)` 終端で既に排除されている（Req 4.4）。
      # `${single_canonical} (#` の長さ分だけ prefix を剥がし、末尾 `)` を 1 文字
      # 落として `<n>` 部を抽出する。
      suffix_num="${subject#"${single_canonical}" (#}"
      suffix_num="${suffix_num%)}"
      if [[ "$suffix_num" =~ ^[0-9]+$ ]]; then
        current_mark="$sha"
        via="single-id-marker-with-suffix"
      fi
    fi
  done <<<"$all_pairs"

  # ─── (b) 単記 marker が無ければ連記 marker を fallback 検索（Req 2 / #164 Req 2.2） ───
  if [ -z "$current_mark" ]; then
    while IFS=$'\t' read -r sha subject; do
      [ -n "$sha" ] || continue
      # subject から <ids> 部を抽出（`docs(tasks): mark <ids> as done` または
      # `docs(tasks): mark <ids> as done (#<n>)`）。
      # - 末尾 ` (#<n>)` は optional（capture group 2 / Req 2.1）。<n> は `[0-9]+` で
      #   有界化（NFR 3.2）。閉じ括弧後の追加文字列は末尾アンカ `$` で排除（Req 4.4）。
      # - capture group 1（<ids> 部）が空白なし / 括弧なし / 非数字 suffix を含む
      #   変則 subject にマッチしないことは末尾アンカ + 厳密な suffix 構造で担保される。
      # - sed BRE には `?` 量指定子が無いため `-E` (ERE) を維持しつつ optional group
      #   `(...)?` を使う。
      id_list=$(printf '%s' "$subject" | sed -nE 's/^docs\(tasks\): mark (.+) as done( \(#[0-9]+\))?$/\1/p')
      [ -n "$id_list" ] || continue
      # suffix 有無の判定（observability tag の選択用 / Req 2.3）。
      # subject 末尾が ` (#<n>)` の形ならば suffix 付き、そうでなければ無し。
      local _matched_with_suffix=0
      if [[ "$subject" == *" (#"*")" ]]; then
        # 抽出した id_list の後ろに ` (#<n>)` が続いて行終端していることを再確認する。
        # （上の sed が match している時点で構造は保証されているが、observability
        # タグ選択の判定として明示的に確認する）
        _matched_with_suffix=1
      fi
      # `/` / `,` を空白に正規化し、word 単位で task_id と完全一致する token を探す。
      # word splitting は IFS のデフォルト（空白）で行われ、任意連続空白に対応する。
      found=false
      for tok in $(printf '%s' "$id_list" | tr '/,' '  '); do
        if [ "$tok" = "$task_id" ]; then
          found=true
          break
        fi
      done
      if [ "$found" = "true" ]; then
        current_mark="$sha"
        if [ "$_matched_with_suffix" -eq 1 ]; then
          via="multi-id-marker-with-suffix"
        else
          via="multi-id-marker"
        fi
      fi
    done <<<"$all_pairs"
  fi

  if [ -z "$current_mark" ]; then
    return 1
  fi

  # all_pairs 順序を再度走査して current_mark の直前要素を探す（既存挙動を踏襲）
  local prev_mark=""
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if [ "$sha" = "$current_mark" ]; then
      break
    fi
    prev_mark="$sha"
  done <<<"$all_pairs"

  local range_start
  if [ -n "$prev_mark" ]; then
    range_start="$prev_mark"
  else
    # 初回 task: $BASE_BRANCH の SHA を使う
    range_start=$(git rev-parse "$base" 2>/dev/null || true)
    if [ -z "$range_start" ]; then
      return 1
    fi
  fi

  # NFR 2.1 / Req 1.5 / Req 2.3: 解決経路を識別可能なタグを stderr に残す（運用者が
  # `grep via=...` で件数把握できる）。suffix 無し単記経由は出力しない（既存ログ量を
  # 増やさない後方互換 / Req 3.3）。stderr に出すことで関数の主出力（stdout の
  # SHA pair）と分離する。
  case "$via" in
    multi-id-marker)
      echo "[$(date '+%F %T')] per-task: diff-range resolved via=multi-id-marker task_id=${task_id} sha=${current_mark}" >&2
      ;;
    single-id-marker-with-suffix)
      echo "[$(date '+%F %T')] per-task: diff-range resolved via=single-id-marker-with-suffix task_id=${task_id} sha=${current_mark}" >&2
      ;;
    multi-id-marker-with-suffix)
      echo "[$(date '+%F %T')] per-task: diff-range resolved via=multi-id-marker-with-suffix task_id=${task_id} sha=${current_mark}" >&2
      ;;
  esac

  printf '%s\t%s\n' "$range_start" "$current_mark"
  return 0
}

# ─── pt_detect_post_marker_commits <marker_sha> ───
#
# 指定 marker SHA より後ろ（`<marker_sha>..HEAD`）に存在する commit を列挙する safety net。
# per-task Reviewer reject 後の Implementer 再実行で、修正 commit が古い marker より後ろに
# 積まれた場合（idd-codex #14 と同型）に silent range truncation を防ぐための検出 hook。
#
# Contract（design.md「pt_detect_post_marker_commits」節 / Req 2.1, NFR 1.3, NFR 2.1）:
#   引数: <marker_sha>
#   stdout: post-marker SHA list（newline 区切り、git log と同じ「新しい順」/ HEAD 側が先頭）
#   stderr: 警告ログ（NFR 2.1 / git エラー時のみ）
#   rc=0: 1 件以上検出
#   rc=1: 0 件（fall-through OK / NFR 1.3 既存挙動温存）
#   rc=2: git エラー（fail-safe / 呼び出し側は rc=1 と同様に扱える）
#
# 後方互換性（NFR 1.3）:
#   - post-marker commit が 0 件のケース（典型シナリオ）では rc=1 / stdout 空となるため、
#     呼び出し側は既存ルートを温存できる
#
# 参照実装:
#   - 本関数は `docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/
#     test-post-marker-detect.sh` 内の参照実装と algorithm body を byte 同期させる責務がある
#     （stderr 行の prefix のみ `[smoke]` ↔ `[YYYY-MM-DD HH:MM:SS] per-task:` で差を許容、
#     既存 #164 fixture と同方針）
#
# Requirements: 2.1, NFR 1.3, NFR 2.1
pt_detect_post_marker_commits() {
  local marker_sha="$1"
  local post_list
  if ! post_list=$(git log --format=%H "${marker_sha}..HEAD" 2>/dev/null); then
    pt_warn "post-marker-commits-detect: git log error marker=${marker_sha}"
    return 2
  fi
  if [ -z "$post_list" ]; then
    return 1
  fi
  printf '%s\n' "$post_list"
  return 0
}

# ─── pt_classify_post_marker_paths <marker_sha> ───
#
# Issue #356: marker_sha より後ろ (`<marker_sha>..HEAD`) の累積 diff の変更ファイル集合を
# `POST_MARKER_DOCS_ALLOWLIST` glob パターンと突合し、`docs-only` / `mixed` を判定する
# helper（Req 1.1, 2.1, 2.2）。
#
# 判定ルール:
#   - 全変更ファイルが allowlist のいずれかにマッチ → `docs-only`（rc=0）
#   - 1 件でも allowlist 外（コード / テスト / 設定ファイル等）が含まれる → `mixed`（rc=1）
#   - 変更ファイル 0 件は想定外（呼び出し側は `pt_detect_post_marker_commits` で先に
#     0 件を rc=1 で除外している）。本関数では `mixed` に倒す（保守的判定）
#
# Contract:
#   引数: $1 = marker_sha
#   stdout:
#     1 行目: `docs-only` または `mixed`
#     2 行目: `mixed` の場合は最初に検出された allowlist 外パス（取得できれば）
#   stderr: 警告ログ（git エラー時のみ）
#   rc=0: docs-only と判定
#   rc=1: mixed と判定（allowlist 外パスが 1 件以上 / 変更ファイル 0 件 / allowlist 空）
#   rc=2: git エラー（fail-safe / 呼び出し側は `mixed` 同様に扱える）
#
# パターンマッチング:
#   - `ar_classify_diff` と同じ POSIX bash `[[ "$path" == $pattern ]]` イディオム
#   - glob ワイルドカード（`*` / `**` / `?`）が使用可能
#   - 1 件でも unmatched が出た時点で即座に `mixed` 判定（保守的判定 / Req 2.2）
#
# 後方互換性（NFR 1.1, 1.3）:
#   - 本関数は新規追加であり、呼び出し側（`pt_handle_post_marker_commits`）が rc=0
#     （docs-only）以外の戻り値をすべて従来挙動（safety net 発火）に倒す
#
# Requirements: 1.1, 1.5, 2.1, 2.2, NFR 1.3
pt_classify_post_marker_paths() {
  local marker_sha="$1"

  # allowlist 未設定 / 空文字 → 保守的に mixed 扱い（Req 2.2 安全側）
  if [ -z "${POST_MARKER_DOCS_ALLOWLIST:-}" ]; then
    echo "mixed"
    return 1
  fi

  local changed_paths
  if ! changed_paths=$(git diff --name-only "${marker_sha}..HEAD" 2>/dev/null); then
    pt_warn "post-marker-paths-classify: git diff error marker=${marker_sha}"
    echo "mixed"
    return 2
  fi

  if [ -z "$changed_paths" ]; then
    # 変更ファイル 0 件は本来呼ばれない（detect 側で除外済み）。保守的に mixed
    echo "mixed"
    return 1
  fi

  # allowlist をカンマ区切りで配列展開
  local -a patterns=()
  local IFS=','
  read -ra patterns <<< "$POST_MARKER_DOCS_ALLOWLIST"
  IFS=$' \t\n'

  local path matched pattern first_unmatched=""
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    matched=false
    for pattern in "${patterns[@]}"; do
      # 前後空白除去
      pattern="${pattern# }"
      pattern="${pattern% }"
      [ -z "$pattern" ] && continue
      # POSIX bash の path matching（`==` + glob）。
      # 右辺の変数 glob 比較は意図的なので SC2053 を局所無効化。
      # shellcheck disable=SC2053
      if [[ "$path" == $pattern ]]; then
        matched=true
        break
      fi
    done
    if [ "$matched" = "false" ]; then
      first_unmatched="$path"
      break
    fi
  done <<< "$changed_paths"

  if [ -n "$first_unmatched" ]; then
    echo "mixed"
    echo "$first_unmatched"
    return 1
  fi

  echo "docs-only"
  return 0
}

# ─── pt_handle_post_marker_commits <task_id> <round> <range_start> <marker_sha> <post_marker_list> ───
#
# `pt_detect_post_marker_commits` で marker 後の未レビュー commit が検出された場合の
# recovery dispatcher。env `POST_MARKER_RECOVERY_MODE` に応じて以下のいずれかに分岐する:
#
#   - `extend-range`: stdout に新 `<range_start>\t<HEAD_SHA>` を出力し rc=0 を返す。
#     呼び出し側は marker を捨てて HEAD まで range を拡張し、`extended=true` で
#     Reviewer prompt を組み立てる
#   - `fail-with-diagnostic` (default): 後続タスク（#304 task 4）で追加される
#     `pt_mark_post_marker_commits_detected` を呼んで claude-failed を付与した上で rc=5
#     を返す。本 task 3 時点では当該関数が未実装のため、本実装は rc=5 を返すまでに留め、
#     `run_per_task_reviewer` 経路の組み込み（task 5）または `pt_mark_post_marker_commits_detected`
#     追加（task 4）で `mark` 呼び出しを補完する
#
# 不正値 / 未設定はすべて default の `fail-with-diagnostic` にフォールバックする
# （安全側に倒す / Req 2.2）。
#
# Contract（design.md「pt_handle_post_marker_commits」節 / Req 2.2, 2.3, 3.3, NFR 1.1, NFR 2.1）:
#   引数: <task_id> <round> <range_start> <marker_sha> <post_marker_list>
#   env:  POST_MARKER_RECOVERY_MODE (default=fail-with-diagnostic, 不正値も default 化)
#   stdout: extend-range 時のみ <new_range_start>\t<new_range_end>（HEAD まで拡張済み）
#   stderr: NFR 2.1 準拠の単一行イベントログ（後述）
#   rc=0: extend-range で続行（呼び出し側は新しい range で Reviewer 起動）
#   rc=5: fail-with-diagnostic で停止（後段で claude-failed を付与）
#
# NFR 2.1 ログ書式（fixture 参照実装 line 158 と同一書式 / `pt_warn` の WARN: 接頭辞を付けない
# 単一行イベントログとして出力する）:
#   `[YYYY-MM-DD HH:MM:SS] per-task: post-marker-commits-detected task_id=<id> round=<n>
#    marker=<sha> post_marker_shas=<csv> recovery=<mode>`
#
# 参照実装:
#   - 本関数は `docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/
#     test-post-marker-detect.sh` 内の参照実装と algorithm body を byte 同期させる責務がある
#     （stderr 行の `[smoke]` warn prefix のみ `pt_warn` で置換、NFR 2.1 メインログは
#     fixture と同一書式を保つ / 既存 #164 fixture と同方針）
#
# Requirements: 2.2, 2.3, 3.3, NFR 1.1, NFR 2.1
pt_handle_post_marker_commits() {
  local task_id="$1"
  local round="$2"
  local range_start="$3"
  local marker_sha="$4"
  local post_marker_list="$5"

  local mode="${POST_MARKER_RECOVERY_MODE:-fail-with-diagnostic}"
  case "$mode" in
    extend-range|fail-with-diagnostic) ;;
    *)
      pt_warn "post-marker-commits-detect: invalid POST_MARKER_RECOVERY_MODE='${mode}', falling back to fail-with-diagnostic"
      mode="fail-with-diagnostic"
      ;;
  esac

  local ts post_csv
  ts=$(date '+%F %T')
  post_csv=$(printf '%s' "$post_marker_list" | tr '\n' ',' | sed 's/,$//')

  # ─── Issue #356: docs-only auto-refresh の前段判定 ─────────────────────────
  # `POST_MARKER_RECOVERY_MODE=extend-range` 設定時は既存挙動を温存する（Req 3.3:
  # docs-only 判定はこの mode をオーバーライドしない）。それ以外（default
  # `fail-with-diagnostic` / fallback 経由の `fail-with-diagnostic`）でのみ、
  # `pt_classify_post_marker_paths` の判定結果が `docs-only` の場合に safety net を
  # 発火させず marker を HEAD まで auto-refresh する。
  #
  # 後方互換性（Req 3.2, NFR 1.1）:
  #   - `extend-range` mode: 既存どおり docs / code を問わず range 拡張（本ブロックを skip）
  #   - `fail-with-diagnostic` mode + 全パス allowlist 内: docs-only-auto-refresh で続行
  #   - `fail-with-diagnostic` mode + allowlist 外 1 件以上 / 混在 / classify 失敗:
  #     既存どおり fail-with-diagnostic（rc=5）に倒す（Req 2.2, 2.4）
  if [ "$mode" != "extend-range" ]; then
    local classify_out classify_rc=0 classify_verdict classify_unmatched=""
    classify_out=$(pt_classify_post_marker_paths "$marker_sha") || classify_rc=$?
    classify_verdict=$(printf '%s' "$classify_out" | sed -n '1p')
    classify_unmatched=$(printf '%s' "$classify_out" | sed -n '2p')

    if [ "$classify_rc" = "0" ] && [ "$classify_verdict" = "docs-only" ]; then
      local head_sha
      if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
        pt_warn "post-marker-commits-detect: git rev-parse HEAD failed during docs-only auto-refresh (range_start=${range_start})"
        # auto-refresh 失敗 → fail-with-diagnostic 相当に倒す
        echo "[${ts}] per-task: post-marker-commits-detected task_id=${task_id} round=${round} marker=${marker_sha} post_marker_shas=${post_csv} recovery=${mode}" >&2
        return 5
      fi
      # Req 1.2 / NFR 2.2: docs-only auto-refresh 発火を 1 行イベントログとして観測可能に
      echo "[${ts}] per-task: post-marker-commits-detected task_id=${task_id} round=${round} marker=${marker_sha} post_marker_shas=${post_csv} recovery=docs-only-auto-refresh" >&2
      printf '%s\t%s\n' "$range_start" "$head_sha"
      return 0
    fi

    # docs-only 不成立 → mixed / classify 失敗の旨を観測ログ（NFR 1.3）に残し、
    # 既存の mode dispatch（fail-with-diagnostic）に続行する。
    local _classify_reason="mixed"
    if [ "$classify_rc" = "2" ]; then
      _classify_reason="classify-git-error"
    elif [ -n "$classify_unmatched" ]; then
      _classify_reason="mixed(first_unmatched=${classify_unmatched})"
    fi
    pt_warn "post-marker-paths-classify: not docs-only task_id=${task_id} marker=${marker_sha} reason=${_classify_reason}"
  fi

  echo "[${ts}] per-task: post-marker-commits-detected task_id=${task_id} round=${round} marker=${marker_sha} post_marker_shas=${post_csv} recovery=${mode}" >&2

  if [ "$mode" = "extend-range" ]; then
    local head_sha
    if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
      pt_warn "post-marker-commits-detect: git rev-parse HEAD failed (range_start=${range_start})"
      return 5
    fi
    printf '%s\t%s\n' "$range_start" "$head_sha"
    return 0
  fi

  # fail-with-diagnostic: task 3 時点では rc=5 を返すのみで終わる設計とし、
  # `pt_mark_post_marker_commits_detected`（task 4 で追加）を呼ぶ責務は
  # `run_per_task_reviewer`（task 5）側に倒した。本関数は fixture 参照実装
  # （`test-post-marker-detect.sh` line 139〜172）と algorithm body を byte 同期させる
  # 責務を保持しているため、ここで mark 呼び出しを追加すると fixture との同期が崩れる。
  # `run_per_task_reviewer` 側は rc=5 を受領した際に必要な marker_sha / post_marker_list を
  # 自前で保持しているため、そちらから mark を呼べる（Issue #304 task 5 で接続）。
  return 5
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

# ─── pt_is_parent_checkbox_only_diff <task_id> <range_start> <range_end> ───
#
# 指定 diff range (`range_start..range_end`) の変更内容が、`tasks.md` 1 ファイルのみで構成され、
# かつその変更内容が指定 task_id の checkbox flip `- [ ]` → `- [x]` のみであることを判定する
# （Issue #270 / Req 3.1, 3.4, 3.5）。
#
# 戻り値:
#   0 = 条件成立（Reviewer スキップ可能）
#   1 = 条件不成立（tasks.md 以外のファイル変更を含む / tasks.md 内に他編集を含む / fail-safe）
#
# 判定手順:
#   1. `git diff --name-only <range>` で変更ファイル集合を取得し、`tasks.md` 1 件のみであることを確認
#      - 0 件 / 2 件以上 → 不成立
#      - 1 件だがファイル名が tasks.md でない → 不成立
#   2. `git diff <range> -- <tasks_md>` の hunk 内行を走査し、以下のみで構成されることを確認:
#      - 削除行 `- ` で始まる中身が `- [ ] <task_id>(\.)? ` で始まる行のみ
#      - 追加行 `+ ` で始まる中身が `- [x] <task_id>(\.)? ` で始まる行のみ
#      - diff header / hunk header / context 行は無視
#   3. 削除行 1 件 + 追加行 1 件で完全に対応する（task_id checkbox flip 1 ペアのみ）こと
#      - 他 task_id の checkbox flip / `_Requirements:_` 編集 / 新規追加 / 削除のみ等が
#        混入すれば不成立
#
# Req 3.2: tasks.md 以外のファイルが 1 件でも含まれれば不成立
# Req 3.5: tasks.md 内の変更が他編集を含めば不成立
# NFR 1.3: 異常系（git diff 失敗等）は不成立（保守的に倒す）
#
# Requirements (Issue #270): 3.1, 3.2, 3.4, 3.5, NFR 1.3
pt_is_parent_checkbox_only_diff() {
  local task_id="$1"
  local range_start="$2"
  local range_end="$3"

  if [ -z "$task_id" ] || [ -z "$range_start" ] || [ -z "$range_end" ]; then
    return 1
  fi

  # spec ディレクトリ配下の tasks.md パスを canonical に決める。git diff --name-only は
  # repo root からの相対パスで返るため、SPEC_DIR_REL/tasks.md と比較する。
  local tasks_md_rel="${SPEC_DIR_REL:-}/tasks.md"
  if [ -z "${SPEC_DIR_REL:-}" ]; then
    # SPEC_DIR_REL が未設定 → fail-safe で不成立
    return 1
  fi

  # ── (1) 変更ファイル集合の取得と検証 ──
  local changed_files
  if ! changed_files=$(git diff --name-only "${range_start}..${range_end}" 2>/dev/null); then
    return 1
  fi

  # 空 diff → 不成立（checkbox flip すら無い）
  if [ -z "$changed_files" ]; then
    return 1
  fi

  # 変更ファイルが tasks.md ちょうど 1 件のみであることを検証
  local changed_count
  changed_count=$(printf '%s\n' "$changed_files" | wc -l | tr -d '[:space:]')
  if [ "$changed_count" != "1" ]; then
    return 1
  fi
  if [ "$changed_files" != "$tasks_md_rel" ]; then
    return 1
  fi

  # ── (2) tasks.md 内の hunk 内容を走査 ──
  local diff_body
  if ! diff_body=$(git diff "${range_start}..${range_end}" -- "$tasks_md_rel" 2>/dev/null); then
    return 1
  fi
  if [ -z "$diff_body" ]; then
    return 1
  fi

  # task_id を正規表現リテラルとして安全にエスケープ
  local task_id_re
  # shellcheck disable=SC2016
  task_id_re=$(printf '%s' "$task_id" | sed -E 's/[][\\.*^$()+?{|/]/\\&/g')

  # hunk 行を分類:
  #   - 削除行: `-` で始まるが `--- a/path` の diff file header ではない行
  #   - 追加行: `+` で始まるが `+++ b/path` の diff file header ではない行
  #   - その他（context / hunk header `@@` / `diff --git` / `index ` 行）: 無視
  # 期待: 削除行 1 件 + 追加行 1 件のペアのみで、それぞれが当該 task_id の checkbox flip。
  #
  # 注意: 削除行の中身が `- [ ]` で始まる markdown list の場合、diff 上は `-- [ ]` のように
  # 行頭が `--` 2 文字になる。よって `^-[^-]` で diff header を除外する素朴な regex は
  # markdown 削除行を取りこぼす。`^--- ` を file header として明示除外する形に修正する。
  local minus_count plus_count minus_match plus_match
  # `- [ ] <task_id>(\.)? ` で始まる削除行 = `^-- \[ \] <task_id>(\.)? `
  minus_match=$(printf '%s\n' "$diff_body" | grep -cE "^-- \[ \] ${task_id_re}\.? " 2>/dev/null || true)
  # `- [x] <task_id>(\.)? ` で始まる追加行 = `^\+- \[x\] <task_id>(\.)? `
  plus_match=$(printf '%s\n' "$diff_body" | grep -cE "^\+- \[x\] ${task_id_re}\.? " 2>/dev/null || true)

  # 全削除行 / 追加行の総数: 行頭 `-` / `+` を持ち、かつ file header (`--- ` / `+++ `) ではない行。
  # diff header / hunk header / context 行は除外する。
  minus_count=$(printf '%s\n' "$diff_body" | grep -E '^-' | grep -cvE '^--- ' 2>/dev/null || true)
  plus_count=$(printf '%s\n' "$diff_body" | grep -E '^\+' | grep -cvE '^\+\+\+ ' 2>/dev/null || true)

  # 厳密一致: 削除行 1 件 + 追加行 1 件で、それぞれが当該 task_id の checkbox flip ペア
  if [ "$minus_count" = "1" ] && [ "$plus_count" = "1" ] \
     && [ "$minus_match" = "1" ] && [ "$plus_match" = "1" ]; then
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

# ─── build_per_task_implementer_prompt <task_id> [<redo_mode>] ───
#
# per-task Implementer 用の prompt を heredoc で組み立てて stdout に出力。
# 既存 `build_dev_prompt_a` の形式を踏襲しつつ、以下を明示する:
#
#   - 本起動で実装する task は <task_id> 1 件のみ（他の未完了 task に着手しない / Req 2.2）
#   - `tasks.md` の進捗マーカー更新 `- [ ]` → `- [x]` と `docs(tasks): mark <id> as done`
#     commit 規約（既存 #67 / #112 規約を流用 / Req 2.4, 2.5）
#   - `impl-notes.md` の `## Implementation Notes` 配下に `### Task <id>` を追記し、
#     先行 task の learnings は **改変・削除・並び替え禁止**（Req 4.1, 4.2, 4.4）
#   - 既存 learnings の inline 埋め込み（Req 4.3）
#   - PR 作成禁止 / spec 書き換え禁止（既存 Stage A 制約と同等）
#
# redo_mode 引数（Issue #305 で追加 / 既定 "initial"）:
#   - "initial"        : 初回 Implementer 起動。Findings / Fix Plan 注入ブロックを追加しない
#                        （既存 1 引数呼び出しと **完全に同一**の prompt を生成 / NFR 1.1）
#   - "after-round1"   : Reviewer round=1 reject 後の redo。`## 直前 round の Reviewer Findings`
#                        ブロックと `## Finding Closure Matrix の記録義務` ブロックを注入
#   - "after-debugger" : Debugger Gate 経由 round=3 の redo。上記 2 ブロックに加えて
#                        `## Debugger の Fix Plan` ブロックを注入 + Matrix 5 列目指示を追記
#   - 未知の値は安全側に "initial" へ fallback
#
# Requirements: 2.2, 2.3, 2.4, 2.5, 4.1, 4.2, 4.3, 4.4,
#               1.1, 1.2, 1.3, 1.4, 1.5, 4.3 (Issue #305),
#               NFR 1.1, NFR 3.1, NFR 4.1, NFR 4.2 (Issue #305)
build_per_task_implementer_prompt() {
  local task_id="$1"
  local redo_mode="${2:-initial}"
  # 安全側 fallback: 未知の値は initial 扱い
  case "$redo_mode" in
    initial|after-round1|after-debugger) ;;
    *) redo_mode=initial ;;
  esac

  local learnings
  learnings=$(pt_extract_learnings "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md")
  local learnings_block
  if [ -n "$learnings" ]; then
    learnings_block=$(cat <<EOF
## これまで完了した task の learnings（impl-notes.md より）

以下は先行 task の Implementer が記録した learning（採用方針 / 重要な判断 / 残存課題）です。
**本 task の実装で、命名規約・採用ライブラリ・運用判断との一貫性を維持するために必ず参照**
してください。各 \`### Task <id>\` セクションの本文を **改変・削除・並び替えしないこと**。

\`\`\`markdown
${learnings}
\`\`\`
EOF
)
  else
    learnings_block=$(cat <<'EOF'
## これまで完了した task の learnings（impl-notes.md より）

（先行 task の learnings はまだ存在しません。本 task が最初の per-task 実装です）
EOF
)
  fi

  # ─── redo_mode != initial 時のみ Findings / Fix Plan / Matrix 規約ブロックを構築 ───
  #
  # 注入ブロックは redo 経路（after-round1 / after-debugger）でのみ prompt 本文に追加され、
  # redo_mode=initial では空文字のまま heredoc に埋まる（= 既存 1 引数呼び出しと完全等価 / NFR 1.1）。
  #
  # NFR 3.1: 注入実施事実を grep 可能な 1 行で watcher ログに出力する。round 番号は本関数の引数
  # に含めず redo_mode に紐付ける形で省略する（after-round1 ≒ round=2 redo /
  # after-debugger ≒ round=3 redo の対応関係は run_per_task_loop 側で構造的に保証される）。
  # design.md 行 528 は `redo_mode=<mode> inject=<comma-sep-files> round=<N>` を例示するが、本
  # build 関数は round を引数で受け取らない設計（呼び出し側の wrapper で stage_label に
  # redo_mode を埋め込む / 後方互換性の単純化）のため round はログから省略する。
  local findings_block_section=""
  local debugger_block_section=""
  local closure_matrix_section=""
  # ─── #313: Context Map 注入ブロック（Req 3.1 / 3.5） ───
  # `cm_enabled` 通過時のみ context-map.md の内容を inline embed する markdown ブロックを
  # 生成。未設定 / off のときは空文字列のまま heredoc に展開され、prompt は本機能導入前と
  # byte 一致を保つ（NFR 1.1）。
  local context_map_block_section=""
  if cm_enabled; then
    context_map_block_section=$(cm_render_prompt_section "$task_id")
  fi
  if [ "$redo_mode" != "initial" ]; then
    local _inject_files=""
    # ── Reviewer Findings 注入（after-round1 / after-debugger 共通） ──
    local _review_notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
    local _findings_block
    if _findings_block=$(pt_extract_findings_block "$_review_notes_path"); then
      findings_block_section=$(cat <<EOF

## 直前 round の Reviewer Findings（review-notes.md より）

per-task Reviewer が直前 round で reject 判定を返した際の Findings セクションを以下に
inline で運びます。各 Finding の **Target / Category / Detail / Required Action** を確認し、
本起動で **必ず対応**してください（同じ指摘が次 round で再度 reject されないように、
fix commit + 追加テスト + 検証結果を Finding Closure Matrix に記録します。後述）。

\`\`\`markdown
${_findings_block}
\`\`\`
EOF
)
      _inject_files="review-notes"
    else
      findings_block_section=$(cat <<'EOF'

## 直前 round の Reviewer Findings（review-notes.md より）

(review-notes.md が見つかりません / 抽出失敗のため Findings の inline 注入を諦めました。
spec ディレクトリ配下の review-notes.md を直接読み、直前 round の Findings を参照してください)
EOF
)
      pt_log "task=$task_id redo_mode=$redo_mode inject=skipped reason=findings-extract-failed" >> "$LOG"
    fi

    # ── Debugger Fix Plan 注入（after-debugger のみ） ──
    if [ "$redo_mode" = "after-debugger" ]; then
      local _debugger_notes_path="$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md"
      local _debugger_block
      if _debugger_block=$(pt_extract_debugger_section "$_debugger_notes_path" "$task_id"); then
        debugger_block_section=$(cat <<EOF

## Debugger の Fix Plan（debugger-notes.md より）

Debugger サブエージェントが当該 task について生成した Fix Plan を以下に inline で運びます。
\`### 根本原因\` / \`### 修正手順\` / \`### 検証方法\` / \`### 残存リスク\` を読み、本起動で
修正手順を順に実施し、検証方法で挙動を確認してください。Debugger は **コード修正権限を
持たない**ため、Fix Plan の実装は本起動の Developer が担います。

\`\`\`markdown
${_debugger_block}
\`\`\`
EOF
)
        if [ -n "$_inject_files" ]; then
          _inject_files="${_inject_files},debugger-notes"
        else
          _inject_files="debugger-notes"
        fi
      else
        debugger_block_section=$(cat <<EOF

## Debugger の Fix Plan（debugger-notes.md より）

(debugger-notes.md または \`## Task ${task_id}\` セクションが見つかりません / 抽出失敗
のため Fix Plan の inline 注入を諦めました。spec ディレクトリ配下の debugger-notes.md を
直接読み、当該 task の Fix Plan を参照してください)
EOF
)
        pt_log "task=$task_id redo_mode=$redo_mode inject=skipped reason=debugger-section-not-found" >> "$LOG"
      fi
    fi

    # ── 注入実施を 1 行で記録（NFR 3.1） ──
    if [ -n "$_inject_files" ]; then
      pt_log "task=$task_id redo_mode=$redo_mode inject=$_inject_files" >> "$LOG"
    fi

    # ── Finding Closure Matrix の記録義務（redo 経路共通） ──
    #
    # 詳細規約は developer.md の「per-task retry 時の Finding Closure Matrix 記録義務」節
    # （Issue #305 の task 7 で追加予定）を canonical source として参照する。本 prompt では
    # 規約への参照と最小限の指示を 1〜2 段落で運ぶ。
    if [ "$redo_mode" = "after-debugger" ]; then
      closure_matrix_section=$(cat <<EOF

## Finding Closure Matrix の記録義務（per-task retry 経路）

本起動は per-task retry 経路（redo_mode=${redo_mode}）です。直前 round の Reviewer Findings
（および Debugger Fix Plan）に対する対応状況を、**Finding Closure Matrix** として
\`${SPEC_DIR_REL}/impl-notes.md\` の \`### Task ${task_id}\` セクション末尾に追記してください。
規約詳細は \`.claude/agents/developer.md\` の「per-task retry 時の Finding Closure Matrix
記録義務」節を canonical source として参照すること。

Matrix の各行には直前 round の Reviewer Finding ごとに **Finding / Target / Fix Commit /
Added/Updated Test / Verification** の 4 項目（5 列）を対応付け、本起動は Debugger Gate
経由 round=3 のため **5 列目「Fix Plan Step」**（対応する Debugger Fix Plan の修正手順番号）も
**必ず追記**してください。fix commit が存在しない Finding には「未対応」「対応不可（理由）」
「次 round へ持ち越し」のいずれかを Fix Commit 列で明示します。先行 task の Matrix および
先行 round の Matrix 既存行は **改変・削除・並び替え禁止**（新規 round の Matrix は新規
見出しで追加）。
EOF
)
    else
      closure_matrix_section=$(cat <<EOF

## Finding Closure Matrix の記録義務（per-task retry 経路）

本起動は per-task retry 経路（redo_mode=${redo_mode}）です。直前 round の Reviewer Findings
に対する対応状況を、**Finding Closure Matrix** として
\`${SPEC_DIR_REL}/impl-notes.md\` の \`### Task ${task_id}\` セクション末尾に追記してください。
規約詳細は \`.claude/agents/developer.md\` の「per-task retry 時の Finding Closure Matrix
記録義務」節を canonical source として参照すること。

Matrix の各行には直前 round の Reviewer Finding ごとに **Finding / Target / Fix Commit /
Added/Updated Test / Verification** の 4 項目（4 列）を対応付け、fix commit が存在しない
Finding には「未対応」「対応不可（理由）」「次 round へ持ち越し」のいずれかを Fix Commit
列で明示します。先行 task の Matrix および先行 round の Matrix 既存行は **改変・削除・
並び替え禁止**（新規 round の Matrix は新規見出しで追加）。
EOF
)
    fi
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **per-task ループ**（PER_TASK_LOOP_ENABLED=true）の下で、\`tasks.md\` の
**1 件の task のみ** を fresh context で実装するために起動されました。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 本起動で実装する task

- **対象 task ID**: \`${task_id}\`
- 本起動では \`tasks.md\` の **${task_id} 1 件のみ** を実装します。他の未完了 task には
  一切着手しないこと（次 task は別の fresh Implementer 起動で消化されます）

## 進め方

1. developer サブエージェントを起動し、対象 task \`${task_id}\` を実装＋テスト＋commit する
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は人間レビュー済みで **書き換え禁止**（矛盾は impl-notes.md の
     「確認事項」に記載するに留める）
   - tasks.md の対象 task の \`_Requirements:_\` / \`_Boundary:_\` に従う
   - 規約は CLAUDE.md に従う

2. **進捗マーカー更新**（既存 #67 / #112 規約 + Issue #164「1 commit = 1 task ID」厳格化）:
   - 対象 task の \`- [ ] ${task_id}\` 行を \`- [x] ${task_id}\` に書き換える
   - 子タスク（例: ${task_id}.1）を完了した場合、親 task（${task_id} の親、例: ${task_id%.*}）
     配下の全子タスクが \`- [x]\` になったタイミングで親も \`- [x]\` に昇格する
   - 進捗マーカー更新は **専用 commit**: \`docs(tasks): mark <id> as done\`
     - 当該 commit には \`tasks.md\` 以外のファイルを含めない
   - **【重要 / Issue #164】1 つの marker commit には 1 つの task ID のみを含めること**:
     - 1 つの \`docs(tasks): mark <id> as done\` commit には **必ず 1 つの task ID のみ**
       を含めること（per-task Reviewer の diff range 解決が task ID 単位で行われるため）
     - **親 task の完了昇格も別 commit に分割**する。例: 子 \`1.1\` 完了で親 \`1\` も
       全完了になる場合、まず \`docs(tasks): mark 1.1 as done\` を 1 commit で作成し、
       続けて \`docs(tasks): mark 1 as done\` を **別 commit** として続けて作成する
     - **連記禁止例（NG）**: \`docs(tasks): mark 1 / 1.1 as done\` /
       \`docs(tasks): mark 1, 1.1 as done\` のように複数 ID を 1 commit にまとめる
       subject 表記は禁止
     - 連記 marker commit を作成すると、per-task Reviewer の diff range 解決が単記 ID で
       一致しなくなり \`diff-range-resolve-failed\` を起こす可能性がある（watcher 側で
       fallback 解決は試行するが、canonical は単記分割のみ）
   - 書き換え禁止領域: タスク本文 / \`_Requirements:_\` / \`_Boundary:_\` / \`_Depends:_\` /
     タスク順序 / 親タスクのインデント / deferrable 印 \`- [ ]*\`

3. **learning 追記**（per-task ループの中核 / Req 4.1, 4.2, 4.4）:
   - \`${SPEC_DIR_REL}/impl-notes.md\` の \`## Implementation Notes\` セクション配下に
     \`### Task ${task_id}\` 見出しを **追加**（既存セクションが無ければ作成）し、本 task の
     learning を簡潔に記録する:
     - 採用方針（1 行）
     - 重要な判断（1〜3 行）
     - 残存課題（次 task に影響する事項。なければ「なし」）
   - **先行 task の \`### Task <id>\` 見出し（既存の learnings）は改変・削除・並び替えしない**
   - \`## Implementation Notes\` セクション **外** の既存記述（補足ノート / 確認事項など）
     には触れない

${learnings_block}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、impl-notes.md の「確認事項」セクションに列挙すること
- **PR は作成しないこと**（Reviewer / PjM は別 stage で起動されます）
- **本 task 以外の未完了 task には一切着手しないこと**
- requirements.md / design.md / tasks.md 本文の書き換えは禁止（tasks.md の進捗マーカー
  \`- [ ]\` → \`- [x]\` のみ例外）

## 既存 commit の温存

本 worktree は既存 commit を温存した状態でチェックアウトされています。

- 作業前に \`git log --oneline ${BASE_BRANCH}..HEAD\` で既存 commit を確認すること
- \`git reset\` / \`git rebase\` / branch の切り替えは **禁止**
- 既存 commit と矛盾する変更が必要な場合は、既存 commit を打ち消す追加 commit を積むか、
  impl-notes.md の「確認事項」に矛盾内容を記載して人間判断を仰ぐ
${findings_block_section}${debugger_block_section}${closure_matrix_section}${context_map_block_section}
EOF
}

# ─── build_per_task_reviewer_prompt <task_id> <range_start_sha> <range_end_sha> <round> <prev_result> [<extended>] ───
#
# per-task Reviewer 用の prompt を heredoc で組み立てて stdout に出力。
# 既存 `build_reviewer_prompt` の形式を踏襲しつつ、以下を明示する:
#
#   - 判定対象 diff range は `<range_start>..<range_end>` のみ（HEAD 全体ではない / Req 3.2）
#   - 判定 AC は当該 task の `_Requirements:_` 列挙分のみ（全 AC verify は Stage B / Req 3.3）
#   - `_Boundary:_` 違反は depth に関わらず常に reject 対象
#   - 既存 reviewer.md の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）と
#     RESULT 行 / review-notes.md 出力契約を流用
#   - 第 6 引数 `extended`（"true"/"false"、省略時 "false"）: watcher が marker 後の
#     post-marker commit を検出して HEAD ベースに range を拡張したか否か（Issue #304 Req 3.3）
#
# Requirements: 3.1, 3.2, 3.3
build_per_task_reviewer_prompt() {
  local task_id="$1"
  local range_start="$2"
  local range_end="$3"
  local round="$4"
  local prev_result="$5"
  # Issue #304 Req 3.3: 第 6 引数 `extended` は省略時 "false"（既存呼び出し互換）。
  # watcher が post-marker commit を検出して range を HEAD まで拡張した場合のみ "true" が
  # 渡される。値は prompt 本文の `range_extended:` 行と extended-range 説明文に反映される。
  local extended="${6:-false}"

  # Issue #304 Req 3.3: extended=true 時の追加説明 block（normal 経路では空文字列）。
  # heredoc 中で条件分岐すると bash 構文が崩れるため、変数で差し込む方式を採用。
  # 変数の中身は外側の `cat <<EOF` で変数展開された後の最終 prompt にそのまま埋め込まれる。
  # quoted heredoc（'EXTENDED_EOF'）を使うことで $ / ` / \ が一切解釈されず、markdown の
  # バッククォートも literal で保持される（外側 heredoc の二重 escape 不要）。
  # ─── #313: Context Map 注入ブロック（Req 3.2 / 3.5） ───
  # `cm_enabled` 通過時のみ context-map.md の内容を inline embed する markdown ブロックを
  # 生成。未設定 / off のときは空文字列のまま heredoc に展開され、prompt は本機能導入前と
  # byte 一致を保つ（NFR 1.1）。
  local context_map_block_section=""
  if cm_enabled; then
    context_map_block_section=$(cm_render_prompt_section "$task_id")
  fi

  local extended_explanation=""
  if [ "$extended" = "true" ]; then
    extended_explanation=$(cat <<'EXTENDED_EOF'

### Extended range（watcher による range 拡張通知）

watcher が当該 task の `docs(tasks): mark` marker commit より後ろに **未レビューの
post-marker commit** を検出したため、env `POST_MARKER_RECOVERY_MODE=extend-range` の
recovery 経路により range_end を marker SHA ではなく **HEAD まで拡張** しています
（Issue #304 Req 3.3）。

上記 `range_end_sha` は marker commit ではなく **HEAD の SHA** であり、上記
`range_start_sha..range_end_sha` の範囲には marker 後に積まれた修正 commit も含まれます。
extended 状態でも本 Reviewer の判定基準は変わりません（range 内 commit のみを判定根拠と
してください）。
EXTENDED_EOF
)
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **per-task ループ**（PER_TASK_LOOP_ENABLED=true）の下で、直前の Implementer が
完了した **1 件の task の commit 範囲のみ** を独立 context でレビューするために起動されました。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- ROUND        : ${round}
- PREV_RESULT  : ${prev_result}

## 判定対象の task / diff range

- **対象 task ID**: \`${task_id}\`
- **range_start_sha**: \`${range_start}\` （= 直前の \`docs(tasks): mark\` commit、または初回時は \`${BASE_BRANCH}\` の SHA）
- **range_end_sha**:   \`${range_end}\`   （= 当該 task の \`docs(tasks): mark ${task_id} as done\` commit、ただし extended=true の場合は HEAD）

reviewer は **本 range のみ** を判定対象としてください。HEAD 全体は対象外（全体観点は
最終 Stage B Reviewer が別途担当します）。

> **Warning（Issue #304 Req 3.2）**: 上記 \`range_start_sha..range_end_sha\` の **外側** に
> ある commit（HEAD が range_end より後ろにある場合等）は本 Reviewer の **判定対象外** です。
> range 外 commit の内容を理由に approve / reject を出してはいけません。HEAD 全体観点は
> 最終 Stage B Reviewer が担当します。本 Reviewer は \`range_start_sha..range_end_sha\` 内
> commit のみを判定根拠としてください。

## 判定対象 SHA range（machine-parseable）

以下は watcher → Reviewer 間の range 引き継ぎを機械パース可能な形で再掲した block です
（Issue #304 Req 3.1）。Reviewer は本 block の値を判定対象 SHA range の正本として扱って
ください。

\`\`\`
range_start_sha: ${range_start}
range_end_sha:   ${range_end}
range_extended:  ${extended}
\`\`\`
${extended_explanation}

## 必読ファイル

reviewer サブエージェントは着手前に以下を必ず Read してください:

- \`CLAUDE.md\`（特に「テスト規約」と「禁止事項」）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（特に対象 task \`${task_id}\` の \`_Requirements:_\` / \`_Boundary:_\`）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer の補足。\`### Task ${task_id}\` の learning を含む）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）

## 差分の取得（reviewer が Bash で実行）

reviewer は **必ず自分で** Bash で以下を実行し、本 task の commit 範囲だけを取得してください:

1. 全体把握（変更ファイル一覧と統計）:
   \`\`\`bash
   git diff --stat ${range_start}..${range_end}
   git log --oneline ${range_start}..${range_end}
   \`\`\`
2. ファイル単位の詳細差分（必要に応じて変更ファイルごとに実行）:
   \`\`\`bash
   git diff ${range_start}..${range_end} -- <path>
   \`\`\`

## 判定基準（per-task ループの判定 depth 制約）

reviewer.md の **3 カテゴリ**（AC 未カバー / missing test / boundary 逸脱）のみで判定します。
per-task ループでは判定 depth が以下に絞り込まれます:

- **判定対象 AC**: 当該 task \`${task_id}\` の \`_Requirements:_\` で列挙された numeric ID **のみ**
  - それ以外の AC が当該 diff で未カバーであっても reject 理由にしないこと
  - 全 AC verify は最終 Stage B Reviewer が HEAD 全体で実施するため、本 Reviewer では
    範囲外 AC を理由とした reject を出さない
- **\`_Boundary:_\` 違反**: depth に関わらず **常に reject 対象**（task 単位境界の逸脱検出が
  本ループの主目的）

## 進め方

reviewer サブエージェントを起動し、以下を判定して \`${SPEC_DIR_REL}/review-notes.md\` に
書き出してください（reviewer.md の出力契約に従う）。

- 最終行は必ず \`RESULT: approve\` または \`RESULT: reject\` で終わること（lowercase 完全一致）
- 装飾（バッククォート / bullet / blockquote / 行末プローズ）禁止

## 制約
- requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと
- \`git add\` / \`git commit\` / \`git push\` / \`gh\` を実行しないこと
- スタイル / 命名 / lint / フォーマット観点での reject はしないこと
${context_map_block_section}
EOF
}
