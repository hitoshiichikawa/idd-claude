#!/usr/bin/env bash
# shellcheck shell=bash
# promote-pipeline.sh — watcher の Promote Pipeline + Path Overlap プロセッサモジュール
#
# 用途:
#   issue-watcher.sh から切り出した 2 つの processor 群の関数定義を集約する。
#   - Promote Pipeline (#15): ST base 昇格パイプライン。Phase A により BASE_BRANCH に
#     merge された変更について ST check-run 結果をポーリングし、success なら
#     PROMOTION_TARGET_BRANCH への fast-forward 昇格、failure なら git revert + reopen +
#     st-failed 付与を行う（PROMOTE_PIPELINE_ENABLED=true の opt-in 機能）。
#     pp_resolve_target_branch / pp_collect_merged_issues / pp_get_st_state /
#     pp_handle_st_failure / pp_handle_st_success / pp_do_promote / process_promote_pipeline ほか。
#   - Path Overlap Checker (#18, Phase E): 同サイクル内 dispatch 競合予防・待機。
#     Triage 結果の edit_paths を永続化し、in-flight Issue と top-level path が重複する
#     場合に awaiting-slot ラベルを付与して dispatch を見送る。
#     po_parse_triage_edit_paths / po_compute_overlap / po_check_dispatch_gate /
#     po_apply_awaiting_slot / po_clear_awaiting_slot ほか。
#   Path Overlap (po_*) は独立モジュール化せず本モジュールへ同居させる（#181 design.md
#   decision 3。元コードで po_* は pp_* 定義群の物理的内部に挟まれていた経緯と Part 1
#   境界マップの同居指定に従う）。
#
# 配置先:
#   $HOME/bin/modules/promote-pipeline.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pp_log / pp_warn / pp_error は core_utils.sh に定義済みのため本モジュールでは
#     再定義しない（#180 Part 2 で core_utils.sh へ集約済み）。po_log / po_warn は本体由来の
#     ため本モジュールへ移す。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PROMOTION_TARGET_BRANCH / $PROMOTE_MODE /
#     $PROMOTE_PIPELINE_ENABLED / $PATH_OVERLAP_CHECK / $LABEL_STAGED_FOR_RELEASE /
#     $LABEL_ST_FAILED 等）は本体冒頭の Config ブロックで定義済み。bash の遅延束縛により
#     呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_promote_pipeline || pp_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ / #181 design.md）。
#   - dispatcher が po_check_dispatch_gate を、本モジュール内部から po_apply/clear_awaiting_slot を呼ぶ。
#   - 外部 CLI: gh / git / jq。
#
# セットアップ参照先:
#   - 設計: docs/specs/181-feat-watcher-issue-watcher-sh-part-3-pr/design.md
#   - README「Phase B Promote Pipeline」「Path Overlap Checker (Phase E)」節

po_log() {
  echo "[$(date '+%F %T')] [$REPO] path-overlap: $*"
}
po_warn() {
  echo "[$(date '+%F %T')] [$REPO] path-overlap: WARN: $*" >&2
}

