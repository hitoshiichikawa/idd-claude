#!/usr/bin/env bash
# design-review-release.sh — Design Review Release Processor モジュール（#40 / #456 切り出し）
#
# 用途:
#   `awaiting-design-review` ラベルが付いた Issue について、リンクされた設計 PR
#   （head branch が `^claude/issue-<N>-design-` 規約）が merged 状態なら、
#   Issue からラベルを除去してステータスコメントを 1 件投稿する processor。
#
#   - drr_already_processed        : hidden marker による既処理判定
#   - drr_find_merged_design_pr    : merged 設計 PR の検出
#   - drr_remove_label_and_comment : ラベル除去 + ステータスコメント投稿
#   - process_design_review_release: サイクルあたりの entry point
#
#   標準機能としてデフォルト有効（#112）。手動でラベルを外す運用に戻したい場合は
#   DESIGN_REVIEW_RELEASE_ENABLED=false を明示する。
#
# 配置先:
#   $HOME/bin/modules/design-review-release.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $DESIGN_REVIEW_RELEASE_ENABLED / $DESIGN_REVIEW_RELEASE_MAX_ISSUES /
#     $DESIGN_REVIEW_RELEASE_HEAD_PATTERN / $DRR_GH_TIMEOUT / $LABEL_AWAITING_DESIGN /
#     $LABEL_FAILED / $LABEL_NEEDS_DECISIONS / $LABEL_NEEDS_ITERATION）は本体冒頭の Config
#     ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - ロガー drr_log / drr_warn / drr_error は modules/core_utils.sh に定義済み（#177 Part 1）。
#   - 外部 CLI: gh / jq。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# 与えられた Issue が、本機能が以前のサイクルで投稿したステータスコメントを既に
# 持っているかを判定する（hidden HTML marker による既処理判定）。
#   入力: $1 = issue_number
#   出力: stdout に "true" or "false"
#   返り値: 0 = 判定成功 / 1 = API エラー or タイムアウト（呼び出し元で WARN）
# AC 4.2 / 4.3 / 4.4 / 5.3 / 5.4
drr_already_processed() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$DRR_GH_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    return 1
  fi
  local marker_re="idd-claude:design-review-release issue=${issue_number}"
  if echo "$comments_json" | jq -e --arg re "$marker_re" \
      '.comments // [] | map(.body // "") | any(test($re))' >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

