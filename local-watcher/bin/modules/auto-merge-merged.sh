#!/usr/bin/env bash
# auto-merge-merged.sh — auto-merge 経路で armed された PR の実 merge 完了検知 + Slack 通知（#388）
#
# 用途:
#   `auto-merge` / `auto-merge-design` processor が `gh pr merge --auto` で armed
#   した PR を pending state file に積み、後続サイクルで `gh pr view` の
#   `state=MERGED` 観測時に **「merge 完了」** を表す Slack 通知（event_type=
#   `auto-merge-merged` / `auto-merge-design-merged`）を 1 度だけ送信する補助 processor。
#   armed 通知（`result=armed`）と merged 通知（`result=merged`）を Slack 上で分離
#   することで、運用者が「armed のまま停滞している PR」と「実際に merge された PR」を
#   区別できるようにする（Issue #388 Req 1.x / 2.x）。
#
#   - amm_log / amm_warn / amm_error  : auto-merge-merged 専用ロガー
#   - amm_resolve_gate_enabled        : SLACK_NOTIFY_MERGED_ENABLED env 値の正規化 + 判定
#   - amm_state_dir                   : pending state ファイルの配置先（純粋関数）
#   - amm_state_path                  : 1 PR の state file 絶対パス（純粋関数）
#   - amm_save_pending                : armed 成功時に pending state を atomic write
#   - amm_remove_pending              : merged 通知発火後 / closed 観測後に state file 削除
#   - amm_list_pending_pr_numbers     : pending state file 一覧から PR 番号配列を返す
#   - amm_check_one_pending           : 1 件の pending を `gh pr view` で merged 判定
#   - process_auto_merge_merged       : サイクルあたりの entry point
#
# 配置先:
#   $HOME/bin/modules/auto-merge-merged.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$SLACK_NOTIFY_ENABLED / $SLACK_NOTIFY_MERGED_ENABLED /
#     $AUTO_MERGE_MERGED_STATE_DIR / $AUTO_MERGE_MERGED_MAX_CHECKS /
#     $AUTO_MERGE_MERGED_GH_TIMEOUT / $REPO / $REPO_SLUG）は本体冒頭の Config ブロックで
#     定義済み。bash の遅延束縛で呼び出し時に解決される。
#   - 外部 CLI: gh / jq / mktemp / mv / ls / rm（NFR 3.1 で curl / jq 以外を増やさない方針に整合）。
#
# 後方互換性 (Issue #388 / NFR 4.1):
#   - SLACK_NOTIFY_ENABLED=false / 未設定では、`amm_save_pending` を含むすべての
#     副作用関数が外部副作用ゼロで return する（state file も書かない）。
#   - SLACK_NOTIFY_ENABLED=true かつ SLACK_NOTIFY_MERGED_ENABLED が =true 厳密一致以外
#     なら、`amm_save_pending` は呼ばれた時点で何もせず return し、merged 通知も
#     発火しない（armed 通知のみ既存挙動 + 文面変更で発火する）。
#
# セットアップ参照先:
#   README.md「Slack 通知 emitter」節 / docs/specs/388-fix-slack-notify-auto-merge-result-succe/

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ロガー（既存 sn_log / am_log と同形式の 3 段 prefix）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
amm_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-merged: $*"
}
amm_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-merged: WARN: $*" >&2
}
amm_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-merged: ERROR: $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# amm_resolve_gate_enabled: 本 processor の AND 二重 opt-in を判定する（Req 3.1, 3.5 / NFR 4.1）
#
#   - SLACK_NOTIFY_ENABLED が `=true` 厳密一致でない場合 → OFF（Slack 通知 emitter 自体 OFF）
#   - SLACK_NOTIFY_MERGED_ENABLED が `=true` 厳密一致でない場合 → OFF
#     （merged 通知＝新規外部副作用は独自 gate で opt-in / 後方互換）
#   その他（未設定 / 空 / `True` / `1` / `on` / `yes` / typo / 前後空白）はすべて
#   安全側 OFF として扱う（NFR 1.1, 4.1）。
#
#   戻り値: 0 = gate ON / 1 = OFF
#   副作用: なし（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
amm_resolve_gate_enabled() {
  case "${SLACK_NOTIFY_ENABLED:-false}" in
    true) : ;;
    *)    return 1 ;;
  esac
  case "${SLACK_NOTIFY_MERGED_ENABLED:-false}" in
    true) return 0 ;;
    *)    return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# amm_state_dir: pending state ファイルの配置先を返す（CLAUDE.md §6 準拠 / NFR 4.4）
