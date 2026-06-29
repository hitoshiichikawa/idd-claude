#!/usr/bin/env bash
# auto-merge-disarm.sh — arm 済み auto-merge を terminal ラベル遷移時に取り消す processor（#434）
#
# 用途:
#   `auto-merge` / `auto-merge-design` processor が `gh pr merge --auto` で arm した PR
#   （`autoMergeRequest != null`）が、その後 `claude-failed` / `needs-decisions` といった
#   terminal ラベルへ遷移しても disarm されず、必須 status checks が全 green に到達した
#   瞬間に「失敗確定済み PR」が誤って merge されてしまう不具合（Defect A / #434）を解消する。
#   本 processor は毎サイクル GitHub を直接クエリして「arm 済み かつ terminal ラベル付き かつ
#   open」な PR を列挙し、`gh pr merge --disable-auto` で native auto-merge を取り消す。
#   実 merge を行わず、arm の取り消し（autoMergeRequest を null へ戻す）のみを行う。
#
#   関数 prefix は本 module 専用の `amx_`（auto-merge disarm / 既存 am_ / amm_ / amd_ と非衝突）。
#
#   - amx_log / amx_warn / amx_error    : auto-merge-disarm 専用ロガー
#   - amx_resolve_gate_enabled          : opt-in gate 判定（AUTO_MERGE_ENABLED OR
#                                         AUTO_MERGE_DESIGN_ENABLED の相乗り。詳細は関数コメント）
#   - amx_should_disarm_for_pr          : 1 PR が disarm 対象か判定（純粋関数）
#   - amx_disarm_pr                     : 1 PR に対し `gh pr merge --disable-auto` を実行
#   - process_auto_merge_disarm         : サイクルあたりの entry point
#
# 配置先:
#   $HOME/bin/modules/auto-merge-disarm.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$AUTO_MERGE_ENABLED / $AUTO_MERGE_DESIGN_ENABLED /
#     $AUTO_MERGE_DISARM_MAX_PRS / $AUTO_MERGE_GIT_TIMEOUT / $AUTO_MERGE_HEAD_PATTERN /
#     $AUTO_MERGE_DESIGN_HEAD_PATTERN / $LABEL_FAILED / $LABEL_NEEDS_DECISIONS / $REPO）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - `full_auto_enabled` 関数（#348）は本体に定義済み（AND 二重 opt-in の片側）。
#   - 外部 CLI: gh / jq。
#
# 後方互換性 (#434 / NFR 1.1, 1.2):
#   - opt-in gate（FULL_AUTO_ENABLED AND (AUTO_MERGE_ENABLED OR AUTO_MERGE_DESIGN_ENABLED)）が
#     成立しない場合、`process_auto_merge_disarm` は gh API ゼロ呼び出しで早期 return し、
#     本不具合修正導入前と完全に同一の挙動（no-op）を保つ。
#   - gate を arm 側（auto-merge / auto-merge-design）に相乗りさせることで、arm が起きない
#     環境では disarm も no-op になり、新規 env gate を増やさずに後方互換を満たす。
#
# セットアップ参照先:
#   README.md（「オプション機能一覧」節 / Auto-Merge Disarm Processor 節） / install.sh（配置ロジック）

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Auto-Merge Disarm Processor (#434)
#   FULL_AUTO_ENABLED AND (AUTO_MERGE_ENABLED OR AUTO_MERGE_DESIGN_ENABLED) の opt-in 下で、
#   arm 済み（autoMergeRequest != null）かつ terminal ラベル（claude-failed / needs-decisions）
#   付きの open PR の native auto-merge を `gh pr merge --disable-auto` で取り消す。
#   gate OFF / 非対象 PR では完全 no-op で本不具合修正導入前と等価（Req 1.5, 2.3 / NFR 1.1）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ロガー: 既存 am_log / amm_log と同形式の `[YYYY-MM-DD HH:MM:SS] [$REPO] auto-merge-disarm:` 形式。
amx_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-disarm: $*"
}
amx_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-disarm: WARN: $*" >&2
}
amx_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-disarm: ERROR: $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# amx_resolve_gate_enabled: 本 processor の opt-in gate を判定する（NFR 1.1, 1.2）。
#
#   gate = FULL_AUTO_ENABLED AND (AUTO_MERGE_ENABLED OR AUTO_MERGE_DESIGN_ENABLED)
#
#   設計判断（gate の OR 拡張 / #434）:
#     arm は #352 Auto-Merge（impl PR / AUTO_MERGE_ENABLED）と #354 Design Auto-Merge
#     （design PR / AUTO_MERGE_DESIGN_ENABLED）の双方で起きうる。どちらの arm 源で arm された
#     PR も disarm 対象に含めるため、gate は両 arm 源の OR を取る。どちらの arm 源も無効なら
#     arm 自体が起きないため、disarm も完全 no-op で後方互換（NFR 1.1）。
#     さらに #348 kill switch（FULL_AUTO_ENABLED）との AND を取り、kill switch OFF では一切
#     発火しない（arm 側と同じ二重 opt-in セマンティクス）。
#
#   値正規化: `AUTO_MERGE_ENABLED` / `AUTO_MERGE_DESIGN_ENABLED` は `=true` 厳密一致のみ ON。
#     未設定 / 空 / `false` / `0` / `True` / `TRUE` / `1` / `on` / `yes` / typo 等はすべて
#     OFF として扱う（安全側 / NFR 1.1）。FULL_AUTO_ENABLED は full_auto_enabled に委譲。
#
#   戻り値: 0 = gate ON / 1 = OFF
#   副作用: なし（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
amx_resolve_gate_enabled() {
  # #348 kill switch（AND の片側）
  if ! full_auto_enabled; then
    return 1
  fi
  # arm 源の OR（どちらかの arm が有効なら disarm 対象になりうる）
  case "${AUTO_MERGE_ENABLED:-false}" in
    true) return 0 ;;
  esac
  case "${AUTO_MERGE_DESIGN_ENABLED:-false}" in
    true) return 0 ;;
  esac
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# amx_should_disarm_for_pr: 1 PR が disarm 対象か判定する（Req 1.1〜1.3, 1.5 / Req 2.1, 2.2）。
#
#   入力: $1 = pr_json（gh pr list が返す 1 要素 JSON）
#   戻り値:
#     0 : disarm 対象（arm 済み かつ terminal ラベル付き かつ open）
#     1 : 対象外（未 arm / terminal ラベル無し / open でない）
#   副作用: なし（純粋関数）
#
#   判定条件（すべて満たすとき true）:
#     - state == OPEN（既に merge / close 済みは対象外 / Req 2.2）
#     - autoMergeRequest != null（arm 済み。未 arm は対象外 / Req 2.1 no-op の前提）
#     - claude-failed または needs-decisions ラベルを持つ（terminal / Req 1.1〜1.3）
#       → terminal ラベルが無い arm 済み PR は disarm しない（Req 1.5）
# ─────────────────────────────────────────────────────────────────────────────
amx_should_disarm_for_pr() {
  local pr_json="$1"

  # Req 2.2: open でない（merged / closed）PR は対象外
  local pr_state
  pr_state=$(echo "$pr_json" | jq -r '.state // ""')
  if [ "$pr_state" != "OPEN" ]; then
    return 1
  fi

  # Req 2.1 / 1.x: 未 arm（autoMergeRequest == null）は対象外（no-op の前提条件）
  local auto_merge_req
  auto_merge_req=$(echo "$pr_json" | jq -r '.autoMergeRequest // empty')
  if [ -z "$auto_merge_req" ] || [ "$auto_merge_req" = "null" ]; then
    return 1
  fi

  # Req 1.1, 1.2, 1.3: terminal ラベル（claude-failed / needs-decisions）のいずれかを持つ
  if echo "$pr_json" | jq -e --arg l "$LABEL_FAILED" \
      '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
    return 0
  fi
  if echo "$pr_json" | jq -e --arg l "$LABEL_NEEDS_DECISIONS" \
      '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
    return 0
  fi

  # Req 1.5: arm 済みだが terminal ラベル無し → disarm しない
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# amx_disarm_pr: 1 PR に対し `gh pr merge --disable-auto` を実行して native auto-merge を
#   取り消す（Req 1.1〜1.3 / Req 2.4 fail-open）。
#
#   入力: $1 = pr_number（数値検証する）
#         $2 = head_ref（観測ログ用 / 任意）
#         $3 = pr_url（観測ログ用 / 任意）
#   戻り値:
#     0 : disarm 呼び出し成功（log に disarmed 行を出力 / NFR 3.1）
#     1 : disarm 呼び出し失敗 or PR 番号不正（WARN 1 行を残してパイプライン継続 / Req 2.4）
#   副作用: gh pr merge --disable-auto API 呼び出し
#
#   冪等性: 既に未 arm の PR は amx_should_disarm_for_pr が false で除外され本関数は呼ばれない
#     （Req 2.1）。万一 disable-auto を二重に打っても GitHub 側で no-op 相当（副作用最小）。
# ─────────────────────────────────────────────────────────────────────────────
amx_disarm_pr() {
  local pr_number="$1"
  local head_ref="${2:-}"
  local pr_url="${3:-}"

  # NFR 2.1: PR 番号は数値のみ（URL / gh 引数として使う直前に検証）
  if ! echo "$pr_number" | grep -qE '^[0-9]+$'; then
    amx_warn "PR number '${pr_number}' は数値ではないため disarm を skip"
    return 1
  fi

  # Req 1.x: `gh pr merge --disable-auto <PR>` で arm を取り消す
  # NFR 2.2: `--` でオプション解釈打ち切り（PR 番号は数値だが安全側で統一）
  local stderr_file
  stderr_file=$(mktemp 2>/dev/null || echo "/tmp/amx-disarm-stderr-$$")
  local rc=0
  timeout "$AUTO_MERGE_GIT_TIMEOUT" \
    gh pr merge --repo "$REPO" --disable-auto -- "$pr_number" \
      >/dev/null 2>"$stderr_file" || rc=$?

  if [ "$rc" -eq 0 ]; then
    # NFR 3.1: 成功時の log line（PR 番号 / 動作 disarmed / head branch）
    amx_log "PR #${pr_number}: auto-merge disarmed (terminal label present) head=${head_ref} url=${pr_url}"
    rm -f "$stderr_file" 2>/dev/null || true
    return 0
  fi

  # Req 2.4: disarm 失敗は WARN 1 行を残して fail-open（パイプライン継続）。silent fail させない。
  local stderr_tail=""
  if [ -f "$stderr_file" ]; then
    stderr_tail="$(tr '\n' ' ' <"$stderr_file" 2>/dev/null | tail -c 500)"
  fi
  amx_warn "PR #${pr_number}: auto-merge disarm failed head=${head_ref} url=${pr_url} stderr=${stderr_tail}"
  rm -f "$stderr_file" 2>/dev/null || true
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# process_auto_merge_disarm: サイクルあたりの entry point。
#   1. gate を判定（FULL_AUTO AND (AUTO_MERGE OR AUTO_MERGE_DESIGN)）。OFF なら早期 return
#      （gh API ゼロ呼び出し / NFR 1.1）
#   2. open PR を gh pr list で取得（GitHub 直接クエリ。pending state dir に依存しない /
#      Req 1.4）。head pattern は impl / design 双方を含めてクライアント側 jq でフィルタ
#      （人間が手書きした PR を除外）
#   3. 各 PR について amx_should_disarm_for_pr → amx_disarm_pr
#      1 件失敗で全体を止めない（Req 2.5）
#   4. サマリ 1 行を出力（NFR 3.1）。対象 0 件は過剰ログを出さない（NFR 3.2）
#
#   Req 1.x, 2.x / NFR 1.x, 2.x, 3.x
# ─────────────────────────────────────────────────────────────────────────────
process_auto_merge_disarm() {
  # NFR 1.1, 1.2: gate OFF（kill switch / 両 arm 源 OFF）→ 早期 return（gh API ゼロ呼び出し）。
  # arm 側（process_auto_merge / process_auto_merge_design）が suppression ログを出すため、
  # 本 processor からは gate OFF 時の追加ログを出さない（NFR 3.2 / 過剰ログ抑止）。
  if ! amx_resolve_gate_enabled; then
    return 0
  fi

  # 走査件数上限（残りは次回サイクルに持ち越し / NFR 3.x）。数値以外は既定 10 に丸める。
  local max_prs="${AUTO_MERGE_DISARM_MAX_PRS:-10}"
  if ! [[ "$max_prs" =~ ^[0-9]+$ ]] || [ "$max_prs" -le 0 ]; then
    max_prs=10
  fi

  # Req 1.4: GitHub を直接クエリして open PR を取得（pending state dir には依存しない）。
  #   - state:open のみ取得。terminal ラベル / arm 有無は client 側 jq で判定する
  #     （server-side の -label フィルタを使うと「arm 済み かつ terminal」の AND が
  #      表現しづらく、autoMergeRequest は server-side filter 不可のため client 側で扱う）。
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$AUTO_MERGE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --json number,headRefName,labels,autoMergeRequest,url,state,isDraft,headRepositoryOwner \
      --limit 100 2>/dev/null); then
    amx_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # head pattern によるクライアント側フィルタ（人間が手書きした PR を除外）+ fork 除外。
  # impl / design 双方の arm 源を disarm 対象に含めるため、両 head pattern の OR でフィルタ。
  # NFR 2.3: 未信頼値（pattern / owner）は jq --arg で渡す。
  prs_json=$(echo "$prs_json" | jq \
    --arg impl_pattern "$AUTO_MERGE_HEAD_PATTERN" \
    --arg design_pattern "$AUTO_MERGE_DESIGN_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select((.headRefName | test($impl_pattern)) or (.headRefName | test($design_pattern)))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]' 2>/dev/null || echo '[]')

  local total
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)

  # 対象候補を amx_should_disarm_for_pr で絞り込む（disarm 対象のみ列挙）。
  local target_iter
  target_iter=$(echo "$prs_json" | jq -c '.[]' 2>/dev/null || echo "")

  local disarmed_count=0
  local failed_count=0
  local checked=0

  if [ -n "$target_iter" ]; then
    while IFS= read -r pr_json; do
      [ -n "$pr_json" ] || continue
      if [ "$checked" -ge "$max_prs" ]; then
        amx_log "上限 ${max_prs} に到達したため残りを次サイクルへ持ち越し"
        break
      fi

      # disarm 対象でなければ skip（gh 呼び出しなし / Req 1.5, 2.1, 2.2）
      if ! amx_should_disarm_for_pr "$pr_json"; then
        continue
      fi
      checked=$((checked + 1))

      local pr_number head_ref pr_url
      pr_number=$(echo "$pr_json" | jq -r '.number')
      head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
      pr_url=$(echo "$pr_json"    | jq -r '.url')

      # NFR 2.1: PR 番号は数値のみ
      if ! echo "$pr_number" | grep -qE '^[0-9]+$'; then
        amx_warn "PR number '${pr_number}' は数値ではないため disarm を skip (url=${pr_url})"
        failed_count=$((failed_count + 1))
        continue
      fi

      # Req 2.5: 1 件失敗で残りを中断しない
      if amx_disarm_pr "$pr_number" "$head_ref" "$pr_url"; then
        disarmed_count=$((disarmed_count + 1))
      else
        failed_count=$((failed_count + 1))
      fi
    done <<< "$target_iter"
  fi

  # NFR 3.2: 対象 0 件のときは過剰ログを出さず、サマリ 1 行のみに留める。
  if [ "$disarmed_count" -eq 0 ] && [ "$failed_count" -eq 0 ]; then
    amx_log "サマリ: disarmed=0, failed=0 (open候補=${total})"
    return 0
  fi

  amx_log "サマリ: disarmed=${disarmed_count}, failed=${failed_count} (open候補=${total})"
  return 0
}
