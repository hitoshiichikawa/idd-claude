#!/usr/bin/env bash
# api-rate-guard.sh — GitHub API rate limit の削減・耐性強化モジュール（#521）
#
# 用途:
#   watcher の 1 cron tick（サイクル）における GitHub API rate limit（core / graphql /
#   search バケット）の消費削減と枯渇耐性を集約する単一モジュール。5 機能を束ねる:
#     Req2 snapshot : grl_snapshot_init / _active / _prs / _issues /
#                     grl_pr_snapshot_or_live / grl_issue_snapshot_or_live
#                     （サイクル冒頭で PR/Issue 超集合を各 1 回取得し file 共有）
#     Req3 bucket   : grl_buckets_log（cycle 終端に core/graphql/search を 1 行ログ）
#     Req4 degrade  : grl_buckets_refresh / grl_degrade_should_run（残量閾値割れで非必須 skip）
#     Req5 retry    : grl_retry_label_op（状態遷移系ラベル操作の rate-limit 限定リトライ）
#     Req6 REST     : grl_rest_prs_for_head（per-branch PR 存在確認を REST core へ逃がす）
#
# prefix:
#   grl_（GitHub Rate Limit）。Claude Max quota（rate_limit_event / quota-aware.sh の
#   `qa_` / #66・#104）とは別物のため、ログ prefix は `gh-rate-limit:`、env prefix は
#   `GH_API_` に統一して用語混同を避ける。
#
# 配置先:
#   $HOME/bin/modules/api-rate-guard.sh（install.sh が local-watcher/bin/modules/ から配置）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#     `set -euo pipefail` は本体側で宣言済みのため、本モジュールは関数定義のみを持ち
#     トップレベル副作用（代入・実行）を持たない（module loader 規約 / CLAUDE.md §1）。
#   - ロガー grl_log / grl_warn / grl_error は core_utils.sh に定義（本体より前に source）。
#   - グローバル変数（$REPO / $REPO_SLUG / $LABEL_TRIGGER / $GH_API_*）は
#     watcher-config.sh が本体 source 前に定義・正規化済み。
#   - モジュールグローバル: GRL_SNAPSHOT_STATUS（active/inactive）/ GRL_BUCKET_* を
#     grl_snapshot_init / grl_buckets_refresh が代入する（単一 writer = flock 済み main）。
#   - 外部 CLI: gh / jq / date / mktemp / mv / cat / timeout。
#   - すべての新挙動は対応 gate（GH_API_*_ENABLED）が `true` 厳密一致のときのみ発火し、
#     それ以外（未設定 / 不正値 / 取得失敗）は従来の個別取得・従来 mutation・従来 GraphQL へ
#     透過フォールバックする（fail-safe / NFR 2.1）。
#
# セットアップ参照先:
#   README.md「オプション機能一覧」/ docs/specs/521-feat-watcher-github-api-rate-limit/

# ─────────────────────────────────────────────────────────────────────────────
# Req 2: サイクル内スナップショット共有
# ─────────────────────────────────────────────────────────────────────────────

# 超集合の --json フィールド union（design「等価性ルール」節）。参加 processor は
# 超集合を client jq で自 processor の server search 条件へ絞り込む。
# PR: 全 open PR 全件（--search なし）を 1 回取得。
# Issue: open ∧ auto-dev（picked/claimed/needs-quota-wait は auto-dev を保持する部分集合）。
grl_snapshot_pr_fields() {
  echo "number,title,headRefName,headRefOid,baseRefName,isDraft,mergeable,mergeStateStatus,reviewDecision,labels,url,headRepositoryOwner,autoMergeRequest"
}
grl_snapshot_issue_fields() {
  # design Issue union（number,title,body,url,labels,author）に加え、stale-pickup-reaper
  # （Inventory #13 参加）が必須とする updatedAt を含めて真の超集合にする（#521 確認事項参照）。
  echo "number,title,body,url,labels,author,updatedAt"
}

# snapshot ディレクトリの絶対パス（config 既定は $HOME/.issue-watcher/api-snapshot/$REPO_SLUG）。
grl_snapshot_dir() {
  echo "${GH_API_SNAPSHOT_DIR:-$HOME/.issue-watcher/api-snapshot/$REPO_SLUG}"
}

