#!/usr/bin/env bash
# shellcheck shell=bash
# pr-iteration-comments.sh — PR Iteration Processor 一般コメント収集 + filter chain
#
# family: pr-iteration / prefix: pi_（#469 で pr-iteration.sh から分割。family マニフェストは
#   pr-iteration.sh 冒頭ヘッダを参照）
#
# 用途:
#   needs-iteration PR の一般コメントを収集し、self / resolved / excessive / out-of-scope /
#   event-style の filter chain と件数上限 truncate を適用して iteration prompt 用のコメント
#   集合を返す。エントリは pi_collect_general_comments（pr-iteration-exec.sh の
#   pi_build_iteration_prompt から呼ばれる）。
#   - filter chain: pi_general_filter_self / _resolved / _excessive / _oos / _event_style
#   - 件数削減: pi_general_truncate
#   - オーケストレーション: pi_collect_general_comments
#
# 配置先:
#   $HOME/bin/modules/pr-iteration-comments.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - ロガー pi_log / pi_warn は core_utils.sh。グローバル（$REPO / $PR_ITERATION_GIT_TIMEOUT /
#     $PR_REVIEWER_ADJUDICATOR_ENABLED / $PR_ITERATION_OOS_ENABLED / $PI_GENERAL_MAX_COMMENTS 等）は
#     watcher-config.sh。pi_read_last_run（pr-iteration-state.sh）を遅延束縛で呼ぶ。
#   - 外部 CLI: gh / jq。

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_self: PR Iteration Processor 自身の自動投稿コメントを除外
#   （prefix `idd-claude:pr-iteration` 単位の判定 / Issue #400 Req 2）
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.1, 2.7 / #400 Req 2.1〜2.5
#
#   判定: comment.body 中に `idd-claude:pr-iteration` を含む HTML hidden marker
#         （`idd-claude:pr-iteration round=...` / `idd-claude:pr-iteration-processing` /
#         `idd-claude:pr-iteration-529-warning` 等）を持つコメントを self として除外する。
#         GitHub user 同一性に依存しない（cron 実行ホストが異なる GitHub user で動いて
#         いても確実に除外できる）。`@claude` 文字列には一切依存しない（Req 2.7）。
#
#   Issue #400: 旧実装は `contains("idd-claude:")` で **全** prefix を除外していたため
#         PR Reviewer 投稿 (`idd-claude:pr-reviewer`) や他系統 (security-review /
#         quota-reset / auto-rebase 等) も self として落ちる事故が起きていた。本関数は
#         `idd-claude:pr-iteration` prefix のみを対象とし、他系統の hidden marker は
#         keep する。`idd-claude:pr-iteration` という substring 判定は前方一致互換で、
#         将来 `idd-claude:pr-iteration-foo` 形式の新サブ種別が追加されても自動的に
#         self として扱われる（#400 Req 2.5 前方互換）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_self() {
  jq '[.[] | select((.body // "") | contains("idd-claude:pr-iteration") | not)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_resolved: 過去 round で対応済みと判定できるコメントを除外
#   入力: $1=last_run (ISO8601 string, 空文字列 = 初回 round)
#         stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.2, 2.3, 2.4, 2.5, 2.7
#
#   判定: last_run が空文字列なら no-op（全件採用 = 初回 round, Req 2.4）。
#         last_run が指定されている場合は `created_at > last_run` のコメントのみ採用。
#         境界（`==`）は採用側に倒さず除外する（fail-safe、設計判断 Req 2.3 解釈）。
#         比較は ISO8601 lex compare（GitHub の created_at は UTC `Z` 終端で揃う）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_resolved() {
  local last_run="${1-}"
  jq --arg last_run "$last_run" \
    '[.[] | select($last_run == "" or (.created_at // "") > $last_run)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_excessive: adjudicator が excessive と判定した指摘コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   Issue #404 Req 2.4, 2.5, 4.3 / NFR 1.1, NFR 2.2
