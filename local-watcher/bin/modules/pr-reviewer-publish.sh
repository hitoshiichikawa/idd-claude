#!/usr/bin/env bash
# shellcheck shell=bash
# pr-reviewer-publish.sh — PR Reviewer 結果投稿（PR コメント / VERDICT 検出 /
#   needs-iteration 連携 / commit status publish #349）
#
# family: pr-reviewer / prefix: pr_（#470 で pr-reviewer.sh から分割。family マニフェストは
#   pr-reviewer.sh 冒頭ヘッダを参照）
#
# 用途:
#   レビュー結果の投稿・VERDICT 検出・commit status publish（Issue #349）を集約する。
#   - コメント投稿: pr_post_review_comment / pr_post_error_comment（hidden marker 付き）
#   - VERDICT 検出 / ラベル付与: pr_detect_iteration_keyword / pr_add_iteration_label
#   - commit status publish（#349）: pr_status_check_enabled（AND 二重 opt-in gate）/
#     pr_publish_commit_status（低レベル API 呼び出し）/ pr_publish_codex_status /
#     pr_publish_claude_status / pr_publish_claude_status_from_branch（#374 catch-up 経路）
#
#   pr_publish_claude_status / pr_status_check_enabled / pr_publish_commit_status は
#   adjudicator.sh / pr-design-reviewer.sh / slot-worker.sh からも遅延束縛で呼ばれる
#   family 外部公開 API（既存の cross-module 依存。#470 分割で契約は不変）。
#
# 配置先:
#   $HOME/bin/modules/pr-reviewer-publish.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - ロガー pr_log / pr_warn / pr_error は core_utils.sh。
#   - orchestrator（pr-reviewer.sh）の pr_already_processed を遅延束縛で呼ぶ
#     （pr_post_error_comment 内の重複防止判定）。
#   - グローバル変数（$REPO / $PR_REVIEWER_* / $FULL_AUTO_ENABLED / $LABEL_NEEDS_ITERATION 等）は
#     watcher-config.sh。issue-watcher.sh 本体の parse_review_result（load-order pin 済み）を
#     declare -F で参照。
#   - 外部 CLI: gh / jq。


