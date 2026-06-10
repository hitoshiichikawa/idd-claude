#!/usr/bin/env bash
# shellcheck shell=bash
# context-map.sh — per-task agent 向け context metadata 生成モジュール
#
# 用途:
#   per-task Implementer ループ（PER_TASK_LOOP_ENABLED=true）の各 task 起動直前に、
#   watcher が tasks.md の `_Boundary:_` と design.md の File Structure Plan から
#   短い構造化 metadata `context-map.md` を **決定論的に**生成し、後段の per-task
#   Developer / per-task Reviewer prompt に inline embed することで広域 grep / glob を
#   抑止する仕組み（Issue #313）。LLM を呼ばず純粋な bash パイプラインで処理する。
#
#   提供関数:
#     - cm_log / cm_warn / cm_error     : `context-map:` prefix logger
#     - cm_enabled                       : PER_TASK_LOOP_ENABLED が "true" 厳密一致のとき
#                                          のみ rc=0（per-task ループの標準機能）
#     - cm_resolve_boundary              : tasks.md の `_Boundary:_` 抽出
#     - cm_resolve_candidate_files       : design.md File Structure Plan の解析
#     - cm_resolve_candidate_tests       : 候補テストファイル抽出
#     - cm_resolve_candidate_docs        : 候補 docs ファイル抽出
#     - cm_compose                       : context-map.md 本文生成（stdout）
#     - cm_truncate_if_oversize          : 200 行 / 8 KB 上限超過時の末尾 truncate
#     - cm_generate                      : entry point（全工程を取りまとめて書き出し）
#     - cm_render_prompt_section         : prompt 注入用 markdown 文字列を stdout
#
# 分割の経緯:
#   既存 modules 切り出しパターン（#181 Part 3）に準拠し、stage-a-verify.sh 等と同形式で
#   独立モジュールとして配置する。本体 issue-watcher.sh からは REQUIRED_MODULES 経由で
#   source され、call site は (1) run_per_task_loop 内 task 開始前、(2) per-task
#   Implementer / Reviewer prompt builder の heredoc 末尾の 2 点のみ。
#
# 配置先:
#   $HOME/bin/modules/context-map.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $SPEC_DIR_REL 等）は本体冒頭の Config ブロックで
#     定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 環境変数（読み取り）: PER_TASK_LOOP_ENABLED
#   - 外部 CLI: grep / awk / sed / wc（POSIX 標準）
#
# セットアップ参照先:
#   - 要件: docs/specs/313-feat-watcher-context-map-per-task-agent/requirements.md
#   - 設計: docs/specs/313-feat-watcher-context-map-per-task-agent/design.md
#   - タスク: docs/specs/313-feat-watcher-context-map-per-task-agent/tasks.md

# context-map 専用ロガー（既存 sav_log / pt_log と同形式 / 行頭 prefix 統一）。
# `grep '\[.*\] context-map:'` で全件抽出可能（NFR 4.1 系統 / Issue #119 規約と整合）。
cm_log() {
  echo "[$(date '+%F %T')] [${REPO:-unknown}] context-map: $*"
}
cm_warn() {
  echo "[$(date '+%F %T')] [${REPO:-unknown}] context-map: WARN: $*" >&2
}
cm_error() {
  echo "[$(date '+%F %T')] [${REPO:-unknown}] context-map: ERROR: $*" >&2
}

# ─── cm_enabled ───
#
# context map 機能が当該実行で active かを判定する gate（Req 1.1, 1.4, 3.5, NFR 1.1）。
# context map は per-task ループの標準機能であり、PER_TASK_LOOP_ENABLED が lowercase の
# `true` 厳密一致のときのみ rc=0、それ以外（未設定 / 空 / `True` / `1` / `yes` / 任意の値）は
# rc=1。当初の opt-in gate だった CONTEXT_MAP_ENABLED は削除済み（#313 標準化）。
# 副作用なし。stdout / stderr へも出力しない（純粋判定関数）。
cm_enabled() {
  [ "${PER_TASK_LOOP_ENABLED:-}" = "true" ] || return 1
  return 0
}

