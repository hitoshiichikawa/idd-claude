#!/usr/bin/env bash
# shellcheck shell=bash
# adjudicator.sh — watcher の PR Reviewer Adjudicator モジュール (#404)
#
# 用途:
#   issue-watcher.sh から分離した PR Reviewer Adjudicator (#404) の関数定義を集約する。
#   `PR_REVIEWER_ADJUDICATOR_ENABLED=true` のとき codex 由来のレビュー指摘
#   （`pr-reviewer.sh` の `pr_run_review_for_pr` が PR コメントに投稿した本文）を入力に
#   各指摘を **legitimate（実害）** / **excessive（過剰）** に分類する Claude adjudicator
#   ステップを提供し、`needs-iteration` ラベル + `claude-review` commit status の最終確定権を
#   adjudicator 側に移譲する。設計の詳細は
#   docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/design.md を参照。
#
#   - opt-in gate 判定: adj_gate_enabled
#     既に正規化済みの `PR_REVIEWER_ADJUDICATOR_ENABLED`（issue-watcher.sh:685-690 で
#     `case true) ... *) false` に正規化済み）を厳密 `=true` で評価する。重複正規化は
#     行わない（既定値の責任は呼び出し側 / Req 5.1）。
#   - codex 指摘 parse: adj_extract_findings
#     codex stdout の `## 指摘事項` 配下 bullet 行を awk で抽出し、JSON 配列化する。
#     reconciliation check 内蔵: `## 指摘事項` 配下の bullet 総数と parse 件数を突合し、
#     不一致を検出した場合は WARN を stderr に出し戻り値 4 を返す（書式ドリフトによる
#     silent 取りこぼし防止 / ae-mdm 設計レビュー #4 / Req 1.1, 5.5）。
#
#   後続関数（adj_classify_findings / adj_validate_decisions / adj_apply_label_decision /
#   adj_read_reviewer_verdict / adj_apply_status_decision / adj_post_decision_comment /
#   adj_run_for_pr / pr_catchup_should_defer_for_adjudicator）は task 4-6 で追加予定。
#
# 配置先:
#   $HOME/bin/modules/adjudicator.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - 関数 prefix `adj_` で namespace する（CLAUDE.md「機能追加ガイドライン §2」登録済み）。
#   - ロガー adj_log / adj_warn / adj_error は core_utils.sh に定義済み（#404 task 1 で追加）。
#     本モジュールは bash の遅延束縛で参照するのみで、再定義しない。
#   - グローバル変数（$REPO / $PR_REVIEWER_ADJUDICATOR_ENABLED 他 5 env）は本体冒頭の
#     Config ブロックで定義済み（issue-watcher.sh:685-728 / task 1 で追加）。本モジュールは
#     env を消費するのみで、再宣言・再正規化しない。
#   - 外部 CLI: jq（指摘 JSON 化に使用）。
#
# セットアップ参照先:
#   - 要件: docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/requirements.md
#   - 設計: docs/specs/404-feat-pr-reviewer-codex-advisory-claude-a/design.md
#   - README「PR Reviewer Adjudicator (#404)」節（task 8 で追加予定）

