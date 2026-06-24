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