# ─── Phase E: Triage Edit-Paths Parser (#18 Req 2.4 / 2.5) ───
# Triage 結果 JSON から edit_paths 配列を fail-safe に抽出する。
# - key 不在 / null / 非配列 / 要素に文字列以外混入はすべて空配列にフォールバック
# - 既存 5 keys 抽出（jq -r '.status' 等）は変更しない（Req 2.5）
#
# Args: $1 = Triage 結果 JSON ファイルパス
# Stdout: JSON 配列文字列（必ず `[...]` 形式、空でも `[]`）
# Return: 0 always（失敗時は `[]` を返す fail-safe）
po_parse_triage_edit_paths() {
  local triage_file="$1"
  if [ ! -f "$triage_file" ]; then
    echo '[]'
    return 0
  fi
  # `// []` で key 不在を吸収、`if type=="array" then ... else [] end` で型不正吸収、
  # `map(select(type=="string"))` で文字列以外を除外。jq 失敗時も `[]` を返す。
  jq -c '
    (.edit_paths // [])
    | if type == "array" then
        map(select(type == "string"))
      else
        []
      end
  ' "$triage_file" 2>/dev/null || echo '[]'
}

# ─── Phase E: Path Overlap Persister (#18 Req 3.1〜3.4 / 12.1) ───
# Triage で得た edit_paths を Issue 上に sticky comment として保存する。同じ marker
# (<!-- idd-claude:edit-paths:v1 -->) を持つ既存コメントがあれば PATCH で上書き、
# 無ければ新規 create する（Req 3.3 重複防止）。
#
# 本文形式（人間可読 md リスト + 機械可読 hidden JSON marker の 2 段構成）:
#
#   ## Triage edit_paths（Phase E）
#
#   本 Issue が編集見込みの top-level path:
#
#   - `local-watcher/`
#   - `README.md`
#
#   *(自動生成: Path Overlap Checker。本機能の詳細は README の「Phase E」節を参照)*
#
#   <!-- idd-claude:edit-paths:v1 -->
#   <!-- idd-claude:edit-paths-json:["local-watcher/","README.md"] -->
#
# Args: $1 = issue number, $2 = edit_paths JSON 配列文字列
# Return: 0 = persist OK / 1 = persist 失敗（呼び出し側は warn のみで Triage 全体は成功扱い）
po_persist_edit_paths() {
  local issue_number="$1"
  local edit_paths_json="$2"

  # 本文 md リストを組み立てる（空配列なら "なし" 表示）
  local list_md
  list_md=$(echo "$edit_paths_json" | jq -r '
    if length == 0 then
      "_(Triage は確信のある edit_paths を推定できませんでした)_"
    else
      map("- `" + . + "`") | join("\n")
    end
  ' 2>/dev/null || echo '_(edit_paths 抽出失敗)_')

  local marker_v1="<!-- idd-claude:edit-paths:v1 -->"
  local json_marker
  # JSON marker を 1 行に整形（jq -c で改行なしの compact 形式）
  json_marker="<!-- idd-claude:edit-paths-json:${edit_paths_json} -->"

  local body
  body=$(cat <<EOF
## Triage edit_paths（Phase E）

本 Issue が編集見込みの top-level path:

${list_md}

*(自動生成: Path Overlap Checker。本機能の詳細は README の「Phase E」節を参照)*

${marker_v1}
${json_marker}
EOF
)

  # 既存 sticky comment を gh API で検索（URL 末尾の `#issuecomment-<numeric-id>` から
  # REST API id を抽出。`.comments[].id` は GraphQL の base64 id なので使えない）。
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    return 1
  fi
  local existing_url
  existing_url=$(echo "$comments_json" | jq -r '
    (.comments // [])
    | map(select(.body | contains("<!-- idd-claude:edit-paths:v1 -->")))
    | .[0].url // ""
  ' 2>/dev/null || echo "")
  local existing_comment_id=""
  if [ -n "$existing_url" ]; then
    existing_comment_id=$(printf '%s' "$existing_url" \
      | sed -nE 's/.*#issuecomment-([0-9]+)$/\1/p')
  fi

  if [ -n "$existing_comment_id" ]; then
    # 既存 sticky comment を PATCH で上書き（Req 3.3）
    if ! gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_comment_id}" \
        -f body="$body" >/dev/null 2>&1; then
      return 1
    fi
  else
    # 新規作成
    if ! gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

# ─── Phase E: Path Overlap Loader (#18 Req 12.1) ───
# Issue の sticky comment から edit_paths JSON を読み出す。marker 不在 / API 失敗 /
# 形式異常はすべて空配列 `[]` を返す fail-safe。
# 1 candidate あたり gh issue view --json comments を **1 回のみ** 呼ぶ（Req 12.1）。
#
# Args: $1 = issue number
# Stdout: edit_paths JSON 配列文字列（必ず `[...]` 形式、抽出失敗時は `[]`）
# Return: 0 always
po_load_edit_paths() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    echo '[]'
    return 0
  fi
  # 全コメントから marker 行を抽出 → JSON 部を取り出して valid array かチェック
  local extracted
  extracted=$(echo "$comments_json" \
    | jq -r '.comments // [] | map(.body) | .[]' 2>/dev/null \
    | sed -nE 's/.*<!-- idd-claude:edit-paths-json:(.*) -->.*/\1/p' \
    | tail -1)
  if [ -z "$extracted" ]; then
    echo '[]'
    return 0
  fi
  # extracted が valid な JSON 配列であることを jq で再検証してから返す
  local validated
  validated=$(echo "$extracted" | jq -c '
    if type == "array" then
      map(select(type == "string"))
    else
      []
    end
  ' 2>/dev/null || echo '[]')
  echo "$validated"
}

# ─── Phase E: Holder Label Set Resolver (#221 Req 1.1 / 2.1 / 3.1〜3.3 / 4.1 / NFR1.1) ───
# 呼び出しコンテキストと branch 設定から、in-flight holder とみなすラベル集合を CSV で返す。
# holder の本質は「dispatch 先 base ブランチにまだ取り込まれていない作業」であるため、
# multi-branch（gitflow）運用の dispatch 文脈では develop 統合済みの `staged-for-release` を
# holder から除外する。それ以外（promote / single-branch / 判定不能）は full 集合を返す。
#
# holder 集合決定の真理値表（design.md D3）:
#   context    | BASE_BRANCH vs PROMOTION_TARGET_BRANCH | 返す集合
#   dispatch   | != （multi-branch / gitflow）          | 6 ラベル（staged-for-release 除外）… Req 1.1
#   dispatch   | == （single-branch）                   | 7 ラベル（full / ゼロ差分）       … NFR 1.1
#   promote    | （不問）                               | 7 ラベル（full / SfR 維持）        … Req 2.1
#   不明な値    | （不問）                               | 7 ラベル（full / fail-safe）       … Req 4.1
#
# invariants: 返す CSV は常に 6 基本ラベル
#   claude-claimed / claude-picked-up / awaiting-design-review / ready-for-review /
#   needs-iteration / needs-rebase
# を含む（NFR 1.2）。コンテキストで変動するのは `staged-for-release` の有無のみ。
#
# Args:
#   $1 = context（"dispatch" | "promote"）
# Stdout: holder ラベル CSV（空白なしカンマ区切り。dispatch×multi-branch では
#         staged-for-release を含まない）
# Return: 0 always（判定不能でも full 集合を返す fail-safe / Req 4.1）
po_resolve_holder_labels() {
  local context="${1:-}"

  # 6 基本ラベルは常時集合内（NFR 1.2 invariant）。`$LABEL_*` 定数は本体 Config ブロックで
  # 束縛済みだが、未束縛時にも安全側へ倒すため `:-` で既定リテラルへ fallback する。
  local base_labels
  base_labels="${LABEL_CLAIMED:-claude-claimed},${LABEL_PICKED:-claude-picked-up},${LABEL_AWAITING_DESIGN:-awaiting-design-review},${LABEL_READY:-ready-for-review},${LABEL_NEEDS_ITERATION:-needs-iteration},${LABEL_NEEDS_REBASE:-needs-rebase}"

  # full 集合 = 6 基本ラベル + staged-for-release（ラベル文字列はハードコード重複させず
  # `$LABEL_STAGED_FOR_RELEASE` 定数を参照する / task 明記）。
  local staged_label="${LABEL_STAGED_FOR_RELEASE:-staged-for-release}"
  local full_labels="${base_labels},${staged_label}"

  # dispatch かつ multi-branch（BASE_BRANCH != PROMOTION_TARGET_BRANCH）のみ
  # staged-for-release を除外する。それ以外は full 集合（fail-safe / 安全側）。
  if [ "$context" = "dispatch" ] && [ "${BASE_BRANCH:-main}" != "${PROMOTION_TARGET_BRANCH:-main}" ]; then
    echo "$base_labels"
    return 0
  fi

  echo "$full_labels"
  return 0
}

# ─── Phase E: In-Flight Collector (#18 Req 4.1〜4.4 / 5.3 / 8.1) ───
# 現サイクルの in-flight Issue（候補自身を除く）を gh で 1 回列挙し、各 Issue の
# edit_paths を読み出して **union 配列**と **path → holder Issue 番号配列の map**
# の両方を含む JSON object を返す。
#
# 戻り値の JSON object schema:
#   {
#     "union":   ["local-watcher/", "README.md"],         # 正規化前の paths を union
#     "holders": {                                          # 正規化前の path → holders
#       "local-watcher/": [39, 40],
#       "README.md":      [40]
#     }
#   }
#
# Note: holders map のキーは **正規化前の生 path**（in-flight Issue が persist した
# まま）。`po_check_dispatch_gate` 側で overlap path（正規化済 top-level）と
# 突合する際は同じ `normalize` 関数を holders map のキーにも適用してから引く。
#
# Req 12.1 補足: API 呼び出し回数は本拡張で増えていない。各 in-flight Issue について
# `po_load_edit_paths` を 1 回呼ぶのは従来同様で、その戻り値から union と holders map
# を同時に構築するだけ。candidate 側の `po_load_edit_paths` も 1 回のまま。
#
# in-flight 判定ラベル（Req 4.1）:
#   claude-claimed, claude-picked-up, awaiting-design-review, ready-for-review,
#   needs-iteration, needs-rebase, staged-for-release
# 除外（Req 4.2）: st-failed, awaiting-slot
# 候補自身を除外（Req 4.3）、同 repo のみ（Req 4.4: --repo "$REPO" 固定）
#
# Args: $1 = candidate issue number
# Stdout: JSON object `{"union": [...], "holders": {path: [issue#, ...]}}`
# Return: 0 = 列挙 OK / 1 = gh API 失敗（caller は fail-open で empty 扱い + warn）
po_collect_inflight_issues() {
  local candidate="$1"

  # 7 ラベルのいずれかを持ち、`st-failed` / `awaiting-slot` を持たない open Issue を
  # OR 検索で抽出する。`gh issue list --label A --label B` は AND になるため、
  # `--search 'label:A OR label:B OR ...'` 形式を使う（既存 Phase B / Phase D が同形式
  # を採用済）。
  local search_query
  search_query=$(cat <<EOF
is:open is:issue (label:"claude-claimed" OR label:"claude-picked-up" OR label:"awaiting-design-review" OR label:"ready-for-review" OR label:"needs-iteration" OR label:"needs-rebase" OR label:"staged-for-release") -label:"st-failed" -label:"awaiting-slot"
EOF
)
  local issues_json
  if ! issues_json=$(gh issue list --repo "$REPO" \
      --search "$search_query" \
      --json number \
      --limit 50 2>/dev/null); then
    return 1
  fi

  # 候補自身を除外（Req 4.3）、各 Issue について po_load_edit_paths を呼んで
  # union（unique 済 path 配列）と holders map（path → [issue#, ...]）を併走更新する。
  local accum
  accum='{"union": [], "holders": {}}'
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if [ "$n" = "$candidate" ]; then
      continue
    fi
    local paths
    paths=$(po_load_edit_paths "$n")
    # accum := accum + (paths を union に merge / 各 path に対し holders[path] に n を追記)
    # holders は array で持ち、重複 issue# は jq の unique で抑止する。
    accum=$(jq -nc \
      --argjson acc "$accum" \
      --argjson paths "$paths" \
      --argjson holder "$n" '
      .union as $_ |
      $acc
      | .union = (.union + $paths | unique)
      | reduce $paths[] as $p (
          .;
          .holders[$p] = ((.holders[$p] // []) + [$holder] | unique)
        )
    ')
  done < <(echo "$issues_json" | jq -r '.[].number')

  echo "$accum"
  return 0
}

# ─── Phase E: Holder Resolver (#18 Req 5.3 / 8.1) ───
# overlap path（正規化済 top-level）と holders map（正規化前 path → [issue#, ...]）
# から、各 overlap path に対応する holder Issue 番号配列を解決する。
#
# 既存 `po_compute_overlap` の `normalize` 規約（先頭 `./` 剥がし / 連続スラッシュ
# 圧縮 / top-level セグメント + `/`）を holders map の生キーにも適用してから
# 突合する。
#
# Args: $1 = overlap JSON 配列（正規化済 top-level path 文字列）
#       $2 = holders map JSON（正規化前 path → [issue#, ...]）
# Stdout: JSON object `{overlap_path: [issue#, ...], ...}`
#         （overlap path はすべてキーに登場。holder が見つからない場合は空配列）
# Return: 0 always
po_resolve_overlap_holders() {
  local overlap_json="$1"
  local holders_json="$2"
  jq -nc \
    --argjson overlap "$overlap_json" \
    --argjson holders "$holders_json" '
    def normalize:
      sub("^\\./"; "")
      | gsub("/+"; "/")
      | if test("/") then
          (split("/")[0] + "/")
        else
          .
        end;
    # holders の生キーを normalize して bucket 化（同一 top-level に複数 raw path が
    # 寄ってきた場合は holders を merge して unique）
    ($holders | to_entries
      | map(.key |= normalize)
      | group_by(.key)
      | map({ key: .[0].key, value: (map(.value) | add | unique) })
      | from_entries
    ) as $bucket
    | reduce $overlap[] as $p (
        {};
        .[$p] = ($bucket[$p] // [])
      )
  '
}

# ─── Phase E: Holders Log Formatter (#18 Req 8.1) ───
# overlap-holders map から overlap log line 用の holders フィールド文字列
# （例: "#39,#40"）を生成する。重複 Issue# は除去、ソートして並び順を安定化。
#
# Args: $1 = overlap-holders map JSON（po_resolve_overlap_holders 出力）
# Stdout: "#<N>,#<M>,..." or "" (holders が 1 件も無い場合)
# Return: 0 always
po_format_holders_for_log() {
  local map_json="$1"
  echo "$map_json" | jq -r '
    [.[] | .[]] | unique | sort | map("#" + tostring) | join(",")
  ' 2>/dev/null || echo ""
}

# ─── Phase E: Overlap Table Markdown Formatter (#18 Req 5.3) ───
# overlap-holders map を sticky comment 本文の表形式 markdown に整形する。
# design.md「Awaiting-Slot Sticky Comment Format」（design.md:855-863）参照。
#
# 出力例:
#   | 重複 path | 保持中の Issue |
#   |---|---|
#   | `local-watcher/` | #39, #40 |
#   | `README.md` | #40 |
#
# Args: $1 = overlap-holders map JSON
# Stdout: markdown 表（先頭の見出し 2 行 + 各 overlap path 1 行）
# Return: 0 always
po_format_holders_table_md() {
  local map_json="$1"
  {
    echo '| 重複 path | 保持中の Issue |'
    echo '|---|---|'
    echo "$map_json" | jq -r '
      to_entries
      | sort_by(.key)
      | map(
          "| `" + .key + "` | " +
          (
            if (.value | length) == 0 then
              "_(holder 不明)_"
            else
              (.value | unique | sort | map("#" + tostring) | join(", "))
            end
          ) + " |"
        )
      | .[]
    ' 2>/dev/null
  }
}

# ─── Phase E: Overlap Engine (#18 Req 5.1 / 5.5 / 5.6) ───
# candidate と in-flight の path 配列の積集合を top-level 粒度で計算する。
#
# 正規化規約:
#   - 先頭 `./` を剥がす
#   - 連続スラッシュ `/+` を `/` 1 つに圧縮
#   - スラッシュを含むなら先頭セグメント + `/` を返す（ディレクトリ扱い）
#   - スラッシュを含まないならそのまま（ルート直下ファイル扱い）
#
# 例:
#   `local-watcher/bin/foo.sh` → `local-watcher/`
#   `README.md`                → `README.md`
#   `./docs/specs/18-foo/req.md` → `docs/`
#
# candidate が空配列なら常に積集合は空（Req 5.5 候補不在は dispatch 阻止しない）。
#
# Args: $1 = candidate edit_paths JSON 配列, $2 = in-flight union JSON 配列
# Stdout: 交差 JSON 配列（正規化済 top-level key、重複排除済）
# Return: 0 always
po_compute_overlap() {
  local cand_json="$1"
  local inflight_json="$2"
  jq -nc \
    --argjson c "$cand_json" \
    --argjson f "$inflight_json" '
    def normalize:
      sub("^\\./"; "")
      | gsub("/+"; "/")
      | if test("/") then
          (split("/")[0] + "/")
        else
          .
        end;
    ($c | map(normalize) | unique) as $cn
    | ($f | map(normalize) | unique) as $fn
    | $cn | map(select(. as $p | $fn | index($p)))
  '
}

# ─── Phase E: Awaiting Slot State Machine — apply (#18 Req 5.2 / 5.3 / 8.2) ───
# `awaiting-slot` ラベルを付与（冪等）し、説明 sticky comment を post / update する。
#
# sticky comment marker: <!-- idd-claude:awaiting-slot:v1 -->
# 同一 Issue に 1 件のみ。既存 marker 付きコメントがあれば PATCH で上書き、無ければ
# 新規 create する（cron tick ごとのノイズ累積を抑制）。
#
# 本文には Req 5.3 が要求する「どの path がどの in-flight Issue に保持されているか」
# を表形式（design.md「Awaiting-Slot Sticky Comment Format」L855-863 準拠）で表示する。
#
# Args: $1 = candidate issue number
#       $2 = overlap JSON 配列（正規化済 top-level path 文字列、後方互換用）
#       $3 = overlap-holders map JSON（path → [issue#, ...]、Req 5.3 holder 情報）
# Return: 0 = apply OK / 1 = 致命的失敗（呼び出し側 warn）
po_apply_awaiting_slot() {
  local issue_number="$1"
  local overlap_json="$2"
  local holders_map_json="${3:-}"

  # ラベル付与（冪等。既付与でも error にならない）。
  # #187: ラベル付与に失敗しても early return せず、警告ログを残した上で sticky comment
  # 投稿へ処理を継続する。これによりラベルが付与できなかったケースでも「なぜ Issue が
  # 止まっているか」を Issue 上のコメントから読み取れるようにする（Req 1.1 / 1.2 / 3.1）。
  # コメント投稿/更新はラベル付与の成否に依存せず必ず試行する。
  if gh issue edit "$issue_number" --repo "$REPO" \
      --add-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
    po_log "awaiting-slot added candidate=#${issue_number}"
  else
    po_warn "issue=#${issue_number} awaiting-slot ラベル付与に失敗（見送り理由コメントの投稿は継続）"
  fi

  # sticky comment 本文の組み立て
  # holders_map_json が与えられた場合は表形式（| 重複 path | 保持中の Issue |）で
  # 表示する（Req 5.3 + design.md L855-863）。未指定 / 空 map の場合は path のみの
  # md リストにフォールバック（後方互換）。
  local overlap_section
  if [ -n "$holders_map_json" ] && \
      [ "$(echo "$holders_map_json" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    overlap_section=$(po_format_holders_table_md "$holders_map_json")
  else
    overlap_section=$(echo "$overlap_json" | jq -r '
      if length == 0 then
        "_(overlap path が空ですが本コメントが呼ばれました。状態不整合の可能性あり)_"
      else
        map("- `" + . + "`") | join("\n")
      end
    ' 2>/dev/null || echo '_(overlap 抽出失敗)_')
  fi

  local marker="<!-- idd-claude:awaiting-slot:v1 -->"
  local body
  body=$(cat <<EOF
## ⏸️ Dispatch を見送り中（Phase E Path Overlap Checker）

本 Issue が編集見込みの top-level path のうち、以下が現在 in-flight 中の他 Issue と重複しています。

${overlap_section}

先行 Issue の PR が merge されて in-flight 集合から外れた次サイクルで \`awaiting-slot\`
ラベルが自動除去され、本 Issue は通常 dispatch に戻ります。手動介入は不要です。

詳細は README の「Path Overlap Checker (Phase E)」節を参照してください。

${marker}
EOF
)

  # sticky 化: 既存 marker 付きコメントを検索 → あれば PATCH、無ければ新規 create
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    # コメント取得失敗時は新規 create を試みる（best-effort）
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
    return 0
  fi
  local existing_url
  existing_url=$(echo "$comments_json" | jq -r '
    (.comments // [])
    | map(select(.body | contains("<!-- idd-claude:awaiting-slot:v1 -->")))
    | .[0].url // ""
  ' 2>/dev/null || echo "")
  local existing_comment_id=""
  if [ -n "$existing_url" ]; then
    existing_comment_id=$(printf '%s' "$existing_url" \
      | sed -nE 's/.*#issuecomment-([0-9]+)$/\1/p')
  fi
  if [ -n "$existing_comment_id" ]; then
    gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_comment_id}" \
      -f body="$body" >/dev/null 2>&1 || true
  else
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
  fi
  return 0
}

# ─── Phase E: Awaiting Slot State Machine — clear (#18 Req 6.2 / 6.4 / 8.3) ───
# `awaiting-slot` ラベルを除去する（冪等）。説明 sticky comment は事後監査用に残置する。
#
# Args: $1 = candidate issue number
# Return: 0 = clear OK / 1 = ラベル除去失敗（呼び出し側 warn → 次サイクルで再試行）
po_clear_awaiting_slot() {
  local issue_number="$1"
  if ! gh issue edit "$issue_number" --repo "$REPO" \
      --remove-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
    return 1
  fi
  po_log "awaiting-slot cleared candidate=#${issue_number} (overlap empty)"
  return 0
}

# ─── Phase E: Dispatcher Integration Point (#18 Req 1.1〜1.4 / 5.x / 6.x / 12.2) ───
# _dispatcher_run の candidate ループ内、check_existing_impl_pr 通過直後・
# _dispatcher_find_free_slot 呼び出し前に挿入する gate 関数。
#
# 関数冒頭で `[ "$PATH_OVERLAP_CHECK" = "true" ] || return 0` で opt-in gate を成立
# させ、未設定 / off / 不正値（True / 1 / typo 等）は早期 return 0 = 従来挙動と
# 完全一致（Req 1.2 / 1.3 / NFR 1.1）。
#
# Args: $1 = candidate issue number, $2 = candidate labels JSON
#       （gh issue list の `.labels` フィールドを jq -c で取り出したもの）
# Return: 0 = claim を続行してよい / 1 = この cycle では dispatch skip（continue）
po_check_dispatch_gate() {
  local candidate="$1"
  local labels_json="$2"

  # Req 1.2 / 1.3 / 1.4: opt-in gate（厳密一致 "true" のみ通す）
  [ "$PATH_OVERLAP_CHECK" = "true" ] || return 0

  # 候補の edit_paths を sticky から読む（Req 5.5: marker 不在は空配列扱い）
  local cand_paths
  cand_paths=$(po_load_edit_paths "$candidate")

  # in-flight union + holders map を取得（Req 4.1〜4.4 / 5.3 / 8.1）。
  # 失敗時は fail-open で claim 続行
  local inflight_obj
  if ! inflight_obj=$(po_collect_inflight_issues "$candidate"); then
    po_warn "issue=#${candidate} in-flight 列挙に失敗、本サイクルは overlap 判定を skip して claim 続行"
    return 0
  fi
  local inflight_paths inflight_holders
  inflight_paths=$(echo "$inflight_obj" | jq -c '.union // []' 2>/dev/null || echo '[]')
  inflight_holders=$(echo "$inflight_obj" | jq -c '.holders // {}' 2>/dev/null || echo '{}')

  # overlap 計算（Req 5.1 / 5.6）
  local overlap overlap_count
  overlap=$(po_compute_overlap "$cand_paths" "$inflight_paths")
  overlap_count=$(echo "$overlap" | jq 'length' 2>/dev/null || echo 0)

  # 現状の awaiting-slot ラベル付与状態（既存 labels_json から抽出）
  local has_awaiting
  has_awaiting=$(echo "$labels_json" \
    | jq -r --arg lbl "$LABEL_AWAITING_SLOT" \
        '[.[].name] | index($lbl) // empty' 2>/dev/null || echo "")

  if [ "$overlap_count" -gt 0 ]; then
    # Req 5.2 / 5.3 / 8.1 / 8.2: overlap 検出ログ（holders を含める）→ awaiting-slot
    # 付与（未付与時のみ）。holders は overlap path（正規化済 top-level）ごとに
    # in-flight Issue 番号配列を解決し、log では unique sort で平坦化する。
    local overlap_holders_map holders_for_log paths_for_log
    overlap_holders_map=$(po_resolve_overlap_holders "$overlap" "$inflight_holders")
    holders_for_log=$(po_format_holders_for_log "$overlap_holders_map")
    paths_for_log=$(echo "$overlap" | jq -r 'join(",")')
    if [ -n "$holders_for_log" ]; then
      po_log "overlap detected candidate=#${candidate} paths=${paths_for_log} holders=${holders_for_log}"
    else
      # holders が空（in-flight が close 直後 / holder 不明等）でも paths は記録し、
      # holders=「-」で出力して欠落の事実をログに残す
      po_log "overlap detected candidate=#${candidate} paths=${paths_for_log} holders=-"
    fi
    if [ -z "$has_awaiting" ]; then
      if ! po_apply_awaiting_slot "$candidate" "$overlap" "$overlap_holders_map"; then
        po_warn "issue=#${candidate} awaiting-slot 付与 / コメント投稿に失敗（次サイクルで再評価）"
      fi
    fi
    return 1  # dispatch skip
  fi

  # overlap 空: Req 6.2 / 6.4 / 8.3 自然解消
  if [ -n "$has_awaiting" ]; then
    if ! po_clear_awaiting_slot "$candidate"; then
      po_warn "issue=#${candidate} awaiting-slot 除去に失敗（次サイクルで再試行のため本 cycle は claim 見送り）"
      return 1
    fi
  fi
  return 0  # claim 続行
}

# pp_resolve_target_branch: `PROMOTION_TARGET_BRANCH` のリモート存在を検証し、
# `BASE_BRANCH` と異なることを確認する（Req 1.1.3, 1.2.2）。
# 戻り値: 0 = 検証 OK / 1 = 中止すべき状態
pp_resolve_target_branch() {
  # AC 1.1.3: BASE_BRANCH == PROMOTION_TARGET_BRANCH なら no-op として終了
  if [ "$BASE_BRANCH" = "$PROMOTION_TARGET_BRANCH" ]; then
    pp_log "BASE_BRANCH と PROMOTION_TARGET_BRANCH が同一 ('$BASE_BRANCH')、Phase B は no-op"
    return 1
  fi
  # AC 1.2.2: リモートに存在するか検証
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      git ls-remote --exit-code --heads origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
    pp_error "PROMOTION_TARGET_BRANCH '$PROMOTION_TARGET_BRANCH' がリモートに存在しません。promote を中止します。"
    return 1
  fi
  return 0
}

# pp_issue_has_label: Issue が指定ラベルを持つか確認するヘルパー。
# 戻り値: 0 = 持つ / 1 = 持たない or 取得失敗
pp_issue_has_label() {
  local issue_number="$1"
  local label="$2"
  local labels_json
  if ! labels_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json labels 2>/dev/null); then
    return 1
  fi
  echo "$labels_json" | jq -e --arg l "$label" \
    '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# pp_collect_merged_issues: Phase A 直後の状態で「`BASE_BRANCH` に merge 済みかつ
# `Closes #N` でリンクされている Issue」を抽出し、未付与の Issue には
# `staged-for-release` を自動付与する。fork PR は除外する（NFR 2.4）。
# 自動付与と人間付与の source 区別は行わない（Req 2.1.2、同一ラベル共有）。
#
# stdout: 現時点で `staged-for-release` を持つ全 open Issue の番号を 1 行 1 件で出力
#         （次のステップで ST 判定する対象集合になる）
# Requirements: 2.1, NFR 2.4, NFR 5.2
pp_collect_merged_issues() {
  local repo_owner="${REPO%%/*}"
  local recent_merged_prs_json
  # 1. is:merged base:$BASE_BRANCH の直近 PR を取得（最新 50 件、Req 5.2 範囲）
  if ! recent_merged_prs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --base "$BASE_BRANCH" \
      --json number,headRepositoryOwner,closingIssuesReferences \
      --limit 50 2>/dev/null); then
    pp_warn "merged PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # 2. fork PR を除外（NFR 2.4）し、closingIssuesReferences から Issue 番号を抽出
  local linked_issues
  linked_issues=$(echo "$recent_merged_prs_json" | jq -r \
    --arg owner "$repo_owner" \
    '[.[]
      | select((.headRepositoryOwner.login // "") == $owner)
      | (.closingIssuesReferences // [])[]
      | .number
    ] | unique | .[]')

  # 3. 各 Issue について `staged-for-release` ラベルの有無を確認し、
  #    未付与なら自動付与する（重複付与は抑止 / Req 2.1.1, 2.1.3）
  local added=0
  local skipped=0
  if [ -n "$linked_issues" ]; then
    while IFS= read -r issue_number; do
      [ -n "$issue_number" ] || continue
      if pp_issue_has_label "$issue_number" "$LABEL_STAGED_FOR_RELEASE"; then
        # AC 2.1.3: 既付与なら API 再送しない
        skipped=$((skipped + 1))
        continue
      fi
      # AC 2.1.1: 未付与に対して自動付与
      if timeout "$PROMOTE_GIT_TIMEOUT" \
          gh issue edit "$issue_number" --repo "$REPO" \
            --add-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
        pp_log "issue=#${issue_number} action=label-add label=${LABEL_STAGED_FOR_RELEASE} source=auto"
        added=$((added + 1))
      else
        pp_warn "issue=#${issue_number} staged-for-release 自動付与に失敗（後続 Issue は継続）"
      fi
    done <<< "$linked_issues"
  fi

  pp_log "auto-label サマリ: staged-for-release-added=${added}, already-labeled-skipped=${skipped}"

  # 4. 全 staged-for-release 付き open Issue の番号を stdout に出力（自動 + 人間
  #    付与の両方を含む / Req 2.1.2）。後続 ST 判定の対象集合になる。
  timeout "$PROMOTE_GIT_TIMEOUT" gh issue list --repo "$REPO" \
    --label "$LABEL_STAGED_FOR_RELEASE" --state open \
    --json number --limit 100 --jq '.[].number' 2>/dev/null \
    || pp_warn "staged-for-release 付き Issue 一覧の取得に失敗（per-Issue 処理を見送る）"
}

# pp_resolve_merge_sha: Issue にリンクされた直近の merge commit SHA を解決する。
# GitHub の `gh issue view --json closedByPullRequestsReferences` で Issue を閉じた
# PR を取得し、各 PR の mergeCommit.oid を最新（updatedAt 降順）から拾う。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: merge commit SHA（解決できた場合）
# 戻り値: 0 = 解決成功 / 1 = 失敗（Issue が PR 経由で閉じられていない・取得失敗等）
pp_resolve_merge_sha() {
  local issue_number="$1"
  local pr_list_json
  if ! pr_list_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" \
        --json closedByPullRequestsReferences 2>/dev/null); then
    return 1
  fi
  # PR ごとに mergeCommit.oid を取得（必要に応じて gh pr view で補完）
  local pr_numbers
  pr_numbers=$(echo "$pr_list_json" | jq -r \
    '[.closedByPullRequestsReferences // [] | .[]
      | select(.state == "MERGED")
      | .number] | sort | reverse | .[]' 2>/dev/null) || return 1
  [ -n "$pr_numbers" ] || return 1
  local pr_number merge_sha
  while IFS= read -r pr_number; do
    [ -n "$pr_number" ] || continue
    merge_sha=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" \
        --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null) || continue
    if [ -n "$merge_sha" ] && [ "$merge_sha" != "null" ]; then
      echo "$merge_sha"
      return 0
    fi
  done <<< "$pr_numbers"
  return 1
}

# pp_get_st_state: 1 つの Issue について、リンクされた最新の `BASE_BRANCH` 上
# merge commit に対する ST check-run の状態を取得する。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: 内部状態 5 種のいずれか
#   "success"   ST check-run が完了 & conclusion=success
#   "failure"   ST check-run が完了 & conclusion=failure/cancelled/timed_out/action_required
#   "pending"   ST check-run が in_progress / queued / pending
#   "missing"   ST check-run が見つからない or conclusion 不一致
#   "skip-warn" ST_CHECK_RUN_NAME 未設定（Req 2.2.3）
# 戻り値: 常に 0（呼び出し元で文字列分岐）
# Requirements: 2.2
pp_get_st_state() {
  local issue_number="$1"
  # AC 2.2.3: ST_CHECK_RUN_NAME 未設定なら skip-warn（呼び出し元で WARN ログ）
  if [ -z "$ST_CHECK_RUN_NAME" ]; then
    echo "skip-warn"
    return 0
  fi
  # AC 2.2.5: Issue にリンクされた merge commit を解決できなければ missing
  local merge_sha
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    echo "missing"
    return 0
  fi
  [ -n "$merge_sha" ] || { echo "missing"; return 0; }
  # AC 2.2.1: check-runs API で対象 commit に対する check-run 一覧を取得
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo "missing"
    return 0
  fi
  # AC 2.2.2: ST_CHECK_RUN_NAME と完全一致する check-run を抽出し、最新採用
  local target
  target=$(echo "$check_runs_json" | jq -c --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last' 2>/dev/null) || target="null"
  if [ -z "$target" ] || [ "$target" = "null" ]; then
    echo "missing"
    return 0
  fi
  # AC 2.2.4: status + conclusion で結果判定
  local status conclusion
  status=$(echo "$target" | jq -r '.status // ""')
  conclusion=$(echo "$target" | jq -r '.conclusion // ""')
  case "$status" in
    completed)
      case "$conclusion" in
        success)
          echo "success"
          ;;
        failure|cancelled|timed_out|action_required)
          echo "failure"
          ;;
        *)
          # neutral / skipped / stale / unknown は missing 扱い
          echo "missing"
          ;;
      esac
      ;;
    queued|in_progress|pending|"")
      echo "pending"
      ;;
    *)
      echo "pending"
      ;;
  esac
}

# pp_resolve_st_log_url: ST check-run の details_url を解決する（取得失敗時は空文字列）。
# 入力: $1 = Issue 番号, $2 = merge commit SHA
# 出力（stdout）: details_url または空文字列
pp_resolve_st_log_url() {
  local merge_sha="$2"
  [ -n "$ST_CHECK_RUN_NAME" ] || { echo ""; return 0; }
  [ -n "$merge_sha" ] || { echo ""; return 0; }
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo ""
    return 0
  fi
  echo "$check_runs_json" | jq -r --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last
      | (.details_url // .html_url // "")' 2>/dev/null \
    || echo ""
}

# pp_do_revert: `BASE_BRANCH` 上で merge commit を `git revert -m 1` して
# `--force-with-lease` で push する（NFR 2.1）。サブシェル内で `trap` を仕掛けて
# `BASE_BRANCH` checkout 状態への復帰を保証する（NFR 2.3）。
#
# 入力: $1 = revert 対象の merge commit SHA
# 戻り値:
#   0 = revert + push 成功
#   1 = push 失敗（リモート先行等）。呼び出し元で st-failed 付与を保留（Req 2.4.6）
#   2 = revert 自体が失敗 / checkout / pull 失敗
pp_do_revert() {
  local merge_sha="$1"
  (
    set +e
    # 復帰用 trap: revert を中断したら `git revert --abort` し、$BASE_BRANCH に戻る
    trap 'git revert --abort >/dev/null 2>&1; git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git revert -m 1 --no-edit "$merge_sha" >/dev/null 2>&1; then
      exit 2
    fi
    # NFR 2.1: --force-with-lease のみ。--force 単独は使用しない
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 1
    fi
    exit 0
  )
}

# pp_handle_st_failure: ST failure と判定された Issue について、対応する merge
# commit を revert + push、Issue reopen、`st-failed` 付与、ST log URL を含む
# 1 件のコメント投稿を実施する（Req 2.4）。fail-continue を維持し、1 件失敗しても
# 他 Issue の処理は継続する（NFR 3.1）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 全操作成功 / 1 = いずれかが失敗（呼び出し元でカウンタにのみ反映）
pp_handle_st_failure() {
  local issue_number="$1"
  local merge_sha st_log_url
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    pp_warn "issue=#${issue_number} merge SHA 解決失敗 → ST failure 処理を見送り action=skip"
    return 1
  fi
  # AC 2.4.2: revert commit を作成して push。push 失敗 → st-failed 付与を保留
  local revert_rc=0
  pp_do_revert "$merge_sha" || revert_rc=$?
  case "$revert_rc" in
    0)
      :
      ;;
    1)
      # AC 2.4.6: push 失敗（リモート先行等）→ st-failed 保留 + WARN
      pp_warn "issue=#${issue_number} revert push 失敗（リモート先行等）→ st-failed 付与を保留 action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
    *)
      pp_warn "issue=#${issue_number} revert 自体に失敗（既に revert 済み等）→ ST failure 処理を見送り action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
  esac
  # AC 2.4.1 + 2.4.4: st-failed 付与 + staged-for-release 除去を 1 call に集約
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --add-label "$LABEL_ST_FAILED" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ラベル付与/除去に失敗（revert は実施済み） action=label-fail"
    # ラベル操作の失敗は致命的でないため、reopen / comment は継続する
  fi
  # AC 2.4.3: Issue reopen
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue reopen "$issue_number" --repo "$REPO" >/dev/null 2>&1; then
    # 既に open の場合や API エラーでも次の comment を試みる
    pp_warn "issue=#${issue_number} Issue reopen に失敗（既に open の可能性あり、comment 投稿は継続）"
  fi
  # AC 2.4.3: ST log URL を含む 1 件のステータスコメントを投稿
  st_log_url=$(pp_resolve_st_log_url "$issue_number" "$merge_sha")
  local comment_body
  comment_body=$(cat <<EOF
## 🔁 ST failure 自動 revert (Phase B Promote Pipeline)

\`${BASE_BRANCH}\` に merge された変更について、ST check-run **\`${ST_CHECK_RUN_NAME}\`** が
**failure** と判定されたため、watcher が \`git revert -m 1\` で自動 revert しました。

### Revert 対象 merge commit

- SHA (short): \`${merge_sha:0:7}\`
- ST log URL: ${st_log_url:-_(取得失敗)_}

### 推奨アクション

- ST failure の原因を確認し、修正用 PR を本 Issue にリンクして作成してください
- 本 Issue は \`st-failed\` ラベル付きで自動 reopen されています

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
)
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue comment "$issue_number" --repo "$REPO" \
        --body "$comment_body" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ステータスコメント投稿に失敗（revert / label / reopen は実施済み）"
  fi
  pp_log "issue=#${issue_number} ST=failure action=revert+label-add+label-remove+reopen+comment merge_sha=${merge_sha:0:7} label=${LABEL_ST_FAILED}"
  return 0
}

# pp_handle_st_success: ST success と判定された Issue から `staged-for-release`
# ラベルを除去し、promote 候補集合（PROMOTE_CANDIDATES）に追加する。
# `PROMOTE_MODE=on-demand` の場合はラベル除去 / 集合追加とも行わず、人間トリガー
# を待つ（Req 3.2.5）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 成功 / 1 = 失敗（fail-continue で呼び出し側がカウントのみ実施）
# Requirements: 2.3, 3.2
pp_handle_st_success() {
  local issue_number="$1"
  # AC 3.2.5: on-demand モードはラベルを除去せず、PROMOTE_CANDIDATES にも入れない
  if [ "$PROMOTE_MODE" = "on-demand" ]; then
    pp_log "issue=#${issue_number} ST=success mode=on-demand action=hold-label-await-human-trigger"
    return 0
  fi
  # AC 2.3.1: staged-for-release ラベルを除去
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ST=success staged-for-release 除去に失敗（後続 Issue は継続）"
    return 1
  fi
  # AC 2.3.2: promote 候補集合に追加
  PROMOTE_CANDIDATES+=("$issue_number")
  pp_log "issue=#${issue_number} ST=success action=label-remove+promote-queued label=${LABEL_STAGED_FOR_RELEASE}"
  return 0
}

# pp_process_one_issue: 1 件の Issue について ST 状態を取得し、状態別の
# アクション（success / failure / pending / missing / skip-warn）を実施する。
# 1 件の失敗が他 Issue 処理を止めないように戻り値で集計用カウンタにのみ反映
# する（NFR 3.1 fail-continue）。
#
# 入力: $1 = Issue 番号
# 副作用（成功時のみ加算する集計用変数、呼び出し側スコープで参照）:
#   PP_ST_SUCCESS_COUNT / PP_ST_FAILURE_COUNT / PP_ST_PENDING_COUNT /
#   PP_ST_MISSING_COUNT / PP_FAIL_COUNT
pp_process_one_issue() {
  local issue_number="$1"
  local st_state
  st_state=$(pp_get_st_state "$issue_number")
  case "$st_state" in
    success)
      if pp_handle_st_success "$issue_number"; then
        PP_ST_SUCCESS_COUNT=$((PP_ST_SUCCESS_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    failure)
      if pp_handle_st_failure "$issue_number"; then
        PP_ST_FAILURE_COUNT=$((PP_ST_FAILURE_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    pending)
      # AC 2.2.4: 未完了は次サイクルに持ち越す（ラベル変更なし）
      pp_log "issue=#${issue_number} ST=pending action=skip-next-cycle"
      PP_ST_PENDING_COUNT=$((PP_ST_PENDING_COUNT + 1))
      ;;
    missing)
      # AC 2.2.5: ST check-run が存在しない → WARN + 状態変更なし
      pp_warn "issue=#${issue_number} ST=missing action=skip（check-run 不在 or merge SHA 未解決）"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    skip-warn)
      # AC 2.2.3: ST_CHECK_RUN_NAME 未設定 → WARN + 当該サイクル no-op
      pp_warn "issue=#${issue_number} ST_CHECK_RUN_NAME 未設定 → ST 連動停止 action=skip"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    *)
      pp_warn "issue=#${issue_number} 未知の ST 状態 '${st_state}' action=skip"
      PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      ;;
  esac
  return 0
}

# pp_match_cron_field: 1 つの cron フィールド（分 / 時 / 日 / 月 / 曜日）を
# 現在値とマッチングする。標準 cron のサブパターン:
#   *           （任意の値にマッチ）
#   */N         （N で割り切れる値にマッチ）
#   A-B         （A 以上 B 以下にマッチ）
#   A,B,C       （いずれかの値にマッチ）
#   <整数>      （厳密一致）
#
# 入力: $1 = cron フィールド文字列, $2 = 現在値（整数）
# 戻り値: 0 = match / 1 = no match or 不正
pp_match_cron_field() {
  local field="$1"
  local value="$2"
  [ -n "$field" ] || return 1
  # 数値以外の現在値はマッチ不能
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  # `*` は全てにマッチ
  if [ "$field" = "*" ]; then
    return 0
  fi
  # `*/N` ステップ
  if [[ "$field" =~ ^\*/([0-9]+)$ ]]; then
    local step="${BASH_REMATCH[1]}"
    [ "$step" -gt 0 ] || return 1
    if [ $((10#$value % step)) -eq 0 ]; then
      return 0
    fi
    return 1
  fi
  # カンマ区切りリスト
  if [[ "$field" == *,* ]]; then
    local subfield
    IFS=',' read -ra _PP_CRON_PARTS <<< "$field"
    for subfield in "${_PP_CRON_PARTS[@]}"; do
      if pp_match_cron_field "$subfield" "$value"; then
        return 0
      fi
    done
    return 1
  fi
  # `A-B` レンジ
  if [[ "$field" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local lo="${BASH_REMATCH[1]}"
    local hi="${BASH_REMATCH[2]}"
    if [ "$((10#$value))" -ge "$lo" ] && [ "$((10#$value))" -le "$hi" ]; then
      return 0
    fi
    return 1
  fi
  # 単一整数
  if [[ "$field" =~ ^[0-9]+$ ]]; then
    if [ "$((10#$value))" -eq "$((10#$field))" ]; then
      return 0
    fi
    return 1
  fi
  return 1
}

# pp_match_cron: 標準 cron 5 フィールド式（分 時 日 月 曜日）を現在時刻と比較する。
# `date '+%M %H %d %m %u'` で取得した現在時刻と、cron 各フィールドを `pp_match_cron_field`
# でマッチング。全フィールド一致なら 0、いずれか不一致 / 不正な書式なら 1 を返す。
#
# 入力: $1 = cron 式（5 フィールドのみ。`@daily` 等の特殊文字列は非対応）
# 戻り値: 0 = 現在時刻が cron 式に一致 / 1 = 不一致 or 不正な書式
# Requirements: 3.2.4, 3.2.6
pp_match_cron() {
  local cron="$1"
  [ -n "$cron" ] || return 1
  # 5 フィールドに分解
  local -a fields
  # shellcheck disable=SC2206 # 意図的に IFS=space で分割
  fields=( $cron )
  if [ "${#fields[@]}" -ne 5 ]; then
    return 1
  fi
  local now_min now_hour now_day now_mon now_dow
  now_min=$(date '+%M')
  now_hour=$(date '+%H')
  now_day=$(date '+%d')
  now_mon=$(date '+%m')
  now_dow=$(date '+%u')   # 1=Mon, 7=Sun（cron では 0/7 が Sun のため両対応が望ましい）
  pp_match_cron_field "${fields[0]}" "$now_min"  || return 1
  pp_match_cron_field "${fields[1]}" "$now_hour" || return 1
  pp_match_cron_field "${fields[2]}" "$now_day"  || return 1
  pp_match_cron_field "${fields[3]}" "$now_mon"  || return 1
  # 曜日: cron では 0=Sun, 1=Mon..6=Sat。`date +%u` は 1=Mon..7=Sun のため、
  # まず %u で比較し、cron 0 表記は %u=7（日曜）に丸めて再比較する
  if ! pp_match_cron_field "${fields[4]}" "$now_dow"; then
    if [ "$now_dow" = "7" ] && pp_match_cron_field "${fields[4]}" "0"; then
      :
    else
      return 1
    fi
  fi
  return 0
}

# pp_do_promote_if_eligible: `PROMOTE_MODE` 3 モード（continuous / batched /
# on-demand）の dispatcher。実際の fast-forward push 本体 `pp_do_promote`
# は本関数から呼び出される（task 5.2 で実装）。
#
# Requirements: 3.2.2, 3.2.3, 3.2.4, 3.2.5, 3.2.6
pp_do_promote_if_eligible() {
  case "$PROMOTE_MODE" in
    continuous)
      # AC 3.2.3: 即時 promote。promote 候補が 0 件なら何もしない
      if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
        pp_do_promote
      else
        pp_log "mode=continuous promote 候補 0 件 → 本サイクルは promote なし"
      fi
      ;;
    batched)
      # AC 3.2.4 / 3.2.6: PROMOTE_CRON 一致時のみ実行
      if [ -z "$PROMOTE_CRON" ]; then
        pp_warn "mode=batched PROMOTE_CRON 未設定 → 本サイクルは promote なし"
        return 0
      fi
      if pp_match_cron "$PROMOTE_CRON"; then
        if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
          pp_do_promote
        else
          pp_log "mode=batched cron 一致だが promote 候補 0 件 → 本サイクルは promote なし"
        fi
      else
        # AC 3.2.6: cron 不一致 / 不正な式は本サイクル no-op + WARN
        pp_log "mode=batched PROMOTE_CRON='${PROMOTE_CRON}' 現在時刻と不一致 → 本サイクルは promote なし"
      fi
      ;;
    on-demand)
      # AC 3.2.5: 人間トリガー待ち。何もしない + log
      pp_log "mode=on-demand 人間トリガーを待つ → promote は実行しない"
      ;;
    *)
      # AC 3.2.2: 不正値も on-demand にフォールバック
      pp_warn "mode='${PROMOTE_MODE}' は未知の値 → on-demand にフォールバック（promote 実行しない）"
      ;;
  esac
}

# pp_do_promote: `BASE_BRANCH` HEAD を `PROMOTION_TARGET_BRANCH` に fast-forward
# push する（NFR 2.1, NFR 2.2）。サブシェル内で `trap` を仕掛けて操作終了時に
# `BASE_BRANCH` checkout 状態へ復帰する（NFR 2.3 / Req 3.1.4）。
#
# fast-forward 不可（`PROMOTION_TARGET_BRANCH` 側が `BASE_BRANCH` の祖先でない）と
# 判定した場合は push を中止し、`promote-failed` 識別語を含む WARN を出す
# （Req 3.1.2, 3.1.3, NFR 4.1）。Issue 側のラベル状態は変更しない。
#
# 戻り値: 0 = promote 成功 / 1 = promote 失敗（呼び出し元は集計のみ）
pp_do_promote() {
  local rc=0
  (
    set +e
    trap 'git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    # Req 3.1.1 準備: 最新の PROMOTION_TARGET_BRANCH を fetch
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git fetch origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
      pp_warn "promote-failed: fetch '$PROMOTION_TARGET_BRANCH' に失敗"
      pp_notify_promote_failure "fetch failed"
      exit 1
    fi
    # AC 3.1.2: PROMOTION_TARGET_BRANCH が BASE_BRANCH の祖先か確認。
    # 祖先でない場合 fast-forward 不可 → 中止 + WARN（Req 3.1.3）
    if ! git merge-base --is-ancestor \
        "origin/$PROMOTION_TARGET_BRANCH" "origin/$BASE_BRANCH" 2>/dev/null; then
      pp_warn "promote-failed: '$PROMOTION_TARGET_BRANCH' が '$BASE_BRANCH' の祖先でないため fast-forward 不可"
      pp_notify_promote_failure "non-fast-forward"
      exit 1
    fi
    # NFR 2.1 / 2.2: fast-forward 限定 push（--force 系オプションを付けず
    # 自然な ff push）。non-fast-forward は git server が reject する
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push origin \
          "refs/remotes/origin/${BASE_BRANCH}:refs/heads/${PROMOTION_TARGET_BRANCH}" \
          >/dev/null 2>&1; then
      pp_warn "promote-failed: fast-forward push に失敗"
      pp_notify_promote_failure "ff-push failed"
      exit 1
    fi
    pp_log "promote-success: '$BASE_BRANCH' -> '$PROMOTION_TARGET_BRANCH' fast-forward OK (candidates=${#PROMOTE_CANDIDATES[@]})"
    exit 0
  ) || rc=$?
  # 親シェル側カウンタを更新（サブシェル内で変更したカウンタは失われるため）
  if [ "$rc" -eq 0 ]; then
    PP_PROMOTE_SUCCESS_COUNT=$((PP_PROMOTE_SUCCESS_COUNT + 1))
  else
    PP_PROMOTE_FAILED_COUNT=$((PP_PROMOTE_FAILED_COUNT + 1))
  fi
  return "$rc"
}

# pp_notify_promote_failure: promote 失敗時の通知。`PROMOTE_FAIL_NOTIFY_ISSUE` が
# 数値で指定されていれば該当 Issue に 1 件コメント投稿、未設定 / 不正値なら log のみ
# （Req 3.3.2, 3.3.3）。
pp_notify_promote_failure() {
  local reason="$1"
  # AC 3.3.3: 未設定 / 不正値（数値以外）は log のみ
  if [ -z "$PROMOTE_FAIL_NOTIFY_ISSUE" ] \
     || ! [[ "$PROMOTE_FAIL_NOTIFY_ISSUE" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  # AC 3.3.2: 1 件のコメント投稿（失敗してもサイクルは継続）
  local body
  body=$(cat <<EOF
## ⚠️ Phase B Promote Pipeline: promote 失敗

\`${BASE_BRANCH}\` -> \`${PROMOTION_TARGET_BRANCH}\` への fast-forward 昇格に失敗しました。

- reason: \`${reason}\`
- base: \`${BASE_BRANCH}\`
- target: \`${PROMOTION_TARGET_BRANCH}\`

watcher サイクルは継続しています。手動確認をお願いします。

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
)
  timeout "$PROMOTE_GIT_TIMEOUT" \
    gh issue comment "$PROMOTE_FAIL_NOTIFY_ISSUE" --repo "$REPO" \
      --body "$body" >/dev/null 2>&1 \
    || pp_warn "PROMOTE_FAIL_NOTIFY_ISSUE=#${PROMOTE_FAIL_NOTIFY_ISSUE} へのコメント投稿に失敗"
}

# pp_summary: サイクル終了時のサマリログを 1 行で出力する。grep 集計用に
# `[$REPO] promote-pipeline: サマリ:` prefix と `key=value` 形式で出力する
# （Req 5.1.3, 5.1.5, NFR 4.1）。
pp_summary() {
  pp_log "サマリ: st-success-promoted=${PP_ST_SUCCESS_COUNT}, st-failure-reverted=${PP_ST_FAILURE_COUNT}, pending-skip=${PP_ST_PENDING_COUNT}, missing-skip=${PP_ST_MISSING_COUNT}, promote-success=${PP_PROMOTE_SUCCESS_COUNT}, promote-failed=${PP_PROMOTE_FAILED_COUNT}, fail=${PP_FAIL_COUNT}"
}

# process_promote_pipeline: Promote Pipeline Processor のエントリポイント。
#
# 引数: なし（env var で全制御）
# 戻り値: 常に 0（fail-continue を維持し、後続 Processor を止めない / NFR 3.1）
# 副作用:
#   - 対象 Issue へのラベル付与・除去（staged-for-release / st-failed）
#   - 対象 Issue の reopen + コメント投稿（ST failure 時）
#   - $BASE_BRANCH への revert commit + push（ST failure 時）
#   - $BASE_BRANCH → $PROMOTION_TARGET_BRANCH への fast-forward push（promote 成功時）
#   - $PROMOTE_FAIL_NOTIFY_ISSUE への 1 件コメント（promote 失敗時、env 設定時のみ）
process_promote_pipeline() {
  # AC 1.1.1, NFR 1.1: opt-in gate。`=true` 明示以外はすべて no-op で早期 return
  if [ "$PROMOTE_PIPELINE_ENABLED" != "true" ]; then
    return 0
  fi

  pp_log "サイクル開始 (base=${BASE_BRANCH}, target=${PROMOTION_TARGET_BRANCH}, mode=${PROMOTE_MODE}, timeout=${PROMOTE_GIT_TIMEOUT}s)"

  # AC 1.1.3, 1.2.2: 2-branch model gate + PROMOTION_TARGET_BRANCH のリモート存在検証
  if ! pp_resolve_target_branch; then
    return 0
  fi

  # NFR 2.3: dirty working tree gate。promote / revert は clean な作業ツリーが前提
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    pp_error "dirty working tree を検知。promote / revert を中止します。"
    return 0
  fi

  # AC 2.1: merge 済み PR からリンク Issue を抽出 → 未付与に staged-for-release を
  # 自動付与し、ST 判定対象（= 現在 staged-for-release を持つ全 open Issue）を取得。
  local target_issues
  target_issues=$(pp_collect_merged_issues || true)

  if [ -z "$target_issues" ]; then
    pp_log "サマリ: 対象 Issue なし（staged-for-release 付き Issue 0 件）"
    return 0
  fi

  # ST 判定対象 Issue 数を log に出力
  local target_count
  target_count=$(echo "$target_issues" | grep -c '^[0-9]' || true)
  pp_log "ST 判定対象: ${target_count} 件の Issue を検出"

  # 集計用カウンタと promote 候補集合を初期化（per-cycle 状態）
  PROMOTE_CANDIDATES=()
  PP_ST_SUCCESS_COUNT=0
  PP_ST_FAILURE_COUNT=0
  PP_ST_PENDING_COUNT=0
  PP_ST_MISSING_COUNT=0
  PP_FAIL_COUNT=0

  # AC 2.2〜2.4: 各 Issue について ST 状態取得 + アクション実施。
  # NFR 3.1: 1 件の失敗が他 Issue 処理を止めないよう `|| true` で吸収。
  local issue_number
  while IFS= read -r issue_number; do
    [ -n "$issue_number" ] || continue
    pp_process_one_issue "$issue_number" \
      || pp_warn "issue=#${issue_number} 想定外のエラー → 後続 Issue は継続"
  done <<< "$target_issues"

  # AC 3.1, 3.2: promote 候補集合を PROMOTE_MODE に応じて昇格実行。
  # 集計用カウンタは pp_do_promote / pp_do_promote_if_eligible 内部で更新する。
  PP_PROMOTE_SUCCESS_COUNT=0
  PP_PROMOTE_FAILED_COUNT=0
  # NFR 3.1: 失敗時も後続処理を止めないため `|| true` で吸収
  pp_do_promote_if_eligible || true

  # AC 5.1.3: サイクル終了時のサマリログを 1 行で出力
  pp_summary
}