#
#   既定: $AUTO_MERGE_MERGED_STATE_DIR
#   呼出側 stub から override 可能（テスト用）
#
#   Stdout: 絶対パス
#   Returns: 0（常に）
# ─────────────────────────────────────────────────────────────────────────────
amm_state_dir() {
  printf '%s' "${AUTO_MERGE_MERGED_STATE_DIR:-$HOME/.issue-watcher/auto-merge-pending/${REPO_SLUG:-default}}"
}

# ─────────────────────────────────────────────────────────────────────────────
# amm_state_path: 1 PR の pending state ファイル絶対パスを返す（純粋関数）
#
#   Args: $1 = PR number（数値）
#   Stdout: 絶対パス
#   Returns: 0（常に）
# ─────────────────────────────────────────────────────────────────────────────
amm_state_path() {
  local pr_number="$1"
  local dir
  dir=$(amm_state_dir)
  printf '%s/pr-%s.json' "$dir" "$pr_number"
}

# ─────────────────────────────────────────────────────────────────────────────
# amm_save_pending: armed 成功直後に呼ばれる pending state 書き込み（Req 2.1, 2.2 / NFR 1.1）
#
#   Args:
#     $1 pr_number   : 数値（^[0-9]+$）
#     $2 event_type  : "auto-merge-merged" | "auto-merge-design-merged"
#     $3 head_ref    : head branch（観測ログ用 / 任意）
#     $4 head_sha    : armed 時点の head SHA（観測ログ用 / 任意）
#     $5 pr_url      : GitHub PR URL（merged 通知時に再利用）
#
#   後方互換 / NFR 4.1:
#     - amm_resolve_gate_enabled で OFF と判定された場合は副作用なしで return 0
#     - PR 番号が数値でない場合は WARN 1 行 + return 0（fail-open）
#     - mkdir / mktemp / mv の失敗は WARN + return 0（パイプライン伝播禁止）
#
#   副作用:
#     - mkdir -p $(amm_state_dir)
#     - atomic write（mktemp → mv -f）で 1 PR 分の state file を作る
#
#   Returns: 0（常に / fail-open）
# ─────────────────────────────────────────────────────────────────────────────
amm_save_pending() {
  local pr_number="${1:-}"
  local event_type="${2:-}"
  local head_ref="${3:-}"
  local head_sha="${4:-}"
  local pr_url="${5:-}"

  # gate OFF なら何もせず return（state file も書かない / NFR 4.1）
  if ! amm_resolve_gate_enabled; then
    return 0
  fi

  # PR 番号は数値のみ
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    amm_warn "amm_save_pending: PR number '$(printf '%s' "$pr_number" | tr -cd '[:alnum:]_-' | head -c 32)' は数値ではないため skip"
    return 0
  fi

  # event_type の enum 検証（armed 通知側との対称性を保つ）
  case "$event_type" in
    auto-merge-merged|auto-merge-design-merged) : ;;
    *)
      amm_warn "amm_save_pending: 不正な event_type=$(printf '%s' "$event_type" | tr -cd '[:alnum:]_-' | head -c 32) (PR #${pr_number})"
      return 0
      ;;
  esac

  local dir state_file
  dir=$(amm_state_dir)
  state_file=$(amm_state_path "$pr_number")

  if ! mkdir -p "$dir" 2>/dev/null; then
    amm_warn "amm_save_pending: mkdir -p \"$dir\" 失敗 (PR #${pr_number})"
    return 0
  fi

  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # state JSON 組み立て（すべて jq --arg / --argjson で sanitize / NFR 3.1 準拠）
  local payload
  if ! payload=$(jq -n -c \
      --argjson pr "$pr_number" \
      --arg event_type "$event_type" \
      --arg head_ref "$head_ref" \
      --arg head_sha "$head_sha" \
      --arg url "$pr_url" \
      --arg armed_at "$now_iso" \
      '{
        pr: $pr,
        event_type: $event_type,
        head_ref: $head_ref,
        head_sha: $head_sha,
        url: $url,
        armed_at: $armed_at
      }' 2>/dev/null); then
    amm_warn "amm_save_pending: jq による state 整形に失敗 (PR #${pr_number})"
    return 0
  fi

  # atomic write: 同一 dir に temp file → mv -f で rename
  local tmp_file
  if ! tmp_file=$(mktemp "${state_file}.XXXXXX" 2>/dev/null); then
    amm_warn "amm_save_pending: mktemp 失敗 (PR #${pr_number})"
    return 0
  fi
  if ! printf '%s\n' "$payload" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    amm_warn "amm_save_pending: temp file 書き込み失敗 (PR #${pr_number})"
    return 0
  fi
  if ! mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    rm -f "$tmp_file"
    amm_warn "amm_save_pending: atomic rename 失敗 (PR #${pr_number})"
    return 0
  fi

  amm_log "PR #${pr_number}: pending registered for merged-completion check (event=${event_type})"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# amm_remove_pending: pending state file を削除する（idempotency / Req 2.3, NFR 1.2）
