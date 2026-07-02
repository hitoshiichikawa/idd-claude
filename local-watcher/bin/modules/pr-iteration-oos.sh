#!/usr/bin/env bash
# shellcheck shell=bash
# pr-iteration-oos.sh — out-of-scope 還流 / 検出 / 内容ベース no-progress（Issue #437）
#
# family: pr-iteration / prefix: pi_（#469 で pr-iteration.sh から分割。family マニフェストは
#   pr-iteration.sh 冒頭ヘッダを参照）
#
# 用途:
#   adjudicator / Developer が out-of-scope と判定した指摘を既定経路（needs-decisions）へ
#   還流し、内容ベース fingerprint による no-progress 早期打ち切りを行う（Issue #437）。
#   gate PR_ITERATION_OOS_ENABLED=true のときのみ実効（既定 OFF では呼び出し元・本関数とも
#   no-op で既存フロー byte 互換 / NFR 1.1）。
#   - 還流ルーティング: pi_route_out_of_scope_escalate
#   - Developer マーカー検出: pi_detect_developer_oos_marker
#   - fingerprint / 内容ベース streak: pi_oos_fingerprint / pi_read_oos_no_progress_streak /
#     pi_read_oos_fingerprint / pi_next_oos_no_progress_streak
#
# 配置先:
#   $HOME/bin/modules/pr-iteration-oos.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - ロガー pi_log / pi_warn は core_utils.sh。グローバル（$REPO / $PR_ITERATION_OOS_ENABLED /
#     $PR_ITERATION_OOS_ROUTE / $PR_ITERATION_GIT_TIMEOUT / $LABEL_NEEDS_DECISIONS /
#     $LABEL_NEEDS_ITERATION 等）は watcher-config.sh。
#   - 外部 CLI: gh / jq / sha256sum（不能環境は cksum フォールバック） / grep / sed。

