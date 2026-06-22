#!/usr/bin/env bash
# auto-merge-design.sh — watcher の Design Auto-Merge 制御プロセッサモジュール
#
# 用途:
#   設計 PR（head が `^claude/issue-.*-design` パターン、draft でない、
#   `mergeable=MERGEABLE`、`claude-failed` / `needs-decisions` / `needs-iteration`
#   ラベル不付与）に対して **GitHub ネイティブの auto-merge** を
#   `gh pr merge --auto --squash --delete-branch` で有効化し、必須 status checks
#   （CI + `codex-review` + `claude-review`）が全 green に到達したタイミングで
#   GitHub 側に squash merge + branch 削除を委ねる。
#   watcher 自体は直接 branch を merge せず、merge コマンドの「有効化呼び出し」のみを
#   行う（実 merge / branch 削除は GitHub の auto-merge state machine 任せ）。
#
#   実装 PR 用 `auto-merge.sh` (#352) と完全に対称設計で、env / 関数 prefix / log
#   prefix を独立に分離している（CLAUDE.md §1 / §2 / Issue #354 設計判断）。
#
#   - amd_log / amd_warn / amd_error      : auto-merge-design 専用ロガー
#   - amd_resolve_gate_enabled            : AUTO_MERGE_DESIGN_ENABLED env 値の正規化 + 判定
#   - amd_should_enable_for_pr            : 1 PR が design auto-merge 有効化の対象か判定
#   - amd_enable_auto_merge_for_pr        : 1 PR に対し `gh pr merge --auto --squash --delete-branch` 実行
#   - process_auto_merge_design           : サイクルあたりの entry point
#
# 配置先:
#   $HOME/bin/modules/auto-merge-design.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$AUTO_MERGE_DESIGN_ENABLED / $AUTO_MERGE_DESIGN_MAX_PRS /
#     $AUTO_MERGE_DESIGN_GIT_TIMEOUT / $AUTO_MERGE_DESIGN_HEAD_PATTERN /
#     $LABEL_FAILED / $LABEL_NEEDS_DECISIONS / $LABEL_NEEDS_ITERATION / $REPO）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - `full_auto_enabled` 関数（#348）は本体に定義済み（AND 二重 opt-in の片側）。
#   - 外部 CLI: gh / jq。
#
# セットアップ参照先:
#   README.md（「オプション機能一覧」節 / `AUTO_MERGE_DESIGN_ENABLED`） / install.sh（配置ロジック）

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Design Auto-Merge Processor (#354)
#   `AUTO_MERGE_DESIGN_ENABLED=true` AND `FULL_AUTO_ENABLED=true` の二重 opt-in 下で、
#   設計 PR に GitHub ネイティブの auto-merge を有効化する。実 merge / branch
#   削除は GitHub auto-merge state machine 任せ（watcher は polling しない）。
#   gate OFF / 非対象 PR では完全 no-op で本機能導入前と等価（Req 1.5, 8.1, NFR 1.1）。
#   実装 PR 用 Auto-Merge Processor (#352) とは head pattern で server-side 分離
#   され、相互に独立な opt-in / 観測ログを持つ（Req 6.7 / Issue #354 設計判断）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ロガー: 既存 mq_log / ar_log / pp_log / am_log と同じ
# `[YYYY-MM-DD HH:MM:SS] [$REPO] auto-merge-design:` 形式。`auto-merge:` (#352) と
# `auto-merge-design:` (#354) で運用者が grep 分離可能にし、観測性を確保する
# （Issue #354 設計判断）。
amd_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: $*"
}
amd_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: WARN: $*" >&2
}
amd_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-merge-design: ERROR: $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# amd_resolve_gate_enabled: AUTO_MERGE_DESIGN_ENABLED env 値を `=true` 厳密一致で
#   判定。未設定 / 空 / `false` / `0` / `True` / `TRUE` / `1` / `on` / `yes` /
#   typo 等はすべて OFF として扱う（Req 1.3, NFR 1.1 安全側）。
#
#   戻り値: 0 = AUTO_MERGE_DESIGN_ENABLED gate ON / 1 = OFF
#   副作用: なし（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
amd_resolve_gate_enabled() {
  case "${AUTO_MERGE_DESIGN_ENABLED:-false}" in
    true) return 0 ;;
    *)    return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# amd_should_enable_for_pr: 1 PR が design auto-merge 有効化の対象か判定（Req 2.x / Req 6.x）。