# 与えられた Issue 番号にリンクされた、head branch が DESIGN_REVIEW_RELEASE_HEAD_PATTERN
# にマッチし、かつ body に `Refs #<issue_number>` を含む merged PR の番号を返す。
# 複数件マッチ時は最大番号 = 最新を採用する。
#   入力: $1 = issue_number
#   出力: stdout に PR 番号、該当無しなら空文字
#   返り値: 0 = 検出 or 該当無し（共に正常） / 1 = API エラー or タイムアウト
# AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6 / 5.3 / 5.4 / NFR 2.2
drr_find_merged_design_pr() {
  local issue_number="$1"
  local prs_json
  # head pattern を server-side クエリで一次絞り込み（in:head + 規約 prefix）。
  # 複数件マッチを許容するため limit=20。
  # 注意（Issue #80）: GitHub の text search はトークン分解（"claude" / "issue" / "${N}" /
  # "design" の各語）で他 Issue 用の merged 設計 PR もヒットさせるため、ここでは候補
  # 取得（noisy）に留め、最終一致判定は後段の jq で issue 番号 fix の strict prefix で行う。
  if ! prs_json=$(timeout "$DRR_GH_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --search "is:pr is:merged claude/issue-${issue_number}-design- in:head" \
      --json number,headRefName,mergedAt \
      --limit 20 2>/dev/null); then
    return 1
  fi

  # Issue #80: head 名を issue 番号で strict 比較する（旧 `^claude/issue-[0-9]+-design-`
  # では他 Issue 用 PR が通過していた）。body の `Refs #N` 検査は cross-reference
  # （Architect が design PR 本文で別 Issue を参照する）と衝突して誤検知の原因に
  # なっていたため drop。head が `claude/issue-${N}-design-<slug>` で始まることを
  # 唯一の同定条件とする。
  # 同 issue 番号の merged 設計 PR が複数ある場合（再 design 等）は、PR 番号最大
  # （= 最新と看做す）を採用。
  local strict_head_prefix="claude/issue-${issue_number}-design-"
  local pr_number
  pr_number=$(echo "$prs_json" | jq -r \
    --arg prefix "$strict_head_prefix" \
    '[(. // [])[]
      | select(.headRefName | startswith($prefix))
      | .number
    ] | sort | last // ""' 2>/dev/null || echo "")
  echo "$pr_number"
  return 0
}

# 確定した除去対象 Issue に対し、`awaiting-design-review` ラベル除去 + ステータス
# コメント投稿を順次実行する。PR 側操作・push・close は一切行わない（NFR 2.1 / 2.3）。
#   入力: $1 = issue_number, $2 = merged_pr_number
#   返り値: 0 = ラベル除去 + コメント投稿 成功 / 1 = いずれかが失敗
# AC 3.1 / 3.2 / 3.3 / 3.4 / 3.5 / 3.6 / 5.3 / 5.4 / 6.7 / 7.6
drr_remove_label_and_comment() {
  local issue_number="$1"
  local merged_pr_number="$2"

  # AC 3.1 / 3.4: ラベル除去。失敗時はコメントを投稿しない。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue edit "$issue_number" \
      --repo "$REPO" \
      --remove-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ラベル除去 API 失敗（タイムアウト or 4xx/5xx）。コメント投稿は skip し、次サイクルで再試行します。"
    return 1
  fi

  # AC 3.2 / 3.3 / 4.3: ステータスコメント本文（末尾に hidden marker を含む）。
  local body
  body=$(cat <<EOF
## 自動: 設計 PR merge を検出

設計 PR #${merged_pr_number} が merged されました。
本 Issue から \`awaiting-design-review\` ラベルを自動除去しました。

次回 cron tick で Developer が **impl-resume モード**で自動起動し、
\`docs/specs/<N>-<slug>/\` 配下の design.md / tasks.md に従って実装 PR を作成します。

---

_本コメントは \`local-watcher/bin/issue-watcher.sh\` の Design Review Release Processor が
投稿しました（#112 以降デフォルト有効。\`DESIGN_REVIEW_RELEASE_ENABLED=false\` で無効化可）。_

<!-- idd-claude:design-review-release issue=${issue_number} pr=${merged_pr_number} -->
EOF
)

  # AC 3.5: コメント投稿失敗時もラベルは除去済み。次サイクルで Issue は impl-resume へ進める。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue comment "$issue_number" \
      --repo "$REPO" \
      --body "$body" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ステータスコメント投稿 API 失敗（ラベルは除去済み、後続 Issue 処理は継続）。"
    return 1
  fi

  return 0
}

# Design Review Release Processor のエントリ関数。
# 1 watcher サイクル内で `awaiting-design-review` 付き Issue を検出し、
# 設計 PR が merged なら ラベル除去 + コメント投稿を順次実行する。
# AC 1.1 / 1.4 / 2.1 / 2.7 / 4.1 / 4.4 / 4.5 / 5.2 / 5.5 / 6.1 / 6.2 / 6.3 / 7.5
process_design_review_release() {
  # AC 1.1 / 1.4 / 7.5: opt-out gate（#112 以降デフォルト有効。無効化時は完全スキップ）
  if [ "$DESIGN_REVIEW_RELEASE_ENABLED" != "true" ]; then
    return 0
  fi

  drr_log "サイクル開始 (max_issues=${DESIGN_REVIEW_RELEASE_MAX_ISSUES}, head_pattern=${DESIGN_REVIEW_RELEASE_HEAD_PATTERN}, timeout=${DRR_GH_TIMEOUT}s)"

  # AC 2.1 / 2.7 / 4.1 / 4.5: server-side filter で `awaiting-design-review` を必須に、
  # `claude-failed` / `needs-decisions` を除外。人間が先に手動除去した Issue は候補に上がらない。
  # Issue #54 Req 1.1 / 5.1: PR 専用ラベル `needs-iteration` が Issue 側に誤付与された
  # ケースは Documentation Set 全体で「PR 適用」と一貫させるため、ここでも候補から除外する。
  local issues_json
  if ! issues_json=$(timeout "$DRR_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\"" \
      --json number,title,url,labels \
      --limit 100 2>/dev/null); then
    drr_warn "候補 Issue 取得 API 失敗（タイムアウト or 4xx/5xx）。本サイクルの Design Review Release Processor は skip。"
    return 0
  fi

  # client-side fail-safe filter: label 配列に `awaiting-design-review` あり、
  # `claude-failed` / `needs-decisions` なし（server-side filter の二重ガード）。
  local filtered_json
  filtered_json=$(echo "$issues_json" | jq -c \
    --arg awaiting "$LABEL_AWAITING_DESIGN" \
    --arg failed "$LABEL_FAILED" \
    --arg needs_decisions "$LABEL_NEEDS_DECISIONS" \
    '[(. // [])[]
      | select((.labels // []) | map(.name) | index($awaiting))
      | select(((.labels // []) | map(.name) | index($failed)) | not)
      | select(((.labels // []) | map(.name) | index($needs_decisions)) | not)
    ]' 2>/dev/null || echo "[]")

  local total
  total=$(echo "$filtered_json" | jq 'length' 2>/dev/null || echo 0)
  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$DESIGN_REVIEW_RELEASE_MAX_ISSUES" ]; then
    target_count="$DESIGN_REVIEW_RELEASE_MAX_ISSUES"
    skipped_overflow=$((total - DESIGN_REVIEW_RELEASE_MAX_ISSUES))
    drr_log "対象候補 ${total} 件中、上限 ${DESIGN_REVIEW_RELEASE_MAX_ISSUES} 件のみ処理（${skipped_overflow} 件は次回持ち越し: overflow=${skipped_overflow}）"
  else
    drr_log "対象候補 ${total} 件、処理対象 ${target_count} 件、overflow=${skipped_overflow}"
  fi

  if [ "$target_count" -eq 0 ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local issue_iter
  issue_iter=$(echo "$filtered_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$issue_iter" ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local removed=0
  local kept=0
  local skipped=0
  local failed=0
  # AC 4.4: 同一サイクル内での重複処理ガード（gh issue list の結果は一意のはずだが念のため）
  local processed_numbers=""

  while IFS= read -r issue_json; do
    [ -z "$issue_json" ] && continue
    local issue_number
    issue_number=$(echo "$issue_json" | jq -r '.number' 2>/dev/null || echo "")
    if [ -z "$issue_number" ] || [ "$issue_number" = "null" ]; then
      drr_warn "Issue 番号の解析に失敗: ${issue_json}"
      failed=$((failed + 1))
      continue
    fi

    # AC 4.4: 同一サイクル内で同一 Issue を 2 回処理しない
    case " $processed_numbers " in
      *" $issue_number "*)
        drr_log "Issue #${issue_number}: 同一サイクル内で既に処理済み、skip"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    processed_numbers="$processed_numbers $issue_number"

    # AC 4.2 / 4.3: 既処理判定（hidden marker チェック）
    local already
    if ! already=$(drr_already_processed "$issue_number"); then
      drr_warn "Issue #${issue_number}: 既処理判定 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ "$already" = "true" ]; then
      drr_log "Issue #${issue_number}: action=skip (already processed)"
      skipped=$((skipped + 1))
      continue
    fi

    # AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6: merged 設計 PR の検出
    local merged_pr_number
    if ! merged_pr_number=$(drr_find_merged_design_pr "$issue_number"); then
      drr_warn "Issue #${issue_number}: PR 検出 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ -z "$merged_pr_number" ]; then
      # AC 2.5 / 2.6: リンク PR 0 件 or merged 0 件 → kept
      drr_log "Issue #${issue_number}: merged-design-pr=none, action=kept"
      kept=$((kept + 1))
      continue
    fi

    # AC 3.1 / 3.2 / 3.3: ラベル除去 + ステータスコメント投稿
    if drr_remove_label_and_comment "$issue_number" "$merged_pr_number"; then
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=label removed + commented"
      removed=$((removed + 1))
    else
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=fail"
      failed=$((failed + 1))
    fi
  done <<< "$issue_iter"

  drr_log "サマリ: removed=${removed}, kept=${kept}, skip=${skipped}, fail=${failed}, overflow=${skipped_overflow}"
  return 0
}