#
#   Args: $1 = PR number
#   副作用: state file を 1 件削除（不在なら no-op）
#   Returns: 0（常に / fail-open）
# ─────────────────────────────────────────────────────────────────────────────
amm_remove_pending() {
  local pr_number="${1:-}"
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  local state_file
  state_file=$(amm_state_path "$pr_number")
  rm -f "$state_file" 2>/dev/null || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# amm_list_pending_pr_numbers: pending state file から PR 番号一覧を列挙する
#
#   Stdout: PR 番号を 1 行 1 件で（順不同。空なら何も出力しない）
#   Returns: 0（常に）
#
#   実装メモ:
#     - file 名（`pr-<N>.json`）から PR 番号を抽出する（jq 不要 / NFR 1.2）
#     - state dir が存在しない場合は何も出さずに return（gate OFF 環境で発生）
# ─────────────────────────────────────────────────────────────────────────────
amm_list_pending_pr_numbers() {
  local dir
  dir=$(amm_state_dir)
  [ -d "$dir" ] || return 0
  # ls の結果を grep で `pr-<N>.json` パターンに絞り、N を抽出
  local f base num
  for f in "$dir"/pr-*.json; do
    [ -f "$f" ] || continue
    base=$(basename -- "$f")
    # `pr-<N>.json` から <N> を抽出
    num="${base#pr-}"
    num="${num%.json}"
    # 数値以外は無視（防御）
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$num"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# amm_check_one_pending: 1 件の pending PR を `gh pr view` で観測し、必要なら通知 + 削除
#
#   Args: $1 = PR number
#   戻り値:
#     0 : merged 通知を送って state 削除（または closed-without-merge で state 削除）
#         または PR 観測失敗（次サイクルでリトライ）
#     1 : gate OFF で skip（呼出側で握り潰す前提）
#   副作用:
#     - gh pr view 1 回呼び出し（NFR 3.2 上限管理は呼出側 process_auto_merge_merged 側で実施）
#     - merged の場合: sn_notify 1 回 + state file 削除
#     - closed の場合: state file 削除（通知なし）
#     - open の場合: 何もしない
#
#   Req 2.1〜2.5 / NFR 1.2 / NFR 4.2:
#     - state=MERGED かつ mergedAt が空でない場合のみ merged 通知（Req 2.1, 2.2, NFR 4.2）
#     - state=CLOSED（merged でない）→ state 削除のみ（人間が close した PR / Req 2.4 同等）
#     - state=OPEN → state 維持（次サイクル）
#     - gh pr view 失敗 → state 維持（次サイクルで再試行 / NFR 4.2）
# ─────────────────────────────────────────────────────────────────────────────
amm_check_one_pending() {
  local pr_number="${1:-}"

  if ! amm_resolve_gate_enabled; then
    return 1
  fi
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    amm_warn "amm_check_one_pending: PR number が数値ではない: $(printf '%s' "$pr_number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 0
  fi

  local state_file
  state_file=$(amm_state_path "$pr_number")
  if [ ! -f "$state_file" ]; then
    # 既に削除済み / 競合 → 何もしない
    return 0
  fi

  # state file から event_type / url を取り出す
  local saved_event_type saved_url
  saved_event_type=$(jq -r '.event_type // ""' "$state_file" 2>/dev/null || echo "")
  saved_url=$(jq -r '.url // ""' "$state_file" 2>/dev/null || echo "")
  case "$saved_event_type" in
    auto-merge-merged|auto-merge-design-merged) : ;;
    *)
      # state file 破損 / 想定外 event_type → 削除して次へ
      amm_warn "amm_check_one_pending: PR #${pr_number} の state file が破損または不明な event_type=$(printf '%s' "$saved_event_type" | tr -cd '[:alnum:]_-' | head -c 32) (削除)"
      amm_remove_pending "$pr_number"
      return 0
    ;;
  esac

  # `gh pr view` で PR 状態を取得
  local gh_timeout="${AUTO_MERGE_MERGED_GH_TIMEOUT:-60}"
  if ! [[ "$gh_timeout" =~ ^[0-9]+$ ]] || [ "$gh_timeout" -le 0 ]; then
    gh_timeout=60
  fi
  local pr_json
  if ! pr_json=$(timeout "$gh_timeout" gh pr view "$pr_number" \
      --repo "$REPO" \
      --json state,mergedAt,mergeCommit,url 2>/dev/null); then
    # gh 観測失敗 → state 維持で次サイクル再試行（NFR 4.2 / 偽陽性禁止）
    amm_warn "amm_check_one_pending: PR #${pr_number} の gh pr view 取得失敗（次サイクルで再試行）"
    return 0
  fi

  local pr_state merged_at
  pr_state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null || echo "")
  merged_at=$(printf '%s' "$pr_json" | jq -r '.mergedAt // ""' 2>/dev/null || echo "")

  case "$pr_state" in
    MERGED)
      # mergedAt が空でないことを確認（Req 2.1 / NFR 4.2: 偽陽性禁止）
      if [ -z "$merged_at" ] || [ "$merged_at" = "null" ]; then
        # MERGED 表記だが mergedAt が空 → 次サイクルで再試行
        amm_warn "amm_check_one_pending: PR #${pr_number} state=MERGED だが mergedAt が空（次サイクル再試行）"
        return 0
      fi
      # state file の url を優先（armed 時点の値）。空なら gh から取った値を使う。
      local notify_url="$saved_url"
      if [ -z "$notify_url" ]; then
        notify_url=$(printf '%s' "$pr_json" | jq -r '.url // ""' 2>/dev/null || echo "")
      fi
      amm_log "PR #${pr_number}: merged detected (event=${saved_event_type}, mergedAt=${merged_at})"
      # Slack 通知（fail-open / 失敗してもパイプライン継続）。
      sn_notify "$saved_event_type" "$pr_number" "$notify_url" merged "merged via auto-merge at ${merged_at}" || true
      # 通知発火後に state file を削除（Req 2.3 / NFR 1.1, 1.2）
      amm_remove_pending "$pr_number"
      ;;
    CLOSED)
      # merge されずに close された PR は通知せず state を削除（Req 2.4 / NFR 4.2）
      amm_log "PR #${pr_number}: closed without merge (pending state cleaned up)"
      amm_remove_pending "$pr_number"
      ;;
    OPEN|"")
      # 未 merge → state 維持（次サイクル）。空は gh JSON の欠落で OPEN と等価扱い
      ;;
    *)
      # 想定外 state → 維持しつつ WARN
      amm_warn "amm_check_one_pending: PR #${pr_number} 未対応 state=$(printf '%s' "$pr_state" | tr -cd '[:alnum:]_-' | head -c 32)"
      ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_auto_merge_merged: サイクルあたりの entry point