#
#   入力: $1 = pr_json（gh pr list が返す 1 要素 JSON）
#   戻り値:
#     0  : 全条件を満たす → 呼び出し側で `gh pr merge --auto` を実行
#     1  : 対象外（draft / pattern mismatch / ラベル要件不一致 / mergeable=CONFLICTING/UNKNOWN 等）
#     2  : 既に auto-merge enabled 済み（冪等 skip / Req 6.6）
#   副作用: なし（純粋関数）
#
#   Req 2.1 (head pattern `^claude/issue-.*-design`), 2.2 (not draft),
#   2.3 (mergeable=MERGEABLE), 2.4 (CONFLICTING skip), 2.5 (UNKNOWN skip),
#   2.6 (impl PR pattern との非干渉), 6.2 (claude-failed exclude),
#   6.3 (needs-decisions exclude), 6.4 (needs-iteration exclude),
#   6.6 (already enabled skip)
#
#   注: 設計 PR 用には `ready-for-review` ラベル必須チェックは行わない（design PR
#   にはこのラベルを付与しないため / Issue #354 設計判断、#352 との差分）。
# ─────────────────────────────────────────────────────────────────────────────
amd_should_enable_for_pr() {
  local pr_json="$1"

  # NFR 1.4: head branch pattern の最終確認（server-side filter の保険）。
  # head pattern による client-side filter で impl PR (`^claude/issue-.*-impl`) は
  # `^claude/issue-.*-design` パターン不一致により自動的に排他される（Req 2.6, 6.7）。
  local head_ref
  head_ref=$(echo "$pr_json" | jq -r '.headRefName // ""')
  if ! echo "$head_ref" | grep -qE -- "$AUTO_MERGE_DESIGN_HEAD_PATTERN"; then
    return 1
  fi

  # Req 2.2: draft 除外
  local is_draft
  is_draft=$(echo "$pr_json" | jq -r '.isDraft')
  if [ "$is_draft" = "true" ]; then
    return 1
  fi

  # Req 6.2: claude-failed 除外
  if echo "$pr_json" | jq -e --arg l "$LABEL_FAILED" \
      '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
    return 1
  fi

  # Req 6.3: needs-decisions 除外
  if echo "$pr_json" | jq -e --arg l "$LABEL_NEEDS_DECISIONS" \
      '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
    return 1
  fi

  # Req 6.4: needs-iteration 除外（設計 PR iteration 中は merge 有効化しない）
  if echo "$pr_json" | jq -e --arg l "$LABEL_NEEDS_ITERATION" \
      '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1; then
    return 1
  fi

  # Req 2.3 / 2.4 / 2.5: mergeable=MERGEABLE のみ通す（CONFLICTING / UNKNOWN は skip）
  local mergeable
  mergeable=$(echo "$pr_json" | jq -r '.mergeable')
  if [ "$mergeable" != "MERGEABLE" ]; then
    return 1
  fi

  # Req 6.6: 既に auto-merge enabled 済みなら skip（冪等性 / 重複 enable 抑止）。
  # autoMergeRequest は enable 済みなら object、未 enable なら null（GraphQL の autoMergeRequest）。
  local auto_merge_req
  auto_merge_req=$(echo "$pr_json" | jq -r '.autoMergeRequest // empty')
  if [ -n "$auto_merge_req" ] && [ "$auto_merge_req" != "null" ]; then
    return 2
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# amd_enable_auto_merge_for_pr: 1 PR に対し `gh pr merge --auto --squash --delete-branch`
#   を実行する。実 merge / branch 削除は GitHub 側に委ね、本関数は GitHub の
#   auto-merge state machine に enable 指示を出すのみ。
#
#   入力: $1 = pr_number（数値検証済み）
#         $2 = head_ref（観測ログ用）
#         $3 = head_sha（観測ログ用）
#         $4 = pr_url（観測ログ用）
#   戻り値:
#     0 : enable 呼び出し成功（log に成功行を出力）
#     1 : enable 呼び出し失敗（log に WARN を出力。呼び出し側はパイプライン継続）
#   副作用: gh pr merge --auto API 呼び出し
#
#   Req 3.1 (squash + delete-branch), 3.2 (no direct branch merge),
#   7.1〜7.5 (failure observability), 9.1 (success log line)
# ─────────────────────────────────────────────────────────────────────────────
amd_enable_auto_merge_for_pr() {
  local pr_number="$1"
  local head_ref="$2"
  local head_sha="$3"
  local pr_url="$4"

  # NFR 1.3: PR 番号は数値のみ
  if ! echo "$pr_number" | grep -qE '^[0-9]+$'; then
    amd_warn "PR number '${pr_number}' は数値ではないため auto-merge を skip"
    return 1
  fi

  # Req 3.1: `gh pr merge --auto --squash --delete-branch <PR>`
  # NFR 1.2: `--` でオプション解釈打ち切り（PR 番号は数値だが安全側で統一）
  local stderr_file
  stderr_file=$(mktemp 2>/dev/null || echo "/tmp/amd-merge-stderr-$$")
  local rc=0
  timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" \
    gh pr merge --repo "$REPO" --auto --squash --delete-branch -- "$pr_number" \
      >/dev/null 2>"$stderr_file" || rc=$?

  if [ "$rc" -eq 0 ]; then
    # Req 9.1: 成功時の log line（PR 番号 / head sha / head branch / 動作）
    amd_log "PR #${pr_number}: auto-merge enabled (squash, delete-branch) head=${head_ref} sha=${head_sha} url=${pr_url}"
    rm -f "$stderr_file" 2>/dev/null || true
    return 0
  fi

  # Req 7.1, 7.2, 7.5: 失敗種別を WARN log で残す。silent fail させない（Req 7.4）。
  # stderr 内容で network エラーと API エラーをざっくり区別する（best-effort）。
  local stderr_tail=""
  if [ -f "$stderr_file" ]; then
    stderr_tail="$(tr '\n' ' ' <"$stderr_file" 2>/dev/null | tail -c 500)"
  fi
  local error_category="api-error"
  case "$stderr_tail" in
    *"could not resolve host"*|*"network"*|*"timeout"*|*"connection"*)
      error_category="transport-error"
      ;;
    *"branch protection"*|*"not allowed"*|*"not permitted"*|*"auto merge"*disable*|*"Auto merge"*disable*)
      error_category="repo-config-rejected"
      ;;
  esac

  case "$error_category" in
    transport-error)
      # Req 7.2: network / transport error
      amd_warn "PR #${pr_number}: auto-merge enable failed (transport-error) head=${head_ref} url=${pr_url} stderr=${stderr_tail}"
      ;;
    repo-config-rejected)
      # Req 7.5: branch protection misconfig / auto-merge not permitted
      amd_warn "PR #${pr_number}: auto-merge enable rejected by GitHub (repo-config-rejected, branch protection or repo-level auto-merge disabled) head=${head_ref} sha=${head_sha} url=${pr_url} stderr=${stderr_tail}"
      ;;
    *)
      # Req 7.1: 一般 API error
      amd_warn "PR #${pr_number}: auto-merge enable failed (api-error) head=${head_ref} sha=${head_sha} url=${pr_url} stderr=${stderr_tail}"
      ;;
  esac

  rm -f "$stderr_file" 2>/dev/null || true
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# process_auto_merge_design: サイクルあたりの entry point。
#   1. AND 二重 opt-in を判定（Req 1.2, 1.4）。OFF なら早期 return（gh API ゼロ呼び出し）
#   2. 候補 PR を gh pr list で取得（head pattern + label 除外 + draft 除外）
#   3. 各 PR について amd_should_enable_for_pr → amd_enable_auto_merge_for_pr
#   4. サマリ行を 1 件出力
#
#   Req 1.x, 2.x, 3.x, 6.x, 7.x, 8.x, 9.x, NFR 3.x
# ─────────────────────────────────────────────────────────────────────────────
process_auto_merge_design() {
  # Req 1.4: FULL_AUTO_ENABLED OFF（kill switch）→ 早期 return。
  # #348 の既存 suppression ログに委ねるため、本 processor からは log を出さない（Req 9.3）。
  if ! full_auto_enabled; then
    return 0
  fi

  # Req 1.3 / NFR 1.1: AUTO_MERGE_DESIGN_ENABLED が =true 厳密一致以外なら早期 return。
  # Req 9.2: サイクルあたり 1 行の informational suppression ログを出す。
  if ! amd_resolve_gate_enabled; then
    amd_log "suppressed by AUTO_MERGE_DESIGN_ENABLED gate (no-op)"
    return 0
  fi

  amd_log "サイクル開始 (max=${AUTO_MERGE_DESIGN_MAX_PRS}, head_pattern=${AUTO_MERGE_DESIGN_HEAD_PATTERN}, timeout=${AUTO_MERGE_DESIGN_GIT_TIMEOUT}s)"

  # Req 2.1〜2.6: 候補 PR を取得。
  #   - state:open / draft 除外
  #   - claude-failed / needs-decisions / needs-iteration は server-side で除外
  #     （Req 6.2, 6.3, 6.4）
  # GraphQL の autoMergeRequest フィールドを引いて Req 6.6 の冪等判定に使う。
  # 注: 設計 PR には `ready-for-review` ラベルが付かないため、impl 用 (#352) と異なり
  # ラベル必須条件は付与しない（Issue #354 設計判断）。
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$AUTO_MERGE_DESIGN_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\" -draft:true" \
      --json number,headRefName,headRefOid,baseRefName,mergeable,labels,url,isDraft,headRepositoryOwner,autoMergeRequest \
      --limit 50 2>/dev/null); then
    amd_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # Req 2.6 / 6.7 / 8.3: head pattern によるクライアント側フィルタ（impl PR / 人間が
  # 手書きした PR を除外）+ fork 除外。impl PR は `^claude/issue-.*-design` パターン
  # 不一致により自然分離される（二重防御）。
  prs_json=$(echo "$prs_json" | jq \
    --arg pattern "$AUTO_MERGE_DESIGN_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]')

  local total
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$AUTO_MERGE_DESIGN_MAX_PRS" ]; then
    target_count="$AUTO_MERGE_DESIGN_MAX_PRS"
    skipped_overflow=$((total - AUTO_MERGE_DESIGN_MAX_PRS))
    amd_log "対象候補 ${total} 件中、上限 ${AUTO_MERGE_DESIGN_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    amd_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  if [ "$target_count" -eq 0 ]; then
    amd_log "サマリ: enabled=0, skipped=0, already-enabled=0, failed=0, overflow=${skipped_overflow}"
    return 0
  fi

  local enabled_count=0
  local skipped_count=0
  local already_count=0
  local failed_count=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    amd_log "サマリ: enabled=0, skipped=0, already-enabled=0, failed=0, overflow=${skipped_overflow}"
    return 0
  fi

  while IFS= read -r pr_json; do
    local pr_number head_ref head_sha pr_url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    head_sha=$(echo "$pr_json"  | jq -r '.headRefOid // ""')
    pr_url=$(echo "$pr_json"    | jq -r '.url')

    # NFR 1.3: PR 番号は数値のみ
    if ! echo "$pr_number" | grep -qE '^[0-9]+$'; then
      amd_warn "PR number '${pr_number}' は数値ではないため skip (url=${pr_url})"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    local rc=0
    amd_should_enable_for_pr "$pr_json" || rc=$?
    case "$rc" in
      0)
        if amd_enable_auto_merge_for_pr "$pr_number" "$head_ref" "$head_sha" "$pr_url"; then
          enabled_count=$((enabled_count + 1))
        else
          failed_count=$((failed_count + 1))
        fi
        ;;
      2)
        # Req 6.6: 既に enabled 済み → 冪等 skip
        amd_log "PR #${pr_number}: auto-merge already enabled (skip) head=${head_ref} url=${pr_url}"
        already_count=$((already_count + 1))
        ;;
      *)
        # mergeable=CONFLICTING / UNKNOWN / draft / pattern mismatch / ラベル不一致など
        amd_log "PR #${pr_number}: not eligible for auto-merge (skip) head=${head_ref} url=${pr_url}"
        skipped_count=$((skipped_count + 1))
        ;;
    esac
  done <<< "$pr_iter"

  amd_log "サマリ: enabled=${enabled_count}, skipped=${skipped_count}, already-enabled=${already_count}, failed=${failed_count}, overflow=${skipped_overflow}"
}