#
#   判定: gate ON (PR_REVIEWER_ADJUDICATOR_ENABLED=true) のときのみ、comment.body 中に
#         `idd-claude:pr-adjudicator-excessive` を含む HTML hidden marker を持つコメントを
#         除外する。gate OFF / 未設定 / 不正値 / typo はすべて jq '.' で pass-through
#         （既存件数挙動を維持 / NFR 1.1）。env 値判定は厳密 `=true` 一致のみで ON とする
#         （issue-watcher.sh:685-690 が `case true) ... *) false` 正規化済みの env を渡す
#         前提に整合 / adj_gate_enabled と同方針）。
#
#   設計判断（design.md Components and Interfaces 節）:
#     - gate 判定を本関数内で完結させ、呼び出し元（pi_collect_general_comments）からは
#       無条件で chain に挿入する形に倒す。これにより gate OFF 時の filter chain も
#       `self → resolved → excessive → event_style → truncate` の同一 5 段構成となり、
#       サマリ 1 行ログに `filtered_excessive=0` が常時記録される（観測可能性 / Req 4.4）
#     - 既存 pi_general_filter_self は `idd-claude:pr-iteration` prefix のみを対象とする
#       （#400 Req 2.5）。`pr-adjudicator-excessive` は前方一致しないため self-filter と
#       衝突しない（Req 4.3 / NFR 1.2）。adjudicator 側 summary marker
#       `idd-claude:pr-adjudicator sha=...` も `pr-adjudicator-excessive` を substring に
#       持たないため本関数を素通りする（summary は iteration agent への情報として keep）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_excessive() {
  if [ "${PR_REVIEWER_ADJUDICATOR_ENABLED:-false}" = "true" ]; then
    jq '[.[] | select((.body // "") | contains("idd-claude:pr-adjudicator-excessive") | not)]'
  else
    jq '.'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_oos: adjudicator が out-of-scope と判定した指摘コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   Issue #437 Req 2.1 / NFR 1.1 / NFR 3.1
#
#   判定: gate ON (PR_ITERATION_OOS_ENABLED=true) のときのみ、comment.body 中に
#         `idd-claude:pr-adjudicator-out-of-scope` を含む HTML hidden marker を持つ
#         コメントを除外する。gate OFF / 未設定 / 不正値 / typo はすべて jq '.' で
#         pass-through（既存件数挙動を維持 / NFR 1.1）。env 値判定は厳密 `=true` 一致のみで
#         ON とする（issue-watcher.sh:787- が `case true) ... *) false` 正規化済みの env を
#         渡す前提に整合 / pi_general_filter_excessive と同方針）。
#
#   設計判断（design.md Components and Interfaces / pi_general_filter_oos 節）:
#     - gate 判定を本関数内で完結させ、呼び出し元（pi_collect_general_comments）からは
#       無条件で chain に挿入する形に倒す。これにより gate OFF 時の filter chain も
#       `self → resolved → excessive → out-of-scope → event_style → truncate` の同一 6 段
#       構成となり、サマリ 1 行ログに `filtered_oos=0` が常時記録される（観測可能性 / NFR 4.1）
#     - prefix `pr-adjudicator-out-of-scope` は既存 `pr-adjudicator-excessive` /
#       `pr-iteration` のいずれとも前方一致しないため self-filter / excessive-filter と
#       衝突しない（Data Models / NFR 1.3）。adjudicator summary marker
#       `idd-claude:pr-adjudicator sha=...` も `pr-adjudicator-out-of-scope` を substring に
#       持たないため本関数を素通りする（summary は iteration agent への情報として keep）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_oos() {
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
    jq '[.[] | select((.body // "") | contains("idd-claude:pr-adjudicator-out-of-scope") | not)]'
  else
    jq '.'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_event_style: GitHub system 由来の event-style コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.6, 2.7
#
#   判定: user.type == "Bot" のコメント、および body が空のコメントを除外する。
#         /repos/.../issues/<n>/comments は基本的にユーザーコメントしか返さないため
#         保険的なフィルタだが、Req 2.6 を観測可能に保つために独立化する。
#         watcher 自身の投稿は marker で既に除外済みのため、ここで Bot を全体除外しても
#         二重除外にならず安全。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_event_style() {
  jq '[.[] | select((.user.type // "") != "Bot" and (.body // "") != "")]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_truncate: 件数上限超過時に古い順 drop で削減