# ─────────────────────────────────────────────────────────────────────────────
# pi_route_out_of_scope_escalate: out-of-scope 指摘を既定経路へ還流する共通ヘルパ
#   入力: $1=pr_number, $2=sha, $3=decisions_json（adjudicator 由来 / 空文字列許容）,
#         $4=source_kind（"adjudicator" | "developer-marker" | "no-progress" 等の観測ラベル）,
#         $5=out_of_scope_count（観測ログ用 / 空なら "?" 表示）
#   出力: なし（pi_log / pi_warn のみ）
#   戻り値: 0=ok（ルーティング実施 / 冪等 skip 含む）/ 2=入力検証失敗
#   Issue #437 Req 3.1 / 3.2 / 3.3 / 3.4 / 3.5 / 5.2 / NFR 3.3 / NFR 4.1
#
#   設計判断（design.md Components and Interfaces / pi_route_out_of_scope_escalate 節）:
#     - adjudicator 経路（adj_route_out_of_scope）と Developer marker / 内容ベース no-progress
#       経路（pi_run_iteration）の 2 経路から共通呼び出しされる単一ルーティング実体。
#     - ルート解決: PR_ITERATION_OOS_ROUTE が `needs-decisions`（既定）→ `needs-iteration`
#       除去 + `needs-decisions` 付与 + 追跡コメント投稿。`design-reflow` / `spawn-issue` は
#       本 spec では未実装で `needs-decisions` に正規化する（issue-watcher.sh:795- の env 正規化と
#       二重防御。env 値だけ将来予約 / design.md 確認事項 2 / Non-Goal）。
#     - 冪等性（Req 3.5）: 投稿コメントに hidden marker
#       `<!-- idd-claude:pr-iteration-oos-routed sha=<sha> -->` を付与し、同一 PR・同一 SHA で
#       既存 marker 検出時は再ルーティングを skip する。
#     - 失敗時（ラベル付与 / コメント投稿）は WARN 1 行を残し silent fail しない（Req 3.4）。
#       既存の needs-iteration 据え置き挙動を壊さないよう rc=0 で返す（安全側）。
#     - 観測ログ（NFR 4.1）: `reason=out-of-scope route=<route>` を含む 1 行を機械抽出可能形式で出力。
#     - 未信頼値（reason / file / message）は jq --arg / @tsv でリテラル抽出してから printf へ渡す
#       （filter inline 展開禁止 / CLAUDE.md §5）。gh へは `--` を付与しオプション注入を防ぐ（NFR 3.3）。
# ─────────────────────────────────────────────────────────────────────────────
pi_route_out_of_scope_escalate() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local decisions_json="${3:-}"
  local source_kind="${4:-unknown}"
  local out_of_scope_count="${5:-?}"

  # gate OFF（既定）→ 即 return 0（防御的二重確認 / NFR 1.1。呼び出し元も gate 判定済み）
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # 入力検証（NFR 3.3）: PR 番号 / SHA を path / git revision / URL に使う前に厳密検証する。
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pi_warn "pi_route_out_of_scope_escalate: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    pi_warn "PR #${pr_number}: pi_route_out_of_scope_escalate: 無効な SHA '${sha}'"
    return 2
  fi

  # ルート解決: 本 spec では `needs-decisions` のみ実装。未知値は安全側で needs-decisions に丸める。
  local route="${PR_ITERATION_OOS_ROUTE:-needs-decisions}"
  case "$route" in
    needs-decisions) : ;;
    design-reflow|spawn-issue|*) route="needs-decisions" ;;
  esac
  local label="${LABEL_NEEDS_DECISIONS:-needs-decisions}"
  local iteration_label="${LABEL_NEEDS_ITERATION:-needs-iteration}"
  local timeout_s="${PR_ITERATION_GIT_TIMEOUT:-120}"

  # 冪等性（Req 3.5）: 同一 PR・同一 SHA で既ルーティング済みなら skip する。
  local routed_marker="<!-- idd-claude:pr-iteration-oos-routed sha=${sha} -->"
  local body
  body=$(timeout "$timeout_s" \
    gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")
  # コメント側 marker も走査する（gh pr view body だけでは過去ルーティングコメントを拾えないため）。
  local existing_comment_markers=""
  existing_comment_markers=$(timeout "$timeout_s" \
    gh api "/repos/${REPO}/issues/${pr_number}/comments" --jq '.[].body' 2>/dev/null \
    | grep -F -- "idd-claude:pr-iteration-oos-routed sha=${sha}" 2>/dev/null || true)
  case "${body}${existing_comment_markers}" in
    *"idd-claude:pr-iteration-oos-routed sha=${sha}"*)
      pi_log "PR #${pr_number}: reason=out-of-scope route=${route} action=skip-already-routed sha=${sha} (Req 3.5 冪等)"
      return 0
      ;;
  esac

  # out-of-scope 指摘の判定根拠（Req 1.4 / 3.3）を TSV 化して追跡コメント本文に並べる。
  # 未信頼値（reason / file）は jq @tsv でリテラル抽出してから printf へ渡す（filter inline 展開禁止）。
  local detail_lines=""
  if [ -n "$decisions_json" ]; then
    local oos_rows
    oos_rows=$(printf '%s' "$decisions_json" | jq -r '
      .decisions // []
      | map(select(.verdict == "out-of-scope"))
      | .[]
      | [ (.id | tostring), (.file // ""), ((.line // 0) | tostring), (.reason // "") ]
      | @tsv
    ' 2>/dev/null) || oos_rows=""
    if [ -n "$oos_rows" ]; then
      while IFS=$'\t' read -r oid ofile oline oreason; do
        [ -z "$oid" ] && continue
        detail_lines="${detail_lines}- id: ${oid} / ${ofile}:${oline} — ${oreason}
"
      done <<<"$oos_rows"
    fi
  fi

  # 1. `needs-iteration` 除去（round 候補プールから外す / Req 2.1）。失敗は WARN + 続行（安全側）。
  if ! timeout "$timeout_s" \
      gh pr edit "$pr_number" --repo "$REPO" --remove-label "$iteration_label" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: out-of-scope 還流で '${iteration_label}' 除去に失敗（既存挙動据え置きで安全側）"
  fi

  # 2. 還流ラベル付与（既定 needs-decisions / Req 3.1 / 3.2）。失敗は WARN（silent fail 禁止 / Req 3.4）。
  if ! timeout "$timeout_s" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$label" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: out-of-scope 還流ラベル '${label}' 付与失敗（silent fail せず WARN / Req 3.4）"
  fi

  # 3. 追跡コメント投稿 + 冪等 marker（Req 3.3 / 3.5）。失敗は WARN（silent fail 禁止 / Req 3.4）。
  local route_body
  route_body=$(printf '## 自動裁定: out-of-scope へ還流（人間判断要求）\n\nround を消費させる legitimate 指摘が残っていない一方、当該 PR の権限では requirements.md / design.md / tasks.md の確定事項を変更できない out-of-scope 指摘が残存しています。本 PR を自動 iteration から外し、%s ラベルで人間判断へ還流します（source=%s / Req 3.1 / 3.2）。\n\n### out-of-scope 指摘の還流候補\n\n%s\n%s\n' \
    "$label" "$source_kind" "$detail_lines" "$routed_marker")
  if ! timeout "$timeout_s" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$route_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: out-of-scope 還流コメント投稿失敗（sha=${sha} / ラベルは付与済みで追跡可能 / Req 3.4）"
  fi

  # 4. 観測ログ（NFR 4.1）: PR 番号 / source / round 相当の打ち切り理由 / route を 1 行で機械抽出可能に。
  pi_log "PR #${pr_number}: source=${source_kind} out_of_scope=${out_of_scope_count} reason=out-of-scope route=${route} sha=${sha} action=escalated-to-${label}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_detect_developer_oos_marker: Developer 応答ログから out-of-scope 構造化マーカーを検出
#   入力: $1=log_file（Developer iteration 応答ログのファイルパス）
#   出力: stdout に検出したマーカー種別（"design" | "spec-stale"）。不在 / 不能 / 語彙外は空。
#   戻り値: 0 固定（fail-safe）
#   Issue #437 Req 4.2 / 4.5 / NFR 3.1 / NFR 3.2
#
#   判定: 厳密書式 `^OUT-OF-SCOPE:[[:space:]]+(design|spec-stale)[[:space:]]*$` を grep -E で
#         検出する（行頭一致 / 許容語彙集合 {design, spec-stale} のみ / 前後空白許容）。
#         許容語彙集合外（例: `OUT-OF-SCOPE: foo`）・マーカー不在は空返し（安全側 = 従来 round
#         進行 / Req 4.5）。最初に一致した行の種別を返す。
#   セキュリティ（NFR 3.1 / 3.2）: 未信頼入力（Developer 応答ログ本文）は変数 quote +
#         `grep -E --` でオプション解釈を打ち切る（`-` 始まり等のフラグ注入を防ぐ）。read-only。
# ─────────────────────────────────────────────────────────────────────────────
pi_detect_developer_oos_marker() {
  local log_file="${1:-}"
  # fail-safe: ログ不在 / 読み取り不能は空返し（誤った打ち切りを防ぐ安全側）。
  if [ -z "$log_file" ] || [ ! -r "$log_file" ]; then
    echo ""
    return 0
  fi
  local matched
  matched=$(grep -E -- '^OUT-OF-SCOPE:[[:space:]]+(design|spec-stale)[[:space:]]*$' "$log_file" 2>/dev/null | head -1 || true)
  if [ -z "$matched" ]; then
    echo ""
    return 0
  fi
  # 種別語彙のみを抽出（前後の `OUT-OF-SCOPE:` / 空白を剥がす）。
  local kind
  kind=$(printf '%s' "$matched" | sed -E 's|^OUT-OF-SCOPE:[[:space:]]+||; s|[[:space:]]*$||')
  case "$kind" in
    design|spec-stale) echo "$kind" ;;
    *) echo "" ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_oos_fingerprint: out-of-scope 指摘内容の同一性判定キー（fingerprint）を算出する純粋関数
#   入力: $1=decisions_json（out-of-scope finding を含む JSON / 空許容）
#   出力: stdout に fingerprint 文字列（16 進ハッシュ。入力に out-of-scope が無ければ
#         空入力相当の安定ハッシュ）
#   戻り値: 0 固定
#   Issue #437 Req 5.1 / 5.3 / 5.5 / NFR 3.1
#
#   設計判断（design.md Components and Interfaces / pi_oos_fingerprint 節）:
#     - out-of-scope finding 群の severity / file / message（message 不在時は reason）を
#       正規化連結し sha256（不能環境は cksum）で fingerprint を生成する。
#     - 「同じ design-level 矛盾を指している限り同一」を意図（requirements Open Question）。
#       head commit SHA には依存しない（Req 5.3）。内容が実質変化すれば fingerprint も変わる
#       （Req 5.5）。順序非依存にするため severity/file/message タプルを sort してから連結する。
#     - 純粋関数（副作用なし / グローバル参照なし）→ extract_function テストで隔離検証可能。
#     - 未信頼値は jq @tsv でリテラル抽出（filter inline 展開禁止 / NFR 3.1）。
# ─────────────────────────────────────────────────────────────────────────────
pi_oos_fingerprint() {
  local decisions_json="${1:-}"
  local material=""
  if [ -n "$decisions_json" ]; then
    material=$(printf '%s' "$decisions_json" | jq -r '
      [ (.decisions // [])
        | .[]
        | select(.verdict == "out-of-scope")
        | [ (.severity // ""), (.file // ""), (.message // .reason // "") ]
        | @tsv
      ]
      | sort
      | .[]
    ' 2>/dev/null) || material=""
  fi
  # sha256sum を優先し、不能環境（無い / 失敗）は cksum にフォールバックする。
  local hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "${hash:-}" ]; then
    hash=$(printf '%s' "$material" | cksum 2>/dev/null | awk '{print $1}')
  fi
  echo "${hash:-0}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_oos_no_progress_streak: PR body marker から内容ベース no-progress 連続カウンタを取得
#   入力: $1=pr_body（gh pr view --json body --jq '.body // ""' で取得済みの文字列）
#   出力: stdout に整数（key 不在 / marker 不在なら "0"）
#   戻り値: 0 固定
#   Issue #437 Req 5.1 / 5.3 / 5.5
#
#   marker 形式: <!-- idd-claude:pr-iteration round=N last-run=... no-progress-streak=K
#                oos-no-progress-streak=J oos-fingerprint=<H> -->
#   既存 marker（oos-no-progress-streak キー無し）の場合は "0" を返す（後方互換 / NFR 1.3）。
#   既存 pi_read_no_progress_streak（SHA ベース）とは独立した別カウンタ（Non-Goal: 既存不変）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_oos_no_progress_streak() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo "0"
    return 0
  fi
  local streak
  streak=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-iteration [^>]*oos-no-progress-streak=[0-9]+' \
    | grep -oE 'oos-no-progress-streak=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${streak:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_oos_fingerprint: PR body marker から直前 round の out-of-scope fingerprint を取得
#   入力: $1=pr_body
#   出力: stdout に fingerprint 文字列（key 不在 / marker 不在なら空文字列）
#   戻り値: 0 固定
#   Issue #437 Req 5.3 / 5.5
# ─────────────────────────────────────────────────────────────────────────────
pi_read_oos_fingerprint() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo ""
    return 0
  fi
  local fp
  fp=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-iteration [^>]*oos-fingerprint=[0-9a-zA-Z]+' \
    | grep -oE 'oos-fingerprint=[0-9a-zA-Z]+' \
    | sed -E 's|oos-fingerprint=||' \
    | tail -1)
  echo "${fp:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_next_oos_no_progress_streak: 内容ベース no-progress 連続カウンタの次値を求める純粋関数
#   入力: $1=prev_fingerprint（直前 round の fingerprint / 空許容）
#         $2=current_fingerprint（今 round の fingerprint）
#         $3=prev_streak（前サイクルまでの内容ベース no-progress 連続カウンタ値）
#   出力: stdout に次の streak 値
#           fingerprint 同一（かつ非空）→ prev_streak + 1（内容が変わらず堂々巡り / Req 5.1）
#           fingerprint 変化 / 空 → "0"（内容が実質変化 = リセット / Req 5.5）
#   戻り値: 0 固定
#
#   設計判断（design.md / Req 5.3）:
#     - SHA（head commit）には依存せず fingerprint（内容ハッシュ）の同一性のみで加算する。
#       head SHA が毎 round 変化しても fingerprint 同一なら streak は加算される（Req 5.3）。
#     - prev_fingerprint / current_fingerprint のいずれかが空のときは加算しない（初回 round /
#       取得失敗時に誤って escalate に倒さない安全側 = 0 リセット）。
#     - 純粋関数（副作用なし）→ extract_function テストで隔離検証可能。
# ─────────────────────────────────────────────────────────────────────────────
pi_next_oos_no_progress_streak() {
  local prev_fingerprint="${1-}"
  local current_fingerprint="${2-}"
  local prev_streak="${3-}"
  if [ -n "$prev_fingerprint" ] && [ -n "$current_fingerprint" ] && [ "$prev_fingerprint" = "$current_fingerprint" ]; then
    if [[ "$prev_streak" =~ ^[0-9]+$ ]]; then
      echo "$((prev_streak + 1))"
    else
      echo "1"
    fi
    return 0
  fi
  echo "0"
  return 0
}