# ─── cm_resolve_boundary <tasks_md_path> <task_id> ───
#
# tasks.md から当該 task の `_Boundary:_` 行を抽出し、カンマ区切りコンポーネント名を stdout
# に 1 行で返す（Req 2.3, 2.9）。task 行の形式は checkbox enforcement 規約
# （`^- \[[ x]\]\*? <id>(\.<id>)*\.? `）に準拠。次の task 行 / `## ` 見出し / EOF の手前までを
# 走査範囲とし、最初に出現した `_Boundary:_` を採用する（決定論）。
#
# 入力: $1 = tasks.md の絶対パス, $2 = task ID (例: "1" / "2.1")
# stdout: カンマ区切りコンポーネント名（例: "ContextMap, Watcher"）。空なら何も出さない
# 戻り値: 0 = 解決成功（非空）/ 1 = 解決不能（tasks.md 不在 / task 行不在 / Boundary 不在 or 空）
cm_resolve_boundary() {
  local tasks_path="$1"
  local task_id="$2"
  [ -f "$tasks_path" ] || return 1
  [ -n "$task_id" ] || return 1

  local result
  result=$(awk -v tid="$task_id" '
    BEGIN {
      in_task = 0
      found = ""
    }
    {
      raw = $0
      # 任意の task 行検出（先頭 task と次の task の境界判定用）。
      # checkbox enforcement 規約: ^- \[[ x]\]\*? <id>(\.<id>)*\.? <空白>
      if (match(raw, /^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.?[[:space:]]/)) {
        # 当該 task 行か判定するため、checkbox と先頭インデント装飾を除いた残りから
        # numeric ID 部分を取り出す。
        rest = raw
        sub(/^- \[[ x]\]\*?[[:space:]]+/, "", rest)
        # rest は "<id>. <name>..." または "<id> <name>..." の形。
        # numeric ID を末尾の "." or 空白で区切って取り出す。
        id = rest
        sub(/[.[:space:]].*$/, "", id)
        if (id == tid) {
          in_task = 1
        } else if (in_task) {
          # 次の task に入ったので走査終了。
          exit
        }
        next
      }
      # ## で始まる新規 section 見出しに当たったら走査終了（task block 抜け）。
      if (in_task && raw ~ /^## /) {
        exit
      }
      if (in_task && found == "") {
        # `_Boundary: ...` または `- _Boundary: ...` 行を検出。
        # 行頭の "- " / 空白を除いてから match する。
        line = raw
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        sub(/^[[:space:]]+/, "", line)
        if (match(line, /^_Boundary:[[:space:]]*/)) {
          val = substr(line, RLENGTH + 1)
          # 末尾の `_` を除去（`_Boundary: foo, bar_` の italic マーカー）。
          sub(/_[[:space:]]*$/, "", val)
          sub(/[[:space:]]+$/, "", val)
          found = val
        }
      }
    }
    END {
      if (found != "") print found
    }
  ' "$tasks_path")

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# ─── cm_resolve_candidate_files <design_md_path> <boundary_csv> ───
#
# design.md の File Structure Plan セクション内の fenced code block（ディレクトリ構造図）
# から、boundary_csv に列挙されたコンポーネント名を **substring match** で含む行を抽出し、
# 各行から「それらしいファイル / ディレクトリパス」を 1 行 1 件で stdout に出す（Req 2.4, 2.9）。
#
# 抽出方針（決定論的 + ヒューリスティック）:
#   1. design.md 内の fenced code block（```...```）の中身を全て対象にする。
#   2. 各行から ASCII 装飾文字（├ │ └ ─ など / トレイリングコメント `#...`）を除去する。
#   3. boundary に列挙された各 token のいずれかが substring 一致したら採用候補とする。
#   4. 採用候補のうち、`/` を含むパス / `.` を含むファイル名らしき token を 1 件抽出する。
#
# File Structure Plan が「TBD」/ プレースホルダしか含まない / 一致なしの場合は空 stdout で rc=0。
#
# 入力: $1 = design.md の絶対パス, $2 = カンマ区切り boundary 文字列
# stdout: 改行区切りの候補ファイルパス（重複除去済み / 入力順を保つ）
# 戻り値: 0（一致なしでも 0。呼び出し側で「解決不能」分岐は cm_compose が担当）
cm_resolve_candidate_files() {
  local design_path="$1"
  local boundary_csv="$2"
  [ -f "$design_path" ] || return 0
  [ -n "$boundary_csv" ] || return 0

  awk -v boundary="$boundary_csv" '
    BEGIN {
      in_fence = 0
      # boundary をカンマ区切りで分解し前後空白を除いて配列化。
      n = split(boundary, raw_arr, ",")
      bn = 0
      for (i = 1; i <= n; i++) {
        t = raw_arr[i]
        sub(/^[[:space:]]+/, "", t)
        sub(/[[:space:]]+$/, "", t)
        if (t != "") {
          bn++
          BARR[bn] = t
        }
      }
    }
    {
      raw = $0
      if (raw ~ /^[[:space:]]*```/) {
        in_fence = (in_fence == 0) ? 1 : 0
        next
      }
      if (!in_fence) { next }

      # トレイリング `#...` コメントを除去し、行末空白も除去。
      line = raw
      sub(/[[:space:]]*#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") { next }

      # ツリー描画文字を空白へ変換。
      gsub(/[├│└─]/, " ", line)
      sub(/^[[:space:]]+/, "", line)
      if (line == "") { next }

      # boundary token のいずれかが substring 一致するか確認。
      hit = 0
      for (i = 1; i <= bn; i++) {
        if (index(line, BARR[i]) > 0) { hit = 1; break }
      }
      if (!hit) { next }

      # 行から token を 1 個取り出す: スペースで分割し、最初の token を採用。
      # ファイル / ディレクトリらしさ判定: "/" を含む or "." を含む（ファイル名）。
      split(line, parts, " ")
      cand = parts[1]
      if (cand == "") { next }

      # 重複除去（入力順を保つ）。
      if (!(cand in seen)) {
        seen[cand] = 1
        print cand
      }
    }
  ' "$design_path"
}

# ─── cm_resolve_candidate_tests <design_md_path> <boundary_csv> ───
#
# design.md の File Structure Plan から `test` / `spec` / `test-fixtures` を含むパス、
# および boundary 一致行のうち test らしき候補を抽出（Req 2.5）。
# cm_resolve_candidate_files と同じ抽出方針を流用し、test 系 keyword で post-filter する。
#
# 入力: $1 = design.md の絶対パス, $2 = カンマ区切り boundary 文字列
# stdout: 改行区切りの候補テストファイル / ディレクトリパス
# 戻り値: 0
cm_resolve_candidate_tests() {
  local design_path="$1"
  local boundary_csv="$2"
  [ -f "$design_path" ] || return 0

  awk '
    BEGIN { in_fence = 0 }
    {
      raw = $0
      if (raw ~ /^[[:space:]]*```/) {
        in_fence = (in_fence == 0) ? 1 : 0
        next
      }
      if (!in_fence) { next }
      line = raw
      sub(/[[:space:]]*#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") { next }
      gsub(/[├│└─]/, " ", line)
      sub(/^[[:space:]]+/, "", line)
      if (line == "") { next }

      # test 系 keyword で post-filter（test / spec / test-fixtures / __tests__）。
      if (line !~ /test|spec|__tests__/) { next }

      split(line, parts, " ")
      cand = parts[1]
      if (cand == "") { next }
      if (!(cand in seen)) {
        seen[cand] = 1
        print cand
      }
    }
  ' "$design_path"

  # boundary_csv は現状 test 候補抽出には未使用だが、引数仕様としては受け取る（設計上の
  # 一貫性 / 将来 boundary を絡めた絞り込みを追加できる余地を残す）。
  : "${boundary_csv:-}"
}

# ─── cm_resolve_candidate_docs <spec_dir_abs> ───
#
# spec ディレクトリ配下の docs（requirements.md / design.md / tasks.md / 関連 markdown）を
# 候補として列挙する（Req 2.6）。spec dir 直下の `*.md` を 1 階層だけ走査する（決定論）。
#
# 入力: $1 = spec ディレクトリの絶対パス (e.g., "$REPO_DIR/$SPEC_DIR_REL")
# stdout: 改行区切りの相対パス（spec dir からの相対）
# 戻り値: 0
cm_resolve_candidate_docs() {
  local spec_dir="$1"
  [ -d "$spec_dir" ] || return 0

  # 1 階層のみ走査し、ソート順で決定論にする。
  ( cd "$spec_dir" && find . -maxdepth 1 -type f -name '*.md' 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort ) || true
}

# ─── cm_compose <task_id> <task_name> <boundary> <files> <tests> <docs> ───
#
# 構造化 markdown 本文を組み立てて stdout に出力（Req 2.2〜2.9）。LLM 呼び出しなし
# （Req 2.8）。各引数は以下:
#   $1 = task_id (例: "1" / "2.1")
#   $2 = task_name（task 行から抽出した名称。空でも可）
#   $3 = boundary（カンマ区切り。空なら「解決不能」明示にフォールバック / Req 2.9）
#   $4 = files（改行区切り。空なら「解決不能」明示）
#   $5 = tests（改行区切り。空なら「(none)」表示）
#   $6 = docs（改行区切り。空なら「(none)」表示）
cm_compose() {
  local task_id="$1"
  local task_name="$2"
  local boundary="$3"
  local files="$4"
  local tests="$5"
  local docs="$6"

  printf '%s\n' "<!-- generated by context-map.sh: deterministic, do not edit -->"
  printf '# Context Map for task %s\n\n' "$task_id"

  printf '## Task\n'
  printf -- '- ID: %s\n' "$task_id"
  printf -- '- Name: %s\n\n' "${task_name:-(unknown)}"

  # shellcheck disable=SC2016  # backticks inside markdown text are literal, not command substitution
  printf '## Boundary (from tasks.md `_Boundary:_`)\n'
  if [ -n "$boundary" ]; then
    # boundary をカンマ区切りで 1 行 1 項目に展開。
    printf '%s' "$boundary" | tr ',' '\n' | while IFS= read -r token; do
      token="${token# }"
      token="${token% }"
      [ -n "$token" ] || continue
      printf -- '- %s\n' "$token"
    done
  else
    # shellcheck disable=SC2016
    printf -- '- (resolution: none — task has no `_Boundary:_` or empty value)\n'
  fi
  printf '\n'

  printf '## Candidate files (from design.md File Structure Plan)\n'
  if [ -n "$files" ]; then
    printf '%s\n' "$files" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf -- '- %s\n' "$path"
    done
  else
    printf -- '- (none resolved — design.md File Structure Plan unavailable or no match)\n'
  fi
  printf '\n'

  printf '## Candidate tests\n'
  if [ -n "$tests" ]; then
    printf '%s\n' "$tests" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf -- '- %s\n' "$path"
    done
  else
    printf -- '- (none)\n'
  fi
  printf '\n'

  printf '## Candidate docs\n'
  if [ -n "$docs" ]; then
    printf '%s\n' "$docs" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf -- '- %s\n' "$path"
    done
  else
    printf -- '- (none)\n'
  fi
  printf '\n'

  printf '## Search constraints\n'
  printf -- '- READ FIRST: the files listed above. Do NOT run a repo-wide grep / glob unless they are insufficient.\n'
  # shellcheck disable=SC2016
  printf -- '- AVOID: editing files outside the `_Boundary:_` listed above.\n'
  printf -- '- NOTE: this map is generated deterministically from tasks.md and design.md. If it conflicts with the actual codebase, treat tasks.md and design.md as the authoritative source and record the discrepancy in impl-notes.md.\n'
}

# ─── cm_truncate_if_oversize <path> ───
#
# context-map.md が上限（200 行 / 8 KB）を超えていれば末尾を要約行で置換する（Req 2.10, NFR 4.1）。
# 上限以内なら何もしない（冪等 / NFR 2.1）。
#
# 上限値:
#   - 行数: 200 行
#   - バイト: 8192 バイト (8 KB)
# 超過時の挙動: 200 行以内に切り詰めて末尾に
#   `> (truncated by cm_truncate_if_oversize: original N lines / M bytes exceeded limit)`
# を追記する。
cm_truncate_if_oversize() {
  local path="$1"
  [ -f "$path" ] || return 0

  local _CM_MAX_LINES=200
  local _CM_MAX_BYTES=8192

  local nlines nbytes
  nlines=$(wc -l < "$path" 2>/dev/null | tr -d '[:space:]')
  nbytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  [ -n "$nlines" ] || nlines=0
  [ -n "$nbytes" ] || nbytes=0

  if [ "$nlines" -le "$_CM_MAX_LINES" ] && [ "$nbytes" -le "$_CM_MAX_BYTES" ]; then
    return 0
  fi

  # 上限以内に切り詰めて末尾に要約行を追記する。
  local tmp
  tmp="${path}.tmp.$$"
  head -n "$_CM_MAX_LINES" "$path" > "$tmp" 2>/dev/null || {
    cm_warn "cm_truncate_if_oversize: head 失敗 path=$path"
    rm -f "$tmp"
    return 0
  }
  printf '\n> (truncated by cm_truncate_if_oversize: original %s lines / %s bytes exceeded limit)\n' \
    "$nlines" "$nbytes" >> "$tmp"
  mv "$tmp" "$path" 2>/dev/null || {
    cm_warn "cm_truncate_if_oversize: mv 失敗 path=$path"
    rm -f "$tmp"
    return 0
  }
  return 0
}

# ─── _cm_resolve_task_name <tasks_md_path> <task_id> ───
#
# 当該 task 行から task 名（checkbox / numeric ID 装飾を除いた残り部分）を抽出する内部ヘルパ。
# 解決不能なら空文字を返す。
_cm_resolve_task_name() {
  local tasks_path="$1"
  local task_id="$2"
  [ -f "$tasks_path" ] || return 0
  [ -n "$task_id" ] || return 0

  awk -v tid="$task_id" '
    {
      raw = $0
      if (match(raw, /^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.?[[:space:]]/)) {
        rest = raw
        sub(/^- \[[ x]\]\*?[[:space:]]+/, "", rest)
        id = rest
        sub(/[.[:space:]].*$/, "", id)
        if (id == tid) {
          # numeric ID + 末尾の "." or 空白 を除去して task 名のみ取り出す。
          name = rest
          sub(/^[0-9]+(\.[0-9]+)*\.?[[:space:]]+/, "", name)
          print name
          exit
        }
      }
    }
  '  "$tasks_path"
}

# ─── cm_generate <task_id> ───
#
# 当該 task 用の context-map.md を $REPO_DIR/$SPEC_DIR_REL/context-map.md に生成 / 更新する
# entry point（Req 2.1〜2.10, NFR 2.1, NFR 2.3）。
#
# 入力: $1 = task ID
# 副作用: $REPO_DIR/$SPEC_DIR_REL/context-map.md を上書き作成
# 戻り値: 常に 0（内部失敗は cm_warn でログを残し、per-task ループは止めない / NFR 2.3）
#
# 設計方針:
#   - すべての内部失敗候補は `|| true` または `if ! ...; then warn; fi` で短絡し、
#     `set -e`（本体側）の影響で abort しないようガードする。
#   - 入力ファイル不在時は「解決不能」明示の最小限の context-map.md を生成する（Req 2.9）。
#   - cm_truncate_if_oversize で 200 行 / 8 KB 上限を担保（Req 2.10, NFR 4.1）。
cm_generate() {
  local task_id="$1"
  if [ -z "$task_id" ]; then
    cm_warn "cm_generate: task_id が空のため生成スキップ"
    return 0
  fi

  local spec_dir="${REPO_DIR:-.}/${SPEC_DIR_REL:-}"
  local tasks_path="$spec_dir/tasks.md"
  local design_path="$spec_dir/design.md"
  local out_path="$spec_dir/context-map.md"

  if [ -z "${SPEC_DIR_REL:-}" ] || [ ! -d "$spec_dir" ]; then
    cm_warn "cm_generate: SPEC_DIR_REL 未解決または spec dir 不在 spec_dir=$spec_dir（生成スキップ）"
    return 0
  fi

  # 各情報を順次解決（失敗は warn 止まりで rc=0 継続）。
  local task_name="" boundary="" files="" tests="" docs=""

  task_name=$(_cm_resolve_task_name "$tasks_path" "$task_id" 2>/dev/null || true)

  if ! boundary=$(cm_resolve_boundary "$tasks_path" "$task_id" 2>/dev/null); then
    boundary=""
    cm_warn "cm_generate: task=$task_id _Boundary:_ 解決不能（解決不能明示で生成継続）"
  fi

  if [ -n "$boundary" ]; then
    files=$(cm_resolve_candidate_files "$design_path" "$boundary" 2>/dev/null || true)
    tests=$(cm_resolve_candidate_tests "$design_path" "$boundary" 2>/dev/null || true)
  fi

  docs=$(cm_resolve_candidate_docs "$spec_dir" 2>/dev/null || true)

  # 本文生成 → 書き込み。書き込み失敗は warn 止まり。
  if ! cm_compose "$task_id" "$task_name" "$boundary" "$files" "$tests" "$docs" > "$out_path" 2>/dev/null; then
    cm_warn "cm_generate: context-map.md 書き込み失敗 path=$out_path（per-task ループは継続）"
    return 0
  fi

  cm_truncate_if_oversize "$out_path" || true

  cm_log "GENERATED task=$task_id path=$out_path"
  return 0
}

# ─── cm_render_prompt_section <task_id> ───
#
# per-task Developer / Reviewer prompt に embed する markdown ブロックを stdout に出す
# （Req 3.1, 3.2, 3.5）。
#
# 動作:
#   - cm_enabled 不通過 → 空文字を返す（既存 prompt と差分等価 / Req 3.5, NFR 1.1）。
#   - context-map.md が存在しない → 空文字を返す（生成失敗時の fallback）。
#   - 存在する → 内容を inline embed した markdown ブロックを stdout に出す。
#     per-task agent が改めて Read する余分な turn を避けるため、本文を直接埋め込む
#     （パスも併記して必要なら直接 Read もできるようにする）。
#
# 戻り値: 常に 0
cm_render_prompt_section() {
  local task_id="$1"
  cm_enabled || return 0

  local spec_dir="${REPO_DIR:-.}/${SPEC_DIR_REL:-}"
  local map_path="$spec_dir/context-map.md"
  [ -f "$map_path" ] || return 0

  local rel_path="${SPEC_DIR_REL:-}/context-map.md"
  local body
  body=$(cat "$map_path" 2>/dev/null || true)
  [ -n "$body" ] || return 0

  # heredoc 上で stdout を直接 capture して embed する想定。
  # 注入 markdown 構造は design.md「cm_render_prompt_section」節のテンプレに準拠。
  # fenced code block を 4 backtick で囲み、本文中の 3 backtick fence と干渉しないようにする。
  printf '\n'
  # shellcheck disable=SC2016  # backticks are literal markdown decoration, not command substitution
  printf '## Context Map（auto-generated / per-task ループ標準機能）\n\n'
  # shellcheck disable=SC2016
  printf '本起動では watcher が当該 task の `_Boundary:_` と design.md の File Structure Plan を元に\n'
  printf '**広域 grep / glob を行う前にまず参照すべき一次情報**として以下を生成しました\n'
  # shellcheck disable=SC2016
  printf '（パス: `%s` / task=%s）。\n\n' "$rel_path" "$task_id"
  printf '````markdown\n'
  printf '%s\n' "$body"
  printf '````\n\n'
  printf '上記の候補ファイル列挙で不足する場合のみ広域 grep / glob を行ってください。\n'

  return 0
}