# ─────────────────────────────────────────────────────────────────────────────
# pr_post_review_comment: レビュー結果コメントを投稿（task 5.3）
#   入力: $1 = pr_number, $2 = sha, $3 = review_text, $4 = tool (省略時 none)
#   戻り値: 0 = ok / 1 = 投稿失敗
#   AC: 4.4, 6.1, 6.4
#
#   - review_text 末尾に hidden marker（kind=review）を付与し gh pr comment で投稿。
#   - design.md interface 表は ($1,$2,$3) の 3 引数表記だが marker の tool= 属性
#     のため第 4 引数 tool を追加（pr_build_marker と同様 / impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_post_review_comment() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local tool="${4:-none}"

  local marker body
  marker=$(pr_build_marker "$sha" "review" "$tool")
  body=$(printf '%s\n\n%s' "$review_text" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: レビュー結果コメントの投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: レビュー結果コメント投稿 kind=review tool=${tool} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_error_comment: エラーコメントを投稿（task 5.3）
#   入力: $1 = pr_number, $2 = sha, $3 = kind, $4 = detail, $5 = tool (省略時 none)
#   戻り値: 0 = ok（重複 skip 含む）/ 1 = 投稿失敗
#   AC: 2.4, 3.1, 3.2, 3.3, 3.4, 4.5, 6.1, 6.4
#
#   - 本文冒頭に運用者が人間判断で識別できる見出し `## 自動レビューエラー`（AC 3.4）。
#   - 同一 (sha, kind) marker が既存なら再投稿しない（AC 3.3 / 6.2、冪等 NFR 4.1）。
#   - design.md interface 表は ($1〜$4) の 4 引数表記だが marker の tool= 属性のため
#     第 5 引数 tool を追加（impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_post_error_comment() {
  local pr_number="$1"
  local sha="$2"
  local kind="$3"
  local detail="$4"
  local tool="${5:-none}"

  # AC 3.3 / 6.2: 同一 (sha, kind) が既存なら再投稿しない
  if pr_already_processed "$pr_number" "$sha" "$kind"; then
    pr_log "PR #${pr_number}: kind=${kind} sha=${sha} のエラーコメントは既存のため再投稿しません（重複防止）"
    return 0
  fi

  local marker body
  marker=$(pr_build_marker "$sha" "$kind" "$tool")
  body=$(printf '## 自動レビューエラー\n\n%s\n\n%s' "$detail" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: エラーコメント (kind=${kind}) の投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: エラーコメント投稿 kind=${kind} tool=${tool} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_detect_iteration_keyword: レビュー結果から VERDICT token を検出（task 6）
#   入力: $1 = pr_number（ログ用）, $2 = review_text
#   出力: stdout にマッチ件数（整数。0 のとき "0"）
#   戻り値: 0 固定
#   AC: 5.1, 5.3, 5.4
#
#   - PR_REVIEWER_ITERATION_PATTERN（既定は line-anchored の
#     `^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$`、Decision 4）を
#     `grep -E -i -c` で照合し、マッチ行数を返す。
#   - 件数とパターンを観測ログに記録（AC 5.4 / NFR 3.1）。stdout に件数を返す契約の
#     ため、ログは pr_log を stderr へリダイレクトして出力する（stdout 汚染防止）。
#   - ラベル付与は呼び出し元（件数 > 0 のとき pr_add_iteration_label）が行う。
# ─────────────────────────────────────────────────────────────────────────────
pr_detect_iteration_keyword() {
  local pr_number="$1"
  local review_text="$2"
  local pattern="${PR_REVIEWER_ITERATION_PATTERN}"

  local count
  # `--` でパターン以降をオプション解釈から切り離し、`-f...` 等によるフラグ注入を防ぐ
  # （`PR_REVIEWER_ITERATION_PATTERN` は operator 設定だが安価な hardening）。
  count=$(printf '%s' "$review_text" | grep -E -i -c -- "$pattern" 2>/dev/null || true)
  count="${count:-0}"

  pr_log "PR #${pr_number}: iteration keyword 検出 matches=${count} pattern='${pattern}'" >&2
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_add_iteration_label: needs-iteration ラベルを付与（task 6）
#   入力: $1 = pr_number
#   戻り値: 0 = ok / 1 = 付与失敗
#   AC: 5.1, 5.2
#
#   - `gh pr edit --add-label` は既付与で冪等（再付与は no-op、AC 5.2）。
#   - 既存 PR Iteration Processor (#26) は本ラベルを起動条件とするため、付与により
#     次サイクルで iteration ループへ自動接続される。
# ─────────────────────────────────────────────────────────────────────────────
pr_add_iteration_label() {
  local pr_number="$1"
  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_NEEDS_ITERATION" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルの付与に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルを付与（既付与なら冪等 no-op）"
  return 0
}

# ─── Issue #349: Commit Status Publishing ─────────────────────────────────────
#
# codex / antigravity の VERDICT と Claude Reviewer の RESULT を GitHub Commit Status
# API (`POST /repos/{owner}/{repo}/statuses/{sha}`) 経由で `codex-review` /
# `claude-review` context 名の commit status として publish するためのヘルパー群。
# auto-merge ゲートを required status checks で成立させるための前提整備（D-03 / D-04）。
#
# AND 二重 opt-in:
#   - `PR_REVIEWER_STATUS_CHECK_ENABLED=true` 厳密一致（issue-watcher.sh 本体で正規化済）
#   - `FULL_AUTO_ENABLED=true` 厳密一致（#348 kill switch / 同様に正規化済）
#   どちらか一方でも `=true` 以外なら publish を行わず即 return（Req 1.2, 1.4 / 6.1）。
#
# gate OFF 時の suppression ログは「サイクルあたり最大 1 行」に制限する（Req 7.2）。
# 単一サイクル内で複数の publish 試行（codex 用 + claude 用、複数 PR）が同一 gate OFF
# 状態で suppress される場合でも、`PR_STATUS_GATE_SUPPRESS_LOGGED` フラグで重複出力を抑止
# する。`FULL_AUTO_ENABLED` 側の suppression は #348 既存ログに委ね（重複させない / Req 7.3）。

# ─────────────────────────────────────────────────────────────────────────────
# pr_status_check_enabled: AND 二重 opt-in gate の評価（Req 1.2, 1.4）
#   入力: 環境変数のみ
#   出力: なし
#   戻り値: 0 = 両 gate 有効（publish 許可）/ 1 = いずれかの gate が OFF（publish 抑止）
#
#   - `PR_REVIEWER_STATUS_CHECK_ENABLED` と `FULL_AUTO_ENABLED` を独立に評価し、
#     **双方** が `=true` 厳密一致の場合のみ rc=0 を返す。
#   - 値正規化（unset / 空 / `True` / `TRUE` / `1` / typo の安全側 OFF 化）は
#     issue-watcher.sh 本体の Config ブロックで完了している前提だが、本関数は遅延
#     束縛のため `${VAR:-false}` で fallback して NFR 1.1 安全側に倒す。
# ─────────────────────────────────────────────────────────────────────────────
pr_status_check_enabled() {
  if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  if [ "${FULL_AUTO_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_commit_status: GitHub Commit Status API 呼び出しの低レベルヘルパー
#   入力: $1 = pr_number, $2 = sha, $3 = context, $4 = state,
#         $5 = description, $6 = target_url
#   出力: なし（observe 用 log は pr_log / pr_warn）
#   戻り値: 0 = publish 成功 / 1 = gate OFF（no-op）/ 2 = 入力検証失敗 /
#           3 = API 呼び出し失敗
#   AC: 1.2, 1.4, 2.1, 2.2, 3.1, 3.2, 4.1, 5.1, 5.2, 5.3, 5.4, 7.1
#   NFR: 1.1, 1.2, 1.3, 1.4, 2.1
#
#   - AND 二重 opt-in の gate を先頭で評価し、OFF なら外部副作用ゼロで 1 を返す
#     （Req 6.1 / 1.4）。suppression 観測は cycle あたり 1 行に制限（Req 7.2）。
#   - 未信頼入力（sha / PR 番号）の使用前検証を厳格に行い、不正値時は publish せず
#     2 を返す（NFR 1.3, 1.4）。
#   - description は GitHub 仕様の 140 文字制限内かつ運用要件の 72 文字以内に短縮。
#   - state は GitHub Commit Status API の許容値 `success` / `failure` / `pending` /
#     `error` のいずれかに正規化（本仕様では `success` / `failure` のみ使用 / AC 2.1, 2.2）。
#   - 失敗時は HTTP status / stderr を含めて pr_warn し、silent fail にしない（AC 5.1, 5.4）。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_commit_status() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local context="${3:-}"
  local state="${4:-}"
  local description="${5:-}"
  local target_url="${6:-}"

  # AND 二重 opt-in gate（Req 1.2, 1.4, 6.1）
  if ! pr_status_check_enabled; then
    # cycle あたり 1 行に制限（Req 7.2）。`FULL_AUTO_ENABLED` OFF 起因は #348 既存ログに
    # 委ね、本関数では `PR_REVIEWER_STATUS_CHECK_ENABLED` OFF 起因のみログする（Req 7.3）。
    if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ] \
        && [ "${PR_STATUS_GATE_SUPPRESS_LOGGED:-0}" != "1" ]; then
      pr_log "commit status publish suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED gate (cycle no-op)"
      PR_STATUS_GATE_SUPPRESS_LOGGED=1
    fi
    return 1
  fi

  # ── 未信頼入力の検証（NFR 1.3, 1.4）─────────────────────────────────────────
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pr_warn "commit status publish: 無効な PR 番号 '${pr_number}' を検出（context=${context} state=${state}）"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    pr_warn "commit status publish: 無効な sha '${sha}' を検出（pr=#${pr_number} context=${context} state=${state}）"
    return 2
  fi
  case "$state" in
    success|failure|pending|error) ;;
    *)
      pr_warn "commit status publish: 無効な state '${state}'（pr=#${pr_number} sha=${sha} context=${context}）"
      return 2
      ;;
  esac
  case "$context" in
    "")
      pr_warn "commit status publish: context が空（pr=#${pr_number} sha=${sha} state=${state}）"
      return 2
      ;;
  esac

  # description は 72 文字以内に短縮（AC 2.3, 3.3）。空入力時は context+state から既定値を生成。
  if [ -z "$description" ]; then
    description="${context}: ${state}"
  fi
  if [ "${#description}" -gt 72 ]; then
    description="${description:0:72}"
  fi

  # target_url は空でも GitHub API は受け付けるが、空文字は `-f target_url=` で渡すと
  # 不正な空 URL とみなされる可能性があるため、空時は引数自体を渡さない分岐を取る。
  # ── API call: gh api -X POST ────────────────────────────────────────────────
  # gh は `-f key=value` で POST body を application/json として構築するため、
  # 未信頼値の inline 展開リスクは低い。URL path 部の sha / repo owner は事前検証済。
  local api_path="repos/${REPO}/statuses/${sha}"
  local api_stderr_tmp
  api_stderr_tmp=$(mktemp -t idd-claude-pr-status.XXXXXX 2>/dev/null || echo "")

  local api_rc=0
  if [ -n "$target_url" ]; then
    if [ -n "$api_stderr_tmp" ]; then
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          -f target_url="$target_url" \
          >/dev/null 2>"$api_stderr_tmp" || api_rc=$?
    else
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          -f target_url="$target_url" \
          >/dev/null 2>&1 || api_rc=$?
    fi
  else
    if [ -n "$api_stderr_tmp" ]; then
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          >/dev/null 2>"$api_stderr_tmp" || api_rc=$?
    else
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          >/dev/null 2>&1 || api_rc=$?
    fi
  fi

  if [ "$api_rc" -ne 0 ]; then
    # AC 5.1, 5.2, 5.4: 失敗時は WARN ログに PR / sha / context / state / 終了コード /
    # stderr 抜粋を残す。silent fail にしない。パイプライン継続は呼び出し側の責務。
    local err_tail=""
    if [ -n "$api_stderr_tmp" ] && [ -f "$api_stderr_tmp" ]; then
      err_tail=$(tail -c 512 "$api_stderr_tmp" 2>/dev/null || true)
      rm -f "$api_stderr_tmp" 2>/dev/null || true
    fi
    pr_warn "commit status publish FAILED: pr=#${pr_number} sha=${sha} context=${context} state=${state} rc=${api_rc} stderr='${err_tail//$'\n'/ }'"
    return 3
  fi

  if [ -n "$api_stderr_tmp" ]; then
    rm -f "$api_stderr_tmp" 2>/dev/null || true
  fi
  # AC 7.1: 成功時 1 行 log（PR / sha / context / state）
  pr_log "commit status published: pr=#${pr_number} sha=${sha} context=${context} state=${state}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_codex_status: codex / antigravity の VERDICT から commit status を publish
#   入力: $1 = pr_number, $2 = sha, $3 = review_text, $4 = pr_url
#   出力: なし（log のみ）
#   戻り値: pr_publish_commit_status の戻り値をそのまま返す（0/1/2/3）
#   AC: 2.1, 2.2, 2.3, 2.4, 2.5
#
#   - review_text の最終行 `VERDICT: approve` / `VERDICT: needs-iteration` から
#     state を解決する（approve → success、needs-iteration → failure）。
#   - antigravity 利用時も同じ `codex-review` context を共有する（AC 2.5）。
#   - target_url はコメント permalink を取得できないため PR URL に倒す（AC 2.4 fallback）。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_codex_status() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local pr_url="$4"

  # VERDICT 検出: pr_detect_iteration_keyword が >0 を返せば needs-iteration（=failure）。
  # pr_detect_iteration_keyword は PR_REVIEWER_ITERATION_PATTERN を用いるため挙動が一貫する。
  local match_count
  match_count=$(pr_detect_iteration_keyword "$pr_number" "$review_text")
  match_count="${match_count:-0}"

  local state description
  if [ "$match_count" -gt 0 ] 2>/dev/null; then
    state="failure"
    description="codex: needs-iteration"
  else
    state="success"
    description="codex: approve"
  fi

  pr_publish_commit_status "$pr_number" "$sha" "codex-review" "$state" "$description" "$pr_url"
  return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_claude_status: Claude Reviewer の RESULT から commit status を publish
#   入力: $1 = pr_number, $2 = sha, $3 = result (approve|reject), $4 = target_url
#   出力: なし（log のみ）
#   戻り値: pr_publish_commit_status の戻り値（0/1/2/3）/ 4 = 不正な result
#   AC: 3.1, 3.2, 3.3, 3.4, 3.5
#
#   - 呼び出し元（issue-watcher.sh 本体 / run_reviewer_stage 直後）が
#     `parse_review_result` で result を抽出してから本関数を呼ぶ前提。
#   - approve → success / reject → failure。`parse_review_result` の戻り値 0 を伴う
#     場合のみ呼ばれる前提のため、本関数では result の値検証のみ行う。
#   - target_url は review-notes.md の blob URL（呼び出し側で組み立て）を期待するが、
#     空文字なら pr_publish_commit_status 側で省略される。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_claude_status() {
  local pr_number="$1"
  local sha="$2"
  local result="$3"
  local target_url="${4:-}"

  local state description
  case "$result" in
    approve)
      state="success"
      description="claude: approve"
      ;;
    reject)
      state="failure"
      description="claude: reject"
      ;;
    *)
      pr_warn "claude-review status publish: 不正な result '${result}'（pr=#${pr_number} sha=${sha}）"
      return 4
      ;;
  esac

  # Issue #434 Defect B / Req 3, 4: terminal ラベル付き PR への claude-review=success を
  # fail-closed する。terminal ラベル（claude-failed / needs-decisions）確定後に in-flight
  # だった Reviewer が success を publish すると merge gate が「失敗確定済み PR」に対して緑に
  # 戻り、auto-merge が誤発火する。これを防ぐため、success（result=approve）の publish 直前に
  # 当該 PR の現在ラベルを再取得し、terminal ラベルがあれば success を publish せず skip する
  # （required check が pending のまま残り auto-merge は発火しない / fail-closed）。
  #
  # 本ガードを唯一の publisher である本関数 1 箇所に集約することで、adjudicator 経路
  # （adj_apply_status_decision → pr_publish_claude_status）と catch-up 経路
  # （pr_publish_claude_status_from_branch → pr_publish_claude_status）も自動的に
  # fail-closed 化される（Req 3.1〜3.4）。reject（failure）は gate を閉じる方向なので
  # terminal でもそのまま publish する（ガードは success 経路のみ / Req 3.5）。
  #
  # Issue #482 / #349 Req 6.1: status-check gate（PR_REVIEWER_STATUS_CHECK_ENABLED AND
  # FULL_AUTO_ENABLED）OFF 時は、本 #434 ガードの `gh pr view` も含め外部呼び出しをゼロに保つ。
  # gate OFF なら後段 pr_publish_commit_status が publish 自体を抑止（return 1）するため、
  # publish を前提とする terminal ラベル再取得はそもそも不要。gate ON 時のみ本ガードを実行する
  # ことで、#434 の fail-closed 安全性（success を publish する直前の terminal 判定）は publish が
  # 実際に走る gate ON 経路で完全に保たれる。
  if [ "$state" = "success" ] && pr_status_check_enabled; then
    # Req 4.1: 現在のラベル集合を再取得して terminal 判定する。
    local cur_labels_json gh_rc=0
    cur_labels_json=$(timeout "${PR_REVIEWER_GIT_TIMEOUT:-120}" \
      gh pr view "$pr_number" --repo "$REPO" --json labels 2>/dev/null) || gh_rc=$?
    if [ "$gh_rc" -ne 0 ] || [ -z "$cur_labels_json" ]; then
      # Req 4.2 / 4.3: ラベル再取得失敗時は従来どおり publish を継続（fail-open / 可用性優先）。
      # silent fail させず WARN を 1 行残す。
      pr_warn "claude-review status publish: terminal ラベル再取得に失敗（fail-open で publish 継続 / pr=#${pr_number} sha=${sha} rc=${gh_rc}）"
    else
      # Req 3.1, 3.2: claude-failed / needs-decisions のいずれかを持つなら success を publish しない。
      local terminal_label=""
      if echo "$cur_labels_json" | jq -e --arg l "$LABEL_FAILED" \
          '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
        terminal_label="$LABEL_FAILED"
      elif echo "$cur_labels_json" | jq -e --arg l "$LABEL_NEEDS_DECISIONS" \
          '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
        terminal_label="$LABEL_NEEDS_DECISIONS"
      fi
      if [ -n "$terminal_label" ]; then
        pr_warn "claude-review status publish: terminal label '${terminal_label}' present, skip claude-review=success (fail-closed / pr=#${pr_number} sha=${sha})"
        return 0
      fi
    fi
  fi

  pr_publish_commit_status "$pr_number" "$sha" "claude-review" "$state" "$description" "$target_url"
  return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_claude_status_from_branch: PR が存在する状態で claude-review status を