# $1=書き込み先パス / $2=内容。同一ディレクトリ内 mktemp→mv で atomic 書き込み。
# rc: 0=成功 / 1=失敗（呼び出し元で active=off へフォールバック）。
grl_atomic_write() {
  local dest="$1" content="$2"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# サイクル冒頭で PR/Issue 超集合を各 1 回取得し file へ atomic 書き込みする。
# 成功で GRL_SNAPSHOT_STATUS=active、gate off / 取得失敗は inactive（従来の個別取得へ
# フォールバックさせる / Req 2.5, 2.6 / NFR 2.1）。
# rc: 常に 0（失敗も 0 = fail-safe でサイクルを中断しない）。
grl_snapshot_init() {
  # gate off / 未設定 / 不正値は no-op（active=off のまま / Req 1.1, 1.2, 1.3）
  if [ "${GH_API_SNAPSHOT_ENABLED:-false}" != "true" ]; then
    GRL_SNAPSHOT_STATUS="inactive"
    return 0
  fi
  local dir
  dir="$(grl_snapshot_dir)"
  if ! mkdir -p "$dir" 2>/dev/null; then
    grl_warn "snapshot ディレクトリ作成に失敗（個別取得へフォールバック / Req 2.5）: $dir"
    GRL_SNAPSHOT_STATUS="inactive"
    return 0
  fi
  local timeout_s="${GH_API_SNAPSHOT_GH_TIMEOUT:-60}"
  local prs_json="" issues_json=""
  # PR 超集合: 全 open PR（--search なし）。各参加 processor は client jq で絞る。
  if ! prs_json=$(timeout "$timeout_s" gh pr list \
      --repo "$REPO" \
      --state open \
      --json "$(grl_snapshot_pr_fields)" \
      --limit "${GH_API_SNAPSHOT_PR_LIMIT:-100}" 2>/dev/null); then
    grl_warn "PR 超集合の取得に失敗（個別取得へフォールバック / Req 2.5, 2.6）"
    GRL_SNAPSHOT_STATUS="inactive"
    return 0
  fi
  # Issue 超集合: open ∧ auto-dev（LABEL_TRIGGER）。参加 Issue processor の対象集合は
  # (open ∧ auto-dev) の部分集合（design List Fetch Inventory #11〜#14）。
  if ! issues_json=$(timeout "$timeout_s" gh issue list \
      --repo "$REPO" \
      --state open \
      --label "$LABEL_TRIGGER" \
      --json "$(grl_snapshot_issue_fields)" \
      --limit "${GH_API_SNAPSHOT_ISSUE_LIMIT:-100}" 2>/dev/null); then
    grl_warn "Issue 超集合の取得に失敗（個別取得へフォールバック / Req 2.5, 2.6）"
    GRL_SNAPSHOT_STATUS="inactive"
    return 0
  fi
  if ! grl_atomic_write "$dir/prs.json" "$prs_json" \
    || ! grl_atomic_write "$dir/issues.json" "$issues_json"; then
    grl_warn "snapshot ファイル書き込みに失敗（個別取得へフォールバック / Req 2.5）"
    GRL_SNAPSHOT_STATUS="inactive"
    return 0
  fi
  GRL_SNAPSHOT_STATUS="active"
  local pr_n issue_n
  pr_n=$(printf '%s' "$prs_json" | jq 'length' 2>/dev/null || echo "?")
  issue_n=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo "?")
  grl_log "snapshot 取得完了 PR=${pr_n} Issue=${issue_n} dir=$dir"
  return 0
}

# 当サイクルの snapshot が有効か。
# rc: 0=有効（gate on かつ取得成功）/ 1=無効（gate off or 取得失敗）。
grl_snapshot_active() {
  [ "${GH_API_SNAPSHOT_ENABLED:-false}" = "true" ] \
    && [ "${GRL_SNAPSHOT_STATUS:-inactive}" = "active" ]
}

# PR / Issue 超集合 JSON 配列を stdout へ返す（active 時のみ意味を持つ）。
grl_snapshot_prs() {
  cat "$(grl_snapshot_dir)/prs.json" 2>/dev/null
}
grl_snapshot_issues() {
  cat "$(grl_snapshot_dir)/issues.json" 2>/dev/null
}

# 参加 processor 用ラッパ（PR）。active なら超集合を返し caller が client jq で絞る。
# 非 active（gate off / 取得失敗）なら live 引数で従来 gh pr list を実行（byte 等価）。
# $1=timeout $2=search（空なら --search を付けない）$3=jsonfields $4=limit → stdout PR JSON
grl_pr_snapshot_or_live() {
  local timeout_s="$1" search="$2" fields="$3" limit="$4"
  if grl_snapshot_active; then
    grl_snapshot_prs
    return 0
  fi
  if [ -n "$search" ]; then
    timeout "$timeout_s" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "$search" \
      --json "$fields" \
      --limit "$limit" 2>/dev/null
  else
    timeout "$timeout_s" gh pr list \
      --repo "$REPO" \
      --state open \
      --json "$fields" \
      --limit "$limit" 2>/dev/null
  fi
}