#
#   1. amm_resolve_gate_enabled で OFF なら早期 return（gh API ゼロ呼び出し / NFR 4.1）
#   2. pending state file 一覧を列挙
#   3. AUTO_MERGE_MERGED_MAX_CHECKS（既定 50）件まで上限を取り、各々を amm_check_one_pending
#   4. サマリ 1 行を出す
#
#   Req 2.1〜2.5 / NFR 1.1 / NFR 3.2
# ─────────────────────────────────────────────────────────────────────────────
process_auto_merge_merged() {
  # gate OFF（未 opt-in / SLACK_NOTIFY_ENABLED OFF など）→ 早期 return + 1 行 informational log
  if ! amm_resolve_gate_enabled; then
    return 0
  fi

  local max_checks="${AUTO_MERGE_MERGED_MAX_CHECKS:-50}"
  if ! [[ "$max_checks" =~ ^[0-9]+$ ]] || [ "$max_checks" -le 0 ]; then
    max_checks=50
  fi

  local pending_list
  pending_list=$(amm_list_pending_pr_numbers)
  local total=0
  if [ -n "$pending_list" ]; then
    total=$(printf '%s\n' "$pending_list" | wc -l | tr -d ' ')
  fi
  if [ "$total" -eq 0 ]; then
    return 0
  fi

  amm_log "サイクル開始 (pending=${total}, max_checks=${max_checks})"

  local checked=0
  local pr_number
  while IFS= read -r pr_number; do
    [ -n "$pr_number" ] || continue
    if [ "$checked" -ge "$max_checks" ]; then
      amm_log "上限 ${max_checks} に到達したため残り $((total - checked)) 件を次サイクルへ持ち越し"
      break
    fi
    amm_check_one_pending "$pr_number" || true
    checked=$((checked + 1))
  done <<< "$pending_list"

  amm_log "サマリ: checked=${checked}, pending_total=${total}"
  return 0
}