#   publish する catch-up 経路（Issue #374）。
#   入力: $1 = pr_number, $2 = sha, $3 = head_ref（例: claude/issue-123-impl-foo）,
#         $4 = pr_url（target_url fallback 用）
#   出力: なし（log のみ）
#   戻り値: 0 固定（best-effort / skip / publish 失敗いずれもパイプライン継続）
#
#   背景（Issue #374）:
#     per-task ループ運用（PER_TASK_LOOP_ENABLED=true）では `publish_claude_review_status`
#     が Reviewer round=1〜3 直後に呼ばれる時系列が PjM の impl PR 作成より前になるため、
#     `gh pr list --head <branch>` で PR が解決できず WARN skip で終わってしまう。
#     本関数は `process_pr_reviewer` の review loop（open PR を scan する経路）から
#     呼ばれることで「PR が GitHub 側に存在する状態」を構造的に保証し、AND 二重 opt-in
#     成立時の claude-review status を確実に publish する catch-up 経路を提供する。
#
#   設計判断:
#     - AND 二重 opt-in（`pr_status_check_enabled`）成立時のみ動作。OFF は外部副作用ゼロで
#       即 return（Req 5.1, 5.2 / NFR 1.1）。
#     - head_ref から issue 番号を抽出（`claude/issue-<N>-...`）。一致しなければ silent skip
#       （他 head pattern は本機能対象外）。
#     - workspace は呼び出し元 pr_run_review_for_pr 完了時点で BASE_BRANCH に復帰している
#       前提のため、head 側の `docs/specs/<N>-*/review-notes.md` を `git ls-tree` + `git show`
#       で読み出す（checkout 不要 / 副作用ゼロ）。
#     - 既存 `parse_review_result` を呼び出して RESULT を抽出する（contract 流用 / NFR 1.3）。
#     - 既存 `pr_publish_claude_status` をそのまま呼ぶ（codex 経路と対称 / API 経路は #349 完成形を維持）。
#     - PR 未解決 / file 不在 / parse 失敗いずれも WARN を 1 行残して return 0
#       （silent fail 禁止 / Req 3.1〜3.5）。
pr_publish_claude_status_from_branch() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local head_ref="${3:-}"
  local pr_url="${4:-}"

  # AND 二重 opt-in 早期判定（Req 5.1, 5.2 / NFR 1.1）
  if ! pr_status_check_enabled; then
    # suppression ログは pr_publish_commit_status 側の cycle あたり 1 行制限に委ねる
    # （本関数で重複ログを出さない / Req 5.5 / NFR 3.3）。
    return 0
  fi

  # head_ref から issue 番号を抽出（claude/issue-<N>-...）
  local issue_number=""
  if [[ "$head_ref" =~ ^claude/issue-([0-9]+)- ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    # 本関数対象外 head（design / 他 prefix 等）→ silent skip
    return 0
  fi

  # spec dir を origin/$head_ref の tree から解決（cwd は呼び出し元で REPO_DIR / NFR 1.1）。
  # `git ls-tree --name-only` で `docs/specs/<N>-<slug>/` の直下エントリ群を列挙し、
  # `<N>-` で始まる最初のディレクトリを採用する。
  # `--` でオプション解釈を打ち切り（path 由来のフラグ注入予防 / 既存 hardening 同方針）。
  local tree_out spec_dir_rel=""
  if ! tree_out=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      git ls-tree --name-only "origin/${head_ref}" -- "docs/specs/" 2>/dev/null); then
    pr_warn "claude-review status publish (catch-up): docs/specs 列挙失敗 branch=${head_ref} pr=#${pr_number} reason=ls-tree-failed"
    return 0
  fi
  # `docs/specs/<N>-...` 形式の path から `<N>-` で始まるディレクトリを抽出
  spec_dir_rel=$(echo "$tree_out" \
    | awk -v n="${issue_number}-" -F/ '$3 != "" && index($3, n) == 1 { print "docs/specs/" $3; exit }')
  if [ -z "$spec_dir_rel" ]; then
    pr_warn "claude-review status publish (catch-up): docs/specs/${issue_number}-* 不在 branch=${head_ref} pr=#${pr_number} reason=spec-dir-not-found"
    return 0
  fi

  local notes_rel="${spec_dir_rel}/review-notes.md"
  # review-notes.md を head から取得（cat-file -e で存在確認 → show で内容取得）
  if ! git cat-file -e "origin/${head_ref}:${notes_rel}" 2>/dev/null; then
    pr_warn "claude-review status publish (catch-up): review-notes.md 不在 branch=${head_ref} pr=#${pr_number} path='${notes_rel}' reason=file-not-found"
    return 0
  fi

  local notes_tmp
  notes_tmp=$(mktemp -t idd-claude-pr-claude-notes.XXXXXX 2>/dev/null || mktemp)
  if ! git show "origin/${head_ref}:${notes_rel}" >"$notes_tmp" 2>/dev/null; then
    pr_warn "claude-review status publish (catch-up): review-notes.md 取得失敗 branch=${head_ref} pr=#${pr_number} path='${notes_rel}' reason=git-show-failed"
    rm -f "$notes_tmp" 2>/dev/null || true
    return 0
  fi

  # parse_review_result は issue-watcher.sh 本体で定義（モジュール load 後）。
  # 万一未ロード状態で呼ばれた場合は silent skip（NFR 1.1 安全側）。
  if ! declare -F parse_review_result >/dev/null 2>&1; then
    pr_warn "claude-review status publish (catch-up): parse_review_result 未ロード branch=${head_ref} pr=#${pr_number} reason=parse-helper-missing"
    rm -f "$notes_tmp" 2>/dev/null || true
    return 0
  fi

  local parsed parse_rc=0
  parsed=$(parse_review_result "$notes_tmp") || parse_rc=$?
  rm -f "$notes_tmp" 2>/dev/null || true

  if [ "$parse_rc" -ne 0 ] || [ -z "$parsed" ]; then
    pr_warn "claude-review status publish (catch-up): parse_review_result 失敗 branch=${head_ref} pr=#${pr_number} rc=${parse_rc} reason=parse-failed"
    return 0
  fi

  local result
  result=$(echo "$parsed" | cut -f1)
  case "$result" in
    approve|reject) ;;
    *)
      pr_warn "claude-review status publish (catch-up): 不正な RESULT '${result}' branch=${head_ref} pr=#${pr_number} reason=invalid-result"
      return 0
      ;;
  esac

  # target_url: review-notes.md の blob URL（PR head sha 指定）。組み立て不能時は PR URL に fallback。
  local target_url=""
  if [ -n "$sha" ] && [ -n "$spec_dir_rel" ]; then
    target_url="https://github.com/${REPO}/blob/${sha}/${spec_dir_rel}/review-notes.md"
  elif [ -n "$pr_url" ]; then
    target_url="$pr_url"
  fi

  pr_log "claude-review status publish (catch-up): branch=${head_ref} pr=#${pr_number} sha=${sha} result=${result} spec=${spec_dir_rel}"
  # publish 失敗時も pr_publish_claude_status / pr_publish_commit_status 側で WARN 出力済み。
  pr_publish_claude_status "$pr_number" "$sha" "$result" "$target_url" || true
  return 0
}