#   入力: $1=limit (件数上限)
#         stdin に一般コメント JSON 配列
#   出力: stdout に削減後の JSON 配列
#   AC #55 Req 3.1, 3.4
#
#   アルゴリズム:
#     1. 入力配列 length が limit 以下 → no-op（Req 3.4）
#     2. length > limit → created_at 昇順ソート → 末尾 limit 件を採用（古い順 drop）
#       新しいコメントが残るため、レビュワーが直近に追加した指摘を優先できる。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_truncate() {
  local limit="${1:-50}"
  jq --argjson limit "$limit" \
    'if length <= $limit then . else (sort_by(.created_at // "") | .[-$limit:]) end'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_collect_general_comments: 一般コメント収集 + 3 段フィルタ + 削減のオーケストレーション
#   入力: $1=pr_number
#         $2=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に JSON 配列文字列。要素スキーマ:
#         { id, user, body, url, created_at }
#         取得失敗時 / コメント 0 件時は "[]"。
#   返り値: 0 固定（エラーは degraded path = "[]" + WARN ログに倒す）
#   AC #55 Req 1.1, 1.2, 1.5, 2.5, 3.2, 4.2, 4.3, 4.4, 4.6, 6.2, NFR 1.1, NFR 1.2,
#         NFR 2.1, NFR 2.2
#
#   設計判断:
#     - kind（design/impl）に依存する分岐を持たない（impl/design PR で共通呼び出し、Req 6.2）
#     - @claude 文字列を判定式に使わない（Req 2.7、`@claude` mention 必須を opt-out で
#       復活させる新規 env var を追加しない、Req 4.4）
#     - 上限値は内部定数 PI_GENERAL_MAX_COMMENTS（既定 50、env override 可）
#       README には載せない（運用上 default で十分、Req 4.4 の対象外）
#     - サマリは 1 行で出力し、truncate 発動時のみ pi_warn、それ以外は pi_log（NFR 2.2）
# ─────────────────────────────────────────────────────────────────────────────
pi_collect_general_comments() {
  local pr_number="$1"
  local pr_body="${2-}"
  local limit="${PI_GENERAL_MAX_COMMENTS:-50}"

  # 1. GitHub API から raw 一般コメントを取得（既存と同じ timeout / fall-back 方式）
  local raw_general
  if ! raw_general=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント取得に失敗、空配列で続行"
    echo "[]"
    return 0
  fi

  # 2. 射影: { id, user, body, url, created_at } のスキーマに整形（Req 6.2 / Data Model）
  local projected
  if ! projected=$(echo "$raw_general" | jq '[.[] | {
        id,
        user: (.user.login // ""),
        body: (.body // ""),
        url: .html_url,
        created_at: (.created_at // ""),
        "_meta_user_type": (.user.type // "")
      }]' 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント JSON の整形に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local fetched
  fetched=$(echo "$projected" | jq 'length' 2>/dev/null || echo "0")

  # 3. last-run TS を抽出（marker 不在時は空文字列 = 初回 round）
  local last_run
  last_run=$(pi_read_last_run "$pr_body")

  # 4. フィルタを順次適用しながら各段の length を測定
  #    順序: self → resolved → excessive → out-of-scope → event_style → truncate
  #    Issue #404 task 7: adjudicator が excessive と判定した指摘コメントを除外する
  #    excessive 段を resolved の直後 / event_style の前に挿入。gate OFF 時は内部で
  #    pass-through するため既存件数挙動には影響しない（NFR 1.1）。
  #    Issue #437 task 4: adjudicator が out-of-scope と判定した指摘コメントを除外する
  #    out-of-scope 段を excessive の直後 / event_style の前に挿入。gate
  #    (PR_ITERATION_OOS_ENABLED) OFF 時は内部で pass-through するため既存件数挙動に
  #    影響しない（NFR 1.1）。
  local after_self after_resolved after_excessive after_oos after_event final
  local filter_event_input

  # event_style filter は射影段で残した _meta_user_type を user.type の代理として使う
  # （元 jq schema を {id,user,body,url,created_at} に保つ理由: prompt template 互換）
  if ! after_self=$(echo "$projected" | pi_general_filter_self 2>/dev/null); then
    pi_warn "PR #${pr_number}: 自己投稿フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_self
  count_self=$(echo "$after_self" | jq 'length' 2>/dev/null || echo "0")

  if ! after_resolved=$(echo "$after_self" | pi_general_filter_resolved "$last_run" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 過去 round フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_resolved
  count_resolved=$(echo "$after_resolved" | jq 'length' 2>/dev/null || echo "0")

  # Issue #404 task 7: excessive フィルタ（gate ON 時のみ marker 除外、OFF 時 pass-through）
  if ! after_excessive=$(echo "$after_resolved" | pi_general_filter_excessive 2>/dev/null); then
    pi_warn "PR #${pr_number}: excessive フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_excessive
  count_excessive=$(echo "$after_excessive" | jq 'length' 2>/dev/null || echo "0")

  # Issue #437 task 4: out-of-scope フィルタ（gate ON 時のみ marker 除外、OFF 時 pass-through）
  if ! after_oos=$(echo "$after_excessive" | pi_general_filter_oos 2>/dev/null); then
    pi_warn "PR #${pr_number}: out-of-scope フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_oos
  count_oos=$(echo "$after_oos" | jq 'length' 2>/dev/null || echo "0")

  # event_style フィルタは _meta_user_type を user.type 相当に詰め直してから判定する
  filter_event_input=$(echo "$after_oos" | jq '[.[] | . + {user: {type: ._meta_user_type, login: (.user)}}]' 2>/dev/null || echo "[]")
  if ! after_event=$(echo "$filter_event_input" | pi_general_filter_event_style 2>/dev/null); then
    pi_warn "PR #${pr_number}: event-style フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  # スキーマ復元: user は文字列 (login) のみに戻し、_meta_user_type も落とす
  after_event=$(echo "$after_event" | jq '[.[] | {id, user: (.user.login // ""), body, url, created_at}]' 2>/dev/null || echo "[]")
  local count_event
  count_event=$(echo "$after_event" | jq 'length' 2>/dev/null || echo "0")

  if ! final=$(echo "$after_event" | pi_general_truncate "$limit" 2>/dev/null); then
    pi_warn "PR #${pr_number}: truncate に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_final
  count_final=$(echo "$final" | jq 'length' 2>/dev/null || echo "0")

  # 5. サマリ 1 行ログ
  # Issue #404 task 7: filtered_excessive を filtered_resolved と filtered_event の間に追加。
  # gate OFF 時は pi_general_filter_excessive が pass-through するため filtered_excessive=0 と
  # なり、観測者が「gate が無効か機能してないか」をログ 1 行で確認できる（Req 4.4 観測可能性）。
  # Issue #437 task 4: filtered_oos を filtered_excessive と filtered_event の間に追加。
  # gate (PR_ITERATION_OOS_ENABLED) OFF 時は pi_general_filter_oos が pass-through するため
  # filtered_oos=0 となる（NFR 4.1 観測可能性 / NFR 1.1 既存件数挙動不変）。
  local filtered_self filtered_resolved filtered_excessive filtered_oos filtered_event truncated
  filtered_self=$((fetched - count_self))
  filtered_resolved=$((count_self - count_resolved))
  filtered_excessive=$((count_resolved - count_excessive))
  filtered_oos=$((count_excessive - count_oos))
  filtered_event=$((count_oos - count_event))
  truncated=$((count_event - count_final))

  # サマリは stderr に出力する（本関数の stdout は JSON 配列に予約されているため）。
  # pi_warn は元々 stderr 直行、pi_log は stdout のため明示的に >&2 で逃がす。
  if [ "$truncated" -gt 0 ]; then
    pi_warn "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_excessive=${filtered_excessive}, filtered_oos=${filtered_oos}, filtered_event=${filtered_event}, truncated=${truncated} (limit=${limit}), final=${count_final}"
  else
    pi_log "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_excessive=${filtered_excessive}, filtered_oos=${filtered_oos}, filtered_event=${filtered_event}, truncated=0, final=${count_final}" >&2
  fi

  echo "$final"
  return 0
}
