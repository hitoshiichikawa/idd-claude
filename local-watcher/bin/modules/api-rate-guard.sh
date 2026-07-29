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
  echo "number,title,body,url,labels,author"
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
# $1=timeout $2=search $3=jsonfields $4=limit → stdout Issue JSON
grl_issue_snapshot_or_live() {
  local timeout_s="$1" search="$2" fields="$3" limit="$4"
  if grl_snapshot_active; then
    grl_snapshot_issues
    return 0
  fi
  if [ -n "$search" ]; then
    timeout "$timeout_s" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "$search" \
      --json "$fields" \
      --limit "$limit" 2>/dev/null
  else
    timeout "$timeout_s" gh issue list \
      --repo "$REPO" \
      --state open \
      --json "$fields" \
      --limit "$limit" 2>/dev/null
  fi
}