# ─────────────────────────────────────────────────────────────────────────────
# adj_gate_enabled: opt-in gate 評価（既に正規化済みの env を厳密一致で判定）
#   入力: なし（env のみ参照）
#   出力: なし
#   戻り値: 0 = ON / 1 = OFF
#
#   issue-watcher.sh:685-690 の Config ブロックで `PR_REVIEWER_ADJUDICATOR_ENABLED` は
#   `case true) ... *) false` で正規化されているため、本関数は厳密 `=true` 判定のみ行う
#   （既定 / 未設定 / typo / 大文字違い等はすべて OFF / Req 5.1 安全側 / 重複正規化はしない）。
# ─────────────────────────────────────────────────────────────────────────────
adj_gate_enabled() {
  if [ "${PR_REVIEWER_ADJUDICATOR_ENABLED:-false}" = "true" ]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_extract_findings: codex stdout から `## 指摘事項` 配下の bullet 行を抽出し JSON 配列化
#   入力: $1 = review_text（codex stdout の全文）
#   出力: stdout に [{"severity":"high|medium|low","file":"...","line":N,"message":"..."}, ...]
#         （指摘ゼロ / `## 指摘事項` 不在 / 「指摘なし」のみの場合は `[]` を出力）
#   戻り値: 0 = ok / 4 = reconciliation mismatch（呼び出し元で fail-safe へ倒す）
#
#   アルゴリズム（design.md Components and Interfaces 節の関数 contract 準拠）:
#     1. awk で `## 指摘事項` 見出しを探し、その下から次の `## ` 始まり見出し（または EOF）
#        までを抽出範囲とする。
#     2. 抽出範囲内で行頭が `- ` で始まる bullet 行をすべて数える（reconciliation 用 total）。
#     3. うち書式
#          - [high|medium|low] <file>:<line> — <内容>
#        に厳密一致するもののみ parse して TSV を吐く（severity / file / line / message）。
#        `—` は em dash (U+2014) で codex 出力テンプレ (`pr_default_prompt`) と整合。
#     4. TSV 各行を jq で JSON object 化し、`jq -s '.'` で配列化（未信頼入力は
#        `--arg` でリテラル渡し / jq filter inline 展開禁止 / CLAUDE.md §5 整合）。
#     5. bullet 総数 != parse 件数を検出した場合は WARN を stderr に出し戻り値 4 を返す。
#        ただし「指摘なし」のみ（bullet 総数 0、行頭プレーン 1 行のみ）は reconcile 対象外
#        として `[]` rc=0 で返す（codex VERDICT 経路の通常成功ケース）。
# ─────────────────────────────────────────────────────────────────────────────
adj_extract_findings() {
  local review_text="${1:-}"

  # awk で `## 指摘事項` 見出しから次 `## ` 見出し or EOF までを抽出。
  # 抽出結果は (a) bullet 総数 (b) parse 成功 TSV の 2 つを同時に算出するため、
  # awk 内で 2 系統の出力（"BULLET_TOTAL=<N>" 1 行 + parse 成功 TSV 行群）を吐き、
  # 呼び出し側で分離する。
  local awk_out
  awk_out=$(awk '
    BEGIN {
      in_section = 0
      bullet_total = 0
    }
    # 範囲開始: 行 trim 後が "## 指摘事項" に一致
    {
      line = $0
      # rtrim
      sub(/[[:space:]]+$/, "", line)
    }
    /^## 指摘事項[[:space:]]*$/ {
      in_section = 1
      next
    }
    # 範囲終了: 次の "## " 始まり見出し（"## 指摘事項" は上で処理済み）
    in_section && /^## / {
      in_section = 0
      next
    }
    in_section {
      # bullet 行（行頭が "- "）をカウント
      if (line ~ /^- /) {
        bullet_total++
        # 厳密 parse: "- [high|medium|low] <file>:<line> — <内容>"
        # em dash は U+2014（UTF-8: 0xE2 0x80 0x94）。bash の文字列リテラル経由で awk に
        # 渡される正規表現中の "—" はそのまま UTF-8 byte 列としてマッチする。
        if (match(line, /^- \[(high|medium|low)\] [^[:space:]:]+:[0-9]+ — /)) {
          # severity: [<sev>] を抽出
          sev = line
          sub(/^- \[/, "", sev)
          sub(/\].*$/, "", sev)
          # file:line を抽出（severity 部の後）
          rest = line
          sub(/^- \[(high|medium|low)\] /, "", rest)
          # rest は "<file>:<line> — <内容>" の形
          # "<file>:<line>" 部分を切り出し（最初の " — " で分割）
          pos = index(rest, " — ")
          if (pos > 0) {
            head = substr(rest, 1, pos - 1)
            msg  = substr(rest, pos + length(" — "))
            # head の最後の ":" で file と line を分割（file 名に "." は含まれ得るが ":" は含まない前提）
            colon = 0
            for (i = length(head); i >= 1; i--) {
              if (substr(head, i, 1) == ":") { colon = i; break }
            }
            if (colon > 0) {
              fil = substr(head, 1, colon - 1)
              lin = substr(head, colon + 1)
              # line は [0-9]+ のみであることを念のため検査
              if (lin ~ /^[0-9]+$/) {
                # TSV: severity \t file \t line \t message
                # awk の "\t" はタブ文字。message 中のタブは存在しない前提（codex 出力にタブはない）。
                printf "PARSED\t%s\t%s\t%s\t%s\n", sev, fil, lin, msg
              }
            }
          }
        }
      }
    }
    END {
      printf "BULLET_TOTAL=%d\n", bullet_total
    }
  ' <<<"$review_text")

  # awk_out の最後の "BULLET_TOTAL=<N>" 行を抽出し、それ以外の PARSED 行を parse 成功分とする。
  local bullet_total parsed_lines
  bullet_total=$(printf '%s\n' "$awk_out" | grep -E '^BULLET_TOTAL=[0-9]+$' | tail -n 1 | sed 's/^BULLET_TOTAL=//')
  parsed_lines=$(printf '%s\n' "$awk_out" | grep -E '^PARSED\b' || true)

  if [ -z "$bullet_total" ]; then
    bullet_total=0
  fi

  # parse 成功件数
  local parsed_count=0
  if [ -n "$parsed_lines" ]; then
    parsed_count=$(printf '%s\n' "$parsed_lines" | wc -l | tr -d '[:space:]')
  fi

  # JSON 配列化: TSV 各行を jq で object 化 → `jq -s '.'` で配列化
  # 未信頼入力（codex 出力 / PR コメント由来）は `--arg` でリテラル渡し（jq filter inline 展開禁止）。
  local json_out
  if [ "$parsed_count" -eq 0 ]; then
    json_out="[]"
  else
    json_out=$(printf '%s\n' "$parsed_lines" | while IFS=$'\t' read -r _marker sev fil lin msg; do
      jq -nc \
        --arg severity "$sev" \
        --arg file "$fil" \
        --argjson line "$lin" \
        --arg message "$msg" \
        '{severity: $severity, file: $file, line: $line, message: $message}'
    done | jq -sc '.')
  fi

  printf '%s\n' "$json_out"

  # reconciliation check: bullet 総数 != parse 件数を検出した場合は WARN + rc=4。
  # ただし bullet 総数 0（`## 指摘事項` 見出し配下に bullet 行が 1 件も無い / 「指摘なし」
  # プレーン行のみのケース）は reconcile 対象外。
  if [ "$bullet_total" -gt 0 ] && [ "$bullet_total" -ne "$parsed_count" ]; then
    adj_warn "reconciliation mismatch: bullets=${bullet_total} parsed=${parsed_count}"
    return 4
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_classify_findings: Claude adjudicator を 1 回呼び出し、各指摘に分類を付与
#   入力: $1 = pr_number
#         $2 = sha (head sha; 7〜40 桁 hex)
#         $3 = findings_json (adj_extract_findings 出力。JSON 配列文字列)
#         $4 = spec_dir_hint (絶対パス。空 / 不在なら `(none)` 埋め込み)
#         $5 = base_ref (省略時 `(none)`)
#         $6 = head_ref (省略時 `(none)`)
#   出力: stdout に [{"id":N,"severity":"...","file":"...","line":N,
#                     "verdict":"legitimate|excessive","reason":"..."}, ...] を含む
#         decisions JSON object（adjudicator-prompt.tmpl の出力契約と同形 /
#         `{"decisions":[...],"summary":{...}}`）
#   戻り値: 0 = ok / 1 = claude exec 失敗 (timeout / rc!=0 / prompt 解決失敗)
#           2 = JSON parse 失敗（claude 出力本文から JSON 抽出不能 / valid でない）
#           3 = workspace-modified 検出（read-only invariant 違反）
#
#   引数構成の根拠（impl-notes に記録）:
#     - design.md interface 表は厳密 4 引数だが、adjudicator-prompt.tmpl の `{BASE}` /
#       `{HEAD}` placeholder 流し込みのため base_ref / head_ref を追加引数 5,6 で受ける
#       （pr-reviewer.sh の pr_execute_review_command でも同様の契約拡張の前例あり）。
#     - `{REVIEW_TEXT}` placeholder は findings_json を `## 指摘事項` 形式に再構成して
#       渡す（候補 B / contract 厳守 + stub claude テストでの prompt 置換検証容易性）。
#       これにより呼び出し元が review_text 全文を保持する必要がなく、stub テストでも
#       findings_json のみで擬似実行できる。
#
#   アルゴリズム:
#     1. PR 番号 / SHA / base_ref / head_ref の shell metachar 検査
#        （pr_substitute_placeholders 流。review_text は claude prompt 本文に渡るのみで
#        shell には展開されないため本関数では検査しない / design.md Security Considerations
#        「shell metacharacter 検査」項）。
#     2. PR 番号 = ^[0-9]+$ / SHA = ^[0-9a-f]{7,40}$ の strict 検証。
#     3. findings_json が `[]` / 空文字なら早期 return（`{"decisions":[],"summary":...}`
#        を stdout に流して rc=0）。claude を起動しない。
#     4. prompt 本文の解決順序:
#        a. `PR_REVIEWER_ADJUDICATOR_PROMPT` env が非空 → その値を本文として直接使う
#           （pr-reviewer.sh の `PR_REVIEWER_PROMPT` と同 semantics）。
#        b. 空なら `$HOME/bin/adjudicator-prompt.tmpl` をファイルから読む（既定）。
#        c. ファイル不在 / HOME 解決不能 → adj_warn + rc=1。
#     5. プレースホルダ置換: `{PR}` / `{SHA}` / `{BASE}` / `{HEAD}` / `{REVIEW_TEXT}` /
#        `{SPEC_DIR}` / `{REQUIREMENTS_MD}` を bash パラメータ展開で置換。
#        - {REVIEW_TEXT} は findings_json から `## 指摘事項` bullet 行を再構成
#        - {SPEC_DIR} は空 / dir 不在なら `(none)` を埋める
#        - {REQUIREMENTS_MD} は `${spec_dir}/requirements.md` を cat、不在なら `(none)`
#     6. mktemp で prompt 一時ファイル作成 + 本文書き込み（trap で削除）。
#     7. claude 起動:
#          timeout "$PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT" \
#            claude -p "$(cat "$prompt_file")" --output-format json \
#                   --permission-mode plan --model "$PR_REVIEWER_ADJUDICATOR_MODEL"
#        `--permission-mode plan` は Claude 側で Bash / Edit / Write を構造的にブロックする
#        defense-in-depth（design.md Security Considerations 第 4 項：bypassPermissions 不使用）。
#     8. read-only invariant 検査: 実行直後に `git status --porcelain` でワークツリー変更
#        検出。検出時は `git checkout -- .` で tracked 変更を破棄し rc=3 を返す
#        （pr_execute_review_command Decision 8 流用 / design.md Security Considerations
#        「claude プロンプトの read-only 制約」）。
#     9. claude --output-format json は `{"type":"result","subtype":"success","result":"...", ...}`
#        を返す（SDK 標準）。`jq -r '.result // empty'` で本文を抜き、本文中の JSON を
#        再 parse して stdout に流す。本文中に前置き散文や code fence が混入する case に
#        備え、最終的に `jq -e '.'` で valid JSON 検証してから返す。
#
#   注意: fallback モード（`PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL`）の適用は **呼び出し元
#         adj_run_for_pr（task 6 のスコープ）の責務**。本関数は rc を返すだけ。
# ─────────────────────────────────────────────────────────────────────────────
adj_classify_findings() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local findings_json="${3:-}"
  local spec_dir_hint="${4:-}"
  local base_ref="${5:-}"
  local head_ref="${6:-}"

  # PR 番号 / SHA strict 検証（design.md Security Considerations / pr-reviewer.sh の hardening 踏襲）
  case "$pr_number" in
    ''|*[!0-9]*)
      adj_warn "adj_classify_findings: PR 番号が不正 (pr='${pr_number}')"
      return 1
      ;;
  esac
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    adj_warn "adj_classify_findings: SHA が不正 (sha='${sha}')"
    return 1
  fi

  # shell metacharacter 検査（pr_number / sha / base / head に対し / review_text は対象外）
  local v
  for v in "$pr_number" "$sha" "$base_ref" "$head_ref"; do
    # shellcheck disable=SC2016  # 単一引用符内の $( は意図した「リテラル文字列の検出パターン」
    case "$v" in
      *';'* | *'|'* | *'&'* | *'`'* | *'$('* )
        adj_warn "adj_classify_findings: shell metacharacter 検出 (pr='${pr_number}' sha='${sha}' base='${base_ref}' head='${head_ref}')"
        return 1
        ;;
    esac
  done

  # findings_json 早期 return（空配列 / 空文字なら claude を起動しない）
  if [ -z "$findings_json" ] || [ "$findings_json" = "[]" ]; then
    printf '%s\n' '{"decisions":[],"summary":{"total":0,"legitimate":0,"excessive":0}}'
    return 0
  fi

  # findings_json valid JSON 配列か検証
  local findings_count
  if ! findings_count=$(printf '%s' "$findings_json" | jq -e 'if type=="array" then length else error("not-array") end' 2>/dev/null); then
    adj_warn "adj_classify_findings: findings_json が valid JSON 配列ではない"
    return 1
  fi
  if [ "$findings_count" -eq 0 ]; then
    printf '%s\n' '{"decisions":[],"summary":{"total":0,"legitimate":0,"excessive":0}}'
    return 0
  fi

  # prompt 本文の解決（env override → tmpl ファイル）
  local prompt_body=""
  if [ -n "${PR_REVIEWER_ADJUDICATOR_PROMPT:-}" ]; then
    prompt_body="${PR_REVIEWER_ADJUDICATOR_PROMPT}"
  else
    local home_dir="${HOME:-}"
    if [ -z "$home_dir" ]; then
      adj_warn "adj_classify_findings: HOME 解決不能のため adjudicator-prompt.tmpl を読めません"
      return 1
    fi
    local tmpl_path="${home_dir}/bin/adjudicator-prompt.tmpl"
    if [ ! -f "$tmpl_path" ]; then
      adj_warn "adj_classify_findings: ${tmpl_path} が存在しません"
      return 1
    fi
    if ! prompt_body=$(cat "$tmpl_path" 2>/dev/null); then
      adj_warn "adj_classify_findings: ${tmpl_path} の読み込みに失敗"
      return 1
    fi
  fi

  # {REVIEW_TEXT} 用に findings_json から `## 指摘事項` 形式の bullet 行を再構成。
  # 未信頼入力（codex 出力由来）は jq の --argjson でリテラル渡し、filter inline 展開禁止。
  local review_text_body
  review_text_body=$(printf '%s' "$findings_json" | jq -r '
    "## 指摘事項\n" +
    ([.[] | "- [\(.severity)] \(.file):\(.line) — \(.message)"] | join("\n"))
  ' 2>/dev/null) || {
    adj_warn "adj_classify_findings: findings_json から REVIEW_TEXT 再構成に失敗"
    return 1
  }

  # {SPEC_DIR} / {REQUIREMENTS_MD} 解決
  local spec_dir_val="(none)"
  local requirements_md_val="(none)"
  if [ -n "$spec_dir_hint" ] && [ -d "$spec_dir_hint" ]; then
    spec_dir_val="$spec_dir_hint"
    local req_path="${spec_dir_hint}/requirements.md"
    if [ -f "$req_path" ]; then
      requirements_md_val=$(cat "$req_path" 2>/dev/null) || requirements_md_val="(none)"
    fi
  fi

  # base / head の `(none)` 既定値
  local base_val="${base_ref:-(none)}"
  local head_val="${head_ref:-(none)}"
  [ -z "$base_val" ] && base_val="(none)"
  [ -z "$head_val" ] && head_val="(none)"

  # プレースホルダ置換（bash パラメータ展開 / 既存 pr_substitute_placeholders 流）
  local rendered="$prompt_body"
  rendered="${rendered//\{PR\}/$pr_number}"
  rendered="${rendered//\{SHA\}/$sha}"
  rendered="${rendered//\{BASE\}/$base_val}"
  rendered="${rendered//\{HEAD\}/$head_val}"
  rendered="${rendered//\{REVIEW_TEXT\}/$review_text_body}"
  rendered="${rendered//\{SPEC_DIR\}/$spec_dir_val}"
  rendered="${rendered//\{REQUIREMENTS_MD\}/$requirements_md_val}"

  # mktemp で prompt 一時ファイル / 出力 tempfile を作成し、trap で削除（security-review.sh pattern）
  local prompt_file out_file err_file
  if ! prompt_file=$(mktemp -t idd-claude-adjudicator-prompt.XXXXXX 2>/dev/null); then
    adj_warn "adj_classify_findings: prompt 一時ファイル作成に失敗"
    return 1
  fi
  if ! out_file=$(mktemp -t idd-claude-adjudicator-out.XXXXXX 2>/dev/null); then
    rm -f "$prompt_file" 2>/dev/null || true
    adj_warn "adj_classify_findings: out tempfile 作成に失敗"
    return 1
  fi
  if ! err_file=$(mktemp -t idd-claude-adjudicator-err.XXXXXX 2>/dev/null); then
    rm -f "$prompt_file" "$out_file" 2>/dev/null || true
    adj_warn "adj_classify_findings: err tempfile 作成に失敗"
    return 1
  fi
  # shellcheck disable=SC2064
  trap "rm -f '$prompt_file' '$out_file' '$err_file' 2>/dev/null || true" RETURN

  printf '%s' "$rendered" > "$prompt_file"

  # claude CLI 起動。`--permission-mode plan` で write 系ツールを Claude 側でブロック
  # （design.md Security Considerations 第 4 項 / bypassPermissions 不使用）。
  # `eval` は使わず timeout + claude を直接呼ぶ。
  local exec_rc=0
  local timeout_s="${PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT:-300}"
  local model="${PR_REVIEWER_ADJUDICATOR_MODEL:-claude-sonnet-4-5}"

  timeout "$timeout_s" claude \
    -p "$(cat "$prompt_file")" \
    --output-format json \
    --permission-mode plan \
    --model "$model" \
    >"$out_file" 2>"$err_file" || exec_rc=$?

  # read-only invariant 検査（実行直後 / pr_execute_review_command Decision 8 流用）。
  # adjudicator は claude を read-only で起動するが、defense-in-depth として
  # ワークツリー変更を検出した場合は tracked 変更を破棄し rc=3 を返す。
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git checkout -- . >/dev/null 2>&1 || true
    adj_warn "adj_classify_findings: workspace-modified を検出（read-only 違反）"
    return 3
  fi

  if [ "$exec_rc" -ne 0 ]; then
    local err_excerpt
    err_excerpt=$(tail -c 512 "$err_file" 2>/dev/null || true)
    adj_warn "adj_classify_findings: claude exec 失敗 (rc=${exec_rc}, err_tail='${err_excerpt}')"
    return 1
  fi

  # claude --output-format json の出力は SDK 標準フォーマット
  # `{"type":"result","subtype":"success","result":"<本文>", ...}` で、`result` フィールドに
  # adjudicator-prompt.tmpl の出力契約に従う JSON 本文が文字列として埋め込まれている。
  local result_body
  result_body=$(jq -r '.result // empty' "$out_file" 2>/dev/null) || {
    adj_warn "adj_classify_findings: claude 出力のトップレベル JSON parse 失敗"
    return 2
  }
  if [ -z "$result_body" ]; then
    adj_warn "adj_classify_findings: claude 出力に .result が含まれない"
    return 2
  fi

  # result 本文中に前置き散文や code fence が混入する case に備え、最初の `{` から
  # 最後の `}` までを雑に切り出す（防御的）。
  local stripped
  stripped=$(printf '%s' "$result_body" | awk '
    BEGIN { started = 0; depth = 0 }
    {
      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)
        if (!started) {
          if (ch == "{") { started = 1; depth = 1; printf "%s", ch }
        } else {
          printf "%s", ch
          if (ch == "{") depth++
          else if (ch == "}") {
            depth--
            if (depth == 0) { printf "\n"; exit }
          }
        }
      }
      if (started) printf "\n"
    }
  ')

  # 最終 valid JSON 検証
  if ! printf '%s' "$stripped" | jq -e '.' >/dev/null 2>&1; then
    adj_warn "adj_classify_findings: 切り出した本文が valid JSON でない"
    return 2
  fi

  printf '%s\n' "$stripped"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# adj_validate_decisions: 分類 JSON の妥当性を schema 検証
