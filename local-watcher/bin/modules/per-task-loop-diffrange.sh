#!/usr/bin/env bash
# per-task-loop-diffrange.sh — per-task loop の diff-range 解決・fail-fast・post-marker 判定ヘルパー
#
# family: per-task-loop / prefix: pt_（#500 で per-task-loop.sh から分割。family マニフェストは
#   per-task-loop.sh 冒頭ヘッダを参照）
#
# 用途:
#   task 単位の diff range（marker commit から HEAD までの範囲）を解決し、fail-fast
#   （無進捗）判定・marker commit 以降の追加 commit（post-marker commits）の検出・分類を行う
#   純粋判定ヘルパー群。escalation（claude-failed 付与）自体は行わず、呼び出し側
#   （per-task-loop-exec.sh の runner 群）が判定結果を受けて pt_mark_* 系へ分岐する。
#   - pt_resolve_diff_range           : task 単位 diff range の開始/終了 SHA を解決
#   - pt_check_fail_fast              : fail-fast（無進捗）条件を判定
#   - pt_detect_post_marker_commits   : marker commit 以降の追加 commit を検出
#   - pt_classify_post_marker_paths   : post-marker の変更パスを分類
#   - pt_handle_post_marker_commits   : post-marker commit をハンドリング
#   - pt_is_parent_checkbox_only_diff : 親 checkbox のみの diff かを判定
#
# 配置先:
#   $HOME/bin/modules/per-task-loop-diffrange.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - 本ファイルの関数は cross-file 呼び出しを行わない（自己完結した純粋判定ヘルパー）。
#     判定結果は呼び出し側（per-task-loop-exec.sh）が受け取り、pt_mark_* 系 escalation へ分岐する。
#   - グローバル変数（$REPO_DIR / $SPEC_DIR_REL / $POST_MARKER_RECOVERY_MODE /
#     $POST_MARKER_DOCS_ALLOWLIST 等）は watcher-config.sh。
#   - 外部 CLI: git / grep。

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