# 参加 processor 用ラッパ（Issue）。active なら超集合を返し caller が client jq で絞る。
# 非 active なら live 引数で従来 gh issue list を実行。
# $1=timeout（空なら timeout ラッパを付けない = 元々 timeout 無しの consumer 用）
# $2=search（空なら --search を付けない）$3=jsonfields $4=limit → stdout Issue JSON
# 元々 timeout / --search を付けていなかった consumer（quota-aware / path-overlap /
# dependency-resolver）に対しても gate off の live 経路を等価に保つため、空値時は当該
# フラグ / timeout ラッパを省略する。
grl_issue_snapshot_or_live() {
  local timeout_s="$1" search="$2" fields="$3" limit="$4"
  if grl_snapshot_active; then
    grl_snapshot_issues
    return 0
  fi
  local -a cmd=(gh issue list --repo "$REPO" --state open)
  [ -n "$search" ] && cmd+=(--search "$search")
  cmd+=(--json "$fields" --limit "$limit")
  if [ -n "$timeout_s" ]; then
    timeout "$timeout_s" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Req 3 / 4: バケット別 rate limit の可視化・縮退用残量取得
# ─────────────────────────────────────────────────────────────────────────────

# `gh api rate_limit`（プライマリ rate limit を消費しない参照経路 / Req 3.2）で core /
# graphql / search バケットの remaining・limit をモジュールグローバルへ取り込む。
# BUCKET_LOG / DEGRADE のいずれも無効なら新規 API 呼び出しゼロで即 return（NFR 1.1）。
# 取得 / パース失敗は warn + GRL_BUCKET_STATUS=unavailable で継続（Req 3.4 / NFR 2.1）。
# rc: 常に 0（fail-safe）。
grl_buckets_refresh() {
  if [ "${GH_API_BUCKET_LOG_ENABLED:-false}" != "true" ] \
    && [ "${GH_API_DEGRADE_ENABLED:-false}" != "true" ]; then
    GRL_BUCKET_STATUS="disabled"
    return 0
  fi
  local json
  if ! json=$(gh api rate_limit 2>/dev/null); then
    grl_warn "rate_limit の取得に失敗（バケット可視化 / 縮退は当サイクル無効化して継続 / Req 3.4, NFR 2.1）"
    GRL_BUCKET_STATUS="unavailable"
    return 0
  fi
  local parsed
  parsed=$(printf '%s' "$json" | jq -r '
    [ (.resources.core.remaining // "?"), (.resources.core.limit // "?"),
      (.resources.graphql.remaining // "?"), (.resources.graphql.limit // "?"),
      (.resources.search.remaining // "?"), (.resources.search.limit // "?") ]
    | @tsv' 2>/dev/null)
  if [ -z "$parsed" ]; then
    grl_warn "rate_limit のパースに失敗（バケット可視化 / 縮退は当サイクル無効化して継続 / Req 3.4）"
    GRL_BUCKET_STATUS="unavailable"
    return 0
  fi
  IFS=$'\t' read -r GRL_BUCKET_CORE_REMAINING GRL_BUCKET_CORE_LIMIT \
    GRL_BUCKET_GRAPHQL_REMAINING GRL_BUCKET_GRAPHQL_LIMIT \
    GRL_BUCKET_SEARCH_REMAINING GRL_BUCKET_SEARCH_LIMIT <<< "$parsed"
  GRL_BUCKET_STATUS="ok"
  return 0
}

# cycle 終端に core / graphql / search の残量・上限を 1 行の固定書式でログ出力する（Req 3.1,
# 3.3）。grep 可能な固定書式: `gh-rate-limit: core=<r>/<l> graphql=<r>/<l> search=<r>/<l>`。
# gate off は no-op、残量取得失敗は warn + 継続（Req 3.4）。
# rc: 常に 0。
grl_buckets_log() {
  if [ "${GH_API_BUCKET_LOG_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  # cycle 終端の残量を反映するため再取得する（rate_limit は非消費 / Req 3.2）。
  grl_buckets_refresh
  if [ "${GRL_BUCKET_STATUS:-}" != "ok" ]; then
    grl_warn "バケット残量を取得できず可視化ログを出力できません（Req 3.4）"
    return 0
  fi
  grl_log "core=${GRL_BUCKET_CORE_REMAINING}/${GRL_BUCKET_CORE_LIMIT} graphql=${GRL_BUCKET_GRAPHQL_REMAINING}/${GRL_BUCKET_GRAPHQL_LIMIT} search=${GRL_BUCKET_SEARCH_REMAINING}/${GRL_BUCKET_SEARCH_LIMIT}"
  return 0
}

# 非必須プロセッサ call site の縮退 gate。graphql バケット残量が閾値を下回ったら skip
# （rc=1）+ WARN（bucket・残量・閾値を含む / Req 4.1, 4.2, 4.5 / NFR 4.2）。
# gate off / 残量未取得 / 残量が非整数のときは常に実行（rc=0 / 安全側 / Req 4.6 / NFR 2.2）。
# essential プロセッサは呼び出し側で本 gate を通さないため常に実行される（Req 4.3）。
# Args: $1 = プロセッサ名（skip ログに記録）
# rc: 0=実行してよい / 1=当サイクルは skip
grl_degrade_should_run() {
  local name="$1"
  # gate off は常に実行（従来挙動 / Req 4.6）
  if [ "${GH_API_DEGRADE_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  # 残量が取得できていない（bucket 取得失敗等）→ 安全側で実行（必須処理を守る / NFR 2.2）
  if [ "${GRL_BUCKET_STATUS:-}" != "ok" ]; then
    return 0
  fi
  local remaining="${GRL_BUCKET_GRAPHQL_REMAINING:-}"
  local threshold="${GH_API_DEGRADE_GRAPHQL_THRESHOLD:-500}"
  # 残量が非整数（"?" 等）→ 判定不能なので安全側で実行
  case "$remaining" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$remaining" -lt "$threshold" ]; then
    # 閾値割れ → WARN + skip。skip ログに processor 名・bucket・残量・閾値を含める
    # （Req 4.1 WARN / Req 4.5 skip 根拠 / NFR 4.2）。
    grl_warn "skip processor=$name reason=degrade bucket=graphql remaining=$remaining threshold=$threshold"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Req 5: 状態遷移系ラベル操作の限定リトライ
# ─────────────────────────────────────────────────────────────────────────────

# resumable-return 系の `gh issue edit`（LABEL_PICKED 除去等）を rate-limit 起因失敗時のみ
# 有限回リトライするラッパ。gate off は 1 回だけ実行（従来挙動 / gh 出力抑止 / rc をそのまま
# 返す = byte 等価 / NFR 1.1）。gate on 時、rate-limit 文言を検出したときのみ
# GH_API_STATE_RETRY_MAX_ATTEMPTS まで GH_API_STATE_RETRY_SLEEP 秒 backoff 再試行する。
# 非 rate-limit 失敗は再試行せず即返す（不要な二次消費回避 / Req 5.2）。上限到達でも Issue は
# LABEL_PICKED を残置したまま最終 rc を返し次 tick で再評価される（孤児化しない / Req 5.4）。
# holder からのラベル誤除去等は発生させない（既存 gh 引数の rc を変えず回数のみ増やす / Req 5.5）。
# Args: $1=issue 番号 / $@(2..)=gh issue edit の引数（--repo ... --remove-label ... 等）
# rc: 最終 gh の rc（成功 0）
grl_retry_label_op() {
  local issue="$1"
  shift
  # gate off → 1 回だけ実行（従来挙動 / gh の stdout/stderr は従来同様抑止 / Req 5 gate off）
  if [ "${GH_API_STATE_RETRY_ENABLED:-false}" != "true" ]; then
    gh issue edit "$issue" "$@" >/dev/null 2>&1
    return $?
  fi
  # op 記述（--remove-label / --add-label 値から compact に組み立て、ログの grep 性を高める）
  local op="" prev="" a
  for a in "$@"; do
    case "$prev" in
      --remove-label) op="${op:+$op,}-${a}" ;;
      --add-label)    op="${op:+$op,}+${a}" ;;
    esac
    prev="$a"
  done
  [ -z "$op" ] && op="label-edit"
  local max="${GH_API_STATE_RETRY_MAX_ATTEMPTS:-3}"
  local sleep_s="${GH_API_STATE_RETRY_SLEEP:-2}"
  local attempt=1 rc=0 err=""
  while :; do
    err=$(gh issue edit "$issue" "$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    # rate-limit 起因でなければ即返す（二次消費回避 / Req 5.2）
    if ! printf '%s' "$err" | grep -qiE 'rate.?limit|RATE_LIMITED|HTTP 429|too many requests'; then
      return "$rc"
    fi
    if [ "$attempt" -ge "$max" ]; then
      # 上限到達 → 最終 rc を返す（label 残置で次 tick 再評価 / 孤児化しない / Req 5.4）
      grl_warn "retry issue=#$issue op=$op attempt=$attempt/$max 上限到達（label 残置で次 tick 再評価）"
      return "$rc"
    fi
    # 再試行ログ（Req 5.6: issue 番号・操作種別・試行回数）
    grl_log "retry issue=#$issue op=$op attempt=$attempt/$max"
    sleep "$sleep_s" 2>/dev/null || true
    attempt=$((attempt + 1))
  done
}