#   入力: $1 = findings_json (adj_extract_findings 出力)
#         $2 = decisions_json (adj_classify_findings 出力。
#              `{"decisions":[...],"summary":{...}}` 形)
#   戻り値: 0 = valid / 1 = invalid（呼び出し元で fail-safe = 全件 legitimate に倒す /
#                                    Req 1.4「迷ったら legitimate」の徹底）
#   出力: stdout 出力なし。invalid 検出時のみ adj_warn を 1 行 stderr に出す。
#
#   検証項目（adjudicator-prompt.tmpl の出力契約 / design.md「Data Models」と整合）:
#     1. decisions_json が valid JSON object かつ `.decisions` が array で、
#        `.summary` が object であること
#     2. findings_json が `[]` / 空配列なら decisions も `[]` であること
#        （空でないなら schema 不整合扱い）
#     3. `length(.decisions) == length(findings_json)`（件数一致 / Req 1.5）
#     4. 各 decisions 要素に `id` / `verdict` / `reason` が存在し、`verdict` が
#        `legitimate` または `excessive` 厳密一致であること
#     5. decisions の `id` フィールドが 1〜N の連番（軽い sanity check / adjudicator-prompt.tmpl
#        の id 採番規約「登場順に 1, 2, 3 と独立採番」と整合）
#     6. `summary.total == length(.decisions)` かつ
#        `summary.legitimate + summary.excessive == summary.total`
#
#   invalid 時の呼び出し元責務:
#     - 呼び出し元 adj_run_for_pr（task 6 のスコープ）は本関数が rc=1 を返した場合、
#       全 finding を legitimate と扱う sentinel に倒す（Req 1.4 保守的判定の徹底）。
#     - 本関数自体は sentinel 値を返さない（rc のみで invalid を伝える）。
# ─────────────────────────────────────────────────────────────────────────────
adj_validate_decisions() {
  local findings_json="${1:-}"
  local decisions_json="${2:-}"

  # findings_json の件数算出（不正なら 0 扱い）
  local findings_count=0
  if [ -n "$findings_json" ]; then
    findings_count=$(printf '%s' "$findings_json" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null) || findings_count=0
    case "$findings_count" in
      ''|*[!0-9]*) findings_count=0 ;;
    esac
  fi

  # decisions_json は valid JSON object でかつ `.decisions` が array、`.summary` が object か
  if [ -z "$decisions_json" ]; then
    adj_warn "validation failed: decisions_json が空"
    return 1
  fi
  if ! printf '%s' "$decisions_json" | jq -e 'type == "object" and (.decisions | type == "array") and (.summary | type == "object")' >/dev/null 2>&1; then
    adj_warn "validation failed: decisions_json が JSON object でないか .decisions/.summary 構造が不正"
    return 1
  fi

  local decisions_count
  decisions_count=$(printf '%s' "$decisions_json" | jq -r '.decisions | length' 2>/dev/null)
  case "$decisions_count" in
    ''|*[!0-9]*) decisions_count=0 ;;
  esac

  # findings が空 → decisions も空でなければ不整合
  if [ "$findings_count" -eq 0 ]; then
    if [ "$decisions_count" -ne 0 ]; then
      adj_warn "validation failed: findings 空だが decisions=${decisions_count} 件"
      return 1
    fi
    # findings 空 + decisions 空 → 妥当
    return 0
  fi

  # 件数一致（Req 1.5）
  if [ "$decisions_count" -ne "$findings_count" ]; then
    adj_warn "validation failed: 件数不一致 findings=${findings_count} decisions=${decisions_count}"
    return 1
  fi

  # 各 decisions 要素に id / verdict / reason が存在し、verdict が legitimate|excessive 厳密一致か
  if ! printf '%s' "$decisions_json" | jq -e '
    .decisions | all(
      (has("id") and (.id | type == "number")) and
      (has("verdict") and (.verdict == "legitimate" or .verdict == "excessive")) and
      (has("reason") and (.reason | type == "string"))
    )
  ' >/dev/null 2>&1; then
    adj_warn "validation failed: decisions 各要素の id/verdict/reason 検証失敗"
    return 1
  fi

  # id が 1〜N の連番（軽い sanity check / adjudicator-prompt.tmpl の id 採番規約と整合）
  if ! printf '%s' "$decisions_json" | jq -e --argjson n "$decisions_count" '
    ([.decisions[].id] | sort) == ([range(1; $n + 1)])
  ' >/dev/null 2>&1; then
    adj_warn "validation failed: id が 1〜${decisions_count} の連番でない"
    return 1
  fi

  # summary 検証: summary.total == decisions count / summary.legitimate + excessive == total
  if ! printf '%s' "$decisions_json" | jq -e --argjson n "$decisions_count" '
    (.summary.total == $n) and
    ((.summary.legitimate + .summary.excessive) == .summary.total) and
    (.summary.legitimate == ([.decisions[] | select(.verdict == "legitimate")] | length)) and
    (.summary.excessive == ([.decisions[] | select(.verdict == "excessive")] | length))
  ' >/dev/null 2>&1; then
    adj_warn "validation failed: summary 集計が decisions の verdict 集計と不整合"
    return 1
  fi

  return 0
}
